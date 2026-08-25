# Bazzite Deck 44 migration

This runbook covers the MSI Claw A1M migration from the current Bazzite Deck 43 deployment to Deck 44.

The first Deck 44 boot is intentionally a native-stack baseline:

- Quarantine the custom hibernate route and `hiberdecky`.
- Quarantine the custom suspend, WiFi recovery, input, battery, audio, and power-button hooks.
- Keep the narrow BE200 PCI D3cold guard enabled; it does not invoke NetworkManager or rfkill.
- Keep the existing Gamescope adjustments, including `--disable-layers` and the DPMS-off setting.
- Preserve the existing ZeroTier installation, node identity, service, and network membership.
- Keep existing Decky plugins except `hiberdecky`; rebuild and verify `uninstalldecky`.
- Retain the UTC RTC setting and preserve hibernate files for rollback, but do not test hibernation during the baseline.

The historical troubleshooting document describes the Deck 43 baseline. This document describes the migration state and the Deck 44 procedure.

## Hibernate on Deck 44

Bazzite's current documentation says Bazzite-Deck provides hibernation through Handheld Daemon using a dynamic swap path exposed at `General -> Hibernate`. That is the upstream/native option, not the custom `hiberdecky` route.

For this MSI Claw, the native option is **not yet validated**. The Deck 43 installation required a custom hibernate script because the stock path could not handle this machine's multi-device BTRFS swap arrangement. During the Deck 44 migration, `hiberdecky`, the HHD hibernate redirect, and the custom suspend/WiFi integration were quarantined. The swapfile and resume metadata were retained only for rollback and a later supervised decision.

Useful local menu access while inspecting Gaming Mode:

- QAM: press the MSI Center M button once, or use `Ctrl`+`2` with a keyboard.
- OpenGamepadUI: long-press the MSI Center M button. Bazzite also documents a double-tap/device-specific shortcut.
- Native hibernate, if HHD exposes it on this installation: open the HHD/OGUI `General` section and look for `Hibernate`.

There is no documented direct keyboard shortcut for hibernate. Do not select a native or custom Hibernate action during this migration without a person at the Claw and an explicit test decision: either path can power the device off and the custom path has not been revalidated on Deck 44.

## Operator safety

The following actions can interrupt SSH, WiFi, Steam Gaming Mode, or ZeroTier. Stop immediately before each one and get an explicit go-ahead from the device operator:

- `rpm-ostree` transactions and reboot
- Stopping or restarting ZeroTier, NetworkManager, HHD, Steam, or `plugin_loader`
- NetworkManager, `rfkill`, or WiFi reassociation commands
- Suspend, hibernate, power-button, or wake testing
- Replacing or repairing the ZeroTier package or node state

Read-only inspection, Mac-side builds, backups, and file preparation can continue automatically while the connection is healthy.

The operator must perform local actions when needed:

- Keep the Claw on AC power and at the device for the upgrade and reboot.
- Toggle WiFi locally if WiFi does not reconnect. Do not remotely cycle `rfkill` or NetworkManager while SSH is the only management path.
- Press the physical power button for any resume test.
- Confirm the Claw is back at the expected screen and that SSH or ZeroTier is reachable before the next remote step.

Do not remotely invoke the custom hibernate script. RTC wake has not been proven to recover this hibernate path unattended.

## Phase 1: read-only preflight

Run the repository copy of the collector from the Mac. It executes on the Claw but only reads state and prints a report:

```bash
ssh -o BatchMode=yes user@msi-claw-b.local 'bash -s' < scripts/deck44-preflight.sh | tee /tmp/deck44-preflight-$(date +%Y%m%d-%H%M%S).txt
```

The report records:

- Active deployment, kernel arguments, kernel, storage, and pending systemd jobs
- systemd, NetworkManager, IWD, and Python versions
- ZeroTier service state, node status, and joined networks
- Decky Loader state and plugin manifests
- Presence of the custom hibernate, sleep, WiFi, audio, battery, power, and Gamescope files
- Whether the retained Gamescope files still contain `GAMESCOPE_BIN` and `--disable-layers`

Do not commit the report. It can contain network identifiers and local machine details.

On the Mac, confirm whether the custom plugin sources are tracked or ignored before treating a build as a recovery artifact:

```bash
git status --short
git ls-files hiberdecky uninstalldecky
git check-ignore -v hiberdecky uninstalldecky
```

The current repository ignores both plugin directories. Their source and build output must therefore be preserved separately from the Git history.

## Phase 2: pin and back up Deck 43

Inspect the deployment list and identify the currently booted Deck 43 entry:

