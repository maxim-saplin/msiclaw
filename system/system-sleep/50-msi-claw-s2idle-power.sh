#!/bin/sh
STATE=/run/msi-claw-s2idle.state
GOODIX_USB=3-4
MSI_USB=3-9
MSI_JOYSTICK=/dev/input/by-path/pci-0000:00:14.0-usb-0:9:1.0-joystick
WIFI_PCI=$(lspci -Dn 2>/dev/null | awk '/0280:8086:272b/{print $1}')
KICK=/usr/local/bin/claw-battery-charge-kick.sh
WIFI_FIX=/usr/local/bin/claw-wifi-post-resume.sh
ZT_FLAG=/run/claw-start-zt-after-wifi

log() { logger -t msi-claw-s2idle "$*"; }

msi_gamepad_raw_ready() {
  [ -e "/sys/bus/usb/devices/${MSI_USB}" ] || return 1
  [ -e "/sys/bus/usb/devices/${MSI_USB}:1.0/driver" ] || return 1
  [ "$(basename "$(readlink -f "/sys/bus/usb/devices/${MSI_USB}:1.0/driver")")" = "usbhid" ] || return 1
  [ -e "$MSI_JOYSTICK" ] || return 1
}

msi_gamepad_irq_storm() {
  journalctl -b -k --since "10 seconds ago" --no-pager 2>/dev/null \
    | grep -q "usb ${MSI_USB}: input irq status -75 received"
}

msi_gamepad_needs_rebind() {
  ! msi_gamepad_raw_ready || msi_gamepad_irq_storm
}

msi_gamepad_rebind() {
  log "post: rebinding MSI gamepad USB"
  echo "$MSI_USB" >/sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
  sleep 1
  echo "$MSI_USB" >/sys/bus/usb/drivers/usb/bind 2>/dev/null || true
}

rfkill_state() {
  id="$1"
  rfkill list "$id" 2>/dev/null | awk '/Soft blocked/ {print $3}' | tr -d ':'
}

case "$1" in
  pre)
    zt_want=0
    if [ -f "$STATE" ]; then
      # Hibernate can invoke pre twice; preserve ZT restart intent across the wipe.
      # shellcheck disable=SC1090
      . "$STATE" 2>/dev/null || true
      zt_want="${zerotier:-0}"
    fi
    : >"$STATE"
    echo "bt=$(rfkill_state bluetooth)" >>"$STATE"
    log "pre: blocking bluetooth radio"
    rfkill block bluetooth 2>/dev/null || true
    if [ -n "$WIFI_PCI" ] && [ -e "/sys/bus/pci/devices/${WIFI_PCI}/d3cold_allowed" ]; then
      echo "wifi_d3cold=$(cat /sys/bus/pci/devices/${WIFI_PCI}/d3cold_allowed)" >>"$STATE"
      echo 0 >"/sys/bus/pci/devices/${WIFI_PCI}/d3cold_allowed" 2>/dev/null || true
      log "pre: BE200 d3cold_allowed=0"
    fi
    if systemctl is-active --quiet fprintd.service; then
      echo "fprintd=1" >>"$STATE"
      log "pre: stopping fprintd"
      systemctl stop fprintd.service 2>/dev/null || true
    fi
    if systemctl is-active --quiet zerotier-one.service; then
      echo "zerotier=1" >>"$STATE"
      log "pre: stopping zerotier-one"
      systemctl stop zerotier-one.service 2>/dev/null || true
    elif systemctl is-enabled --quiet zerotier-one.service 2>/dev/null || [ "$zt_want" = "1" ]; then
      echo "zerotier=1" >>"$STATE"
    fi
    if [ -e "/sys/bus/usb/devices/${GOODIX_USB}" ]; then
      echo "fp_present=1" >>"$STATE"
      log "pre: unbinding Goodix fingerprint USB"
      echo "$GOODIX_USB" >/sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
    fi
    # MSI gamepad USB (3-9): keep power=on — autosuspend breaks HID after resume (-75 irq storm).
    if [ -e "/sys/bus/usb/devices/${MSI_USB}/power/control" ]; then
      echo on >"/sys/bus/usb/devices/${MSI_USB}/power/control" 2>/dev/null || true
    fi
    ;;
  post)
    zt_start=0
    if [ -f "$STATE" ]; then
      . "$STATE"
      if [ "${fp_present:-0}" = "1" ]; then
        log "post: rebinding Goodix fingerprint USB"
        echo "$GOODIX_USB" >/sys/bus/usb/drivers/usb/bind 2>/dev/null || true
        sleep 1
      fi
      if msi_gamepad_needs_rebind; then
        msi_gamepad_rebind
      else
        log "post: MSI gamepad healthy; skipping rebind"
      fi
      if [ -n "${wifi_d3cold:-}" ]; then
        echo "$wifi_d3cold" >"/sys/bus/pci/devices/${WIFI_PCI}/d3cold_allowed" 2>/dev/null || true
      fi
      if [ "${bt:-no}" = "no" ]; then
        log "post: unblocking bluetooth"
        rfkill unblock bluetooth 2>/dev/null || true
      fi
      zt_start="${zerotier:-0}"
      rm -f "$STATE"
    fi
    if [ -x "$KICK" ]; then
      log "post: scheduling battery charge kick (background retry)"
      nohup "$KICK" --retry 5 10 >/dev/null 2>&1 &
    fi
    if [ "${zt_start:-0}" = "1" ]; then
      : >"$ZT_FLAG"
    fi
    if [ -x "$WIFI_FIX" ]; then
      log "post: starting WiFi post-resume recovery (background)"
      nohup "$WIFI_FIX" >/dev/null 2>&1 &
    elif [ "${zt_start:-0}" = "1" ]; then
      log "post: starting zerotier-one (fallback)"
      systemctl start zerotier-one.service 2>/dev/null || true
    fi
    log "post: restore complete"
    ;;
esac
