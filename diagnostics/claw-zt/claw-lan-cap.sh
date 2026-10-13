#!/bin/bash
# Read-only capture (run as root via systemd-run, writes a world-readable pcap): ARP and ZeroTier UDP to/from the W12PC LAN address.
exec /usr/sbin/tcpdump -i wlp44s0f0 -nn -U -Z root -s 96 -w /var/tmp/claw-lan-cap.pcap "arp or (udp port 9993 and host ${W12PC_LAN_IP:?set W12PC_LAN_IP})"
