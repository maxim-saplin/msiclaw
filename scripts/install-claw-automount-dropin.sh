#!/usr/bin/env bash
# Install the drop-in that stops ublue-os-media-automount from reporting the btrfs
# member-device failure on every boot. Run on the Claw:
#   sudo ~/src/msiclaw/scripts/install-claw-automount-dropin.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run with sudo" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO_ROOT/system/systemd/ublue-os-media-automount.service.d/10-claw-btrfs-member.conf"
DEST_DIR=/etc/systemd/system/ublue-os-media-automount.service.d

[ -f "$SRC" ] || { echo "error: missing $SRC" >&2; exit 1; }

install -d "$DEST_DIR"
install -m 644 "$SRC" "$DEST_DIR/10-claw-btrfs-member.conf"
systemctl daemon-reload

echo "Installed:"
echo "  $DEST_DIR/10-claw-btrfs-member.conf"
echo "Done. Restart ublue-os-media-automount.service to apply now, or reboot."
