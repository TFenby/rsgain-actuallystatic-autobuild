# Actually-Static rsgain: Design

Date: 2026-09-18
Status: Approved

## Problem

Upstream [complexlogic/rsgain](https://github.com/complexlogic/rsgain) publishes a
Linux release tarball from a CI job named `Static`. It is not static. Inspecting
the published v3.8 artifact:

```
$ file rsgain
ELF 64-bit LSB pie executable, x86-64, dynamically linked,
interpreter /lib64/ld-linux-x86-64.so.2

$ ldd rsgain
libstdc++.so.6, libm.so.6, libgcc_s.so.1, libpthread.so.0, libc.so.6
```

The job builds every *third-party dependency* as a `.a` through vcpkg, but never
statically links the *toolchain*. The result is a binary that still requires a
host glibc (>= 2.31, since the job pins `debian:bullseye`) and a matching
libstdc++. It cannot run in a `scratch` container, on musl systems, or on
distributions older than the build host.

This project produces the binary that tarball claims to be.

## Approach

Build upstream's source **unmodified** with one additional linker flag:

```
-DCMAKE_EXE_LINKER_FLAGS="-static"
```

No fork, no patches, no vendored dependencies, no musl toolchain. We consume
upstream's tagged source and its own `complexlogic/vcpkg` overlay ports exactly
as upstream's CI does, changing only the final link and the packaging.

### Verified

A probe on 2026-09-18 built upstream v3.8 this way and confirmed:

| Check | Upstream v3.8 | This build |
|---|---|---|
| `file` | `dynamically linked` | `statically linked` |
| `NEEDED` entries | 6 | 0 |
| `INTERP` segment | present | none |
| Runs in `FROM scratch` | no | yes |
| Image size | 45 MB | 9.72 MB |
| Binary size | 2.2 MB | 6.6 MB stripped |

It also passed a functional check: scanned a generated flac and wrote back
`REPLAYGAIN_TRACK_GAIN=3.75 dB`, exercising the statically linked ffmpeg and
TagLib. Version output confirms libebur128 1.2.6, libavformat/avcodec 63.1.101,
libavutil 61.1.101, libswresample 7.1.101, TagLib 2.3.1 are all baked in.

### Build image: trixie, not bullseye

Upstream pins `debian:bullseye` to link against an old glibc for runtime
portability. A static binary does not care which glibc it was built against, so
the pin buys nothing — and bullseye is now EOL with 404ing package mirrors. We
build on `debian:trixie`.

### Rejected alternatives

- **Alpine + system static libraries.** Alpine ships static archives for only
  `inih` and `zlib`; there are no `ffmpeg-static`, `taglib-static`, or
  `libebur128-static` packages. Dead end.
- **musl + hand-built dependency chain.** Works, but means owning ffmpeg's
  configure flags and ~150 lines of build script. Unnecessary now that glibc
  static is proven.
- **zig cc cross-compilation.** Nicer cross-arch story, materially fiddlier with
  ffmpeg via vcpkg. Not needed given native arm64 runners.

## Architecture

### Files

| File | Role |
|---|---|
| `.github/workflows/build.yml` | poll upstream, build matrix, verify, release, push image |
| `verify.sh` | the staticness gate; runnable locally |
| `Dockerfile` | `FROM scratch` |
| `README.md` | what it is, why upstream's is not static |

### Jobs

1. **`check`** — resolves upstream's latest release tag via the GitHub API and
   compares it to this repo's latest release. Outputs `version` and
   `should_build`. A `workflow_dispatch` run bypasses the comparison and builds
   the supplied `ref`.

2. **`build`** — matrix over `ubuntu-latest` (amd64) and `ubuntu-24.04-arm`
   (arm64), each in a `debian:trixie` container. Checks out the upstream tag,
   bootstraps vcpkg, configures with the flag above, builds, runs `verify.sh`,
   packages a tarball, uploads it as a workflow artifact.

3. **`publish`** — needs both matrix legs. Downloads the artifacts, creates the
   GitHub release with both tarballs attached, then uses `docker buildx` to push
   a multi-arch manifest built by `COPY`ing the already-built per-arch binaries
   (no emulation required).

Release and image are published only after *both* architectures pass, so a
half-broken release cannot exist.

### Triggers

Daily cron, plus `workflow_dispatch` with a `ref` input accepting any upstream
tag or branch.

## The verification gate

`verify.sh <binary>` is what earns the repo its name. It runs in CI as a hard
failure and is runnable locally:

1. `readelf -d` reports zero `NEEDED` entries
2. `readelf -l` reports no `INTERP` segment
3. `file` reports `statically linked`, not `dynamically linked`
4. functional smoke test: encode a 1-second flac with the builder's ffmpeg, run
   `rsgain custom -s i` on it, assert `REPLAYGAIN_TRACK_GAIN` is read back

The `build` job runs inside a `debian:trixie` container and so has no Docker
daemon available. The fifth assertion — that the binary runs with no userland at
all — therefore belongs to `publish`, which runs on the runner host: after
`buildx` produces the `scratch` image, `publish` executes `docker run --rm
<image> -v` and fails if it does not print a version. Together the two jobs cover
the same ground the probe did.

The fixture is **generated at build time**, not committed — ffmpeg is already
present in the builder, and this keeps binary files out of the repo.

If upstream or vcpkg ever regresses the link to dynamic, the build fails rather
than silently shipping another mislabelled tarball.

## Artifacts

- `rsgain-<version>-linux-<arch>-static.tar.xz`, containing the binary and
  `presets/` (`default.ini`, `ebur128.ini`, `loudgain.ini`, `no_album.ini`),
  mirroring the upstream tarball layout so it is a drop-in replacement.
- `ghcr.io/tfenby/rsgain-actuallystatic:<version>` and `:latest`, a multi-arch
  `FROM scratch` image with presets at `/usr/share/rsgain/presets`.

Release tags mirror upstream's verbatim (`v3.8`), which lets the `check` job
compare tags directly.

## Relationship to rsgain-static-autobuild

`TFenby/rsgain-static-autobuild` is superseded by this project and has been
archived. It repackaged upstream's dynamically linked binary into a distroless
image; this project builds a genuinely static binary from source, which makes the
older approach redundant.

The repo name is deliberate: "actually static" differentiates these artifacts
from upstream's mislabelled `Static` build, and that distinction is the reason
the project exists. Images publish to `ghcr.io/tfenby/rsgain-actuallystatic`,
matching the repo name.

The old `ghcr.io/tfenby/rsgain` package is left in place and no longer receives
updates. Re-linking that package name to this repo is possible but would silently
change what existing `:latest` pullers receive. The archived repo and its package
are out of scope for implementation — nothing in this project touches them.

## Error handling

Every step fails hard and loudly. No partial releases, no fallbacks:

- upstream tag resolution fails → workflow fails
- configure or build fails → that matrix leg fails, `publish` never runs
- `verify.sh` fails any assertion → that leg fails
- either architecture fails → no release, no image

## Risks

- **arm64 is unverified.** The probe covered amd64 only. The upstream overlay
  ports and ffmpeg's build may need attention on `arm64-linux` (notably `nasm`,
  which is x86-only). First implementation step is to confirm an arm64 build
  before wiring up the rest. If it proves troublesome, the response is to drop
  arm64 from the matrix as a design decision and ship amd64 only — not to let a
  failing leg through at runtime. The no-partial-release rule above is absolute:
  whatever architectures are in the matrix must all pass.
- **Static glibc caveats** (`getaddrinfo`/NSS, `dlopen`) do not apply — rsgain is
  a local file tagger and uses neither. Confirmed by the probe running cleanly in
  `scratch`.
- **Upstream CI drift.** If upstream changes its vcpkg features or overlay ports
  branch, our build breaks visibly at build time, which is the intended behaviour.
