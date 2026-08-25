#!/usr/bin/env bash
set -euo pipefail

QUARANTINE_ROOT=/var/home/user
QUARANTINE_PREFIX=deck44-quarantine-
MANIFEST_NAME=manifest.tsv

LIVE_PATHS=(
  /home/user/homebrew/plugins/hiberdecky
  /usr/local/lib/hhd-bin/systemctl
  /etc/systemd/system/hhd.service.d/hibernate.conf
  /etc/systemd/system/hhd.service.d/zz-swap-off.conf
  /etc/systemd/system/systemd-suspend.service.d/msi-claw-s2idle.conf
  /etc/systemd/system-sleep/50-msi-claw-s2idle-power.sh
  /usr/local/bin/claw-wifi-post-resume.sh
  /etc/NetworkManager/dispatcher.d/99-claw-wifi-post-resume
  /etc/sysctl.d/99-msi-claw-wlan-rp-filter.conf
  /etc/udev/rules.d/99-msi-claw-zt-rp-filter.rules
  /etc/udev/rules.d/99-be200-no-d3cold.rules
  /usr/local/bin/claw-battery-charge-kick.sh
  /etc/udev/rules.d/99-msi-claw-battery-charge-kick.rules
  /etc/modprobe.d/50-msi-claw-sof.conf
  /etc/udev/rules.d/99-msi-claw-audio-pm.rules
  /home/user/.config/wireplumber/wireplumber.conf.d/80-alsa-headroom.conf
  /etc/systemd/logind.conf.d/zz-claw-power.conf
)

usage() {
  printf '%s\n' \
    'Usage: deck44-quarantine.sh status' \
    '       deck44-quarantine.sh apply' \
    '       deck44-quarantine.sh restore /var/home/user/deck44-quarantine-TIMESTAMP'
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' 'error: run this helper as root' >&2
    exit 1
  fi
}

present() {
  [ -e "$1" ] || [ -L "$1" ]
}

status() {
  local path
  printf '%s\n' 'live paths:'
  for path in "${LIVE_PATHS[@]}"; do
    if present "$path"; then
      printf 'present: %s\n' "$path"
    else
      printf 'missing: %s\n' "$path"
    fi
  done
  printf '%s\n' 'quarantine directories:'
  shopt -s nullglob
  local directories=("$QUARANTINE_ROOT"/"$QUARANTINE_PREFIX"*)
  if [ "${#directories[@]}" -eq 0 ]; then
    printf '%s\n' 'none'
    return 0
  fi
  printf '%s\n' "${directories[@]}"
}

new_quarantine() {
  local stamp directory
  stamp=$(date +%Y%m%d-%H%M%S)
  directory="$QUARANTINE_ROOT/$QUARANTINE_PREFIX$stamp"
  if [ -e "$directory" ]; then
    printf 'error: quarantine already exists: %s\n' "$directory" >&2
    exit 1
  fi
  install -d -m 700 -o root -g root "$directory"
  printf '%s\n' "$directory"
}

apply_quarantine() {
  local quarantine path relative destination
  quarantine=$(new_quarantine)
  : >"$quarantine/$MANIFEST_NAME"
  chmod 600 "$quarantine/$MANIFEST_NAME"
  for path in "${LIVE_PATHS[@]}"; do
    if ! present "$path"; then
      continue
    fi
    relative=${path#/}
    destination="$quarantine/$relative"
    if present "$destination"; then
      printf 'error: destination already exists: %s\n' "$destination" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$destination")"
    mv -- "$path" "$destination"
    printf '%s\t%s\n' "$path" "$destination" >>"$quarantine/$MANIFEST_NAME"
    printf 'moved: %s -> %s\n' "$path" "$destination"
  done
  printf 'quarantine=%s\n' "$quarantine"
  printf '%s\n' 'follow-up: reload systemd and the Decky loader only after operator approval'
}

valid_quarantine() {
  case "$1" in
    "$QUARANTINE_ROOT/$QUARANTINE_PREFIX"*) return 0 ;;
    *) return 1 ;;
  esac
}

restore_quarantine() {
  local quarantine="$1" manifest source destination
  if ! valid_quarantine "$quarantine" || [ ! -d "$quarantine" ]; then
    printf 'error: invalid quarantine directory: %s\n' "$quarantine" >&2
    exit 1
  fi
  manifest="$quarantine/$MANIFEST_NAME"
  if [ ! -r "$manifest" ]; then
    printf 'error: missing quarantine manifest: %s\n' "$manifest" >&2
    exit 1
  fi
  while IFS=$'\t' read -r source destination; do
    [ -n "$source" ] || continue
    if present "$source"; then
      printf 'error: refusing to overwrite live path: %s\n' "$source" >&2
      exit 1
    fi
    if ! present "$destination"; then
      printf 'error: quarantined path is missing: %s\n' "$destination" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$source")"
    mv -- "$destination" "$source"
    printf 'restored: %s <- %s\n' "$source" "$destination"
  done <"$manifest"
  printf '%s\n' 'restore complete; quarantine directory retained for audit'
}

main() {
  local command="${1:-}"
  case "$command" in
    status)
      require_root
      status
      ;;
    apply)
      require_root
      apply_quarantine
      ;;
    restore)
      require_root
      if [ "$#" -ne 2 ]; then
        usage >&2
        exit 1
      fi
      restore_quarantine "$2"
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"