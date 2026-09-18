#!/usr/bin/env bash
# Assert a binary is ACTUALLY static -- unlike upstream's "Static" release,
# which is static dependencies wrapped around a dynamic glibc.
set -euo pipefail

BIN="${1:?usage: verify.sh <path-to-rsgain>}"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "$BIN is not an executable file"

# Ensure readelf is available for staticness checks.
command -v readelf >/dev/null || fail "readelf is required for the staticness check"

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
ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=1" -c:a flac "$tmp/t.flac" \
  || fail "failed to generate test FLAC file"
"$BIN" custom -s i "$tmp/t.flac" >/dev/null \
  || fail "failed to tag test FLAC file with rsgain"
ffmpeg -loglevel error -i "$tmp/t.flac" -f ffmetadata - | grep -q REPLAYGAIN_TRACK_GAIN \
  || fail "no REPLAYGAIN_TRACK_GAIN written; the static ffmpeg/TagLib path is broken"

echo "PASS: $BIN is actually static and functional"
