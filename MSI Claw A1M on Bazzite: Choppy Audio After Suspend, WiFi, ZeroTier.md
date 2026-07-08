Post-sleep choppy/fast-forward audio on the MSI Claw A1M was mainly a **real-time clock (RTC) bug on resume**, not a PipeWire-only issue and not something fixed by cranking CPU power. Setting the hardware clock to **UTC** (`timedatectl set-local-rtc 0`) made suspend/resume timing sane and audio recover after a brief glitch. A separate issue — **game controller dead in Proton while Steam UI still worked** — was caused by HHD **DInput mode**; disabling it and restarting the game fixed that. **Post-sleep sticks/dpad/buttons dead (Steam button OK)** is a different bug — MSI gamepad USB `3-9` breaks after sleep unless rebinded. **Sluggish pad for ~15s after wake** was our sleep hook restarting HHD after rebind (fixed — rebind only). Skip `snd_hda_intel` modprobe tweaks; this machine uses **Intel SOF** (`sof-hda-dsp`).

---

> Claw A1M Bazzite: audio glitch = `timedatectl set-local-rtc 0`; WiFi after sleep = BE200 `d3cold_allowed=0` + `claw-wifi-post-resume.sh` (ZT after WiFi, `rp_filter=0`, **no WiFi rfkill / nmcli in hook**); gamepad after sleep = USB `3-9` rebind only (**no autosuspend**, **no HHD restart in hook**); battery stuck = `claw-battery-charge-kick.sh` (HHD limit sync); ZeroTier = ensure-online service; Proton pad = HHD DInput off + restart game; sleep drain/fan in sleep ~2%/h = **same on Windows** (DRIPS 0%), shutdown for long idle; wake black-screen/flash→re-sleep = **Gamescope DPMS off** (`gamemode.gamescope.dpms: false`) — this *is* the black screen, gamescope `drmModeAddFB2WithModifiers`/`flip error` spam is a red herring (§7c). Skip `snd_hda_intel` and `mem_sleep_default=deep`.

## TL;DR

| Problem                                                       | Fix                                                                                    | Status                           |
|---------------------------------------------------------------|----------------------------------------------------------------------------------------|----------------------------------|
| Choppy / fast-forward audio after sleep                       | `timedatectl set-local-rtc 0` + reboot                                                 | **Fixed**                        |
| Controller dead in Proton, OK in Steam UI                     | HHD **DInput off** → restart HHD + **restart game**                                    | **Fixed**                        |
| Sticks/dpad/buttons dead after sleep (Steam btn OK)           | Sleep hook: **no USB autosuspend** on `3-9`; **USB rebind** on wake                    | **Fixed**                        |
| Controller sluggish ~15s after wake                           | Removed **redundant `systemctl restart hhd`** from sleep hook (rebind only)            | **Fixed**                        |
| WiFi dead after sleep                                         | BE200 `d3cold_allowed=0` (udev) + sleep hook                                           | **Fixed**                        |
| WiFi exclamation / "no internet" after wake                   | `rp_filter=0` on wlan0 + `claw-wifi-post-resume.sh`; ZT starts **after** WiFi verified | **Fixed**                        |
| Battery "not charging" on AC (at limit or after Windows boot) | `claw-battery-charge-kick.sh` syncs HHD `p85` → sysfs; `--retry` on wake               | **Fixed**                        |
| ZeroTier OFFLINE after boot                                   | `zerotier-ensure-online.service`                                                       | **Fixed**                        |
| Sleep hook on power-button suspend                            | `systemd-suspend.service.d` drop-in                                                    | **Fixed**                        |
| Fan spinning during sleep                                     | Shallow `s2idle`, no S0ix — **Windows same**                                           | **Not fixed**                    |
| Wake → black screen / brief flash → sleep again               | HHD **Gamescope DPMS** panel-off on wake (`gamemode.gamescope.dpms: false`); §7c        | **Fixed**                        |
| Sleep battery drain (~2%/h)                                   | Firmware floor (S0ix never engages) — **measured 1.20 W / 2.05%/h on battery**          | **Unfixable in-OS** → suspend-then-hibernate |

---

## Hardware (short)

- **Audio:** SOF `sof-hda-dsp`, PCI `8086:7e28` — **not** `snd_hda_intel`
- **WiFi:** BE200 `8086:272b` at `0000:2b:00.0`, drivers `iwlmld` + `iwlwifi` — **not** CNVi `8086:7e40`
- **Gamepad:** MSI USB `0db0:1902` at `usb 3-9` (built-in; not Bluetooth)
- **Sleep:** `s2idle` only — **`mem_sleep_default=deep` = cold reboot**

