#!/bin/sh
STATE=/run/msi-claw-s2idle.state
GOODIX_USB=3-4
MSI_USB=3-9
WIFI_PCI=$(lspci -Dn 2>/dev/null | awk '/0280:8086:272b/{print $1}')
KICK=/usr/local/bin/claw-battery-charge-kick.sh
WIFI_FIX=/usr/local/bin/claw-wifi-post-resume.sh
ZT_FLAG=/run/claw-start-zt-after-wifi
PLATFORM_PROFILE=/sys/firmware/acpi/platform_profile
# Fan curve is EC-owned (no writable pwm duty; curve writes don't stick), so the
# only lever to quiet fans during s2idle is the platform profile. "low-power"
# trims fan RPM ~15% at a given temp and idles the fans at a lower threshold.
# Applied on s2idle entry only ($2=suspend); restored on resume (HHD re-asserts
# its own profile a few seconds after wake regardless).
SLEEP_PROFILE=low-power

log() { logger -t msi-claw-s2idle "$*"; }

rfkill_state() {
  id="$1"
  rfkill list "$id" 2>/dev/null | awk '/Soft blocked/ {print $3}' | tr -d ':'
}

case "$1" in
  pre)
    : >"$STATE"
    echo "bt=$(rfkill_state bluetooth)" >>"$STATE"
    log "pre: blocking bluetooth radio"
    rfkill block bluetooth 2>/dev/null || true
    # s2idle only: EC keeps its fan curve live while suspended, so entering
    # hot leaves the fans audible. Drop to the quietest profile for the sleep.
    if [ "$2" = "suspend" ] && [ -w "$PLATFORM_PROFILE" ]; then
      cur=$(cat "$PLATFORM_PROFILE" 2>/dev/null)
      if [ -n "$cur" ] && [ "$cur" != "$SLEEP_PROFILE" ]; then
        echo "saved_profile=$cur" >>"$STATE"
        if echo "$SLEEP_PROFILE" >"$PLATFORM_PROFILE" 2>/dev/null; then
          log "pre: platform_profile $cur -> $SLEEP_PROFILE (quieter fans in s2idle)"
        fi
      fi
    fi
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
      if [ -e "/sys/bus/usb/devices/${MSI_USB}" ]; then
        log "post: rebinding MSI gamepad USB"
        echo "$MSI_USB" >/sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
        sleep 1
        echo "$MSI_USB" >/sys/bus/usb/drivers/usb/bind 2>/dev/null || true
        sleep 1
      fi
      if [ -n "${wifi_d3cold:-}" ]; then
        echo "$wifi_d3cold" >"/sys/bus/pci/devices/${WIFI_PCI}/d3cold_allowed" 2>/dev/null || true
      fi
      if [ "${bt:-no}" = "no" ]; then
        log "post: unblocking bluetooth"
        rfkill unblock bluetooth 2>/dev/null || true
      fi
      if [ -n "${saved_profile:-}" ] && [ -w "$PLATFORM_PROFILE" ]; then
        echo "$saved_profile" >"$PLATFORM_PROFILE" 2>/dev/null || true
        log "post: platform_profile restored to $saved_profile"
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
