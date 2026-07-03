#!/usr/bin/env bash
# List and fully uninstall non-Steam games from Steam on Linux (Bazzite/Deck).
#
# Usage:
#   steam-nonsteam-games [list]
#   steam-nonsteam-games status
#   steam-nonsteam-games orphans
#   steam-nonsteam-games validate --force
#   steam-nonsteam-games uninstall [n|appid|name]
#   steam-nonsteam-games uninstall --force --yes 11
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PY="${SCRIPT_DIR}/steam_nonsteam.py"

if [ ! -f "$PY" ]; then
  echo "error: steam_nonsteam.py not found beside $0" >&2
  exit 1
fi

exec python3 "$PY" "$@"
