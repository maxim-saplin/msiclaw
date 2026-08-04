# WiFi Hotspot Reshare & WireGuard Gateway (viability)

Research on **msi-claw-b** (Bazzite deck, 2026-08-04): can the Claw reshare its Wi‑Fi as a hotspot, and later transparently share a WireGuard tunnel to hotspot clients?

---

## The short answer (read this first)

**Yes — single-radio Wi‑Fi reshare depends on an externality: what Wi‑Fi the Claw is connected to.**

On one radio, the hotspot **must use the same channel as the upstream network**. So the upstream SSID’s band/channel/regulatory flags decide whether reshare is allowed:

| Upstream Wi‑Fi the Claw joins | Can it reshare on the built-in radio? |
|-------------------------------|----------------------------------------|
| **2.4 GHz** (normal home AP) | **Likely yes** — same-channel concurrent AP is allowed |
| **5 GHz non-DFS**, IR allowed | **Maybe** — only if that channel allows AP beaconing |
| **5 GHz DFS** (e.g. test-day uplink ch 112) | **No** — client OK, AP beacon blocked (`NO-IR RADAR`) |
| Want **5 GHz in / 2.4 GHz out** | **No** on one radio — needs a **second NIC** (USB Wi‑Fi/eth) |

This is not “the Claw’s Wi‑Fi is broken.” The radio can do concurrent STA+AP. **Whether reshape works is driven by the network it consumes**, because AP and STA are forced onto that network’s channel.

Stock `nmcli hotspot` is a separate dead end: it **replaces** the client link instead of sharing it.

WireGuard transparent share is a later step and is software-ready; it does not fix the upstream-channel gate.

---

## TL;DR

| Question | Answer | Status |
|----------|--------|--------|
| Does reshare depend on upstream Wi‑Fi type? | **Yes** — same-channel only; DFS/NO-IR uplink blocks AP | Confirmed |
| Hardware AP mode? | Yes (Intel BE200, iwd `SupportedModes: station, ap, ad-hoc`) | Confirmed |
| Concurrent STA + AP vif? | Yes — `iw phy phy0 interface add ap0 type __ap` while STA connected | Confirmed |
| `nmcli device wifi hotspot` while online? | No — mode-switches `wlan0` to AP, drops uplink | Confirmed (broke SSH) |
| Beacon AP on current channel (112 / 5560)? | No — `Frequency 5560 not allowed for AP mode (NO-IR RADAR)` | Confirmed |
| Same-channel constraint for managed+AP? | Yes — `#channels <= 1` | From nl80211 |
| 5 GHz uplink + 2.4 GHz hotspot? | No (single radio / normal AP mode) | From nl80211 |
| WireGuard tools / kernel? | Present (`wg`, `wg-quick`, module); no tunnel configured | Ready |
| Transparent WG gateway (clients don’t run WG)? | Viable once AP works: forward + MASQUERADE out `wg0` | Not tested |
| Reliable reshape without fighting radio? | Second NIC (USB eth / USB Wi‑Fi) | Recommended |

---

## Device snapshot (test day)

| Item | Value |
|------|--------|
| Host | `msi-claw-b` |
| OS | Bazzite 43 (Kinoite / bazzite-deck), ostree `43.20260420.0` |
| Kernel | `6.17.7-ba29.fc43.x86_64` |
| Wi‑Fi | Intel BE200 `8086:272b`, drivers `iwlmld` + `iwlwifi` + `mac80211` |
| Stack | NetworkManager + **iwd** backend (`wifi.backend=iwd`) |
| Uplink | `wlan0` STA, ch **112** (5560 MHz, 80 MHz), DFS |
| Other tunnels | ZeroTier `zt6ntnkqw7` up; no WireGuard iface |
| Extra NICs | None (no ethernet) |
| Layered pkgs | `grubby`, `zerotier-one` — **no `hostapd`** |
| Regdomain | phy self-managed **GB**; many 5 GHz channels `NO-IR` / DFS / `PASSIVE-SCAN` |

---

## Interface combinations (phy0)

```
#{ managed } <= 2, #{ P2P-client, P2P-GO } <= 1, #{ P2P-device } <= 1,
  total <= 4, #channels <= 2

#{ managed } <= 2, #{ AP, P2P-client, P2P-GO } <= 1, #{ P2P-device } <= 1,
  total <= 4, #channels <= 1
```

Implications:

- **AP + STA** must share **one channel**.
- **P2P-GO + STA** may use **two channels** (possible alternate hotspot path; not tested end-to-end).
- You cannot put AP on 2.4 GHz while STA stays on 5 GHz in true AP combo mode.

---

## Tests performed

### 1. Stock NM hotspot (failed as reshare)

