## MSI Claw customizations inventory

### Hibernate (core workaround for Bazzite + BTRFS)

| Item             | Location / detail                                                                                                                                       |
|------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| Hibernate script | `/usr/local/bin/claw-hibernate.sh` — BTRFS swap, dynamic `resume`/`resume_offset`, calls sleep **pre** hooks, sets `/run/claw-hibernate-resume.pending` |
| Swap file        | `/var/swap/hibernate.swap` (~19 GB, on `nvme0n1p6`)                                                                                                     |
| Swap unit        | `/etc/systemd/system/var-swap-hibernate.swap.swap` — **disabled** at boot (intentional)                                                                 |
| Kernel cmdline   | `resume=PARTUUID=a265b280-4539-47fa-b590-bf36612b6ce6` + `resume_offset=15888907` (PARTUUID fix for dual-partition BTRFS)                               |
| Sleep policy     | `/etc/systemd/sleep.conf.d/claw-hibernate.conf` — `AllowHibernation=yes`, `AllowHybridSleep=no`                                                         |
| HHD → hibernate  | `/usr/local/lib/hhd-bin/systemctl` wrapper → `claw-hibernate.sh`                                                                                        |
| HHD drop-ins     | `hhd.service.d/hibernate.conf` (PATH), `zz-swap-off.conf` (`HHD_SWAP_CREATE=0`)                                                                         |
| Decky plugin     | `~/homebrew/plugins/hiberdecky` — QAM moon tile, calls script, 60s post-resume cooldown                                                                 |
| Mac source repo  | `~/src/msiclaw/hiberdecky` (+ `PLAN.md`, `docs/hibernate-resume.md`)                                                                                    |

**Why:** Stock `systemctl hibernate` / HHD alone fail on multi-device BTRFS; boot-time swap wipes the image.

---

### WiFi after sleep/hibernate

| Item               | Location / detail                                                                                                    |
|--------------------|----------------------------------------------------------------------------------------------------------------------|
| Post-resume script | `/usr/local/bin/claw-wifi-post-resume.sh` — HTTP verify, `CheckConnectivity` dbus refresh, poll until global+wlan0 full, ZT after WiFi; `--refresh-only` for light pass |
| NM dispatcher      | `/etc/NetworkManager/dispatcher.d/99-claw-wifi-post-resume` — wlan0 `up`/`dhcp4-change` + `connectivity-change` → refresh if not full |
| rp_filter fix      | `/etc/sysctl.d/99-msi-claw-wlan-rp-filter.conf` (`wlan0=0`); `/etc/udev/rules.d/99-msi-claw-zt-rp-filter.rules` (`zt*=0`) |
| Install script     | `~/src/msiclaw/scripts/install-claw-wifi-hooks.sh` (sudo) — deploy from Mac repo |
| Sleep hook (WiFi)  | `50-msi-claw-s2idle-power.sh` — BE200 `d3cold_allowed=0` before sleep, WiFi recovery after                           |

---

### Suspend (s2idle) hooks

