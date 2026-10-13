#!/bin/bash
# Test harness (run as root via systemd-run): mark the probe log, arm an RTC wake, then s2idle suspend.
# Deliberately never calls hibernate.
SECS=${1:-45}
echo "$(date '+%F %T.%3N') MARK suspend-request secs=$SECS" >> /home/user/claw-zt-monitor.log
rtcwake -m no -u -s "$SECS" || exit 1
systemctl suspend
