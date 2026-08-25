#!/usr/bin/env bash
set -u

section() {
  printf '\n[%s]\n' "$1"
}

run() {
  printf '$'
  printf ' %q' "$@"
  printf '\n'
  if command -v "$1" >/dev/null 2>&1; then
    "$@" 2>&1 || printf 'exit=%s\n' "$?"
  else
    printf 'not found: %s\n' "$1"
  fi
}

run_root() {
  if [ "$(id -u 2>/dev/null || printf 1)" -eq 0 ]; then
    run "$@"
  elif command -v sudo >/dev/null 2>&1; then
    run sudo -n "$@"
  else
    printf 'root access unavailable: %s\n' "$*"
  fi
}

path_state() {
  local path="$1"
  if [ -L "$path" ]; then
    if [ -e "$path" ]; then
      printf 'present symlink: %s -> %s\n' "$path" "$(readlink -f "$path" 2>/dev/null || readlink "$path")"
    else
      printf 'broken symlink: %s -> %s\n' "$path" "$(readlink "$path")"
    fi
  elif [ -e "$path" ]; then
    printf 'present: %s\n' "$path"
  else
    printf 'missing: %s\n' "$path"
  fi
}

contains() {
  local path="$1"
  local text="$2"
  if [ -r "$path" ] && grep -Fq -- "$text" "$path"; then
    printf 'contains %q: %s\n' "$text" "$path"
  else
    printf 'does not contain %q or unreadable: %s\n' "$text" "$path"
  fi
}

section "preflight"
printf 'read-only collector; no service, network, power, or ostree state is changed\n'
printf 'timestamp: %s\n' "$(date -Is 2>/dev/null || date)"
printf 'host: %s\n' "$(hostname 2>/dev/null || printf unknown)"
printf 'user: %s\n' "$(id -un 2>/dev/null || printf unknown)"

section "storage and deployment"
run df -h / /var
run rpm-ostree status
run ostree admin status
run rpm-ostree kargs
run cat /proc/cmdline
run uname -a
run systemctl list-jobs

section "host services and versions"
run systemctl --version
run nmcli --version
run iwd --version
run python3 --version
run systemctl is-active plugin_loader
run systemctl is-enabled plugin_loader

section "zerotier"
run systemctl is-active zerotier-one.service
run systemctl is-enabled zerotier-one.service
run_root zerotier-cli info
run_root zerotier-cli listnetworks

section "decky plugins"
PLUGIN_ROOT=/home/user/homebrew/plugins
path_state "$PLUGIN_ROOT"
if [ -d "$PLUGIN_ROOT" ]; then
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$PLUGIN_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for manifest in sorted(root.glob("*/plugin.json")):
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"{manifest.parent.name}: invalid manifest ({exc})")
        continue
    print(
        f"{manifest.parent.name}: name={data.get('name', '?')} "
        f"version={data.get('version', '?')} api={data.get('api_version', '?')}"
    )
PY
  else
    find "$PLUGIN_ROOT" -mindepth 2 -maxdepth 2 -type f -name plugin.json -print 2>/dev/null | sort
  fi
fi

section "migration surfaces"
for path in \
  /home/user/homebrew/plugins/hiberdecky \
  /home/user/homebrew/plugins/uninstalldecky \
  /usr/local/bin/claw-hibernate.sh \
  /usr/local/bin/claw-wifi-post-resume.sh \
  /usr/local/bin/claw-gamescope-diag-shim \
  /etc/systemd/system/systemd-suspend.service.d/msi-claw-s2idle.conf \
  /etc/systemd/system-sleep/50-msi-claw-s2idle-power.sh \
  /etc/NetworkManager/dispatcher.d/99-claw-wifi-post-resume \
  /etc/sysctl.d/99-msi-claw-wlan-rp-filter.conf \
  /etc/udev/rules.d/99-msi-claw-zt-rp-filter.rules \
  /etc/systemd/logind.conf.d/zz-claw-power.conf \
  /etc/gamescope-session-plus/sessions.d/steam \
  /etc/gamescope-session-plus/sessions.d/ogui-steam \
  /var/swap/hibernate.swap \
  /etc/systemd/system/var-swap-hibernate.swap.swap \
  /etc/systemd/sleep.conf.d/claw-hibernate.conf; do
  path_state "$path"
done
contains /etc/gamescope-session-plus/sessions.d/steam 'GAMESCOPE_BIN'
contains /etc/gamescope-session-plus/sessions.d/ogui-steam 'GAMESCOPE_BIN'
contains /usr/local/bin/claw-gamescope-diag-shim '--disable-layers'

section "end"
printf 'Review this report before any disruptive action.\n'