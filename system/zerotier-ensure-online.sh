#!/bin/bash
set -euo pipefail

zt_online() {
  /usr/sbin/zerotier-cli info 2>/dev/null | grep -q " ONLINE"
}

sleep 8

for _ in $(seq 1 18); do
  zt_online && exit 0
  sleep 5
done

logger -t zerotier-ensure-online "ZeroTier still OFFLINE; restarting zerotier-one"
systemctl restart zerotier-one.service
sleep 8

for _ in $(seq 1 18); do
  zt_online && exit 0
  sleep 5
done

logger -t zerotier-ensure-online "ZeroTier failed to reach ONLINE after restart"
exit 1