```bash
ssh user@msi-claw-b.local 'rpm-ostree status -v'
```

After confirming the entry, pin the booted deployment by name. This changes deployment retention but does not reboot the device:

```bash
ssh user@msi-claw-b.local 'sudo ostree admin pin booted'
ssh user@msi-claw-b.local 'rpm-ostree status -v'
```

The `booted` target avoids accidentally pinning the staged Deck 44 deployment. The symbolic targets `pending` and `rollback` are also available if a later recovery operation needs them.

Create a root-owned, local-only backup on the Claw. It contains the ZeroTier identity and must not be copied into the repository or uploaded:

```bash
ssh user@msi-claw-b.local '
  stamp=$(date +%Y%m%d-%H%M%S)
  backup=/var/home/user/deck44-preflight-${stamp}.tgz
  sudo tar --xattrs --acls --ignore-failed-read -czf "$backup" -C / \
    var/lib/zerotier-one \
    home/user/homebrew/plugins \
    home/user/.config/wireplumber \
    etc/hhd \
    etc/systemd/system/systemd-suspend.service.d \
    etc/systemd/system/hhd.service.d \
    etc/systemd/system-sleep/50-msi-claw-s2idle-power.sh \
    etc/NetworkManager/dispatcher.d/99-claw-wifi-post-resume \
    etc/sysctl.d/99-msi-claw-wlan-rp-filter.conf \
    etc/udev/rules.d/99-msi-claw-zt-rp-filter.rules \
    etc/udev/rules.d/99-be200-no-d3cold.rules \
    etc/udev/rules.d/99-msi-claw-battery-charge-kick.rules \
    etc/udev/rules.d/99-msi-claw-audio-pm.rules \
    etc/modprobe.d/50-msi-claw-sof.conf \
    etc/systemd/logind.conf.d/zz-claw-power.conf \
    etc/systemd/system/var-swap-hibernate.swap.swap \
    etc/systemd/sleep.conf.d/claw-hibernate.conf \
    etc/gamescope-session-plus/sessions.d/steam \
    usr/local/bin/claw-hibernate.sh \
    usr/local/bin/claw-wifi-post-resume.sh \
    usr/local/bin/claw-battery-charge-kick.sh \
    usr/local/bin/claw-gamescope-diag-shim \
    usr/local/lib/hhd-bin/systemctl \
    etc/fstab
  sudo chmod 600 "$backup"
  sudo tar -tzf "$backup" >/dev/null
  printf "backup=%s\\n" "$backup"
'
```

Keep this archive on the Claw until the Deck 44 rollback window is closed. Do not add the hibernate swapfile itself to the archive: it is large and its contents are not useful as a configuration backup. Preserve it in place and record its metadata separately:

```bash
ssh user@msi-claw-b.local 'ls -lh /var/swap/hibernate.swap; sudo btrfs inspect-internal map-swapfile -r /var/swap/hibernate.swap'
```

## Phase 3: quarantine the custom stack

Quarantine means moving the active file out of its live path into a timestamped directory. Do not delete files and do not overwrite a destination. Use the preflight report to confirm which paths exist.

The repository includes an explicit quarantine helper. Its `status` mode is read-only and should be run first:

```bash
ssh user@msi-claw-b.local 'sudo -n /var/home/user/src/msiclaw/scripts/deck44-quarantine.sh status'
```

Copy the current helper to the device repo if the mirror is stale, then ask for an explicit operator go-ahead before applying it. The helper moves only present paths, refuses to overwrite an existing quarantine, and records every move in `manifest.tsv`:

```bash
scp scripts/deck44-quarantine.sh user@msi-claw-b.local:/tmp/deck44-quarantine.sh
ssh user@msi-claw-b.local 'sudo -n install -m 755 /tmp/deck44-quarantine.sh /var/home/user/src/msiclaw/scripts/deck44-quarantine.sh && sudo -n /var/home/user/src/msiclaw/scripts/deck44-quarantine.sh apply'
```

The helper quarantines these custom components when present:

```text
/home/user/homebrew/plugins/hiberdecky
/usr/local/lib/hhd-bin/systemctl
/etc/systemd/system/hhd.service.d/hibernate.conf
/etc/systemd/system/hhd.service.d/zz-swap-off.conf
/etc/systemd/system/systemd-suspend.service.d/msi-claw-s2idle.conf
/etc/systemd/system-sleep/50-msi-claw-s2idle-power.sh
/usr/local/bin/claw-wifi-post-resume.sh
/etc/NetworkManager/dispatcher.d/99-claw-wifi-post-resume
/etc/sysctl.d/99-msi-claw-wlan-rp-filter.conf
/etc/udev/rules.d/99-msi-claw-zt-rp-filter.rules
/usr/local/bin/claw-battery-charge-kick.sh
/etc/udev/rules.d/99-msi-claw-battery-charge-kick.rules
/etc/modprobe.d/50-msi-claw-sof.conf
/etc/udev/rules.d/99-msi-claw-audio-pm.rules
/home/user/.config/wireplumber/wireplumber.conf.d/80-alsa-headroom.conf
/etc/systemd/logind.conf.d/zz-claw-power.conf
```

