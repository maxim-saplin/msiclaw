#!/bin/sh
# Enable or disable passwordless sudo for the user who invoked sudo.
# Run on the MSI Claw only. Reversible via: sudo ~/bin/msi-sudo-nopasswd disable
#
#   sudo ~/bin/msi-sudo-nopasswd enable   # last time you type the password
#   sudo ~/bin/msi-sudo-nopasswd disable  # restore password prompt
#   ~/bin/msi-sudo-nopasswd status        # show current state (no sudo needed)
set -e

SUDOERS_FILE=/etc/sudoers.d/msi-user-nopasswd

target_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    printf '%s' "$SUDO_USER"
    return
  fi
  if [ -n "${SUDO_UID:-}" ] && [ "$SUDO_UID" != "0" ]; then
    id -nu "$SUDO_UID"
    return
  fi
  logname 2>/dev/null || whoami
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "error: run with sudo (e.g. sudo $0 $1)" >&2
    exit 1
  fi
}

usage() {
  cat <<'EOF'
Usage: msi-sudo-nopasswd <command>

Commands:
  enable   Allow passwordless sudo for your user (run: sudo ... enable)
  disable  Remove passwordless sudo (run: sudo ... disable)
  status   Show whether nopasswd is active

Security: enable grants NOPASSWD: ALL for your user until you disable it.
EOF
}

cmd_enable() {
  require_root enable
  u=$(target_user)
  if [ -z "$u" ] || [ "$u" = "root" ]; then
    echo "error: could not determine non-root target user" >&2
    exit 1
  fi

  tmp=$(mktemp /tmp/msi-sudo-nopasswd.XXXXXX)
  chmod 440 "$tmp"
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$u" >"$tmp"

  if ! visudo -cf "$tmp" >/dev/null; then
    rm -f "$tmp"
    echo "error: visudo rejected sudoers fragment" >&2
    exit 1
  fi

  install -m 440 "$tmp" "$SUDOERS_FILE"
  rm -f "$tmp"
  echo "enabled passwordless sudo for user: $u"
  echo "revert with: sudo $(basename "$0") disable"
}

cmd_disable() {
  require_root disable
  if [ -f "$SUDOERS_FILE" ]; then
    rm -f "$SUDOERS_FILE"
    echo "disabled passwordless sudo; password required again"
  else
    echo "already disabled (no $SUDOERS_FILE)"
  fi
}

cmd_status() {
  if [ -f "$SUDOERS_FILE" ]; then
    echo "passwordless sudo: enabled"
    echo "file: $SUDOERS_FILE"
    cat "$SUDOERS_FILE"
  else
    echo "passwordless sudo: disabled"
  fi
}

case "${1:-}" in
  enable) cmd_enable ;;
  disable) cmd_disable ;;
  status) cmd_status ;;
  -h|--help|help) usage ;;
  *)
    usage >&2
    exit 1
    ;;
esac