```bash
sudo nmcli device wifi hotspot ifname wlan0 ssid ClawShare password '…'
```

- iwd started AP `ClawShare` on `wlan0` (“IWD AP/AdHoc state is now Started”).
- **Replaced** the station connection — no concurrent reshare.
- SSH/uplink died until Wi‑Fi was toggled in the UI.
- Leftover NM profile `Hotspot` was deleted after recovery.

### 2. Concurrent AP vif (succeeded)

With STA still associated:

```bash
sudo iw phy phy0 interface add ap0 type __ap
```

- `ap0` appeared (type AP, DOWN); `wlan0` stayed associated.
- Second managed iface (`wlan1`) also creatable (combo allows 2× managed).
- NM saw `ap0` as `wifi` / later `unmanaged`; iwd did **not** expose a second Device for it.
- Vifs deleted cleanly; uplink intact.

### 3. Concurrent beacon via wpa_supplicant `mode=2` (blocked by reg)

`hostapd` is not installed; used built-in `wpa_supplicant` AP mode on `ap0`:

```text
Frequency 5560 (primary) not allowed for AP mode, flags: … NO-IR RADAR
Primary frequency not allowed
Could not select hw_mode and channel. (-3)
ap0: AP-DISABLED
```

STA remained up. **Same-channel reshape on this DFS uplink is regulatory-blocked**, not a missing vif.

Earlier NM-only AP attempts also left dmesg traces:

```text
wlan0: regulatory prevented using AP config, downgraded
```

### 4. Notes / pitfalls from the session

- Remote NM `wifi.share.*` polkit was `no` (needs sudo / local auth).
- Do **not** use `pkill -f 'wpa_supplicant -i ap0'` inside an SSH one-liner that contains that string — it can kill the remote shell.
- `ip_forward` was `0`; firewalld active (`FedoraWorkstation`). Needed for any real gateway later.

---

## WireGuard transparent share (not tested live)

Software already on device:

- `wireguard` kernel module, `wg` / `wg-quick`
- `nft` / `iptables`, `dnsmasq`, firewalld

Intended pattern (once AP or second NIC works):

1. Bring up WG (full-tunnel `AllowedIPs` as desired).
2. Clients join Claw AP / LAN iface.
3. `net.ipv4.ip_forward=1`.
4. MASQUERADE (or proper routing) out `wg0`; firewalld zone for the shared iface.
5. Optionally NM `ipv4.method=shared` if default route is already via WG.

Clients need no WG config — classic NAT gateway. Blocker is **ingress AP**, not WG itself.

---

## Paths forward (ranked)

| Approach | Pros | Cons |
|----------|------|------|
| **USB ethernet or USB Wi‑Fi as AP** (or as uplink) | Boring, reliable; NM shared works | Extra hardware |
| **STA on 2.4 GHz (or non-DFS IR-OK 5 GHz), then concurrent `ap0` + hostapd/wpa AP on same channel** | Uses built-in radio | Half-duplex / ~½ throughput; need `hostapd` (ostree layer) or careful wpa AP; DFS uplink won’t work |
| **P2P-GO dual-channel** | Combo allows `#channels <= 2` | Client UX / NM-iwd support unclear; untested |
| **`nmcli hotspot` on single radio** | Easy | Drops uplink — not a reshare |

Suggested decisive retest (when convenient): connect Claw to a **2.4 GHz** SSID, create `ap0`, start AP on that same channel, add `192.168.4.1/24` + dnsmasq + MASQUERADE out `wlan0`, join from a phone.

---

## Commands cheat-sheet

```bash
# Phy / concurrent caps
iw phy phy0 info | sed -n '/Supported interface modes:/,/Band 1:/p'
iw phy phy0 info | sed -n '/valid interface combinations:/,/HT Capability overrides/p'
iw reg get
iw dev wlan0 link

# Concurrent vif (safe create/delete)
sudo iw phy phy0 interface add ap0 type __ap
iw dev
sudo iw dev ap0 del

# Do NOT use for reshare on this box (drops STA)
# sudo nmcli device wifi hotspot ifname wlan0 ssid ClawShare password '…'
```

---

## Conclusion

- **Core dependency:** single-radio reshare is gated by **what Wi‑Fi the Claw consumes** (same channel + that channel must allow AP). Upstream DFS/NO-IR ⇒ no reshare; normal 2.4 GHz ⇒ plausible.
- **Bypass NM hotspot** for concurrent use (manual vif + hostapd/wpa + NAT). Stock hotspot drops the uplink.
- **Transparent WireGuard share:** straightforward once AP works; tools already present.
- **Production-friendly / band-split (5 in, 2.4 out):** second NIC, not the built-in radio alone.