---

## 1. Audio after suspend

**Cause:** RTC in local TZ → clock jumps ~3h on wake while real sleep is ~0.1s → PipeWire/SOF timing breaks.

**Fix:**
```bash
sudo timedatectl set-local-rtc 0
sudo reboot
```

**Also installed:**
- `/etc/modprobe.d/50-msi-claw-sof.conf` — SOF quirks
- `/etc/udev/rules.d/99-msi-claw-audio-pm.rules` — audio PCI `power=on`
- `~/.config/wireplumber/wireplumber.conf.d/80-alsa-headroom.conf` — Bazzite profile typo workaround

**Don't:** `snd_hda_intel` modprobe, PCI unbind hooks, PipeWire restart mid-game (needs **game restart**).

---

## 2. WiFi after suspend

### 2a. WiFi dead (no association)

**Cause:** BE200 (`8086:272b`, `0000:2b:00.0`) enters D3cold on `s2idle` wake and can't return to D0 — WiFi dead until reboot.

**Fix:**
```bash
# /etc/udev/rules.d/99-be200-no-d3cold.rules
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x272b", ATTR{d3cold_allowed}="0"
```

Sleep hook (section 6) also sets `d3cold_allowed=0` before sleep.

**Removed:** `fix-wifi-sleep.service` — duplicate of the udev rule.

**Don't:** unload `iwlmld` over SSH — kills WiFi, may need reboot.

### 2b. WiFi connected but exclamation / "can't reach internet"

**Cause (observed in logs):** NM can show `CONNECTED_GLOBAL` while apps still fail (`http error 0` in Steam). Contributing factors:

1. **ZeroTier starting before WiFi** on wake → NM sits at `CONNECTED_LOCAL` (ZT only, no default route) → exclamation icon
2. **`rp_filter=2` on wlan0** — Fedora NM docs warn strict rp_filter breaks connectivity checks / reply packets after resume
3. **`systemd-resolved` cache flush** on clock jump (`Clock change detected. Flushing caches.`) right as WiFi comes up
4. LAN/SSH can work while hostname-based internet is still broken for seconds (or longer without recovery)

NM backend is **IWD** (`/etc/NetworkManager/conf.d/iwd.conf`).

**Fix (installed):**

```bash
# /etc/sysctl.d/99-msi-claw-wlan-rp-filter.conf
net.ipv4.conf.wlan0.rp_filter = 0
```

`/usr/local/bin/claw-wifi-post-resume.sh` — after wake: wait for wlan0 connected → flush DNS caches → verify real HTTP (fedora hotspot + 1.1.1.1) → **`busctl CheckConnectivity` + poll until global and wlan0 both `full`** → `nmcli device reapply wlan0` only when already full (icon nudge) or on failed HTTP (up to 3 tries) → **then** start ZeroTier → **second connectivity finalize** after ZT (ZT `rp_filter=0` via udev).

`/etc/NetworkManager/dispatcher.d/99-claw-wifi-post-resume` — wlan0 `up` / `dhcp4-change` (full script); `connectivity-change` when not `full` → `--refresh-only`.

`sudo ~/src/msiclaw/scripts/install-claw-wifi-hooks.sh` — install/update from repo.

SELinux: `/var/lib/iwd/` relabeled `NetworkManager_var_lib_t` — gamescope WiFi toggle was hitting AVC denials on `wfn.psk`.

**Do not** in the sleep hook:
- `rfkill block wlan` — forces full reconnect on wake
- `nmcli device reapply` / `nmcli device connect` **in the hook itself** — fights NM sleep/wake (the background recovery script is OK — it waits for NM first)

**Don't:** manual WiFi off/on spam from gamescope — creates duplicate `wfn` connection profiles and IWD `InProgress` errors.

Brief exclamation (~1s) during `CONNECTED_SITE` → `CONNECTED_GLOBAL` can still happen — that's normal. Stuck exclamation with LAN working = run recovery manually:

```bash
sudo /usr/local/bin/claw-wifi-post-resume.sh
```

---

## 3. Controller after suspend

### 3a. Dead in Proton only (Steam UI OK)

**Cause:** HHD **DInput mode** — physical pad is DirectInput; Proton expects XInput.

**Fix:** DInput **off** in HHD → `sudo systemctl restart hhd` → **exit and relaunch game**.

### 3b. Sticks / dpad / buttons dead after sleep (Steam button still OK)

