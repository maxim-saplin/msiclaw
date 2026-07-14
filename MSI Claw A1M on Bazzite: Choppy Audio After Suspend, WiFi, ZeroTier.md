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