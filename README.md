# msiclaw

Customizations and utility scripts for the **MSI Claw A1M** running **Bazzite** (SteamOS-style).

Source of truth lives in this repo on the Mac. Scripts deploy to the Claw at `~/bin/`.

## Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| `steam-nonsteam-games` | List, size, and uninstall non-Steam games + orphan compatdata | `~/bin/steam-nonsteam-games list` |
| `msi-sudo-nopasswd` | Toggle passwordless sudo for CLI/agent work (reversible) | `sudo ~/bin/msi-sudo-nopasswd enable` |
| `deploy-to-claw` | Push repo scripts to the Claw (run from Mac) | `./scripts/deploy-to-claw.sh` |
| `deck44-preflight` | Read-only Deck 44 migration inventory | `bash scripts/deck44-preflight.sh` |

### steam-nonsteam-games

```bash
~/bin/steam-nonsteam-games              # list games + orphans (one numbered list)
~/bin/steam-nonsteam-games status       # Steam paths, userdata ID, running state
~/bin/steam-nonsteam-games orphans      # orphans only (compact view)
~/bin/steam-nonsteam-games uninstall    # interactive picker (includes orphans)
~/bin/steam-nonsteam-games uninstall 12 # by list number (e.g. orphan at #12)
~/bin/steam-nonsteam-games uninstall 3658110  # or by appid
```

Add `--yes` to skip typing the game name (still shows the deletion plan). Add `--force` only if Steam is running and you accept the risk.

## Deck 44 migration

The staged Bazzite Deck 44 migration is documented in [docs/deck44-migration.md](docs/deck44-migration.md). The first Deck 44 boot quarantines the custom hibernate, suspend, WiFi, audio, input, battery, and power-button workarounds while retaining the Gamescope adjustments and ZeroTier identity. `uninstalldecky` is the Decky plugin explicitly rebuilt and verified; `hiberdecky` remains deferred.

The rolled-back M1/M2 and Moonlight chord investigation is documented in [docs/msi-claw-m1-m2-moonlight.md](docs/msi-claw-m1-m2-moonlight.md).

The read-only preflight collector can be run from the Mac without installing anything on the Claw:

```bash
ssh -o BatchMode=yes user@msi-claw-b.local 'bash -s' < scripts/deck44-preflight.sh
```

The migration requires a person at the Claw for the update reboot, physical power actions, and any local WiFi recovery. Do not remotely invoke the custom hibernate path.

**Stop Steam before uninstall** (Gaming Mode / `bazzite-steam`). The script backs up `shortcuts.vdf` and removes:

- Game install dir (only under `~/Games/` or GOG-in-prefix paths)
- `steamapps/compatdata/<appid>/`
- `steamapps/shadercache/<appid>/`
- `userdata/.../config/grid/<appid>*`
- `userdata/.../config/librarycache/<appid>.json`
- Shortcut entry in `shortcuts.vdf`

System launchers (e.g. Moonlight via flatpak) never have their exe path deleted.

Orphans appear at the bottom of `list` / `uninstall` as `[orphan]` rows. They only remove compatdata + shadercache. Rows marked `[steam app!]` belong to real Steam library games — leave those unless you intend to wipe that game's Proton prefix.

## Deploy

From the Mac repo root:

```bash
chmod +x scripts/*.sh
./scripts/deploy-to-claw.sh              # default: user@msi-claw-b.local
./scripts/deploy-to-claw.sh --mirror     # also rsync repo to ~/src/msiclaw on Claw
./scripts/deploy-to-claw.sh --host other # custom SSH host
```

Each `scripts/*.sh` is copied to `~/bin/<name>` (`.sh` suffix stripped, `chmod +x`).

## System customizations

Device-level changes (udev, systemd, hibernate, WiFi hooks, etc.) are tracked in [inventory.md](inventory.md).

## Troubleshooting

Detailed runbook for suspend/resume, audio, WiFi, gamepad, battery, hibernate:

[MSI Claw A1M on Bazzite: Choppy Audio After Suspend, WiFi, ZeroTier.md](MSI%20Claw%20A1M%20on%20Bazzite:%20Choppy%20Audio%20After%20Suspend,%20WiFi,%20ZeroTier.md)

## Subprojects

| Path | Description |
|------|-------------|
| [hiberdecky/](hiberdecky/) | Decky Loader plugin for one-button hibernate (own `install.sh`) |
| [uninstalldecky/](uninstalldecky/) | Decky QAM plugin to list/uninstall non-Steam games + orphans |

## Changelog

### 2026-07-02 (uninstaller UX + QA)

- QAM confirm dialog before uninstall; auto disk/list refresh after uninstall with byte-accurate display
- Post-uninstall verification in `steam_nonsteam.py`; `validate --safe-only` for non-destructive health checks
- `scripts/qa-uninstaller.sh` adversarial QA gate (run by separate subagent on Claw)

### 2026-07-02 (uninstalldecky fix)

- Fix Claw Uninstaller plugin: bundled `steam_nonsteam.py`, set `HOME=DECKY_USER_HOME` for root plugin subprocess
- Extract CLI logic to `scripts/steam_nonsteam.py`; bash wrapper is thin `exec python3`
- Remove Validate / Runtime tests from QAM UI; add Refresh button

### 2026-07-02 (uninstalldecky)

- Add `uninstalldecky/` Decky QAM plugin — list, uninstall, runtime validate
- `steam-nonsteam-games` gains `--json` and `validate` command for plugin API

### 2026-07-02 (update)

- `steam-nonsteam-games` shows disk available/total in GB on list/status/orphans; uninstall reports before/after disk space

### 2026-07-02

- Add `scripts/steam-nonsteam-games.sh` — list/uninstall non-Steam games with full compat cleanup
- Add `scripts/deploy-to-claw.sh` — deploy repo scripts to MSI Claw `~/bin`
- Vendor `scripts/msi-sudo-nopasswd.sh` from device into repo
- Add this README as repo paper trail
