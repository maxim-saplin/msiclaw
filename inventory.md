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
| Post-resume script | `/usr/local/bin/claw-wifi-post-resume.sh` — reconnect, connectivity check, hibernate post-hooks, 60s cooldown marker |
| NM dispatcher      | `/etc/NetworkManager/dispatcher.d/99-claw-wifi-post-resume`                                                          |
| rp_filter fix      | `/etc/sysctl.d/99-wlan-rp-filter.conf` — `wlan0 rp_filter=0`                                                         |
| Sleep hook (WiFi)  | `50-msi-claw-s2idle-power.sh` — BE200 `d3cold_allowed=0` before sleep, WiFi recovery after                           |

---

### Suspend (s2idle) hooks

| Item            | Location / detail                                                                                                                           |
|-----------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| Sleep hook      | `/etc/systemd/system-sleep/50-msi-claw-s2idle-power.sh` — BT block, ZT stop, fingerprint USB unbind, gamepad rebind, battery kick, WiFi fix |
| Suspend drop-in | `systemd-suspend.service.d/msi-claw-s2idle.conf`                                                                                            |
| Audio fix       | `99-audio-resume-fix.disabled` — **disabled**                                                                                               |

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
| Power key       | `/etc/systemd/logind.conf.d/claw-power.conf` — `HandlePowerKey=ignore` (short press was causing suspend after hibernate resume) |
| Bazzite default | `deck.conf` — still has `KillUserProcesses=true`                                                                                |

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