**Cause:** Built-in gamepad USB `3-9` (`0db0:1902`) hits `input irq status -75` storm after sleep. Sleep hook used to set **USB autosuspend** on `3-9` — restoring `power=on` wasn't enough. Steam button uses separate **MSI WMI hotkeys**, so it can still work.

**Fix (in sleep hook):** keep `3-9` **power=on** (no autosuspend); post-wake **unbind/rebind** `3-9` only. HHD recovers the pad on its own after rebind.

**Manual recovery (if pad still dead):**
```bash
sudo sh -c 'echo 3-9 > /sys/bus/usb/drivers/usb/unbind; sleep 2; echo 3-9 > /sys/bus/usb/drivers/usb/bind'
sudo systemctl restart hhd   # only if rebind alone isn't enough
```

**Don't confuse with 3a** — DInput off won't fix USB `-75` irq storm.

### 3c. Pad sluggish for several seconds after wake (but eventually OK)

**Cause (logs):** Sleep hook did USB rebind → HHD launched emulated pad → hook then **`systemctl restart hhd`** → full HHD cold start (~15–18s: SDL mappings, DPMS handler, relaunch pad). HHD also resets TDP/GPU on wake (+4–5s).

**Fix:** removed HHD restart from sleep hook. Expect **~3–5s** before pad is fully responsive. A few seconds more from HHD TDP/GPU wake timers is normal.

**Optional HHD:** **Steam Powerbutton Handler** (`powerbuttond`) — fine to enable; unrelated to USB `-75`. If wake feels like it **immediately sleeps again**, see §7b (Gamescope DPMS).

---

## 4. ZeroTier after boot

**Fix:** `zerotier-ensure-online.service` + `/usr/local/bin/zerotier-ensure-online.sh` — polls for ONLINE, restarts `zerotier-one` if stuck.

On **resume**, hook stops ZT before sleep; `claw-wifi-post-resume.sh` starts it only after WiFi passes real connectivity checks (not on a fixed 5s timer).

---

## 5. Battery "not charging" on AC

**Cause:** EC/firmware charge path stuck after sleep (`Not charging`, 0A with AC on). Also: **Windows 80% charge limit** can persist into Linux (sysfs `charge_control_end_threshold=80` while HHD wants `p85`) — looks like "not charging" at 80%.

**Fix:**
- `/usr/local/bin/claw-battery-charge-kick.sh` — syncs limit from HHD `state.yml`, nudges EC via threshold 100→limit; `--retry` on wake
- `/etc/udev/rules.d/99-msi-claw-battery-charge-kick.rules` — delayed kick on AC plug-in

**Manual:**
```bash
sudo /usr/local/bin/claw-battery-charge-kick.sh --sync
sudo /usr/local/bin/claw-battery-charge-kick.sh
```

**Normal:** at **85%** with HHD `charge_limit: p85` — intentional hold, not a bug.

---

## 6. Sleep hook (power-button suspend)

Early on, hooks in `/etc/systemd/system-sleep/` didn't run on button suspend. Fixed:

```ini
# /etc/systemd/system/systemd-suspend.service.d/msi-claw-s2idle.conf
[Service]
ExecStartPre=-/etc/systemd/system-sleep/50-msi-claw-s2idle-power.sh pre suspend
ExecStartPost=-/etc/systemd/system-sleep/50-msi-claw-s2idle-power.sh post suspend
```

**Hook does:** rfkill **BT only** (not WiFi), BE200 d3cold, stop fprintd/zerotier, unbind Goodix USB `3-4`, **keep gamepad USB `3-9` power=on** (no autosuspend); post-wake: rebind Goodix, **rebind gamepad `3-9` only** (no HHD restart), battery charge kick (background `--retry`), launch **`claw-wifi-post-resume.sh`** (ZT starts from that script after WiFi verified). **NM handles WiFi reconnect** — no nmcli in hook.

**Hook does NOT:** fix S0ix / sleep drain / fan-off in sleep.

---

## 7. Sleep drain, fan, and wake quirks — NOT FIXED

### 7a. Battery drain (~2%/h) — root-caused (2026-07)

S0ix never engages on Linux. **Windows 11 Modern Standby (Connected)** on same hardware (VMD enabled): **DRIPS 0%**, **~2–2.6%/hr**, power LED stays on. Not a Linux-only regression; platform/firmware floor with connected standby.

