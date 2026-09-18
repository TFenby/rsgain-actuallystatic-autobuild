# rsgain-actuallystatic-autobuild

Statically linked [rsgain](https://github.com/complexlogic/rsgain) builds — for
real this time.

## Why this exists

Upstream publishes a Linux tarball from a CI job named `Static`. It isn't:

```
$ file rsgain            # upstream v3.8
rsgain: ELF 64-bit LSB pie executable, x86-64, version 1 (GNU/Linux),
dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, ...
$ ldd rsgain
	linux-vdso.so.1 (...)
	libstdc++.so.6 => /usr/lib/libstdc++.so.6 (...)
	libm.so.6 => /usr/lib/libm.so.6 (...)
	libgcc_s.so.1 => /usr/lib/libgcc_s.so.1 (...)
	libpthread.so.0 => /usr/lib/libpthread.so.0 (...)
	libc.so.6 => /usr/lib/libc.so.6 (...)
	/lib64/ld-linux-x86-64.so.2 => /usr/lib64/ld-linux-x86-64.so.2 (...)
```

Six `NEEDED` entries (`readelf -d`): libstdc++, libm, libgcc_s, libpthread,
libc, and — because it's a PIE binary — the dynamic loader itself,
`ld-linux-x86-64.so.2`.

Upstream builds its *dependencies* statically (ffmpeg, libebur128, inih via
vcpkg) but never statically links the *toolchain*, so the binary still needs a
host glibc (>= 2.30) and a matching libstdc++. It can't run in a `scratch`
container or on musl systems.

These builds have zero `NEEDED` entries, no `INTERP` segment, and run anywhere
with a Linux kernel.

## Use it

```bash
docker run --rm -v /path/to/music:/music \
  ghcr.io/tfenby/rsgain-actuallystatic easy /music
docker run --rm -v /path/to/music:/music \
  ghcr.io/tfenby/rsgain-actuallystatic easy -p ebur128 /music
```

The image is `FROM scratch` — about 6.6 MB (amd64) / 5.7 MB (arm64) on disk,
~3 MB to pull, no shell, no libc, nothing but the binary and its presets.
Both architectures are built and published natively (no cross-compilation,
no emulation). Or grab a tarball from [Releases](../../releases) and drop
the binary anywhere on `$PATH` — note that `-p <name>` preset lookup only
works if the presets end up installed at `/usr/share/rsgain/presets` (as
they are in the image); otherwise pass a preset by its full path instead of
by name.

## How it's built

Upstream's source, unmodified, built through vcpkg the same way upstream's
own CI does, plus one flag:

```
-DCMAKE_EXE_LINKER_FLAGS="-static"
```

No fork, no patches, no vendored dependencies. A daily job checks upstream
for a new release and builds amd64 and arm64 natively (separate native
runners per architecture, not QEMU).

Every build must pass `./verify.sh`, which asserts zero `NEEDED` entries, no
`INTERP` segment, that `file` reports `statically linked`, and that the
binary actually tags a generated flac correctly. Nothing publishes unless
every architecture passes — so a regression to dynamic linking fails the
build instead of shipping as another mislabelled tarball.

Run it yourself against any rsgain binary:

```bash
./verify.sh /path/to/rsgain
```
