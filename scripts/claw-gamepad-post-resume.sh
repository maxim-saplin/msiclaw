#!/bin/sh
set -u

MSI_USB=3-9
MSI_JOYSTICK=/dev/input/by-path/pci-0000:00:14.0-usb-0:9:1.0-joystick
USB_POWER=/sys/bus/usb/devices/${MSI_USB}/power/control

log() {
  logger -t msi-claw-gamepad "$*"
}

raw_ready() {
  [ -e "/sys/bus/usb/devices/${MSI_USB}" ] || return 1
  [ -e "/sys/bus/usb/devices/${MSI_USB}:1.0/driver" ] || return 1
  [ "$(basename "$(readlink -f "/sys/bus/usb/devices/${MSI_USB}:1.0/driver")")" = "usbhid" ] || return 1
  [ -e "$MSI_JOYSTICK" ]
}

irq_storm() {
  journalctl -b -k --since "10 seconds ago" --no-pager 2>/dev/null \
    | grep -q "usb ${MSI_USB}: input irq status -75 received"
}

rebind() {
  log "rebinding MSI gamepad USB ${MSI_USB}"
  echo "$MSI_USB" >/sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
  sleep 1
  echo "$MSI_USB" >/sys/bus/usb/drivers/usb/bind 2>/dev/null || true
}

case "${1:-}" in
  --prepare)
    if [ -e "$USB_POWER" ]; then
      echo on >"$USB_POWER" 2>/dev/null || true
    fi
    ;;
  --force)
    rebind
    ;;
  *)
    if ! raw_ready || irq_storm; then
      rebind
    else
      log "gamepad healthy; skipping rebind"
    fi
    ;;
esac