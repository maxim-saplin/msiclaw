#!/bin/bash
# Post-suspend WiFi recovery for MSI Claw (Bazzite + IWD + BE200 + ZeroTier).
# Installed to /usr/local/bin by scripts/install-claw-wifi-hooks.sh
set -euo pipefail

TAG=claw-wifi
ZT_FLAG=/run/claw-start-zt-after-wifi
HIBERNATE_FLAG=/run/claw-hibernate-resume.pending
COOLDOWN_FILE=/run/claw-hibernate-cooldown
SLEEP_HOOK=/etc/systemd/system-sleep/50-msi-claw-s2idle-power.sh
MAX_WAIT=90
REFRESH_ONLY=0

log() { logger -t "$TAG" "$*"; }

usage() {
  cat <<'EOF'
Usage: claw-wifi-post-resume.sh [--refresh-only]

  (default)  Full post-resume recovery: wait for wlan0, verify HTTP, refresh NM
             connectivity state, then start ZeroTier.
  --refresh-only
             Light pass: fix ZT rp_filter, force NM connectivity re-check until
             global + wlan0 report full. No ZeroTier start/stop.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --refresh-only) REFRESH_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

nm_global_connectivity() {
  nmcli networking connectivity 2>/dev/null || echo unknown
}

wlan_ip4_connectivity() {
  nmcli -g GENERAL.IP4-CONNECTIVITY device show wlan0 2>/dev/null || echo unknown
}

wlan_connectivity_is_full() {
  case "$(wlan_ip4_connectivity)" in
    *full*) return 0 ;;
    *) return 1 ;;
  esac
}

connectivity_snapshot() {
  printf 'global=%s wlan0_ip4=%s' \
    "$(nm_global_connectivity)" "$(wlan_ip4_connectivity)"
}

force_nm_connectivity_refresh() {
  busctl call org.freedesktop.NetworkManager /org/freedesktop/NetworkManager \
    org.freedesktop.NetworkManager CheckConnectivity >/dev/null 2>&1 || true
  nmcli networking connectivity check >/dev/null 2>&1 || true
}

fix_zt_rp_filter() {
  local iface
  for iface in /sys/class/net/zt*; do
    [ -e "$iface" ] || continue
    iface=$(basename "$iface")
    sysctl -q -w "net.ipv4.conf.${iface}.rp_filter=0" 2>/dev/null || true
  done
}

wait_connectivity_full() {
  local max_wait="${1:-45}" i global
  for i in $(seq 1 "$max_wait"); do
    global=$(nm_global_connectivity)
    if [ "$global" = "full" ] && wlan_connectivity_is_full; then
      [ "$i" -gt 1 ] && log "connectivity full after ${i}s ($(connectivity_snapshot))"
      return 0
    fi
    force_nm_connectivity_refresh
    sleep 1
  done
  log "connectivity not full after ${max_wait}s ($(connectivity_snapshot))"
  return 1
}

finalize_connectivity() {
  fix_zt_rp_filter
  resolvectl flush-caches 2>/dev/null || true
  force_nm_connectivity_refresh
  wait_connectivity_full 30 || true
  # Reapply only once wlan is already full — nudges NM/Plasma to refresh the icon.
  if wlan_connectivity_is_full; then
    nmcli device reapply wlan0 2>/dev/null || true
    sleep 1
    force_nm_connectivity_refresh
    wait_connectivity_full 10 || true
  fi
}

mark_resume_cooldown() {
  date +%s >"$COOLDOWN_FILE"
  log "post-resume hibernate cooldown started (60s)"
}

wait_nm() {
  local i
  for i in $(seq 1 30); do
    nmcli -g RUNNING general 2>/dev/null | grep -qx running && return 0
    sleep 1
  done
  return 1
}

