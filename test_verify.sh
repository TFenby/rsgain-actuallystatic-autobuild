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
