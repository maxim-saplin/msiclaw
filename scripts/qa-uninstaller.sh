#!/usr/bin/env bash
# Adversarial QA for Claw Uninstaller — run from Mac (SSH) or on Claw (local).
set -euo pipefail

HOST="${QA_HOST:-msi-claw-b.local}"
USER="${QA_USER:-user}"
REMOTE="${USER}@${HOST}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PY_PLUGIN="/home/user/homebrew/plugins/uninstalldecky/scripts/steam_nonsteam.py"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Local mode: already on the Claw (no self-SSH).
LOCAL_MODE=0
if [ -f "$PY_PLUGIN" ] && [ "$(hostname -s 2>/dev/null || hostname)" = "${HOST%%.*}" ]; then
  LOCAL_MODE=1
fi

run_cmd() {
  if [ "$LOCAL_MODE" -eq 1 ]; then
    bash -lc "$*"
  else
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE" "$@"
  fi
}

echo "=== qa-uninstaller.sh (mode=$([ "$LOCAL_MODE" -eq 1 ] && echo local || echo remote) host=$HOST) ==="

PY="$PY_PLUGIN"

echo "--- 1. HOME=/root must fail ---"
ROOT_OUT=$(run_cmd "HOME=/root python3 $PY list --json --force 2>&1" || true)
if echo "$ROOT_OUT" | grep -q "userdata ID"; then
  pass "HOME=/root fails as expected"
else
  echo "$ROOT_OUT"
  fail "HOME=/root should fail with userdata error"
fi

echo "--- 2. HOME=/home/user must succeed ---"
LIST_JSON=$(run_cmd "HOME=/home/user python3 $PY list --json --force")
echo "$LIST_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('ok') is True, d; assert 'items' in d; print(f'items={len(d[\"items\"])} disk={d.get(\"disk\",{})}')"
pass "HOME=/home/user list ok"

echo "--- 3. sudo + HOME=user simulates root plugin ---"
run_cmd "sudo env HOME=/home/user USER=user LOGNAME=user python3 $PY list --json --force" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('ok') is True, d"
pass "sudo+HOME=user list ok"

echo "--- 4. validate --safe-only (non-destructive) ---"
VAL_JSON=$(run_cmd "HOME=/home/user python3 $PY validate --json --force --safe-only")
echo "$VAL_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('ok') is True, d
names = {t['name'] for t in d.get('tests', [])}
for required in ('home_env', 'userdata_found', 'list_schema', 'disk_readable'):
    assert required in names, f'missing {required}'
orphan = next(t for t in d['tests'] if t['name'] == 'orphan_delete')
assert 'skipped' in orphan['detail'].lower() or orphan.get('pass'), orphan
print('tests:', [(t['name'], t['pass']) for t in d['tests']])
"
pass "validate --safe-only ok"

echo "--- 5. py_compile on device ---"
run_cmd "python3 -m py_compile $PY" 2>/dev/null || run_cmd "python3 -c \"import py_compile; py_compile.compile('$PY', cfile='/tmp/steam_nonsteam.pyc', doraise=True)\""
pass "py_compile ok"

echo "--- 6. orphan count unchanged by safe validate ---"
BEFORE=$(echo "$LIST_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('counts',{}).get('orphans',0))")
AFTER=$(run_cmd "HOME=/home/user python3 $PY list --json --force" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('counts',{}).get('orphans',0))")
if [ "$BEFORE" = "$AFTER" ]; then
  pass "orphan count unchanged ($BEFORE)"
else
  fail "orphan count changed: $BEFORE -> $AFTER (safe validate must not delete)"
fi

echo "=== ALL QA CHECKS PASSED ==="
