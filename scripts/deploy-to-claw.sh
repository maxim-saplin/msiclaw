#!/usr/bin/env bash
# Deploy msiclaw scripts from Mac repo to MSI Claw ~/bin.
#
# Usage:
#   ./scripts/deploy-to-claw.sh              # user@msi-claw-b.local
#   ./scripts/deploy-to-claw.sh --mirror       # also rsync full repo to ~/src/msiclaw
#   ./scripts/deploy-to-claw.sh --host HOST    # custom SSH target
set -euo pipefail

HOST="msi-claw-b.local"
USER="user"
MIRROR=0
REMOTE_BIN="~/bin"
SKIP_DEPLOY=0

usage() {
  cat <<'EOF'
Usage: deploy-to-claw.sh [options]

Options:
  --host HOST   SSH host (default: msi-claw-b.local)
  --user USER   SSH user (default: user)
  --mirror      Also rsync full repo to ~/src/msiclaw on the Claw
  --bin-only    Skip --mirror even if set elsewhere
  -h, --help    Show this help

Deploys every scripts/*.sh to ~/bin/<name> (strips .sh suffix).
Excludes deploy-to-claw.sh itself (Mac-only).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --mirror) MIRROR=1; shift ;;
    --bin-only) MIRROR=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${USER}@${HOST}"
SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes)

echo "Deploying scripts to ${TARGET}:${REMOTE_BIN}"

ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p bin"

deployed=0
for src in "$SCRIPT_DIR"/*.sh; do
  [ -f "$src" ] || continue
  base=$(basename "$src" .sh)
  if [ "$base" = "deploy-to-claw" ]; then
    continue
  fi
  dest="${REMOTE_BIN}/${base}"
  echo "  $src -> ${TARGET}:${dest}"
  scp "${SSH_OPTS[@]}" "$src" "${TARGET}:${dest}.new"
  ssh "${SSH_OPTS[@]}" "$TARGET" "chmod +x ${dest}.new && mv ${dest}.new ${dest}"
  deployed=$((deployed + 1))
done

py="${SCRIPT_DIR}/steam_nonsteam.py"
if [ -f "$py" ]; then
  dest="${REMOTE_BIN}/steam_nonsteam.py"
  echo "  $py -> ${TARGET}:${dest}"
  scp "${SSH_OPTS[@]}" "$py" "${TARGET}:${dest}.new"
  ssh "${SSH_OPTS[@]}" "$TARGET" "chmod +x ${dest}.new && mv ${dest}.new ${dest}"
  deployed=$((deployed + 1))
fi

if [ "$deployed" -eq 0 ]; then
  echo "warning: no scripts to deploy" >&2
else
  echo "Deployed ${deployed} script(s)."
fi

if [ "$MIRROR" -eq 1 ]; then
  echo "Mirroring repo to ${TARGET}:~/src/msiclaw"
  ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p src/msiclaw"
  rsync -avz --delete \
    --exclude '.git/' \
    --exclude 'hiberdecky/node_modules/' \
    --exclude 'hiberdecky/dist/' \
    -e "ssh ${SSH_OPTS[*]}" \
    "$REPO_ROOT/" "${TARGET}:src/msiclaw/"
  echo "Mirror complete."
fi

echo "Done."