| Item            | Location / detail                                                                                                                           |
|-----------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| Sleep hook      | `/etc/systemd/system-sleep/50-msi-claw-s2idle-power.sh` — BT block, ZT stop, fingerprint USB unbind, gamepad rebind, battery kick, WiFi fix, s2idle fan-quiet. Repo copy tracked at `system/system-sleep/50-msi-claw-s2idle-power.sh`. |
| Suspend drop-in | `systemd-suspend.service.d/msi-claw-s2idle.conf`                                                                                            |
| Audio fix       | `99-audio-resume-fix.disabled` — **disabled**                                                                                               |
| Fans loud in sleep-when-hot | EC owns the fan curve (`msi_wmi_platform`: `pwm*_enable` only accepts 1/2, **no `pwm*` duty file**, `auto_point*_pwm` writes don't stick). In s2idle the EC keeps its curve live, so entering hot leaves fans audible until the SoC passively drops below ~50 °C (curve floor). **True "fans off" is not achievable from the OS.** Only lever: `platform_profile` — `low-power` trims ~15% RPM at a given temp. Mitigation (2026-07-08): sleep hook sets `platform_profile=low-power` on **s2idle entry only** (gated `$2=suspend`; hibernate/S4 powers off anyway) and restores the saved profile on resume (HHD also re-asserts its own profile ~4s after wake). `SLEEP_PROFILE` var at top of hook. |
| `fw-fanctrl-suspend` noise | `/usr/lib/systemd/system-sleep/fw-fanctrl-suspend` errors `exit status 1` on every sleep — **benign**: `fw-fanctrl` (Framework tool) is disabled/inactive and doesn't control the Claw's fans. Lives in immutable `/usr`; leave it. |

---

### Battery / charging

| Item               | Location / detail                                                         |
|--------------------|---------------------------------------------------------------------------|
| Charge kick script | `/usr/local/bin/claw-battery-charge-kick.sh` — post-resume charging nudge |
| HHD setting        | `charge_limit: p80` in `/etc/hhd/state.yml`                               |

---

### Power / input

| Item            | Location / detail                                                                                                               |
|-----------------|---------------------------------------------------------------------------------------------------------------------------------|
| Power key       | `/etc/systemd/logind.conf.d/zz-claw-power.conf` — `HandlePowerKey=ignore` (short press was causing suspend after hibernate resume). **`zz-` prefix is required**: drop-ins merge last-wins by filename, and `deck.conf` (`HandlePowerKey=suspend`) sorts after `claw-power.conf`, silently overriding it. `zz-` sorts after `deck.conf` so `ignore` wins. Verify live: `busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandlePowerKey`. |
| Bazzite default | `deck.conf` — still has `KillUserProcesses=true` and `HandlePowerKey=suspend` (the latter is overridden by `zz-claw-power.conf`)  |
| HHD DPMS        | `gamemode.gamescope.dpms: false` in `/etc/hhd/state.yml` ("Poweroff screen before sleep"). Default `true` re-fires a stale DPMS timer just after hibernate resume → panel powered off → logind suspends again ~28s post-wake. Fixed + confirmed 2026-07-03. (Was one cause of black-screen-on-resume; see next row for the other.) |
| Post-hibernate power-press guard | **The other "black screen after hibernate resume" cause** (recurred with DPMS already off, 2026-07-08). The power press used to *wake* from S4 is queued into HHD's own power-button handler (`PBTN`), which fires `steam://shortpowerpress` ~15-20s post-resume → Steam asks logind to suspend → device drops to black (often a 2s suspend-then-wake, or stays black until you press power again). Note logind `HandlePowerKey=ignore` does **not** cover this — HHD's `powerbuttond` is a separate path straight to Steam. Fix: `claw-hibernate.sh` holds a `systemd-inhibit --what=sleep --mode=block` for `${CLAW_PBTN_GUARD_SECS:-30}`s right after `echo disk` returns (runs as root, so the block inhibitor is permitted). Confirm on next resume: journal `claw-hibernate: post-resume: blocking sleep 30s to swallow stale power press` and no suspend in that window. Normal power-button suspend still works outside the window. |
| gamescope xe noise | `drm: drmModeAddFB2WithModifiers failed: Invalid argument` + `drm: flip error: Device or resource busy` from `gamescope-session-plus` are **benign, continuous** on `xe`/Meteor Lake — fire during normal menus, plugin/HHD restarts, hibernate *entry*, and clean resumes alike. **Not** the black-screen cause (decorrelated: present on good resumes). Do not chase unless a black screen recurs with DPMS already off. |

---

### HHD / device quirks (from earlier in session)

| Item             | Detail                                                          |
|------------------|-----------------------------------------------------------------|
| Gamepad USB      | `3-9` kept at `power/control=on` in sleep hook (no autosuspend) |
| RTC              | `timedatectl set-local-rtc 0` (dual-boot clock)                 |
| `hibernate_auto` | HHD default — emergency hibernate at ~5% battery                |

---

### Admin / deploy (on device only, not in Decky repo)

| Item        | Location                                                           |
|-------------|--------------------------------------------------------------------|
| Sudo toggle | `~/bin/msi-sudo-nopasswd` — `enable` / `disable` passwordless sudo |

---

### Experimental / leftover (not part of active stack)

Scripts in `/usr/local/bin/`: `claw-sleep-experiment.sh`, `claw-sleep-ltr-test.sh`, `claw-sleep-quicktest.sh`, `claw-sleep-snapshot.sh`, `claw-sleep-wifi-local-test.sh` — from earlier sleep debugging.

---

### Intentionally **not** done / avoid

- Boot-time auto-`swapon` of hibernate swap  
- `mem_sleep_default=deep`  
- `HHD_SWAP_CREATE=1`  
- `snd_hda_intel` workaround  
- Gamepad USB autosuspend on `3-9`  
- `resume=UUID=...` (ambiguous across BTRFS partitions)  

---

**One-liner:** Custom hibernate path (script + swap + PARTUUID kargs + HHD/Decky wiring), sleep/WiFi/battery hooks for MSI Claw quirks, Decky one-button hibernate plugin, power-key change to stop post-resume suspend loops.