The following are deliberately retained:

```text
/usr/local/bin/claw-gamescope-diag-shim
/etc/gamescope-session-plus/sessions.d/steam
/etc/gamescope-session-plus/sessions.d/ogui-steam
/etc/hhd/state.yml                         # retain gamemode.gamescope.dpms: false
/etc/udev/rules.d/99-be200-no-d3cold.rules  # narrow BE200 suspend guard
/var/lib/zerotier-one                      # preserve node identity
/etc/systemd/system/var-swap-hibernate.swap.swap
/etc/systemd/sleep.conf.d/claw-hibernate.conf
/var/swap/hibernate.swap
```

The resume kargs are preserved for rollback and later hibernate reassessment. They are not evidence that hibernation is enabled or tested.

After the helper completes, reload the affected managers only with the operator's approval. A plugin-loader restart can affect Gaming Mode, and a systemd reload changes live service configuration:

```bash
ssh user@msi-claw-b.local 'sudo systemctl daemon-reload'
ssh user@msi-claw-b.local 'sudo systemctl restart plugin_loader'
```

Confirm that `hiberdecky` is absent from the loader and that `uninstalldecky` and all other pre-existing plugins remain present. Do not restart NetworkManager to apply the quarantine; let the reboot establish the clean state.

## Phase 4: upgrade to Deck 44

Before the transaction, verify:

- The Claw is on AC power.
- The preflight report is complete.
- Deck 43 is pinned.
- The backup archive passes `tar -tzf`.
- The device is reachable over the currently working path.
- No important local file transfer or game session is in progress.

Ask the operator for an explicit go-ahead immediately before the transaction. Apply the normal update; do not rebase and do not add package layers for this migration:

```bash
ssh user@msi-claw-b.local 'sudo rpm-ostree upgrade'
```

The command may download and prepare a deployment without disconnecting immediately. Do not run another mutating command when it returns. Have the operator reboot locally when ready:

```text
Reboot the Claw from the local Bazzite/Steam UI or local console.
```

Expect the SSH and ZeroTier sessions to disappear. Wait for the operator to confirm the Claw has booted and that WiFi is connected before reconnecting. If WiFi does not reconnect, the operator toggles it locally; do not remotely use `rfkill`, `nmcli device disconnect`, or `nmcli device connect`.

## Phase 5: post-upgrade validation

Once the operator confirms the Claw is back online, run the read-only preflight collector again:

```bash
ssh -o BatchMode=yes user@msi-claw-b.local 'bash -s' < scripts/deck44-preflight.sh | tee /tmp/deck44-postflight-$(date +%Y%m%d-%H%M%S).txt
```

Confirm the active deployment reports Deck 44 and the pinned Deck 43 deployment remains available:

```bash
ssh user@msi-claw-b.local 'rpm-ostree status -v'
ssh user@msi-claw-b.local 'rpm-ostree kargs'
ssh user@msi-claw-b.local 'cat /proc/cmdline'
```

Confirm the custom hibernate and suspend/WiFi paths are not live:

```bash
ssh user@msi-claw-b.local 'test ! -e /home/user/homebrew/plugins/hiberdecky'
ssh user@msi-claw-b.local 'test ! -e /etc/systemd/system/systemd-suspend.service.d/msi-claw-s2idle.conf'
ssh user@msi-claw-b.local 'test ! -e /etc/NetworkManager/dispatcher.d/99-claw-wifi-post-resume'
```

Do not treat a failed `test` as permission to delete anything. Inspect the quarantine and restore the intended move if a path was wrong.

### Native handheld stack

The Deck 44 announcement replaces the old handheld stack with InputPlumber, SteamOS-Manager, PowerStation where needed, and OpenGamepadUI. Current Bazzite hardware detection recognizes MSI Claw products for SteamOS-Manager TDP handling; the MSI Claw is not in the current PowerStation fallback list.

Run read-only service and hardware checks:

