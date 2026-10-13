import re, subprocess, sys, os, time, datetime
# Per-network addresses come from the environment (see the ZeroTier doc, section 9).
W12PC_NODE = os.environ['W12PC_NODE']   # ZeroTier node ID of the W12PC
W12PC_LAN = os.environ['W12PC_LAN_IP']  # W12PC address on the home LAN
CLAW_LAN = os.environ['CLAW_LAN_IP']    # Claw address on the home LAN
LOG = os.path.expanduser('~/claw-zt-monitor.log')
CAP = "/var/tmp/claw-lan-cap.pcap"
lines = open(LOG, errors='replace').read().splitlines()
marks = [i for i, l in enumerate(lines) if ' MARK suspend-request' in l]
if not marks:
    sys.exit('no suspend markers in log')
m = marks[int(sys.argv[1]) if len(sys.argv) > 1 else -1]

def to_epoch(s):
    dt = datetime.datetime.strptime(s[:23], '%Y-%m-%d %H:%M:%S.%f')
    return time.mktime(dt.timetuple()) + dt.microsecond / 1e6

t_req = to_epoch(lines[m])
jr = subprocess.run(['journalctl', '-b', '0', '-o', 'short-unix', '--no-pager',
                     '--since=@%d' % (t_req - 5), '--until=@%d' % (t_req + 900)],
                    capture_output=True, text=True).stdout.splitlines()
ev = []
for l in jr:
    mm = re.match(r'^(\d+\.\d+) \S+ (.*)$', l)
    if mm:
        ev.append((float(mm.group(1)), mm.group(2)))

def first(pred, after=0.0):
    for t, msg in ev:
        if t >= after and pred(msg):
            return t
    return None

t_entry = first(lambda s: 'PM: suspend entry' in s)
t_exit = first(lambda s: 'PM: suspend exit' in s, t_entry or 0)
rel = lambda t: ('+%.1fs' % (t - t_exit)) if t else 'none'
t_link = first(lambda s: 'wlp44s0f0' in s and 'device activated' in s, t_exit)
t_cws = first(lambda s: 'claw-wifi[' in s and 'full recovery start' in s, t_exit)
t_cwd = first(lambda s: 'claw-wifi[' in s and 'full recovery done' in s, t_exit)
re_suspend = [t for t, msg in ev if 'PM: suspend entry' in msg and t_exit and t > t_exit]

samples, zts = [], []
for l in lines[m + 1:]:
    if len(l) < 24:
        continue
    try:
        ep = to_epoch(l)
    except ValueError:
        continue
    if ' wifi=' in l:
        code = re.search(r'http=\[(\d{3})', l)
        icmp = re.search(r'icmp_ms=(\S+)', l)
        lan = re.search(r'lan_ms=(\S+)', l)
        up = ' wifi=up' in l
        samples.append((ep, code.group(1) if code else '?', (icmp.group(1) if icmp else '-') if up else '-', (lan.group(1) if lan else '-') if up else '-'))
    elif ' zt info=' in l:
        info = re.search(r'info=(\S+)', l)
        lanp = re.search(re.escape(W12PC_NODE) + r' lat=\S+ pref=(\S+)', l)
        zts.append((ep, info.group(1) if info else '?', bool(lanp and lanp.group(1).startswith(W12PC_LAN + '/'))))

after = [s for s in samples if t_exit and s[0] >= t_exit]
def first_after(pred):
    return next((s[0] for s in after if pred(s)), None)
t_http = first_after(lambda s: s[1] == '200')
t_zt_ping = first_after(lambda s: s[2] != '-')
t_lan_ping = first_after(lambda s: s[3] != '-')
t_lan_pref = next((z[0] for z in zts if t_exit and z[0] >= t_exit and z[2]), None)
info_changes, prev = [], None
for ep, info, _ in zts:
    if t_exit and ep >= t_exit and info != prev:
        info_changes.append('%s@%s' % (info, rel(ep)))
    prev = info

cap = []
if os.path.exists(CAP):
    out = subprocess.run(['tcpdump', '-nn', '-tttt', '-r', CAP], capture_output=True, text=True).stdout
    for l in out.splitlines():
        if len(l) > 26 and l[:4].isdigit():
            try:
                cap.append((to_epoch(l), l.strip()))
            except ValueError:
                pass
def cfirst(pred):
    return next((t for t, s in cap if t_exit and t >= t_exit and pred(s)), None)
c_arp_req = cfirst(lambda s: 'ARP' in s and 'who-has ' + CLAW_LAN in s)
c_arp_rep = cfirst(lambda s: 'ARP' in s and 'Reply ' + CLAW_LAN + ' is-at' in s)
c_peer_in = cfirst(lambda s: 'UDP' in s and W12PC_LAN + '.' in s and '> ' + CLAW_LAN + '.' in s)
c_claw_out = cfirst(lambda s: CLAW_LAN + '.' in s and '> ' + W12PC_LAN + '.9993' in s)

print('cycle marker %d: request %s, suspended %s' % (m, lines[m][11:19], ('%.1fs' % (t_exit - t_entry)) if t_entry and t_exit else '?'))
print('  wifi link up (NM activated):      %s' % rel(t_link))
print('  claw-wifi start / done:           %s / %s' % (rel(t_cws), rel(t_cwd)))
print('  LAN ping W12PC LAN addr ok:  %s' % rel(t_lan_ping))
print('  ZT LAN path preferred (W12PC):     %s' % (rel(t_lan_pref) if t_lan_pref else 'not seen'))
print('  ZT ping W12PC ok:                 %s' % rel(t_zt_ping))
print('  Sunshine HTTP 200 first ok:       %s' % rel(t_http))
print('  ZT online-state changes:          %s' % (' '.join(info_changes) or 'none logged'))
print('  LAN capture: ARP who-has .172:    %s' % rel(c_arp_req))
print('  LAN capture: ARP reply .172:      %s' % rel(c_arp_rep))
print('  LAN capture: first Claw->W12PC UDP: %s' % rel(c_claw_out))
print('  LAN capture: first W12PC->Claw UDP: %s' % rel(c_peer_in))
print('  extra suspend entries after resume: %d' % len(re_suspend))
