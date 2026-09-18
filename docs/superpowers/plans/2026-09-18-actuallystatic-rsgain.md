# Actually-Static rsgain Autobuild — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish genuinely statically linked rsgain binaries and a `FROM scratch` container image, built automatically from upstream releases.

**Architecture:** Build upstream's unmodified source through vcpkg exactly as upstream's own CI does, adding `-DCMAKE_EXE_LINKER_FLAGS="-static"`. A `verify.sh` gate asserts the result has zero `NEEDED` entries, no `INTERP` segment, and still tags audio correctly — so a regression to dynamic linking fails the build instead of shipping.

**Tech Stack:** GitHub Actions, Docker/buildx, CMake, vcpkg, bash.

**Spec:** `docs/superpowers/specs/2026-09-18-actuallystatic-rsgain-design.md`

## Global Constraints

- Build container image: `debian:trixie`. Never `bullseye` — it is EOL and its mirrors 404.
- Link flag, verbatim: `-DCMAKE_EXE_LINKER_FLAGS="-static"`
- vcpkg pin: `VCPKG_COMMITTISH: a1cae005c39be7b18ba319fced856b68d7276271` (upstream's pin; bump deliberately, never silently)
- vcpkg manifest features, verbatim: `fmt;ffmpeg;libebur128;inih;`
- Overlay ports: repo `complexlogic/vcpkg`, branch `rsgain`
- Upstream repo: `complexlogic/rsgain`
- Triplets: `x64-linux` (amd64), `arm64-linux` (arm64)
- Image name: `ghcr.io/tfenby/rsgain-actuallystatic`
- Presets must land at `/usr/share/rsgain/presets` in the image — that path is compiled into the binary via `CMAKE_INSTALL_PREFIX=/usr`.
- Release tags mirror upstream verbatim (`v3.8`).
- No partial releases: every architecture in the matrix must pass before anything publishes.
- The repo must stay **public** — free native `ubuntu-24.04-arm` runners require it. Already created and public; do not run `gh repo create`.
- `TFenby/rsgain-static-autobuild` is already archived and is strictly out of scope. No task may modify it or its `ghcr.io/tfenby/rsgain` package.

---

### Task 1: The `verify.sh` gate

This is the invariant the whole repo exists to defend, so it gets built and tested first — before any CI exists. It is testable entirely locally against two fixtures you already have.

**Files:**
- Create: `verify.sh`
- Create: `test_verify.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `verify.sh <path-to-binary>` — exit 0 if the binary is actually static and functional, non-zero with a `FAIL:` message on stderr otherwise. Task 3 calls it as `./verify.sh build/rsgain`.

**Fixtures (already on disk, do not commit them):**
- Static (must PASS): `/tmp/claude-1000/-home-tyler-src-rsgain-actuallystatic-autobuild/7528e9e1-2dc3-4f3e-a537-b5e48c5bea0d/scratchpad/out/rsgain`
- Dynamic (must FAIL): `/bin/ls`

- [ ] **Step 1: Write the failing test**

Create `test_verify.sh`:

```bash
#!/usr/bin/env bash
# Tests verify.sh itself: it must REJECT a dynamic binary and ACCEPT a static one.
# Usage: ./test_verify.sh <path-to-known-static-rsgain>
set -uo pipefail

STATIC="${1:?usage: test_verify.sh <path-to-static-rsgain>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
DYNAMIC=/bin/ls
rc=0

# Guard: if the negative fixture is not actually dynamic, the test below proves nothing.
if ! file "$DYNAMIC" | grep -q 'dynamically linked'; then
  echo "SKIP: $DYNAMIC is not dynamically linked; cannot test the negative case" >&2
  exit 77
fi

if "$DIR/verify.sh" "$DYNAMIC" >/dev/null 2>&1; then
  echo "FAIL: verify.sh accepted $DYNAMIC, which is dynamically linked"; rc=1
else
  echo "ok: rejected a dynamic binary"
fi

if "$DIR/verify.sh" "$STATIC" >/dev/null 2>&1; then
  echo "ok: accepted the static binary"
else
  echo "FAIL: verify.sh rejected $STATIC, which should pass"; rc=1
fi

[ $rc -eq 0 ] && echo "PASS: verify.sh behaves correctly"
exit $rc
```

```bash
chmod +x test_verify.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
./test_verify.sh /tmp/claude-1000/-home-tyler-src-rsgain-actuallystatic-autobuild/7528e9e1-2dc3-4f3e-a537-b5e48c5bea0d/scratchpad/out/rsgain
```
Expected: FAIL — both cases error because `verify.sh` does not exist yet (exit 1).

- [ ] **Step 3: Write minimal implementation**

Create `verify.sh`:

```bash
#!/usr/bin/env bash
# Assert a binary is ACTUALLY static -- unlike upstream's "Static" release,
# which is static dependencies wrapped around a dynamic glibc.
set -euo pipefail

BIN="${1:?usage: verify.sh <path-to-rsgain>}"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "$BIN is not an executable file"

# 1. No dynamic dependencies recorded.
needed=$(readelf -d "$BIN" 2>/dev/null | grep -c 'NEEDED' || true)
[ "$needed" -eq 0 ] || fail "$needed NEEDED entries; binary is dynamically linked"

# 2. No program interpreter -- nothing for ld.so to do.
if readelf -l "$BIN" 2>/dev/null | grep -qi 'interpreter'; then
  fail "binary has an INTERP segment; it still needs a dynamic loader"
fi

# 3. file(1) agrees.
file "$BIN" | grep -q 'statically linked' \
  || fail "file(1) does not report 'statically linked': $(file -b "$BIN")"

# 4. It runs.
"$BIN" -v >/dev/null 2>&1 || fail "binary does not execute"

# 5. It actually works: tag a generated flac and read the tag back. This is what
#    proves the statically linked ffmpeg and TagLib are wired up, not just present.
command -v ffmpeg >/dev/null || fail "ffmpeg is required for the functional check"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=1" -c:a flac "$tmp/t.flac"
"$BIN" custom -s i "$tmp/t.flac" >/dev/null
ffmpeg -loglevel error -i "$tmp/t.flac" -f ffmetadata - | grep -q REPLAYGAIN_TRACK_GAIN \
  || fail "no REPLAYGAIN_TRACK_GAIN written; the static ffmpeg/TagLib path is broken"

echo "PASS: $BIN is actually static and functional"
```

```bash
chmod +x verify.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
./test_verify.sh /tmp/claude-1000/-home-tyler-src-rsgain-actuallystatic-autobuild/7528e9e1-2dc3-4f3e-a537-b5e48c5bea0d/scratchpad/out/rsgain
```
Expected: PASS — `ok: rejected a dynamic binary`, `ok: accepted the static binary`, exit 0.

Also confirm it rejects upstream's mislabelled binary, which is the actual adversary:
```bash
./verify.sh /tmp/claude-1000/-home-tyler-src-rsgain-actuallystatic-autobuild/7528e9e1-2dc3-4f3e-a537-b5e48c5bea0d/scratchpad/rsgain-3.8-Linux/rsgain
```
Expected: `FAIL: 5 NEEDED entries; binary is dynamically linked`, exit 1.

- [ ] **Step 5: Commit**

```bash
git add verify.sh test_verify.sh
git commit -m "feat: add verify.sh staticness gate with self-test"
```

---

### Task 2: arm64 CI probe

The single unverified assumption in the design. Retire it on real hardware before building anything on top of it. This task deliberately ships a throwaway workflow — Task 3 replaces it.

**Files:**
- Create: `.github/workflows/probe-arm64.yml` (deleted again in Task 3)

**Interfaces:**
- Consumes: `verify.sh` from Task 1.
- Produces: a yes/no answer on whether `arm64-linux` builds. That answer decides the Task 3 matrix.

- [ ] **Step 1: Confirm the repo is ready**

The repo already exists and `origin` is already configured — do not create it.
Just confirm the preconditions the arm64 probe depends on:

```bash
git remote -v                       # origin -> TFenby/rsgain-actuallystatic-autobuild
gh repo view --json nameWithOwner,visibility -q '.nameWithOwner + " " + .visibility'
```

Expected: `TFenby/rsgain-actuallystatic-autobuild PUBLIC`. Public matters — free
native `ubuntu-24.04-arm` runners are not available to private repos. If it ever
reads `PRIVATE`, stop: the arm64 leg will queue forever rather than fail loudly.

Push the work from Task 1 so the workflow has `verify.sh` to call:

```bash
git push -u origin master
```

- [ ] **Step 2: Write the probe workflow**

Create `.github/workflows/probe-arm64.yml`:

```yaml
name: Probe arm64

on:
  workflow_dispatch:

jobs:
  probe:
    runs-on: ubuntu-24.04-arm
    container:
      image: debian:trixie
    steps:
      - name: Install build dependencies
        run: |
          set -euo pipefail
          apt-get update -qq
          apt-get install -y -qq curl zip unzip tar build-essential git cmake \
            pkg-config python3 binutils ca-certificates file ffmpeg xz-utils

      - name: Checkout this repo
        uses: actions/checkout@v4

      - name: Checkout upstream source
        uses: actions/checkout@v4
        with:
          repository: complexlogic/rsgain
          ref: v3.8
          path: upstream
          fetch-depth: 0

      - name: Checkout vcpkg overlay ports
        uses: actions/checkout@v4
        with:
          repository: complexlogic/vcpkg
          ref: rsgain
          path: overlays

      - name: Bootstrap vcpkg
        run: |
          set -euo pipefail
          git clone https://github.com/microsoft/vcpkg /opt/vcpkg
          git -C /opt/vcpkg checkout a1cae005c39be7b18ba319fced856b68d7276271
          /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics

      - name: Configure
        run: |
          set -euo pipefail
          cmake -S upstream -B build \
            -DCMAKE_TOOLCHAIN_FILE=/opt/vcpkg/scripts/buildsystems/vcpkg.cmake \
            -DVCPKG_TARGET_TRIPLET=arm64-linux \
            -DVCPKG_MANIFEST_FEATURES="fmt;ffmpeg;libebur128;inih;" \
            -DVCPKG_OVERLAY_PORTS=overlays/ports \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/usr \
            -DPACKAGE=TXZ \
            -DSTRIP_BINARY=ON \
            -DCMAKE_EXE_LINKER_FLAGS="-static"

      - name: Build
        run: cmake --build build -j"$(nproc)"

      - name: Verify actually static
        run: ./verify.sh build/rsgain
```

Note: `nasm` is deliberately absent — it is an x86-only assembler and ffmpeg does not need it on arm64. If vcpkg's ffmpeg port demands it anyway, that is exactly the finding this probe exists to surface.

- [ ] **Step 3: Commit and run the probe**

```bash
git add .github/workflows/probe-arm64.yml
git commit -m "ci: add throwaway arm64 feasibility probe"
git push
gh workflow run probe-arm64.yml
sleep 30 && gh run watch
```

- [ ] **Step 4: Record the outcome**

Expected on success: the `Verify actually static` step prints `PASS: build/rsgain is actually static and functional`.

**If it fails**, read the log and classify before reacting:
- ffmpeg port fails on `arm64-linux` → try adding `nasm` back; if the failure is asm-related and unresolvable, drop arm64 from Task 3's matrix and note it in the README. Do not let a failing leg ship.
- Out of disk on the runner → add a cleanup step, not a scope change.
- Timeout → the runner is native, so a timeout indicates a real build problem, not slowness. Investigate rather than raising the limit.

Append the result (pass/fail, and any deviation) to the Risks section of the spec so the decision is recorded where the reasoning lives.

- [ ] **Step 5: Commit the finding**

```bash
git add docs/superpowers/specs/2026-09-18-actuallystatic-rsgain-design.md
git commit -m "docs: record arm64 probe outcome"
git push
```

---

### Task 3: The build workflow

**Files:**
- Create: `.github/workflows/build.yml`
- Delete: `.github/workflows/probe-arm64.yml`

**Interfaces:**
- Consumes: `verify.sh` from Task 1; the arm64 verdict from Task 2.
- Produces: workflow artifacts `tarball-<arch>` (containing `rsgain-<version>-linux-<arch>-static.tar.xz`), `binary-<arch>` (containing the bare `rsgain`), and `presets` (the four `.ini` files). Task 4's `publish` job consumes all three by exactly these names. Also job outputs `check.outputs.version` (e.g. `3.8`) and `check.outputs.ref` (e.g. `v3.8`).

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/build.yml`:

```yaml
name: Build

on:
  schedule:
    - cron: "17 4 * * *"
  workflow_dispatch:
    inputs:
      ref:
        description: "Upstream ref to build (tag or branch). Blank = latest upstream release."
        required: false
        default: ""

permissions:
  contents: write
  packages: write

env:
  UPSTREAM: complexlogic/rsgain
  VCPKG_COMMITTISH: a1cae005c39be7b18ba319fced856b68d7276271

jobs:
  check:
    name: Check for new upstream release
    runs-on: ubuntu-latest
    outputs:
      version: ${{ steps.r.outputs.version }}
      ref: ${{ steps.r.outputs.ref }}
      should_build: ${{ steps.r.outputs.should_build }}
    steps:
      - id: r
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          INPUT_REF="${{ github.event.inputs.ref }}"
          if [ -n "$INPUT_REF" ]; then
            echo "Manual dispatch for $INPUT_REF; skipping the up-to-date check."
            echo "ref=$INPUT_REF"            >> "$GITHUB_OUTPUT"
            echo "version=${INPUT_REF#v}"    >> "$GITHUB_OUTPUT"
            echo "should_build=true"         >> "$GITHUB_OUTPUT"
            exit 0
          fi
          UP=$(gh release view --repo "$UPSTREAM" --json tagName -q .tagName)
          MINE=$(gh release view --repo "${{ github.repository }}" --json tagName -q .tagName 2>/dev/null || echo "")
          echo "upstream=$UP ours=${MINE:-none}"
          echo "ref=$UP"         >> "$GITHUB_OUTPUT"
          echo "version=${UP#v}" >> "$GITHUB_OUTPUT"
          if [ "$UP" = "$MINE" ]; then
            echo "should_build=false" >> "$GITHUB_OUTPUT"
          else
            echo "should_build=true"  >> "$GITHUB_OUTPUT"
          fi

  build:
    name: Build ${{ matrix.arch }}
    needs: check
    if: needs.check.outputs.should_build == 'true'
    strategy:
      fail-fast: false
      matrix:
        include:
          - arch: amd64
            runner: ubuntu-latest
            triplet: x64-linux
            extra_pkgs: nasm
          - arch: arm64
            runner: ubuntu-24.04-arm
            triplet: arm64-linux
            extra_pkgs: ""
    runs-on: ${{ matrix.runner }}
    container:
      image: debian:trixie
    steps:
      - name: Install build dependencies
        run: |
          set -euo pipefail
          apt-get update -qq
          apt-get install -y -qq curl zip unzip tar build-essential git cmake \
            pkg-config python3 binutils ca-certificates file ffmpeg xz-utils \
            ${{ matrix.extra_pkgs }}

      - name: Checkout this repo
        uses: actions/checkout@v4

      - name: Checkout upstream source
        uses: actions/checkout@v4
        with:
          repository: complexlogic/rsgain
          ref: ${{ needs.check.outputs.ref }}
          path: upstream
          fetch-depth: 0

      - name: Checkout vcpkg overlay ports
        uses: actions/checkout@v4
        with:
          repository: complexlogic/vcpkg
          ref: rsgain
          path: overlays

      - name: Bootstrap vcpkg
        run: |
          set -euo pipefail
          git clone https://github.com/microsoft/vcpkg /opt/vcpkg
          git -C /opt/vcpkg checkout "$VCPKG_COMMITTISH"
          /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics

      - name: Configure
        run: |
          set -euo pipefail
          cmake -S upstream -B build \
            -DCMAKE_TOOLCHAIN_FILE=/opt/vcpkg/scripts/buildsystems/vcpkg.cmake \
            -DVCPKG_TARGET_TRIPLET=${{ matrix.triplet }} \
            -DVCPKG_MANIFEST_FEATURES="fmt;ffmpeg;libebur128;inih;" \
            -DVCPKG_OVERLAY_PORTS=overlays/ports \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/usr \
            -DPACKAGE=TXZ \
            -DSTRIP_BINARY=ON \
            -DCMAKE_EXE_LINKER_FLAGS="-static"

      - name: Build
        run: cmake --build build -j"$(nproc)"

      - name: Verify actually static
        run: ./verify.sh build/rsgain

      - name: Package
        run: |
          set -euo pipefail
          V="${{ needs.check.outputs.version }}"
          D="rsgain-$V-linux-${{ matrix.arch }}-static"
          mkdir -p "dist/$D/presets"
          cp build/rsgain "dist/$D/rsgain"
          cp upstream/config/presets/*.ini "dist/$D/presets/"
          cp upstream/LICENSE "dist/$D/LICENSE"
          cp upstream/README.md "dist/$D/README.md"
          tar -C dist -cJf "$D.tar.xz" "$D"
          ls -la "$D.tar.xz"

      - name: Upload tarball
        uses: actions/upload-artifact@v4
        with:
          name: tarball-${{ matrix.arch }}
          path: rsgain-*-linux-${{ matrix.arch }}-static.tar.xz

      - name: Upload bare binary
        uses: actions/upload-artifact@v4
        with:
          name: binary-${{ matrix.arch }}
          path: build/rsgain

      - name: Upload presets
        if: matrix.arch == 'amd64'
        uses: actions/upload-artifact@v4
        with:
          name: presets
          path: upstream/config/presets/*.ini
```

- [ ] **Step 2: Remove the probe workflow**

```bash
git rm .github/workflows/probe-arm64.yml
```

- [ ] **Step 3: Test it**

```bash
git add .github/workflows/build.yml
git commit -m "ci: add build workflow with amd64/arm64 matrix"
git push
gh workflow run build.yml -f ref=v3.8
sleep 30 && gh run watch
```

Expected: `check` outputs `should_build=true`; both `build` legs succeed; `Verify actually static` prints PASS on each; three artifact names appear (`tarball-amd64`, `tarball-arm64`, `binary-amd64`, `binary-arm64`, `presets`).

- [ ] **Step 4: Verify the up-to-date short circuit**

Run the workflow again with no ref, *before* any release exists:
```bash
gh workflow run build.yml
sleep 30 && gh run watch
```
Expected: `should_build=true` (this repo has no releases yet, so `MINE` is empty and differs from upstream). Re-test the `false` path after Task 4 creates a release.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "ci: drop arm64 probe, superseded by build matrix"
git push
```

---

### Task 4: Publish — release and scratch image

**Files:**
- Create: `Dockerfile`
- Modify: `.github/workflows/build.yml` (append the `publish` job)

**Interfaces:**
- Consumes: artifacts `tarball-amd64`, `tarball-arm64`, `binary-amd64`, `binary-arm64`, `presets` from Task 3; outputs `check.outputs.version` and `check.outputs.ref`.
- Produces: a GitHub release tagged `v<version>` with both tarballs attached, and `ghcr.io/tfenby/rsgain-actuallystatic:<version>` + `:latest`.

- [ ] **Step 1: Write the Dockerfile**

Create `Dockerfile`:

```dockerfile
# The binary is actually static, so there is nothing to put underneath it.
FROM scratch
ARG TARGETARCH
COPY rsgain-$TARGETARCH /rsgain
COPY presets /usr/share/rsgain/presets
ENTRYPOINT ["/rsgain"]
```

`TARGETARCH` is supplied automatically by buildx per platform (`amd64`, `arm64`), which is why the staged binaries are named with those exact suffixes. Presets must live at `/usr/share/rsgain/presets` — that path is compiled into the binary by `CMAKE_INSTALL_PREFIX=/usr`, and is how `-p ebur128` resolves.

- [ ] **Step 2: Append the publish job to `.github/workflows/build.yml`**

```yaml
  publish:
    name: Publish release and image
    needs: [check, build]
    runs-on: ubuntu-latest
    env:
      IMAGE: ghcr.io/${{ github.repository_owner }}/rsgain-actuallystatic
    steps:
      - name: Checkout this repo
        uses: actions/checkout@v4

      - name: Download artifacts
        uses: actions/download-artifact@v4
        with:
          path: artifacts

      - name: Stage image build context
        run: |
          set -euo pipefail
          mkdir -p ctx/presets
          cp Dockerfile ctx/Dockerfile
          cp artifacts/binary-amd64/rsgain ctx/rsgain-amd64
          cp artifacts/binary-arm64/rsgain ctx/rsgain-arm64
          cp artifacts/presets/*.ini ctx/presets/
          chmod +x ctx/rsgain-amd64 ctx/rsgain-arm64
          ls -laR ctx

      - name: Set up buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to ghcr.io
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push multi-arch image
        run: |
          set -euo pipefail
          IMAGE_LC="${IMAGE,,}"
          docker buildx build --push \
            --platform linux/amd64,linux/arm64 \
            -t "$IMAGE_LC:${{ needs.check.outputs.version }}" \
            -t "$IMAGE_LC:latest" \
            ctx

      - name: Smoke test the scratch image
        run: |
          set -euo pipefail
          IMAGE_LC="${IMAGE,,}"
          # This is the fifth verify.sh assertion, which cannot run inside the
          # build container: prove the binary runs with no userland at all.
          out=$(docker run --rm "$IMAGE_LC:${{ needs.check.outputs.version }}" -v)
          echo "$out"
          echo "$out" | grep -q "rsgain" || { echo "scratch image did not run"; exit 1; }

      - name: Create release
        env:
          GH_TOKEN: ${{ github.token }}
          REF: ${{ needs.check.outputs.ref }}
          VERSION: ${{ needs.check.outputs.version }}
        run: |
          set -euo pipefail
          IMAGE_LC="${IMAGE,,}"
          # Written to a file rather than inlined: YAML block indentation would
          # otherwise leak into the rendered release notes.
          cat > notes.md <<EOF
          Actually-static build of upstream rsgain $REF.

          Zero \`NEEDED\` entries, no \`INTERP\` segment, runs in \`FROM scratch\`.
          Verified by \`verify.sh\` on every architecture before publishing.

          Container image: \`$IMAGE_LC:$VERSION\`
          EOF
          sed -i 's/^          //' notes.md
          gh release create "$REF" \
            artifacts/tarball-amd64/*.tar.xz \
            artifacts/tarball-arm64/*.tar.xz \
            --title "$REF" \
            --notes-file notes.md
```

Note `${IMAGE,,}` lowercases the owner — ghcr.io rejects uppercase path segments, and the GitHub owner is `TFenby`.

- [ ] **Step 3: Test it**

```bash
git add Dockerfile .github/workflows/build.yml
git commit -m "feat: publish release and multi-arch scratch image"
git push
gh workflow run build.yml -f ref=v3.8
sleep 30 && gh run watch
```

Expected: release `v3.8` exists with two tarballs; the smoke test prints the rsgain version banner from inside a `scratch` container.

- [ ] **Step 4: Verify the published artifacts independently**

```bash
gh release download v3.8 --pattern '*amd64*'
tar xf rsgain-3.8-linux-amd64-static.tar.xz
./verify.sh rsgain-3.8-linux-amd64-static/rsgain
docker run --rm ghcr.io/tfenby/rsgain-actuallystatic:3.8 -v
docker image inspect ghcr.io/tfenby/rsgain-actuallystatic:3.8 --format '{{.Size}}'
```

Expected: `verify.sh` prints PASS on the *downloaded* artifact (not just the CI-internal one), the image runs, and size is roughly 10 MB.

Then confirm the short circuit now works:
```bash
gh workflow run build.yml
sleep 30 && gh run watch
```
Expected: `should_build=false`, `build` and `publish` skipped.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit --allow-empty -m "ci: verified end-to-end release and image publish"
git push
```

---

### Task 5: README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: the published artifacts from Task 4.
- Produces: nothing consumed by later tasks.

**Out of scope:** `TFenby/rsgain-static-autobuild` is already archived. This plan
must not touch that repo or its `ghcr.io/tfenby/rsgain` package in any way — no
README edit, no archive call, no re-linking.

- [ ] **Step 1: Write the README**

Create `README.md`:

```markdown
# rsgain-actuallystatic-autobuild

Statically linked [rsgain](https://github.com/complexlogic/rsgain) builds — for
real this time.

## Why this exists

Upstream publishes a Linux tarball from a CI job named `Static`. It isn't:

```
$ file rsgain            # upstream v3.8
ELF 64-bit LSB pie executable, dynamically linked,
interpreter /lib64/ld-linux-x86-64.so.2
$ ldd rsgain
libstdc++.so.6, libm.so.6, libgcc_s.so.1, libpthread.so.0, libc.so.6
```

Upstream builds its *dependencies* statically but never statically links the
*toolchain*, so the binary still needs a host glibc (>= 2.31) and a matching
libstdc++. It can't run in a `scratch` container or on musl systems.

These builds have zero `NEEDED` entries, no `INTERP` segment, and run anywhere
with a Linux kernel.

## Use it

```bash
docker run --rm -v /path/to/music:/music \
  ghcr.io/tfenby/rsgain-actuallystatic easy /music
docker run --rm -v /path/to/music:/music \
  ghcr.io/tfenby/rsgain-actuallystatic easy -p ebur128 /music
```

The image is `FROM scratch` — around 10 MB, no shell, no libc, nothing but the
binary and its presets. Or grab a tarball from
[Releases](../../releases) and drop the binary anywhere on `$PATH`.

## How it's built

Upstream's source, unmodified, built through vcpkg exactly as upstream's own CI
does, plus one flag:

```
-DCMAKE_EXE_LINKER_FLAGS="-static"
```

No fork, no patches, no vendored dependencies. A daily job checks upstream for a
new release and builds amd64 and arm64 natively.

Every build must pass `./verify.sh`, which asserts zero `NEEDED` entries, no
`INTERP` segment, that `file` reports `statically linked`, and that the binary
actually tags a generated flac correctly. Nothing publishes unless every
architecture passes — so a regression to dynamic linking fails the build instead
of shipping as another mislabelled tarball.

Run it yourself against any rsgain binary:

```bash
./verify.sh /path/to/rsgain
```
```

- [ ] **Step 2: Verify the README's claims are true**

Every factual claim above must hold. Check them rather than trusting the draft:

```bash
# Size claim.
docker image inspect ghcr.io/tfenby/rsgain-actuallystatic:latest --format '{{.Size}}'

# Preset lookup claim -- needs real audio, so generate some. Scanning an empty
# directory proves nothing.
d=$(mktemp -d)
ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=1" -c:a flac "$d/a.flac"
docker run --rm -v "$d:/music" ghcr.io/tfenby/rsgain-actuallystatic easy -p ebur128 /music
ffmpeg -loglevel error -i "$d/a.flac" -f ffmetadata - | grep REPLAYGAIN
rm -rf "$d"
```

Fix any number or command that does not match reality. Do not round a 14 MB image down to "around 10 MB".

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add README"
git push
```

- [ ] **Step 4: Final end-to-end check**

```bash
gh release list
gh workflow list
docker run --rm ghcr.io/tfenby/rsgain-actuallystatic -v
```

Expected: one release, one workflow (`Build` — the probe is gone), and a working image.