```bash
ssh user@msi-claw-b.local 'systemctl --failed'
ssh user@msi-claw-b.local 'systemctl list-unit-files | grep -Ei "inputplumber|steamos-manager|powerstation|opengamepadui" || true'
ssh user@msi-claw-b.local 'cat /sys/devices/virtual/dmi/id/sys_vendor /sys/devices/virtual/dmi/id/product_name /sys/devices/virtual/dmi/id/board_name'
```

From the Claw, the operator verifies in Gaming Mode:

1. Gaming Mode starts normally and QAM opens.
2. The built-in gamepad, sticks, bumpers, and buttons work.
3. TDP and performance profile controls are available through the native UI.
4. Fan behavior is acceptable; missing manual fan control is a known Deck 44 transition issue.
5. The retained Gamescope adjustment is still active.

If OpenGamepadUI is missing, do not run `ujust configure-opengamepadui` remotely. The operator can run it locally after reviewing the native baseline:

```bash
ujust configure-opengamepadui
```

### Gamescope retention

Check the retained extension and shim without restarting the session:

```bash
ssh user@msi-claw-b.local 'grep -F GAMESCOPE_BIN /etc/gamescope-session-plus/sessions.d/steam'
ssh user@msi-claw-b.local 'grep -F GAMESCOPE_BIN /etc/gamescope-session-plus/sessions.d/ogui-steam'
ssh user@msi-claw-b.local 'grep -F -- --disable-layers /usr/local/bin/claw-gamescope-diag-shim'
```

The operator can confirm the live process from a local terminal or read-only SSH inspection:

```bash
ssh user@msi-claw-b.local 'pgrep -a gamescope'
```

The live command line must contain `--disable-layers`. Do not restart Gamescope merely to make this check pass; investigate whether Deck 44 replaced the extension first.

Deck 44 currently launches the `ogui-steam` client. The older `/etc/gamescope-session-plus/sessions.d/steam` override is not read for that client, so the live process initially lacked `--disable-layers`. The effective `/etc/gamescope-session-plus/sessions.d/ogui-steam` override is installed on the Claw and was live-validated after a supervised Gamescope session restart on 2026-08-25.

The manually launched IDUN runtime is also confirmed under the corrected session: Proton Experimental, DXVK, and the Intel Arc Vulkan path are active. No xe/DRM hang, reset, device-loss, or Unity render error appeared. IDUN still reports high CPU usage, and OpenGamepadUI continues its once-per-second orphan-window warning loop, so the five-second UI freeze is not considered resolved.

The orphan IDs map to IDUN's `steam_app_2407626767` windows and Steam child/input windows on the nested `:1` Xwayland display, while OpenGamepadUI runs on the outer `:0` display. This is a reproducible OpenGamepadUI window-association defect, but OGUI uses only about 6% CPU and the host has about 82% CPU idle with no I/O or memory pressure. It is therefore a plausible source of log noise, not a proven cause of the freeze.

The Deck 44 `plasma-foreground-booster.service` failed when the Gamescope Wayland connection was replaced, then repeatedly aborted because its user manager had no `DISPLAY`. Importing the current Gaming Mode display variables (`DISPLAY=:0`, `WAYLAND_DISPLAY=gamescope-0`) allowed one clean restart, but the service reports that Plasma's window-management protocol is unavailable and the Gamescope session cgroup remains at the default `cpu.weight=100`. This is recorded as a diagnostic finding, not a persistent stutter fix.

### ZeroTier preservation

Do not join a new network or replace `/var/lib/zerotier-one` during validation. First compare the public identity fingerprint and service state:

```bash
ssh user@msi-claw-b.local 'sudo sha256sum /var/lib/zerotier-one/identity.public'
ssh user@msi-claw-b.local 'systemctl is-enabled zerotier-one.service; systemctl is-active zerotier-one.service'
ssh user@msi-claw-b.local 'zerotier-cli info; zerotier-cli listnetworks'
```

The node address and joined network must match the preflight report. Test peer connectivity using the existing ZeroTier address only after the operator confirms both WiFi and ZeroTier are online.

If the service or package is missing, stop at that point. Do not install a second client or regenerate the identity. Identify the existing installation source first; use the official ZeroTier Linux package instructions only with an explicit repair decision, preserving `/var/lib/zerotier-one`.

The repository currently does not contain the documented `zerotier-ensure-online.service` or its script. Record whether that unit exists on the device. If it is still required, its unit and installer should be added in a separate change without putting the network ID or identity secret in Git.

### Decky plugins

Build the retained uninstaller on the Mac. This is local work and does not affect the Claw:

```bash
cd uninstalldecky
npm run qa
```