**Measured directly (`pmc_core` debugfs + `charge_now` deltas):**
- `slp_s0_residency_usec` stays **0** across every suspend — SoC floors at **Package C8**, never reaches S0ix/C10.
- **On battery: 1.20 W sleep draw, 2.05 %/hr** (~20% / 10h). Same on AC.
- Cause = **wakeup/interrupt storm during freeze** (~60+ `LOC` timer wakes/sec). Diff of `/proc/interrupts` across suspend: worst offender is the **Thunderbolt/TCSS NHI (`00:0d.2`), firing ~280 IRQs/min even while OS-suspended** — not OS-fixable. Also HD-audio `00:1f.3`, xHCI `00:14.0`, EC (IO-APIC IRQ 9), BE200 WiFi.

**Ruled out (don't re-chase):**
- **Disable VMD in BIOS** → fixes only *runtime* idle S0ix (minor active-battery gain); **zero** effect on suspend drain. ⚠️ Also risks Windows boot (`INACCESSIBLE_BOOT_DEVICE`) — Windows here was installed with VMD on. Re-enable it unless you want the runtime gain and don't dual-boot.
- **AC unplugged** (charger is the only USB-C/TCSS port): TBT storm + drain unchanged → charge link is not the cause.
- **Quiescing** gamepad/Thunderbolt/audio before suspend → still 0% S0ix.
- **VT-d** → not a factor (IRQ/DMA remapping, not platform wake).
- **`mem_sleep_default=deep`** → still cold-reboots this board.

**Fix = hibernate.** RTC wake works (verified: a 90 s alarm fired to the exact second; use `rtcwake -u` since RTC is UTC), so **suspend-then-hibernate is viable** — but it must route to the custom `claw-hibernate.sh` (native systemd hibernate fails on the multi-device BTRFS). Quick s2idle for short breaks → auto-hibernate after N min → ~0% overnight. Shutdown/hibernate for long idle (8h+).

**Debug gotchas:** `/tmp` is `noexec` on Bazzite (run scripts via `bash /path` or from `$HOME`); `systemctl suspend` returns async (measure real sleep via journal `PM: suspend entry/exit` or use `rtcwake`, which blocks); after an `rtcwake` self-wake with no active session, HHD/logind **re-suspends** the device (goes unreachable until a power-button tap).

### 7b. Fan audible during "sleep"

**Observed:** Fan can run while device appears asleep (including long `s2idle` sessions). Logs show real `PM: suspend entry` / `suspend exit` — not a failed suspend, but **shallow sleep** with SoC still warm. Fan may also run during the **pre-suspend freeze** phase (seconds before hardware sleeps). **No software fan-off** — MSI EC/firmware; `fw-fanctrl-suspend` is a Framework script and fails here (ignore).

### 7c. Wake → black screen / flash → sleeps again  ✅ FIXED

**Observed:** HHD enables **Gamescope DPMS** on sleep entry; on wake, **`DPMS timeout lapsed`** (~30 min timer, can coincide with wake) → logind **`The system will suspend now!`** again. The panel-off from DPMS **is** the "black screen after hibernate resume" — not a compositor/DRM failure.

**Fix applied (2026-07-03):** Set `gamemode.gamescope.dpms: false` in `/etc/hhd/state.yml` (HHD → "Poweroff screen before sleep" = off), restart `hhd.service`. Confirmed on a hibernate resume: panel stayed on, no re-sleep.

**Red herring — do NOT chase:** gamescope logs `drm: drmModeAddFB2WithModifiers failed: Invalid argument` and `drm: flip error: Device or resource busy` on `xe`/Meteor Lake. These are **continuous background noise** — they fire during normal menu use, plugin restarts, and hibernate *entry*, and they appear on **clean resumes with no black screen**. They are decorrelated from the black screen; an earlier incident report wrongly fingerprinted them as the cause. Ignore unless a black screen recurs *with DPMS already disabled*.

Also required so a stray power tap during this window can't re-suspend: power key must be `ignore` and win the logind drop-in merge — see §Power/input (`zz-claw-power.conf`).

**Never do:** `mem_sleep_default=deep`, `modprobe -r intel_vpu`, PCI audio unbind hook, ROG Ally fingerprint rule, **USB autosuspend on gamepad `3-9`**.

---

### 8. Passwordless sudo

For easier CLI, e.g. agent sshing into device and doing stuff use the below script:
```
sudo ~/bin/msi-sudo-nopasswd enable    # last password prompt
~/bin/msi-sudo-nopasswd status
sudo ~/bin/msi-sudo-nopasswd disable   # turn password back on
```

The script:

```
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
```
```