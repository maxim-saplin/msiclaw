#!/usr/bin/env bash
# Install MSI Claw WiFi post-resume hooks (script, NM dispatcher, sysctl, udev).
# Run on the Claw: sudo ~/src/msiclaw/scripts/install-claw-wifi-hooks.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run with sudo" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

find_repo_file() {
  local name="$1"
  for candidate in \
    "$SCRIPT_DIR/$name" \
    "$REPO_ROOT/system/$name" \
    "$REPO_ROOT/$name"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  echo "error: missing $name under $SCRIPT_DIR, $REPO_ROOT/system, or $REPO_ROOT" >&2
  exit 1
}

WIFI_SCRIPT="$(find_repo_file claw-wifi-post-resume.sh)"
DISPATCHER="$(find_repo_file 99-claw-wifi-post-resume)"
SYSCTL_WLAN="$(find_repo_file 99-msi-claw-wlan-rp-filter.conf)"
UDEV_ZT="$(find_repo_file 99-msi-claw-zt-rp-filter.rules)"
UDEV_BE200="$(find_repo_file 99-be200-no-d3cold.rules)"
WATCHDOG="$(find_repo_file claw-wifi-resume-watchdog.sh)"
ZT_ENSURE_SCRIPT="$(find_repo_file zerotier-ensure-online.sh)"

SUSPEND_DROPIN="$REPO_ROOT/system/systemd/systemd-suspend.service.d/99-msi-claw-wifi-resume.conf"
ZT_ENSURE_UNIT="$REPO_ROOT/system/systemd/zerotier-ensure-online.service"
for f in "$SUSPEND_DROPIN" "$ZT_ENSURE_UNIT"; do
  [ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }
done

install -m 755 "$WIFI_SCRIPT" /usr/local/bin/claw-wifi-post-resume.sh
install -m 755 "$DISPATCHER" /etc/NetworkManager/dispatcher.d/99-claw-wifi-post-resume
install -m 644 "$SYSCTL_WLAN" /etc/sysctl.d/99-msi-claw-wlan-rp-filter.conf
install -m 644 "$UDEV_ZT" /etc/udev/rules.d/99-msi-claw-zt-rp-filter.rules
install -m 644 "$UDEV_BE200" /etc/udev/rules.d/99-be200-no-d3cold.rules
install -m 755 "$WATCHDOG" /usr/local/bin/claw-wifi-resume-watchdog.sh
install -d /etc/systemd/system/systemd-suspend.service.d
install -m 644 "$SUSPEND_DROPIN" /etc/systemd/system/systemd-suspend.service.d/99-msi-claw-wifi-resume.conf
install -m 755 "$ZT_ENSURE_SCRIPT" /usr/local/bin/zerotier-ensure-online.sh
install -m 644 "$ZT_ENSURE_UNIT" /etc/systemd/system/zerotier-ensure-online.service
systemctl daemon-reload

sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-msi-claw-wlan-rp-filter.conf
udevadm control --reload-rules
udevadm trigger --subsystem-match=net --action=add

for iface in /sys/class/net/zt*; do
  [ -e "$iface" ] || continue
  sysctl -q -w "net.ipv4.conf.$(basename "$iface").rp_filter=0" 2>/dev/null || true
done

echo "Installed:"
echo "  /usr/local/bin/claw-wifi-post-resume.sh"
echo "  /etc/NetworkManager/dispatcher.d/99-claw-wifi-post-resume"
echo "  /etc/sysctl.d/99-msi-claw-wlan-rp-filter.conf"
echo "  /etc/udev/rules.d/99-msi-claw-zt-rp-filter.rules"
echo "  /etc/udev/rules.d/99-be200-no-d3cold.rules"
echo "  /usr/local/bin/claw-wifi-resume-watchdog.sh"
echo "  /etc/systemd/system/systemd-suspend.service.d/99-msi-claw-wifi-resume.conf"
echo "  /usr/local/bin/zerotier-ensure-online.sh"
echo "  /etc/systemd/system/zerotier-ensure-online.service"
echo "Done. Test after next suspend: sudo /usr/local/bin/claw-wifi-post-resume.sh --refresh-only"
