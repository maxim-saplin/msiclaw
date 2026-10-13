#!/bin/bash
# Resume watchdog for WiFi (root). Started detached from systemd-suspend.service
# (see systemd-suspend.service.d/99-msi-claw-wifi-resume.conf) after every suspend.
#
# claw-wifi-post-resume.sh is otherwise only triggered by the NM dispatcher on a
# wlan "up" event. If NetworkManager sits disconnected after resume, that event
# never fires and nothing retries association (seen 2026-10-12 21:09: ~5 min
# disconnected). This script only nudges NM when WiFi is clearly not coming back
# on its own; on a normal resume it logs one line and exits.
set -u

TAG=claw-wifi-watchdog
log() { logger -t "$TAG" "$*"; }

IF=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2 == "wifi" {print $1; exit}')
[ -n "$IF" ] || { log "no wifi device found"; exit 0; }

wifi_state() {
  nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: -v i="$IF" '$1 == i {print $2; exit}'
}

# Only act on states where NM is not already negotiating or connected.
stuck() {
  case "$1" in
    disconnected|unavailable|failed) return 0 ;;
    *) return 1 ;;
  esac
}

sleep 15
state=$(wifi_state)
if ! stuck "$state"; then
  log "wifi ${state:-unknown} 15s after resume; nothing to do"
  exit 0
fi

log "wifi $state 15s after resume; asking NetworkManager to connect $IF"
nmcli device connect "$IF" >/dev/null 2>&1 || true

sleep 25
state=$(wifi_state)
if ! stuck "$state"; then
  log "wifi $state after connect request"
  exit 0
fi

log "wifi still $state 40s after resume; cycling WiFi radio"
rfkill block wifi >/dev/null 2>&1 || true
sleep 1
rfkill unblock wifi >/dev/null 2>&1 || true
sleep 10
log "wifi $(wifi_state) after radio cycle"
