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
| W12PC (Moonlight) 20–30 s late after wake — ZeroTier is the only route off the home LAN | Claw side can't shorten it: ZeroTier stays silent ~30 s after resume; restarting it costs ~3 min; §9 | **Open** (measured on home LAN only) |
| Wi-Fi stays disconnected after resume (no NM retry, ~5 min seen 2026-10-12) | `claw-wifi-resume-watchdog.sh` via `systemd-suspend.service.d` drop-in nudges NM at 15 s; §9 | **Working** (normal path verified; stall branch untested) |
| Power button does nothing after reboot in Big Picture (desktop → Big Picture fixes it) | Boot session `gamescope-session-plus steam` never started `steamos-powerbuttond`; drop-in `gamescope-session-plus@steam.service.d` adds it; §10 | **Fixed** (verify on next reboot) |
| `ublue-os-media-automount.service` failed on every boot (`systemctl --failed`) | Script also tries root btrfs member `nvme0n1p7`; drop-in `SuccessExitStatus=1`; §11 | **Fixed** (benign failure; see §11 trade-off) |
| Battery "not charging" on AC (at limit or after Windows boot) | `claw-battery-charge-kick.sh` syncs HHD `p85` → sysfs; `--retry` on wake               | **Fixed**                        |
| ZeroTier OFFLINE after boot                                   | `zerotier-ensure-online.service`                                                       | **Fixed**                        |
| Sleep hook on power-button suspend                            | `systemd-suspend.service.d` drop-in                                                    | **Fixed**                        |
| Fan spinning during sleep                                     | Shallow `s2idle`, no S0ix — **Windows same**                                           | **Not fixed**                    |
| Wake → black screen / brief flash → sleep again               | HHD **Gamescope DPMS** panel-off on wake (`gamemode.gamescope.dpms: false`); §7c        | **Fixed** (this specific mechanism) |
| Long-hibernate resume → black screen (stuck DRM plane, CRTC/panel otherwise healthy) | Gamescope hardware-plane assignment stuck (`drmModeAddFB2WithModifiers` EINVAL), 2 of 5 planes never scanned out; workaround `--disable-layers`; §7c-update (2026-07-14) | **Fixed** (this specific mechanism) |
| WiFi stuck retrying (`supplicant-disconnect` loop) after hibernate resume | `claw-wifi-post-resume.sh` was silently gated behind a wlan0 `up` NM dispatcher event that never fires if wlan0 can't reconnect on its own; now triggered directly from `claw-hibernate.sh`, and `wait_wlan` actively kicks a stuck connection; §WiFi-update (2026-07-14) | **Working so far** (not battle-tested) |
| Long-hibernate resume → black screen (Steam's own CEF renderer, not DRM/gamescope; occasionally hits a running game too) | Root cause: race between Xe driver's post-hibernate cold GPU reinit and a client's buffer-modifier commit; no retry/recreate logic on either side. No OS/config fix found; only known mitigation is manually restarting Steam or the session; §7d (2026-07-14) | **Root-caused, NOT fixed** |
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

### WiFi-update (2026-07-14): stuck-reconnect after hibernate, and a bigger gating gap

Observed: after a hibernate resume, wlan0 repeatedly failed to associate (`state change: config -> failed (reason 'supplicant-disconnect')`, ~4s apart) for **over a minute** before finally connecting (helped along by manually toggling WiFi off/on in the UI, though even that didn't fix it on the very next attempt — looks like the BE200 genuinely needs more time to settle post-hibernate before it'll associate).

**Bigger problem found while digging into this:** `run_hibernate_post_hooks()` in `claw-wifi-post-resume.sh` (bluetooth unblock, fingerprint/gamepad USB rebind, wifi `d3cold` restore — i.e. most of the sleep hook's `post` case) was **only ever invoked when the NM dispatcher noticed wlan0 reach `up`**. If wlan0 gets stuck failing to associate, as above, that dispatcher event never fires — so bluetooth stayed blocked, the fingerprint reader stayed unbound, etc., for as long as WiFi stayed stuck, with nothing to intervene. This is a single point of failure in the whole post-resume hardware-restore chain, not just a WiFi issue.

**Fix:**
- `claw-hibernate.sh` now calls `claw-wifi-post-resume.sh` directly in its post-resume section, instead of relying on the WiFi dispatcher as the sole trigger. Hardware restore now runs promptly regardless of whether WiFi ever reconnects on its own.
- `wait_wlan()` in `claw-wifi-post-resume.sh` now actively intervenes instead of passively polling: forces `nmcli device disconnect wlan0` + `connect wlan0` if not connected after 15s, then cycles the radio via `rfkill block/unblock wifi` if still stuck after 40s (automating the manual toggle that helped above), within the existing 90s budget.

**Status (2026-07-14): working so far**, tested against the corrected, de-duplicated script (see the `claw-hibernate.sh` duplication note in `hiberdecky/docs/hibernate-resume.md` — the first "still broken" result was against the wrong file and doesn't count). `/usr/local/bin/claw-hibernate.sh` is now a symlink to the Decky-bundled copy, so there's only one file to keep in sync going forward.

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

> **Stale (2026-10-13):** the s2idle hook that stops ZeroTier before sleep is not deployed on the Claw, so `zerotier-one` stays up across suspend. Restarting it after resume costs ~3 min of W12PC connectivity; see §9. (The old text described the hook design, not what runs.)

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

> **Not deployed (2026-10-13):** `/etc/systemd/system-sleep/` on the Claw has no copy of `50-msi-claw-s2idle-power.sh`, and there is no `msi-claw-s2idle.conf` drop-in. The suspend drop-ins that run are the gamepad one (`99-msi-claw-gamepad-resume.conf`) and the Wi-Fi watchdog (§9). The repo copy's `pre` step stops `zerotier-one`; don't deploy it as-is (§9).

Early on, hooks in `/etc/systemd/system-sleep/` didn't run on button suspend. Fixed:

```ini
# /etc/systemd/system/systemd-suspend.service.d/msi-claw-s2idle.conf
[Service]
ExecStartPre=-/etc/systemd/system-sleep/50-msi-claw-s2idle-power.sh pre suspend
ExecStartPost=-/etc/systemd/system-sleep/50-msi-claw-s2idle-power.sh post suspend
```

**Hook does:** rfkill **BT only** (not WiFi), BE200 d3cold, stop fprintd/zerotier, unbind Goodix USB `3-4`, **keep gamepad USB `3-9` power=on** (no autosuspend); post-wake: rebind Goodix, **conditionally rebind gamepad `3-9` only if raw HID is missing or the known `usb 3-9: input irq status -75` storm is present** (no HHD restart), battery charge kick (background `--retry`), launch **`claw-wifi-post-resume.sh`** (ZT starts from that script after WiFi verified). **NM handles WiFi reconnect** — no nmcli in hook.

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

**Red herring — do NOT chase (usually):** gamescope logs `drm: drmModeAddFB2WithModifiers failed: Invalid argument` and `drm: flip error: Device or resource busy` on `xe`/Meteor Lake. These are **continuous background noise** — they fire during normal menu use, plugin restarts, and hibernate *entry*, and they appear on **clean resumes with no black screen**. They are decorrelated from the black screen; an earlier incident report wrongly fingerprinted them as the cause. Ignore unless a black screen recurs *with DPMS already disabled* — see the 2026-07-14 follow-up below, which is exactly that exception case.

Also required so a stray power tap during this window can't re-suspend: power key must be `ignore` and win the logind drop-in merge — see §Power/input (`zz-claw-power.conf`).

**Never do:** `mem_sleep_default=deep`, `modprobe -r intel_vpu`, PCI audio unbind hook, ROG Ally fingerprint rule, **USB autosuspend on gamepad `3-9`**.

### 7c-update (2026-07-14): recurrence *with DPMS already off*

A separate black-screen mode recurred on long hibernations (worse the longer the hibernation; short ones mostly fine) — screen black, but HHD's side-menu overlay and MangoHud's perf overlay kept working. This is the exact "ignore unless it recurs with DPMS already disabled" exception the red-herring note above calls out, so it was investigated rather than dismissed.

**Live evidence (not just log noise this time):** caught it live via `sudo cat /sys/kernel/debug/dri/0/state` while the screen was actually black. `crtc[88] pipe A` was `enable=1 active=1` (i.e. **not** DPMS-blanked — a real DPMS-off would show `active=0`), eDP-1 `connected`, backlight `bl_power=0` (on) at real brightness. Of gamescope's 5 compositing planes, 3 had valid attached framebuffers (correct 1920x1080, Intel Tile4 modifier `0x100000000000009`) and **2 were stuck `crtc=(null) fb=0`** — exactly the planes that never got a `drmModeAddFB2WithModifiers` call to succeed. So this time the AddFB2 errors aren't noise decorrelated from the symptom — they coincide with specific planes that never got scanned out, on a resume that is a genuine cold POST + fresh Xe/KMS driver reinit (unlike s2idle, which keeps the same live kernel).

**Workaround applied:** `--disable-layers` (disables libliftoff hardware-plane assignment, forces full GPU compositing to one buffer instead of juggling multiple planes+modifiers). Deployed without touching read-only `/usr`: a `GAMESCOPE_BIN` shim at `/usr/local/bin/claw-gamescope-diag-shim` (execs `gamescope --disable-layers "$@"`) activated via `/etc/gamescope-session-plus/sessions.d/steam` (`export GAMESCOPE_BIN=...`) — both are supported extension points `gamescope-session-plus` already reads, so no vendor files were modified.

**Status (2026-07-14): working so far.** Confirmed the flag is actually being passed (checked `/proc/<pid>/cmdline`), and user-confirmed no recurrence across the subsequent test cycles. Treat as **provisionally fixed, not battle-tested** — it's held up over one testing session, not weeks of normal use. If a black screen ever recurs with `--disable-layers` still active in the running gamescope's cmdline, this workaround is wrong and the plane-modifier theory needs revisiting.

The temporary diagnostic capture (`claw-resume-diag.sh`) that caught the original live evidence has been removed now that this is holding — script deleted, both call sites (`claw-hibernate.sh`, `50-msi-claw-s2idle-power.sh`) reverted, log file deleted. See `hiberdecky/docs/hibernate-resume.md` for the record of what it was.

### 7d (2026-07-14): a second, distinct black-screen mechanism — Steam's own renderer, not DRM/gamescope

Despite `--disable-layers` confirmed still active (checked the running gamescope's `/proc/<pid>/cmdline`), a later long hibernation still produced a black main screen with HHD's overlay and MangoHud still working — same visible symptom as §7c-update, but this time a different, newly-confirmed root cause. Don't conflate the two: §7c-update's stuck-plane mechanism is fixed and stayed fixed; this is a separate bug the same workaround doesn't touch.

**Ruled out gamescope/DRM this time:** `/sys/kernel/debug/dri/0/state` showed `crtc[88] active=1`, backlight on at real brightness, and gamescope's own planes (1A/4A/5A) all had valid attached framebuffers with the correct Tile4 modifier — no stuck `crtc=(null)` planes like §7c-update. `gamescopectl debug_force_repaint` changed nothing (gamescope faithfully recomposited what it already had — so gamescope itself isn't the broken party).

**Confirmed via X11-level capture:** `magick import -window <Steam Big Picture Mode window id>`, bypassing gamescope's compositor entirely, captured the *actual* Steam window content as solid black. The bug is inside Steam's own CEF renderer (`steamwebhelper`), upstream of gamescope, not a scanout/plane problem.

**Mechanism (best-supported theory from the evidence gathered; not traced in kernel/Steam source):** hibernate is a genuine power-off (S4) — unlike `s2idle`, the Xe GPU driver has to cold re-initialize on resume (firmware reload, buffer-tiling-modifier re-validation). Every frozen process/thread wakes simultaneously (`Restarting tasks: Starting`/`Done` land in the same timestamp), so there's a brief, unsynchronized race between "is the Xe driver done re-validating tiled buffer modifiers yet" and "is some client (Steam's UI render surface, or a game) trying to submit its next frame right now." Nothing in this stack makes clients wait for driver-ready before committing; whichever loses the race gets `drmModeAddFB2WithModifiers failed: Invalid argument`, and — critically — neither Steam nor games have retry/recreate logic for that rejection, so the affected surface just stays stale/black indefinitely.

This explains every observed pattern:
- **Why menus/overlays are unaffected:** QAM, notification toasts, and MangoHud are idle until invoked — they don't attempt a GPU commit during the narrow vulnerable window, so by the time they're opened (driver long since settled) they build a fresh context with no problem.
- **Why it's sometimes fine, sometimes not:** pure scheduling-timing luck under a post-resume thundering herd (USB re-enum, Bluetooth, WiFi reassociation, battery logic, HHD wake handling, Steam's own background update check — all competing for CPU at the same instant).
- **Why longer hibernations are worse:** a longer power-off plausibly means a colder GPU/firmware reinit, widening the vulnerable window.
- **Why it can occasionally hit a running game too** (per the original report — "no matter if game is playing or Steam home on screen"): a game's own render surface is just another GPU client that can lose the same race.

**Status: root-caused, NOT fixed.** No config or kernel change has been applied.

- **Kernel update checked:** current is `6.17.7-ba29.fc43` on `bazzite-deck:stable` (image dated 2026-04-20); `rpm-ostree upgrade --check` reported no update available as of 2026-07-14. Web search found the same `drmModeAddFB2WithModifiers` error on other Intel-iGPU + gamescope setups, but no confirmed upstream fix to point to — not worth chasing blindly on an immutable/ostree system without one.
- **Config hardening candidates identified, neither applied (pending a decision):**
  - `gamescopectl backend_set_dirty` in the post-resume hook — forces gamescope to proactively re-poll its DRM backend state. Cheap, low-risk, but only hardens gamescope's own plane/backend layer; does **not** address Steam's own render-context loss confirmed above, since that lives upstream of gamescope.
  - `wayland_use_modifiers` convar set to `0` — would remove tiled-buffer-modifier negotiation entirely, i.e. remove the specific thing that's racing. Closer to a structural fix, but costs real GPU memory-bandwidth/power efficiency device-wide, all the time, not just around hibernate. Untested.
- **The only known mitigation remains manual:** restart Steam, or restart the whole session (`systemctl --user restart gamescope-session-plus@steam.service`) if Steam itself won't recover — same as before this investigation.

**Do NOT send mutating commands (e.g. `Page.reload`) to Steam's own internal webviews via its CDP remote-debugging port** (`steamwebhelper --remote-debugging-port=8080`, reachable at `localhost:8080/json`). Read-only inspection (listing targets, `Page.getFrameTree`) is fine and was useful here. A `Page.reload` sent to the "Steam Big Picture Mode" target during this investigation did not fix the black screen and instead corrupted Steam's internal state — a matching internal assertion failure (`clienthandler.cpp: Assertion Failed: Local file request not allowed for about:blank?...browserType=4...`) appeared in the logs shortly after, and the session went from "black main screen, menus working" to fully unresponsive (menus gone too), requiring a full `gamescope-session-plus@steam.service` restart to recover. The device/OS itself was never at risk throughout (SSH stayed responsive, no kernel errors, no crashed processes) — this was a session-level, not system-level, casualty. Steam's internal browser views are managed directly by its own C++ code and aren't meant to be driven externally like a normal browser tab.

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
---

## 9. Resume latency: W12PC over ZeroTier (2026-10-13)

**Symptom.** After s2idle resume, Moonlight shows the W12PC 20–30 s late. Moonlight's own log for two user cycles put it online at about +17 s and +33 s after wake.

**Why ZeroTier is the only route.** Moonlight's W12PC entry holds ZeroTier addresses (`<W12PC-ZT-IP>` as local and manual; the public `<home-public-IP>` as remote). Sunshine advertises over mDNS on the ZeroTier interface only. The W12PC's ZeroTier node is `<W12PC-ZT-node>`, which also sits on the LAN at `<W12PC-LAN-IP>`. There SMB (445) is open but Sunshine (47989) is refused. Any ZeroTier delay is therefore a delay for Moonlight. Off the home LAN the Claw sits behind provider NAT, so ZeroTier is the only route there too, via NAT traversal or a relay. That path hasn't been measured.

**Measurements.** `systemctl suspend` with an RTC wake after 45 s (s2idle only). Times are seconds after wake.

| Run | Wi-Fi link up | claw-wifi done | ZeroTier LAN path preferred | Sunshine answers |
|---|---|---|---|---|
| Baseline, 09:34 | +1.8 | +11.1 | +8.0 | +32.4 |
| Baseline, 09:40 | +1.7 | +10.8 | +16.1 | +31.6 |
| `zerotier-one` restarted after Wi-Fi (rejected) | +1.6 | +15.2 | ONLINE at ~+8 | none for ~3.3 min |
| Validation, 10:01 (changes below) | +2.5 | +9.6 | +8.1 | +31.6 |

**Findings**

- **Wi-Fi is not the gate.** The link is up within about 2 s of wake and DHCP within about 2.3 s. The `sleep 2` and internet verification in `claw-wifi-post-resume.sh` add about 8 s before "done", but they don't delay ZeroTier.
- **ZeroTier is the gate.** A capture on the LAN shows the W12PC's packets reaching the Claw from about +2.7 s. The Claw sends nothing back until about +30 s, then fires a burst on all its UDP sockets. Both baselines fit this. No ZeroTier log explains it, so treat the ~30 s as observed behaviour, not a documented timer.
- **Restarting `zerotier-one` is worse.** After a restart the peer path returns within seconds. But the tap's ARP entry for `<W12PC-ZT-IP>` stays `INCOMPLETE`, and the W12PC doesn't answer for about 3 min (restart 09:45:22, answer 09:48:33). A static `ip neigh` entry for the W12PC's MAC (`<W12PC-ZT-MAC>`) didn't help. Don't restart ZeroTier on resume.
- **The repo's s2idle hook must not be deployed as-is.** `system/system-sleep/50-msi-claw-s2idle-power.sh` stops `zerotier-one` before suspend. It isn't deployed on the Claw (see §4 and §6), and this is the reason.
- **LAN ICMP to `<W12PC-LAN-IP>` is inconsistent after resume.** One cycle answered at about +4 s; another gave no answer for about 12 s. Not investigated on the W12PC side.
- **Stall gap.** `claw-wifi-post-resume.sh` only runs on NM's wlan `up` event. On 2026-10-12 Wi-Fi sat disconnected for about 5 min after the 21:09 resume with no logged reason, and the 19:46 resume needed minutes of recovery too. Nothing retried association, and the script's own stall logic was unreachable. The stable cloned MAC also changed at 21:09 (`<earlier-Claw-Wi-Fi-MAC>` → `<Claw-Wi-Fi-MAC>`).

**Deployed 2026-10-13.** Repo → device via `scripts/install-claw-wifi-hooks.sh`, run from a staged copy. Every target was checked against the repo by hash, mode and owner.

- `claw-wifi-post-resume.sh`: the unconditional `sleep 2` is gone from the normal resume path. It stays in the hibernate branch.
- `claw-wifi-resume-watchdog.sh` and `systemd-suspend.service.d/99-msi-claw-wifi-resume.conf`: started after every suspend through `ExecStartPost=-systemd-run --no-block`, so it runs in its own unit. At 15 s, if `wlp44s0f0` is disconnected, unavailable or failed, it runs `nmcli device connect`. If still stuck at 40 s it cycles the radio with rfkill. A normal resume logs "nothing to do" (verified). The stall branches are not yet exercised.
- Reconciled the repo with the device: `99-claw-wifi-post-resume` (interface detection, instead of hard-coded `wlan0`), `99-msi-claw-wlan-rp-filter.conf` (`all`/`default`, instead of `wlan0`), and `zerotier-ensure-online.{sh,service}` (on the device but missing from the repo). The installer now installs these too.

**Not changed:** ZeroTier configuration, the W12PC, the gamepad drop-in, and the hibernate path.

**Open**

- A LAN route (`<W12PC-LAN-IP>`) is not an option. It only works on the home network, and it would need a W12PC firewall change. Off home, the Claw is behind provider NAT, so ZeroTier is the only path. Every measurement here is from the home LAN, where ZeroTier's W12PC path is direct. Measure the off-home path next time the Claw is on the other Wi-Fi.
- The stored WAN address (`<home-public-IP>:47989`) in Moonlight is a possible second route only if the home router forwards Sunshine's ports. That is unverified; test it from the other network with `curl`.
- Watch the next Wi-Fi stall: `journalctl -t claw-wifi-watchdog`.
- The device's `~/src/msiclaw` clone is a stale copy from 2026-07-03 (it still uses `wlan0`). Refresh it with `scripts/deploy-to-claw.sh --mirror` when convenient. It wasn't run as part of this work.

**Diagnostics** (`diagnostics/claw-zt/`). The scripts read the addresses from the environment, so set them first: `W12PC_ZT_IP` (W12PC ZeroTier address), `W12PC_LAN_IP`, `W12PC_NODE` (its ZeroTier node ID) and `CLAW_LAN_IP`. The addresses are not stored in the repo.

- `claw-zt-monitor.sh`: 1 Hz probe of Wi-Fi state, Sunshine HTTP and ICMP over ZeroTier, LAN ICMP and Sunshine port, and ZeroTier state every 5 s. Run as a user unit: `systemd-run --user --unit=claw-zt-monitor /bin/bash ~/claw-zt-monitor.sh`. Logs to `~/claw-zt-monitor.log`.
- `claw-zt-cycle.sh`: suspend test harness. It writes a marker, arms an RTC wake, and runs `systemctl suspend`. Start it with `sudo systemd-run --unit=claw-test-cycle-$(date +%s) --collect /bin/bash ~/claw-zt-cycle.sh 45`. It never hibernates.
- `claw-zt-analyze.py`: summarises the last cycle from the journal and the probe log.
- `claw-lan-cap.sh`: ARP and ZeroTier UDP capture on the LAN, written to `/var/tmp/claw-lan-cap.pcap`.

**Test-rig notes**

- Use s2idle only (`systemctl suspend` with an RTC wake). Don't hibernate for tests.
- Arming with `rtcwake` overwrote a pre-existing RTC alarm (07:01 UTC). Check `/proc/driver/rtc` before arming.
- SELinux blocks systemd from executing scripts in `/home/user`, so run them with `/bin/bash`. Root can't write into `/home/user`, so use `/var/tmp` for output.

---

## 10. Power button dead after reboot in Big Picture (2026-10-13)

**Symptom.** After a reboot, the power button does nothing in Big Picture. Switching to desktop and back to Big Picture makes it work.

**How the power button works.** `logind` ignores the power key (`/etc/systemd/logind.conf.d/deck.conf`: `HandlePowerKey=ignore`). The key reaches Steam only through the user service `steamos-powerbuttond`, which sends `steam://shortpowerpress`. Without that daemon, the key does nothing.

**Cause.**
- SDDM autologin starts `gamescope-session-steam.desktop` (`/etc/sddm.conf.d/zz-holo-autologin.conf`, `Session=`). That runs `gamescope-session-plus steam`, which starts `gamescope-session-plus@steam.service`.
- `steamos-powerbuttond` is only wanted by `gamescope-session-plus@ogui-steam.service`, through `/usr/lib/systemd/user/gamescope-session-plus@ogui-steam.service.wants/`. The `steam` instance doesn't want it.
- Desktop → Big Picture starts `gamescope-session-ogui-steam.desktop`, which starts the `ogui-steam` instance and so the daemon. That's why the switch fixes it.
- Evidence from boot 2026-10-12 17:54: `steamos-powerbuttond` isn't started until 18:04:43, when SDDM starts `gamescope-session-plus ogui-steam`. No power-button forwarding happens before then. Presses after 18:04 are forwarded.
- The Deck 44 migration runs `ogui-steam`, but the autologin file still points at the older `steam` session.

**Fix (deployed 2026-10-13).** `system/systemd-user/gamescope-session-plus@steam.service.d/10-claw-powerbutton.conf` adds `Wants=steamos-powerbuttond.service` to the `steam` instance. Installed with `scripts/install-claw-powerbutton-session.sh`. The session you boot into doesn't change.

Verified on the device: the hash matches the repo, the mode is 644 root, and `systemctl --user show gamescope-session-plus@steam.service -p Wants` now lists `steamos-powerbuttond.service`. The fix isn't verified across a reboot yet.

**Alternative, not done.** Point the autologin at `gamescope-session-ogui-steam.desktop` through a drop-in in `/etc/sddm.conf.d/` that sorts after `zz-holo-autologin.conf`. That would change the session you boot into, so it's left for a decision.

**Verify on the next reboot.** `journalctl -b 0 | grep "started successfully"` should show `steamos-powerbuttond` starting soon after login. Then press the power button in Big Picture and check for `sending message: steam://shortpowerpress`.

---

## 11. Failed units after boot (2026-10-13)

`systemctl --failed` showed three units. Here is what each one was.

| Unit | Scope | Cause | Status |
|---|---|---|---|
| `ublue-os-media-automount.service` | system | Failed on every boot. The script also tries `/dev/nvme0n1p7`, which is a member device of the root btrfs filesystem (label `bazzite`, four devices: p2, p4, p6, p7). `systemd-mount` refuses because the transient unit `run-media-system-bazzite.mount` already exists (p6 is mounted there). | **Fixed** with a drop-in: `SuccessExitStatus=1` (`system/systemd/ublue-os-media-automount.service.d/10-claw-btrfs-member.conf`, installed by `scripts/install-claw-automount-dropin.sh`). After a restart the unit is `active (exited)` and nothing is failed. Trade-off: the drop-in also hides any other exit 1 from this script. The alternative is disabling the unit, which also stops auto-mounting other drives. |
| `app-steam@autostart.service` | user | Failed on boot 2026-10-12 at 18:04:48. The Plasma desktop session started at 18:04:36 while Steam was already running in the gamescope session (started 18:04:43). The second Steam instance forwarded its launch and timed out. | Benign. It only happens when two sessions overlap, which the desktop-and-back switch does. The boot into the `steam` session doesn't run it. No change. |
| `app-org.kde.krdpserver.service` | user | Same overlap. KRDP lost its Wayland compositor when gamescope took over (18:04:40 to 18:04:43). | Benign, same as above. No change. |

**Current boot (2026-10-13 10:27):** the boot went straight into the `steam` session. Power-button forwarding started at 10:27:20, and the user manager has no failed units.