Deploy only `uninstalldecky` using its existing staging procedure in [uninstalldecky/README.md](../uninstalldecky/README.md). Do not deploy `hiberdecky` during this migration. Restarting `plugin_loader` is operator-gated because it can affect the current Gaming Mode session.

After the operator confirms the loader is back, verify:

- `uninstalldecky` appears in QAM.
- Its startup safe health check succeeds.
- The list view shows the expected games and disk totals.
- A row opens a confirmation dialog.
- Cancel makes no change.
- A controlled test uninstall refreshes the list and disk totals.
- Plugin-loader logs contain no new errors.

All other plugins should remain at their preflight versions unless their own logs identify a failure. Restore or remove only the named failing plugin, not the whole plugin directory.

### Clean native behavior

With the custom stack still quarantined, the operator performs the following local checks:

- Audio after a normal short suspend/resume
- WiFi reconnect and internet access after that suspend/resume
- ZeroTier online after WiFi returns
- Charging and the configured charge limit
- Power-button behavior
- Gamepad input in Steam and one game

Do not invoke hibernate. If WiFi is not restored after wake, the operator toggles WiFi locally and reports the result before any workaround is restored.

### First supervised WiFi result

On 2026-08-25, with only `99-be200-no-d3cold.rules` active, one local s2idle cycle produced this sequence:

- Suspend entered at 16:48:29 and exited at 16:48:34.
- `wlp44s0f0` associated and completed WPA setup at 16:48:36.
- The first DHCP transaction timed out at 16:49:21.
- NetworkManager retried; the second transaction received a lease at 16:49:27 and activated the connection at 16:49:28.
- No new `ADVANCED_SYSASSERT`, all-`0xFFFFFFFF` transport dump, or `FW reset ACK` timeout appeared during this cycle.

This is a **recovery pass with slow DHCP**, not a fast-reconnect pass. It shows the BE200 remained usable and the remaining delay was after WPA association, in the DHCP/NetworkManager stage. Repeat the local test before adding another recovery hook; do not restore the quarantined Deck 43 NetworkManager/rfkill stack based on this single result.

Three further local cycles were then completed. The first was slow in the same way; the next two recovered immediately. Across four total cycles, the BE200 produced two slow DHCP retries and two immediate recoveries, with no observed repeat of the firmware-reset failure. Treat the narrow guard as the retained Deck 44 WiFi workaround and do not add a forced reconnect hook unless the delay becomes a recurring usability problem.

## Phase 6: controlled restoration

Restore no workaround until a native baseline failure is recorded. If a failure is reproducible, restore one quarantined component at a time and repeat the narrow check:

1. The smallest relevant WiFi or configuration file; the BE200 D3cold guard is already the retained exception
2. The relevant input or sleep hook
3. Optional audio configuration
4. The custom hibernate route last, only after a separate physical test decision

For every restoration, record the source path, destination path, timestamp, and behavior change. Keep Deck 44's native handheld services in control of TDP, input, session switching, and power policy.

## Rollback

If Deck 44 has a critical regression, use the pinned Deck 43 deployment through the local boot menu or the documented Bazzite rollback flow. Do not perform a rollback merely to exercise the procedure.

Before rolling from Deck 44 back to Deck 43, preserve the Deck 44 state and inspect `/etc/sddm.conf.d/`. Bazzite documents that Deck 44-to-43 rollback can break autologin until the Deck 44-created `zz-*` SDDM files are removed. Remove only the documented Deck 44 SDDM files after making a backup; do not confuse them with `/etc/systemd/logind.conf.d/zz-claw-power.conf`, which is a separate Claw workaround and should already be in quarantine.

To restore a quarantine, use its exact printed directory. The helper refuses to overwrite a path that has been recreated:

```bash
ssh user@msi-claw-b.local 'sudo -n /var/home/user/src/msiclaw/scripts/deck44-quarantine.sh restore /var/home/user/deck44-quarantine-TIMESTAMP'
```

After rollback:

- Confirm the active deployment is Deck 43.
- Confirm the Deck 43 deployment is still pinned or pin it again if its index changed.
- Restore the pre-migration plugin and workaround state only as needed.
- Verify ZeroTier identity before starting any service repair.
- Keep a human at the device for any hibernate or suspend test.

## Completion record

Record these values in [inventory.md](../inventory.md) after the migration:

- Deck 44 deployment version and checksum
- Pinned Deck 43 checksum
- Kernel and native handheld service versions
- Whether Gamescope still runs with `--disable-layers`
- ZeroTier node fingerprint, service state, and network connectivity result
- Decky Loader version and retained plugin versions
- Quarantined components and any individually restored workaround
- Whether hibernation remains deferred