wait_wlan() {
  local i state kicked=0 rfkilled=0
  for i in $(seq 1 "$MAX_WAIT"); do
    state=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: '$1=="wlan0"{print $2; exit}')
    [ "$state" = "connected" ] && return 0
    # Seen post-resume: wlan0 stuck retrying association on its own
    # (repeated supplicant-disconnect) for over a minute with nothing to show
    # for it. Give NM's own retry a head start, then force it.
    if [ "$kicked" -eq 0 ] && [ "$i" -ge 15 ]; then
      log "wlan0 stuck (state=${state:-unknown}) after ${i}s, forcing disconnect/reconnect"
      nmcli device disconnect wlan0 >/dev/null 2>&1 || true
      sleep 1
      nmcli device connect wlan0 >/dev/null 2>&1 || true
      kicked=1
    fi
    # Still stuck well past that — cycle the radio itself (this is what
    # manually toggling WiFi off/on in the UI does).
    if [ "$rfkilled" -eq 0 ] && [ "$i" -ge 40 ]; then
      log "wlan0 still stuck (state=${state:-unknown}) after ${i}s, cycling wifi radio"
      rfkill block wifi >/dev/null 2>&1 || true
      sleep 1
      rfkill unblock wifi >/dev/null 2>&1 || true
      rfkilled=1
    fi
    sleep 1
  done
  return 1
}

verify_internet() {
  curl -fsS --connect-timeout 4 --max-time 8 \
    http://fedoraproject.org/static/hotspot.txt 2>/dev/null | grep -q '^OK$' && \
  curl -fsS --connect-timeout 4 --max-time 8 \
    -o /dev/null https://1.1.1.1/cdn-cgi/trace 2>/dev/null
}

recover_wlan() {
  log "recover: nmcli device reapply wlan0 ($(connectivity_snapshot))"
  nmcli device reapply wlan0 2>/dev/null || true
  sleep 3
  resolvectl flush-caches 2>/dev/null || true
  force_nm_connectivity_refresh
  wait_connectivity_full 20 || true
}

start_zt_if_needed() {
  local want_zt=0
  [ -f "$ZT_FLAG" ] && { rm -f "$ZT_FLAG"; want_zt=1; }
  systemctl is-enabled --quiet zerotier-one.service 2>/dev/null && want_zt=1
  [ "$want_zt" -eq 1 ] || return 0

  if systemctl is-active --quiet zerotier-one.service 2>/dev/null; then
    fix_zt_rp_filter
    return 0
  fi

  log "starting zerotier-one after WiFi verified"
  systemctl start zerotier-one.service 2>/dev/null || true
  sleep 2
  fix_zt_rp_filter
  finalize_connectivity
}

run_hibernate_post_hooks() {
  [ -f "$HIBERNATE_FLAG" ] || return 0
  rm -f "$HIBERNATE_FLAG"
  mark_resume_cooldown
  log "hibernate resume: running sleep post hooks"
  if [ -x "$SLEEP_HOOK" ]; then
    "$SLEEP_HOOK" post || log "sleep post hook failed"
    return 0
  fi
  return 1
}

refresh_only_main() {
  log "refresh-only start ($(connectivity_snapshot))"
  fix_zt_rp_filter
  finalize_connectivity
  log "refresh-only done ($(connectivity_snapshot))"
}

main() {
  if [ "$REFRESH_ONLY" -eq 1 ]; then
    refresh_only_main
    exit 0
  fi

  sleep 2

  if [ -f "$HIBERNATE_FLAG" ]; then
    run_hibernate_post_hooks
    exit 0
  fi

  log "full recovery start ($(connectivity_snapshot))"

  wait_nm || { log "NM not running after resume"; start_zt_if_needed; exit 0; }
  wait_wlan || { log "wlan0 not connected after ${MAX_WAIT}s"; start_zt_if_needed; exit 0; }

  resolvectl flush-caches 2>/dev/null || true
  nmcli networking connectivity wait "$MAX_WAIT" 2>/dev/null || true

  local attempt
  for attempt in 1 2 3; do
    if verify_internet; then
      log "internet verified (attempt $attempt, $(connectivity_snapshot))"
      finalize_connectivity
      start_zt_if_needed
      log "full recovery done ($(connectivity_snapshot))"
      exit 0
    fi
    log "internet check failed (attempt $attempt, $(connectivity_snapshot))"
    recover_wlan
    nmcli networking connectivity wait 30 2>/dev/null || true
    sleep 2
  done

  log "internet still failing after recovery attempts ($(connectivity_snapshot))"
  finalize_connectivity
  start_zt_if_needed
}

main
