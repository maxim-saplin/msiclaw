#!/usr/bin/env bash
# Install the power-button dependency for the boot-time "steam" gamescope session.
# Run on the Claw: sudo ~/src/msiclaw/scripts/install-claw-powerbutton-session.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run with sudo" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO_ROOT/system/systemd-user/gamescope-session-plus@steam.service.d/10-claw-powerbutton.conf"
DEST_DIR=/etc/systemd/user/gamescope-session-plus@steam.service.d

[ -f "$SRC" ] || { echo "error: missing $SRC" >&2; exit 1; }

install -d "$DEST_DIR"
install -m 644 "$SRC" "$DEST_DIR/10-claw-powerbutton.conf"

echo "Installed:"
echo "  $DEST_DIR/10-claw-powerbutton.conf"
echo "Done. Run 'systemctl --user daemon-reload' as the user, or reboot, for it to apply."
