# In-place Btrfs storage expansion

This runbook removes the Windows partitions from the MSI Claw without reinstalling Bazzite or copying `/var/home` across the network.

The current disk layout is:

| Area | Current role | Planned role |
| --- | --- | --- |
| `p1` | Shared EFI | Preserve |
| `p2` | Microsoft Reserved | Replace with a large blank Btrfs member |
| `p3` | Windows NTFS | Replace with the remainder of the large Btrfs member |
| `p7` | Existing Btrfs member | Preserve |
| `p4` | Windows recovery NTFS | Replace with a small Btrfs member |
| `p5` | Bazzite `/boot` | Preserve |
| `p6` | Existing Btrfs member and hibernate-swap backing device | Preserve |

The result is one logical Btrfs filesystem of approximately 474-475 GiB backed by four physical members. It is not one physical partition. Existing Bazzite data remains in place; there is no home-directory restore step.

## Safety model

The script [scripts/claw-btrfs-composite-expand.sh](../scripts/claw-btrfs-composite-expand.sh) is device-specific and staged:

- `preflight` is read-only apart from a small metadata record under `/var/home/user/.local/state/`.
- `stage-gpt` is a dry run unless given its explicit commit token.
- The GPT stage preserves `p1`, `p5`, `p6`, and `p7` by exact sector range and existing PARTUUID.
- The kernel is intentionally not forced to reread the changed GPT while Bazzite is mounted. Reboot is a separate gate.
- `add-members` wipes only filesystem signatures from the two already-approved replacement partitions, then adds them to the existing Btrfs filesystem. It never runs `mkfs` or `--force`.
- No Btrfs balance, partition move, reboot, suspend, or hibernate is performed by the script.
- EFI cleanup is delayed until the expanded Bazzite system has booted successfully and removes only `EFI/Microsoft` and matching Windows firmware entries.

Without a full external backup, a wrong GPT write, unexpected power loss, or total device failure can make user data unrecoverable. The metadata record is useful for diagnosis and table recovery, but it is not a file backup.

Keep the Claw on AC power, close games, ensure no hibernate process or active hibernate swap exists, and have the operator physically available for the reboot. Do not invoke hibernate remotely.

## Staged execution

Run these commands from the Mac repository root. The first command transfers only the small operator script:

```bash
scp -o BatchMode=yes -o ConnectTimeout=10 \
  scripts/claw-btrfs-composite-expand.sh \
  user@msi-claw-b.local:/tmp/claw-btrfs-composite-expand.sh

ssh -o BatchMode=yes -o ConnectTimeout=10 user@msi-claw-b.local \
  'sudo -n install -m 755 /tmp/claw-btrfs-composite-expand.sh \
    /var/home/user/src/msiclaw/scripts/claw-btrfs-composite-expand.sh'
```

Run the read-only preflight:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 user@msi-claw-b.local \
  'sudo -n /var/home/user/src/msiclaw/scripts/claw-btrfs-composite-expand.sh preflight'
```

Then generate and inspect the replacement GPT. This remains read-only:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 user@msi-claw-b.local \
  'sudo -n /var/home/user/src/msiclaw/scripts/claw-btrfs-composite-expand.sh stage-gpt'
```

The candidate must show:

- `p1`, `p5`, `p6`, and `p7` with their original starts, sizes, types, and GUIDs.
- A new Linux filesystem entry starting at sector `616448`, size `537133056` sectors.
- A new Linux filesystem entry starting at sector `740229120`, size `2103296` sectors.
- No old Windows `p3` entry or old Windows partition GUID.

Stop here if any value differs. The next command is the first destructive action and requires explicit operator approval:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 user@msi-claw-b.local \
  'sudo -n /var/home/user/src/msiclaw/scripts/claw-btrfs-composite-expand.sh \
    stage-gpt --commit DELETE-WINDOWS-GPT'
```

The script writes the GPT and verifies it directly from disk. It does not reboot. Do not run `partprobe`, `partx`, `mkfs`, or `btrfs device add` at this point.

## Reboot gate

After the GPT write succeeds, reboot locally from Bazzite or use an already-approved reboot command. SSH and ZeroTier will disconnect. Keep a live USB and local recovery access available because the reduced-backup route has no file-level recovery copy.

After Bazzite returns, verify the new partition nodes and the unchanged Bazzite members:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 user@msi-claw-b.local \
  'sudo -n /var/home/user/src/msiclaw/scripts/claw-btrfs-composite-expand.sh \
    verify-after-reboot'
```

This refuses to continue unless a reboot occurred, the new GPT entries have their recorded PARTUUIDs and exact ranges, `/var` is still backed by the original Btrfs filesystem, no new partition is mounted, the Btrfs pool still has its two original members, and the hibernate resume device/offset still match.

## Add the members

Preview the approved devices:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 user@msi-claw-b.local \
  'sudo -n /var/home/user/src/msiclaw/scripts/claw-btrfs-composite-expand.sh \
    add-members'
```

The commit performs `wipefs -a` on only the exact new partitions, adds both with `btrfs device add -K`, and runs `btrfs filesystem resize max`. It does not balance the filesystem:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 user@msi-claw-b.local \
  'sudo -n /var/home/user/src/msiclaw/scripts/claw-btrfs-composite-expand.sh \
    add-members --commit ADD-BTRFS-MEMBERS'
```

The success gate requires four Btrfs devices, approximately 474-475 GiB total device size, `single` data and metadata profiles, no missing member, zero device error counters, and a matching hibernate swap offset.

## Remove Windows EFI state

Only after the Btrfs expansion and a normal boot are verified, preview EFI cleanup:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 user@msi-claw-b.local \
  'sudo -n /var/home/user/src/msiclaw/scripts/claw-btrfs-composite-expand.sh \
    cleanup-efi'
```

The commit archives the small Microsoft EFI directory into the local state directory, removes only firmware entries named Windows or pointing to `EFI/Microsoft`, and deletes `/boot/efi/EFI/Microsoft`:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 user@msi-claw-b.local \
  'sudo -n /var/home/user/src/msiclaw/scripts/claw-btrfs-composite-expand.sh \
    cleanup-efi --commit REMOVE-MICROSOFT-EFI'
```

Keep the EFI partition, `EFI/fedora`, and `EFI/Boot`. `EFI/Boot/BOOTX64.EFI` is Bazzite's fallback loader and must not be removed.

## Post-operation checks

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 user@msi-claw-b.local \
  'lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,PARTUUID,MOUNTPOINTS; \
   sudo -n btrfs filesystem usage -T /var; \
   sudo -n btrfs filesystem show /var; \
   sudo -n btrfs device stats /var; \
   rpm-ostree status; \
   sudo -n efibootmgr -v'
```

Do not test the custom hibernate path as part of the remote storage operation. Before a later supervised local test, confirm which script Decky selects: the bundled `~/homebrew/plugins/hiberdecky/scripts/claw-hibernate.sh` takes precedence over `/usr/local/bin/claw-hibernate.sh`, as documented in [hiberdecky/docs/hibernate-resume.md](../hiberdecky/docs/hibernate-resume.md).