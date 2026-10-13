#!/bin/bash
# Read-only probe: Wi-Fi state, W12PC Sunshine HTTP + ICMP over ZeroTier, plain LAN ICMP to the
# W12PC LAN address (bypasses ZeroTier), and ZeroTier ONLINE/peer paths every 5 s. ~1 Hz.
LOG="/home/user/claw-zt-monitor.log"
HOST=${W12PC_ZT_IP:?set W12PC_ZT_IP}
LANHOST=${W12PC_LAN_IP:?set W12PC_LAN_IP}
IF=wlp44s0f0
n=0
while true; do
  ts=$(date '+%F %T.%3N')
  wifi=$(cat /sys/class/net/$IF/operstate 2>/dev/null)
  ip4=$(ip -4 -br addr show "$IF" 2>/dev/null | awk '{print $3}')
  http=$(curl -s -o /dev/null -m 2 -w '%{http_code} %{time_total}' "http://$HOST:47989/serverinfo" 2>/dev/null)
  icmp=$(ping -c1 -W1 "$HOST" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\) ms.*/\1/p')
  lansun=$(curl -s -o /dev/null -m 1 -w '%{http_code}' "http://$LANHOST:47989/serverinfo" 2>/dev/null)
  lan=$(ping -c1 -W1 "$LANHOST" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\) ms.*/\1/p')
  echo "$ts wifi=$wifi ip=$ip4 http=[${http:-000}] icmp_ms=${icmp:--} lan_ms=- lan_sun=000" >> "$LOG"
  if [ $((n % 5)) -eq 0 ]; then
    info=$(sudo -n zerotier-cli info 2>/dev/null | awk '{print $5}')
    zt=$(sudo -n zerotier-cli -j peers 2>/dev/null | python3 -c 'import json,sys
out=[]
for p in json.load(sys.stdin):
    if p.get("role") != "LEAF": continue
    pref=[x["address"] for x in p.get("paths",[]) if x.get("preferred")]
    out.append("%s lat=%s pref=%s" % (p["address"], p.get("latency"), ",".join(pref) or "-"))
print(" | ".join(out))' 2>/dev/null)
    echo "$ts zt info=${info:-?} $zt" >> "$LOG"
  fi
  n=$((n+1))
  sleep 1
done
