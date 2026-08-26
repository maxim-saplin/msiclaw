#!/usr/bin/env bash
set -euo pipefail

DISK="${CLAW_EXPAND_DISK:-/dev/nvme0n1}"
MOUNTPOINT="${CLAW_EXPAND_MOUNTPOINT:-/var}"
STATE_DIR="${CLAW_EXPAND_STATE_DIR:-/var/home/user/.local/state/claw-btrfs-composite-expand}"
EXPECTED_DISK=/dev/nvme0n1
EXPECTED_SECTORS=1000215216
LINUX_GPT_TYPE=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EFI_GPT_TYPE=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
BOOT_GPT_TYPE=BC13C2FF-59E6-4262-A352-B275FD6F7172
P6_UUID=A265B280-4539-47FA-B590-BF36612B6CE6
P7_UUID=AC1A013C-F27E-4E82-935B-A582BECE8FA4
P1_UUID=9D8D1061-3955-49F7-9F9C-1A16675B258C
P5_UUID=0C07A26E-305F-47ED-81C7-F54E33E904E8
OLD_P2_UUID=1A763B11-8677-41C8-A736-6265F316EF37
OLD_P3_UUID=665CD3B2-E21A-45D0-850B-624CE704AD04
OLD_P4_UUID=029D12C1-6785-40C5-B6AF-68809944834F
LARGE_START=616448
LARGE_SIZE=537133056
TAIL_START=740229120
TAIL_SIZE=2103296
SWAPFILE=/var/swap/hibernate.swap
SWAP_UNIT=/etc/systemd/system/var-swap-hibernate.swap.swap

TMP_DIR=""
LIVE_JSON=""

usage() {
  cat <<'EOF'
Usage: claw-btrfs-composite-expand.sh COMMAND [--commit TOKEN]

Commands:
  preflight             Capture and validate the current layout. Read-only.
  stage-gpt             Print and validate the replacement GPT. Read-only by default.
  verify-after-reboot   Validate the new GPT after the planned reboot. Read-only.
  add-members           Add the two new partitions to the Btrfs filesystem.
  cleanup-efi           Remove only the Microsoft EFI directory and firmware entries.

Commit tokens:
  DELETE-WINDOWS-GPT
  ADD-BTRFS-MEMBERS
  REMOVE-MICROSOFT-EFI

The script is specific to /dev/nvme0n1 on this MSI Claw. It never formats a
partition, runs a Btrfs balance, reboots, or invokes hibernate.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die 'run as root, for example with sudo'
}

require_commands() {
  local command_name
  for command_name in \
    awk btrfs blkid blockdev cmp date efibootmgr findmnt grep lsblk \
    parted pgrep python3 rpm-ostree sfdisk sha256sum tar wipefs; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
  done
}

ensure_state_dir() {
  install -d -m 0700 "$STATE_DIR"
}

partition_node() {
  local number="$1"
  if [[ "$DISK" =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$DISK" "$number"
  else
    printf '%s%s\n' "$DISK" "$number"
  fi
}

load_live_table() {
  LIVE_JSON="$TMP_DIR/live.sfdisk.json"
  sfdisk --json "$DISK" > "$LIVE_JSON"
}

table_field() {
  local field="$1"
  local file="$2"
  python3 - "$field" "$file" <<'PY'
import json
import sys

field, path = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    table = json.load(stream)["partitiontable"]
value = table.get(field)
if value is None:
    raise SystemExit(f"missing partition-table field: {field}")
print(value)
PY
}

part_field() {
  local number="$1"
  local field="$2"
  local file="${3:-$LIVE_JSON}"
  python3 - "$number" "$field" "$DISK" "$file" <<'PY'
import json
import sys

number, field, disk, path = sys.argv[1:]
node = f"{disk}{'p' if disk[-1].isdigit() else ''}{number}"
with open(path, encoding="utf-8") as stream:
    partitions = json.load(stream)["partitiontable"]["partitions"]
for partition in partitions:
    if partition.get("node") == node:
        value = partition.get(field)
        if value is None:
            raise SystemExit(f"missing partition field: {field} for {node}")
        print(value)
        break
else:
    raise SystemExit(f"partition is missing: {node}")
PY
}

partition_exists() {
  local number="$1"
  local file="${2:-$LIVE_JSON}"
  python3 - "$number" "$DISK" "$file" <<'PY'
import json
import sys

number, disk, path = sys.argv[1:]
node = f"{disk}{'p' if disk[-1].isdigit() else ''}{number}"
with open(path, encoding="utf-8") as stream:
    partitions = json.load(stream)["partitiontable"]["partitions"]
raise SystemExit(0 if any(p.get("node") == node for p in partitions) else 1)
PY
}

partition_count() {
  python3 - "$LIVE_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    print(len(json.load(stream)["partitiontable"]["partitions"]))
PY
}

assert_disk_basics() {
  [[ "$DISK" == "$EXPECTED_DISK" ]] || die "refusing unexpected disk: $DISK"
  [[ "$(blockdev --getss "$DISK")" == 512 ]] || die 'unexpected logical sector size'
  [[ "$(blockdev --getsz "$DISK")" == "$EXPECTED_SECTORS" ]] || die 'unexpected disk sector count'
  [[ "$(table_field label "$LIVE_JSON")" == gpt ]] || die 'disk is not GPT'
  [[ "$(table_field firstlba "$LIVE_JSON")" == 34 ]] || die 'unexpected GPT first LBA'
  [[ "$(table_field lastlba "$LIVE_JSON")" == 1000215182 ]] || die 'unexpected GPT last LBA'
}

assert_partition() {
  local number="$1"
  local start="$2"
  local size="$3"
  local type="$4"
  local uuid="$5"
  local actual

  actual="$(part_field "$number" start)" || die "partition $number is missing"
  [[ "$actual" == "$start" ]] || die "partition $number start changed: $actual"
  actual="$(part_field "$number" size)" || die "partition $number is missing"
  [[ "$actual" == "$size" ]] || die "partition $number size changed: $actual"
  actual="$(part_field "$number" type)" || die "partition $number is missing"
  [[ "${actual^^}" == "${type^^}" ]] || die "partition $number type changed: $actual"
  actual="$(part_field "$number" uuid)" || die "partition $number is missing"
  [[ "${actual^^}" == "${uuid^^}" ]] || die "partition $number GUID changed: $actual"
}

assert_original_layout() {
  [[ "$(partition_count)" == 7 ]] || die 'the current table does not contain exactly seven partitions'
  assert_partition 1 2048 614400 "$EFI_GPT_TYPE" "$P1_UUID"
  assert_partition 2 616448 262144 E3C9E316-0B5C-4DB8-817D-F92DF00215AE "$OLD_P2_UUID"
  assert_partition 3 878592 536870912 EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 "$OLD_P3_UUID"
  assert_partition 4 740229120 2103296 DE94BBA4-06D1-4D40-A16A-BFD50179D6AC "$OLD_P4_UUID"
  assert_partition 5 742332416 4194304 "$BOOT_GPT_TYPE" "$P5_UUID"
  assert_partition 6 746526720 253687808 "$LINUX_GPT_TYPE" "$P6_UUID"
  assert_partition 7 537749504 202479616 "$LINUX_GPT_TYPE" "$P7_UUID"
}

assert_preserved_layout() {
  [[ "$(partition_count)" == 6 ]] || die 'the post-write table does not contain exactly six partitions'
  assert_partition 1 2048 614400 "$EFI_GPT_TYPE" "$P1_UUID"
  assert_partition 5 742332416 4194304 "$BOOT_GPT_TYPE" "$P5_UUID"
  assert_partition 6 746526720 253687808 "$LINUX_GPT_TYPE" "$P6_UUID"
  assert_partition 7 537749504 202479616 "$LINUX_GPT_TYPE" "$P7_UUID"
  if partition_exists 3; then
    die 'the old Windows partition number is still present'
  fi
  if grep -Eiq "$OLD_P2_UUID|$OLD_P3_UUID|$OLD_P4_UUID" "$TMP_DIR/current.sfdisk"; then
    die 'an old Windows partition GUID remains in the GPT'
  fi
  return 0
}

assert_btrfs_pool() {
  local expected_devices="$1"
  local show
  local count
  show="$(btrfs filesystem show "$MOUNTPOINT")" || die 'Btrfs filesystem is not available'
  count="$(grep -c 'devid ' <<< "$show" || true)"
  [[ "$count" == "$expected_devices" ]] || die "expected $expected_devices Btrfs devices, found $count"
  [[ "$show" == *"path $(partition_node 6)"* ]] || die 'Btrfs p6 member is missing'
  [[ "$show" == *"path $(partition_node 7)"* ]] || die 'Btrfs p7 member is missing'
  if grep -Eq 'Device missing:' "$TMP_DIR/btrfs-usage.txt" && \
    ! grep -Eq 'Device missing:[[:space:]]+0\.00B' "$TMP_DIR/btrfs-usage.txt"; then
    die 'Btrfs reports a missing device'
  fi
}

assert_btrfs_state() {
  local usage profiles
  usage="$(btrfs filesystem usage -T "$MOUNTPOINT")" || die 'could not read Btrfs usage'
  printf '%s\n' "$usage" > "$TMP_DIR/btrfs-usage.txt"
  profiles="$(btrfs filesystem df "$MOUNTPOINT")" || die 'could not read Btrfs allocation profiles'
  grep -Eq 'Data, single:' <<< "$profiles" || die 'Btrfs data profile is not single'
  grep -Eq 'Metadata, single:' <<< "$profiles" || die 'Btrfs metadata profile is not single'
  assert_btrfs_pool "$1"
  assert_zero_stats
  if btrfs balance status "$MOUNTPOINT" 2>&1 | grep -qi running; then
    die 'a Btrfs balance is active'
  fi
}

assert_zero_stats() {
  local stats
  stats="$(btrfs device stats "$MOUNTPOINT")" || die 'could not read Btrfs device stats'
  if ! awk '$NF != 0 {bad=1} END {exit bad}' <<< "$stats"; then
    die 'Btrfs device error counters are non-zero'
  fi
}

assert_btrfs_identity() {
  local p6_fs p7_fs mount_source
  p6_fs="$(blkid -s UUID -o value "$(partition_node 6)")"
  p7_fs="$(blkid -s UUID -o value "$(partition_node 7)")"
  [[ "${p6_fs^^}" == "E1943FE1-D3F4-41E2-BEDE-22913AA05A8B" ]] || die 'p6 Btrfs UUID changed'
  [[ "${p7_fs^^}" == "${p6_fs^^}" ]] || die 'p6 and p7 are not one Btrfs filesystem'
  mount_source="$(findmnt -no SOURCE -T "$MOUNTPOINT")"
  [[ "$(findmnt -no FSTYPE -T "$MOUNTPOINT")" == btrfs ]] || die "$MOUNTPOINT is not a Btrfs mount"
  [[ "$mount_source" == *"$(partition_node 6)"* ]] || die "$MOUNTPOINT is not backed by p6"
}

assert_resume_identity() {
  local saved_offset current_offset kargs unit_offset
  [[ -e "$SWAPFILE" ]] || die "hibernate swapfile is missing: $SWAPFILE"
  if grep -Fq "$SWAPFILE" /proc/swaps; then
    die 'hibernate swapfile is active; stop before changing storage metadata'
  fi
  if pgrep -af '[c]law-hibernate' >/dev/null 2>&1; then
    die 'a hibernate process is active'
  fi
  saved_offset="$(tr -d '[:space:]' < "$STATE_DIR/preflight.swap-offset")"
  current_offset="$(btrfs inspect-internal map-swapfile -r "$SWAPFILE" | tr -d '[:space:]')"
  [[ "$saved_offset" == "$current_offset" ]] || die "hibernate swap offset changed: $saved_offset -> $current_offset"
  kargs="$(rpm-ostree kargs)"
  grep -Fqi "resume=PARTUUID=$P6_UUID" <<< "$kargs" || die 'kernel resume PARTUUID no longer points to p6'
  grep -Fq "resume_offset=$current_offset" <<< "$kargs" || die 'kernel resume offset does not match the swapfile'
  [[ -f "$SWAP_UNIT" ]] || die "hibernate swap unit is missing: $SWAP_UNIT"
  unit_offset="$(grep -oE 'resume_offset=[0-9]+' "$SWAP_UNIT" | head -1 | cut -d= -f2)"
  [[ "$unit_offset" == "$current_offset" ]] || die 'hibernate swap unit offset does not match the swapfile'
}

capture_snapshot() {
  local prefix="$1"
  local n
  sfdisk --json "$DISK" > "$STATE_DIR/$prefix.sfdisk.json"
  sfdisk --dump "$DISK" > "$STATE_DIR/$prefix.sfdisk"
  parted -m "$DISK" unit s print free > "$STATE_DIR/$prefix.parted-free"
  lsblk -b -e7 -o NAME,PATH,START,SIZE,TYPE,FSTYPE,PARTTYPE,PARTUUID,PARTLABEL,MOUNTPOINTS \
    "$DISK" > "$STATE_DIR/$prefix.lsblk"
  {
    for n in 1 2 3 4 5 6 7; do
      blkid "$(partition_node "$n")" 2>&1 || true
    done
  } > "$STATE_DIR/$prefix.blkid"
  findmnt -R "$MOUNTPOINT" > "$STATE_DIR/$prefix.findmnt" 2>&1 || true
  btrfs filesystem show "$MOUNTPOINT" > "$STATE_DIR/$prefix.btrfs-show" 2>&1 || true
  btrfs filesystem usage -T "$MOUNTPOINT" > "$STATE_DIR/$prefix.btrfs-usage" 2>&1 || true
  btrfs device stats "$MOUNTPOINT" > "$STATE_DIR/$prefix.btrfs-stats" 2>&1 || true
  rpm-ostree kargs > "$STATE_DIR/$prefix.rpm-ostree-kargs" 2>&1 || true
  cat /proc/cmdline > "$STATE_DIR/$prefix.cmdline"
  efibootmgr -v > "$STATE_DIR/$prefix.efibootmgr" 2>&1 || true
  if [[ -e "$SWAPFILE" ]]; then
    btrfs inspect-internal map-swapfile -r "$SWAPFILE" > "$STATE_DIR/$prefix.swap-offset" 2>&1 || true
  else
    printf 'missing\n' > "$STATE_DIR/$prefix.swap-offset"
  fi
  cat /proc/sys/kernel/random/boot_id > "$STATE_DIR/$prefix.boot-id"
  date -Is > "$STATE_DIR/$prefix.timestamp"
}

preflight() {
  require_root
  require_commands
  ensure_state_dir
  load_live_table
  assert_disk_basics
  capture_snapshot preflight
  assert_original_layout
  assert_btrfs_identity
  assert_btrfs_state 2
  assert_resume_identity
  sha256sum \
    "$STATE_DIR/preflight.sfdisk" \
    "$STATE_DIR/preflight.sfdisk.json" \
    "$STATE_DIR/preflight.parted-free" \
    "$STATE_DIR/preflight.efibootmgr" \
    "$STATE_DIR/preflight.rpm-ostree-kargs" \
    "$STATE_DIR/preflight.swap-offset" \
    > "$STATE_DIR/preflight.sha256"
  printf '%s\n' "$(date -Is)" > "$STATE_DIR/preflight.ok"
  printf 'preflight passed; metadata is in %s\n' "$STATE_DIR"
  printf '%s\n' 'no large data backup was created and no device state was changed'
  printf 'saved GPT: %s\n' "$STATE_DIR/preflight.sfdisk"
  printf 'saved EFI state: %s\n' "$STATE_DIR/preflight.efibootmgr"
  printf 'saved hibernate offset: %s\n' "$(tr -d '[:space:]' < "$STATE_DIR/preflight.swap-offset")"
}

require_preflight() {
  [[ -f "$STATE_DIR/preflight.ok" ]] || die "run preflight first: $STATE_DIR/preflight.ok is missing"
  [[ -f "$STATE_DIR/preflight.sfdisk" ]] || die 'preflight GPT dump is missing'
  [[ -f "$STATE_DIR/preflight.boot-id" ]] || die 'preflight boot ID is missing'
}

current_dump_matches_preflight() {
  sfdisk --dump "$DISK" > "$TMP_DIR/current.sfdisk"
  cmp -s "$TMP_DIR/current.sfdisk" "$STATE_DIR/preflight.sfdisk"
}

make_candidate() {
  local large_uuid tail_uuid candidate
  large_uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  tail_uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  candidate="$STATE_DIR/candidate.sfdisk"
  python3 - "$STATE_DIR/preflight.sfdisk" "$candidate" "$DISK" "$large_uuid" "$tail_uuid" <<'PY'
import pathlib
import sys

source, destination, disk, large_uuid, tail_uuid = sys.argv[1:]
suffix = "p" if disk[-1].isdigit() else ""
nodes = {n: f"{disk}{suffix}{n}" for n in (1, 2, 3, 4, 5, 6, 7)}
large = (
    f'{nodes[2]} : start=      616448, size=   537133056, '
    f'type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid={large_uuid}, '
    'name="bazzite-expand"\n'
)
tail = (
    f'{nodes[4]} : start=   740229120, size=     2103296, '
    f'type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid={tail_uuid}, '
    'name="bazzite-expand-tail"\n'
)
output = []
for line in pathlib.Path(source).read_text(encoding="utf-8").splitlines(keepends=True):
    node = line.split(maxsplit=1)[0] if line.strip() else ""
    if node == nodes[2]:
        output.append(large)
    elif node == nodes[3]:
        continue
    elif node == nodes[4]:
        output.append(tail)
    else:
        output.append(line)
pathlib.Path(destination).write_text("".join(output), encoding="utf-8")
PY
  printf '%s\n' "$large_uuid" > "$STATE_DIR/new-large-partuuid"
  printf '%s\n' "$tail_uuid" > "$STATE_DIR/new-tail-partuuid"
}

validate_candidate() {
  local candidate="$1"
  [[ -f "$candidate" ]] || die "candidate GPT is missing: $candidate"
  python3 - "$candidate" "$DISK" "$(cat "$STATE_DIR/new-large-partuuid")" "$(cat "$STATE_DIR/new-tail-partuuid")" <<'PY'
import pathlib
import re
import sys

path, disk, large_uuid, tail_uuid = sys.argv[1:]
suffix = "p" if disk[-1].isdigit() else ""
nodes = {n: f"{disk}{suffix}{n}" for n in (1, 2, 3, 4, 5, 6, 7)}
entries = {}
text = pathlib.Path(path).read_text(encoding="utf-8")
for line in text.splitlines():
    if " : " not in line:
        continue
    node, fields_text = line.split(" : ", 1)
    fields = {}
    for key in ("start", "size", "type", "uuid"):
        match = re.search(rf"\b{key}=\s*\"?([^,\"]+)\"?", fields_text)
        if match:
            fields[key] = match.group(1).strip()
    entries[node] = fields

def check(number, start, size, part_type, uuid):
    node = nodes[number]
    fields = entries.get(node)
    if fields is None:
        raise SystemExit(f"candidate is missing {node}")
    expected = {"start": str(start), "size": str(size), "type": part_type, "uuid": uuid}
    for key, value in expected.items():
        if fields.get(key, "").upper() != value.upper():
            raise SystemExit(f"candidate {node} {key} mismatch: {fields.get(key)!r}")

check(1, 2048, 614400, "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "9D8D1061-3955-49F7-9F9C-1A16675B258C")
check(2, 616448, 537133056, "0FC63DAF-8483-4772-8E79-3D69D8477DE4", large_uuid)
check(4, 740229120, 2103296, "0FC63DAF-8483-4772-8E79-3D69D8477DE4", tail_uuid)
check(5, 742332416, 4194304, "BC13C2FF-59E6-4262-A352-B275FD6F7172", "0C07A26E-305F-47ED-81C7-F54E33E904E8")
check(6, 746526720, 253687808, "0FC63DAF-8483-4772-8E79-3D69D8477DE4", "A265B280-4539-47FA-B590-BF36612B6CE6")
check(7, 537749504, 202479616, "0FC63DAF-8483-4772-8E79-3D69D8477DE4", "AC1A013C-F27E-4E82-935B-A582BECE8FA4")
if nodes[3] in entries:
    raise SystemExit("candidate still contains the old Windows partition")
if len(entries) != 6:
    raise SystemExit(f"candidate contains {len(entries)} partition entries, expected 6")
for old_uuid in ("1A763B11-8677-41C8-A736-6265F316EF37", "665CD3B2-E21A-45D0-850B-624CE704AD04", "029D12C1-6785-40C5-B6AF-68809944834F"):
    if old_uuid.lower() in text.lower():
        raise SystemExit(f"old Windows GUID remains in candidate: {old_uuid}")
PY
  if ! sfdisk --no-act --no-reread --no-tell-kernel "$DISK" < "$candidate" > "$STATE_DIR/candidate-check.log" 2>&1; then
    cat "$STATE_DIR/candidate-check.log" >&2
    die 'sfdisk rejected the candidate GPT'
  fi
}

stage_gpt() {
  local commit_token="${1:-}"
  require_root
  require_commands
  ensure_state_dir
  require_preflight
  load_live_table
  assert_disk_basics
  assert_original_layout
  current_dump_matches_preflight || die 'live GPT changed since preflight; run preflight again'
  if [[ ! -f "$STATE_DIR/candidate.sfdisk" ]]; then
    make_candidate
  fi
  validate_candidate "$STATE_DIR/candidate.sfdisk"
  printf '%s\n' 'candidate GPT:'
  cat "$STATE_DIR/candidate.sfdisk"
  printf '%s\n' 'candidate validation passed; existing Bazzite entries are unchanged'
  if [[ -z "$commit_token" ]]; then
    printf '%s\n' 'dry run only; review the candidate, then rerun with --commit DELETE-WINDOWS-GPT'
    return 0
  fi
  [[ "$commit_token" == DELETE-WINDOWS-GPT ]] || die 'wrong GPT commit token'
  assert_resume_identity
  if pgrep -af '[s]fdisk|[p]arted|[g]disk' >/dev/null 2>&1; then
    die 'another partition editor appears to be running'
  fi
  printf '%s\n' 'writing GPT; the kernel partition table will remain stale until reboot'
  sfdisk --no-reread --no-tell-kernel "$DISK" < "$STATE_DIR/candidate.sfdisk" > "$STATE_DIR/gpt-write.log" 2>&1 || {
    cat "$STATE_DIR/gpt-write.log" >&2
    die 'GPT write failed; do not run further storage commands'
  }
  sfdisk --dump "$DISK" > "$STATE_DIR/gpt-after.sfdisk"
  sfdisk --json "$DISK" > "$STATE_DIR/gpt-after.sfdisk.json"
  cp "$STATE_DIR/gpt-after.sfdisk" "$TMP_DIR/current.sfdisk"
  validate_candidate "$STATE_DIR/gpt-after.sfdisk"
  printf '%s\n' "$(date -Is)" > "$STATE_DIR/gpt-written"
  printf '%s\n' 'GPT write passed its on-disk verification'
  printf '%s\n' 'reboot locally before running verify-after-reboot or add-members'
}

device_for_partuuid() {
  local uuid="$1"
  local device
  device="$(blkid -t "PARTUUID=$uuid" -o device 2>/dev/null || true)"
  [[ -n "$device" ]] || die "no partition found for PARTUUID $uuid"
  printf '%s\n' "$device"
}

verify_after_reboot() {
  local current_boot saved_boot new_large new_tail device
  require_root
  require_commands
  ensure_state_dir
  require_preflight
  [[ -f "$STATE_DIR/gpt-written" ]] || die 'GPT write marker is missing'
  current_boot="$(cat /proc/sys/kernel/random/boot_id)"
  saved_boot="$(cat "$STATE_DIR/preflight.boot-id")"
  [[ "$current_boot" != "$saved_boot" ]] || die 'the planned reboot has not occurred'
  load_live_table
  sfdisk --dump "$DISK" > "$TMP_DIR/current.sfdisk"
  assert_disk_basics
  assert_preserved_layout
  new_large="$(cat "$STATE_DIR/new-large-partuuid")"
  new_tail="$(cat "$STATE_DIR/new-tail-partuuid")"
  assert_partition 2 "$LARGE_START" "$LARGE_SIZE" "$LINUX_GPT_TYPE" "$new_large"
  assert_partition 4 "$TAIL_START" "$TAIL_SIZE" "$LINUX_GPT_TYPE" "$new_tail"
  device_for_partuuid "$new_large" > "$STATE_DIR/new-large-device"
  device_for_partuuid "$new_tail" > "$STATE_DIR/new-tail-device"
  while IFS= read -r device; do
    findmnt -rn -S "$device" >/dev/null 2>&1 && die "new partition is mounted: $device"
  done < <(printf '%s\n' "$(cat "$STATE_DIR/new-large-device")" "$(cat "$STATE_DIR/new-tail-device")")
  {
    printf '%s\n' "--- $(cat "$STATE_DIR/new-large-device")"
    wipefs -n "$(cat "$STATE_DIR/new-large-device")" 2>&1 || true
    printf '%s\n' "--- $(cat "$STATE_DIR/new-tail-device")"
    wipefs -n "$(cat "$STATE_DIR/new-tail-device")" 2>&1 || true
  } | tee "$STATE_DIR/new-signatures.txt"
  assert_btrfs_identity
  assert_btrfs_state 2
  assert_resume_identity
  printf '%s\n' "$(date -Is)" > "$STATE_DIR/after-reboot.ok"
  printf '%s\n' 'post-reboot GPT and Btrfs checks passed; new devices are ready for explicit add-members commit'
}

member_present() {
  local device="$1"
  btrfs filesystem show "$MOUNTPOINT" | grep -Fq "path $device"
}

add_one_member() {
  local device="$1"
  local label="$2"
  local signatures unexpected
  if member_present "$device"; then
    printf 'Btrfs member already present: %s\n' "$device"
    return 0
  fi
  findmnt -rn -S "$device" >/dev/null 2>&1 && die "new partition is mounted: $device"
  signatures="$(wipefs -n "$device" 2>&1 || true)"
  unexpected="$(awk 'NR > 1 && $3 != "ntfs" {print}' <<< "$signatures")"
  if [[ -n "$unexpected" ]]; then
    printf '%s\n' "$unexpected" >&2
    die "$label has a non-NTFS filesystem signature; refusing to wipe $device"
  fi
  printf 'clearing old filesystem signatures on %s\n' "$device"
  wipefs -a "$device"
  sync
  btrfs device add -K "$device" "$MOUNTPOINT"
  sync
}

validate_expanded() {
  local large_device tail_device usage show
  large_device="$(cat "$STATE_DIR/new-large-device")"
  tail_device="$(cat "$STATE_DIR/new-tail-device")"
  show="$(btrfs filesystem show "$MOUNTPOINT")" || die 'Btrfs filesystem is unavailable'
  [[ "$show" == *"path $large_device"* ]] || die 'large new Btrfs member is missing'
  [[ "$show" == *"path $tail_device"* ]] || die 'tail new Btrfs member is missing'
  usage="$(btrfs filesystem usage -T "$MOUNTPOINT")" || die 'could not read expanded Btrfs usage'
  printf '%s\n' "$usage" > "$TMP_DIR/btrfs-usage.txt"
  grep -Eq 'Device size:[[:space:]]+47[34-5]\.' <<< "$usage" || die 'expanded Btrfs device size is not approximately 474-475 GiB'
  assert_btrfs_state 4
  assert_btrfs_identity
  assert_resume_identity
}

add_members() {
  local commit_token="${1:-}"
  local large_device tail_device
  require_root
  require_commands
  ensure_state_dir
  require_preflight
  [[ -f "$STATE_DIR/after-reboot.ok" ]] || die 'run verify-after-reboot first'
  if [[ -f "$STATE_DIR/expanded.ok" ]]; then
    validate_expanded
    printf '%s\n' 'Btrfs expansion is already verified'
    return 0
  fi
  verify_after_reboot
  large_device="$(cat "$STATE_DIR/new-large-device")"
  tail_device="$(cat "$STATE_DIR/new-tail-device")"
  printf '%s\n' 'planned Btrfs additions:'
  printf '  %s\n' "$large_device"
  printf '  %s\n' "$tail_device"
  if [[ -z "$commit_token" ]]; then
    printf '%s\n' 'dry run only; rerun with --commit ADD-BTRFS-MEMBERS'
    return 0
  fi
  [[ "$commit_token" == ADD-BTRFS-MEMBERS ]] || die 'wrong Btrfs commit token'
  add_one_member "$large_device" large
  add_one_member "$tail_device" tail
  btrfs filesystem resize max "$MOUNTPOINT"
  sync
  validate_expanded
  printf '%s\n' "$(date -Is)" > "$STATE_DIR/expanded.ok"
  printf '%s\n' 'Btrfs expansion passed: four devices, single profiles, no balance, clean device stats'
}

windows_entry_numbers() {
  local line number
  while IFS= read -r line; do
    if [[ "$line" =~ ^Boot([0-9A-Fa-f]{4}) ]]; then
      number="${BASH_REMATCH[1]}"
      if [[ "$line" == *'Windows Boot Manager'* ]] || \
        grep -Fq '\EFI\Microsoft\' <<< "$line"; then
        printf '%s\n' "$number"
      fi
    fi
  done < <(efibootmgr -v)
}

cleanup_efi() {
  local commit_token="${1:-}"
  local efi_source microsoft_dir entries entry
  require_root
  require_commands
  ensure_state_dir
  require_preflight
  [[ -f "$STATE_DIR/expanded.ok" ]] || die 'verify the expanded Btrfs filesystem before EFI cleanup'
  efi_source="$(findmnt -no SOURCE -T /boot/efi)"
  [[ "$efi_source" == *"$(partition_node 1)"* ]] || die '/boot/efi is not mounted from the preserved EFI partition'
  [[ -d /boot/efi/EFI/fedora ]] || die 'Bazzite EFI/fedora directory is missing'
  [[ -f /boot/efi/EFI/fedora/shimx64.efi ]] || die 'Bazzite Fedora shim is missing'
  [[ -d /boot/efi/EFI/Boot ]] || die 'Bazzite fallback EFI/Boot directory is missing'
  [[ -f /boot/efi/EFI/Boot/BOOTX64.EFI ]] || die 'Bazzite fallback BOOTX64.EFI is missing'
  microsoft_dir=/boot/efi/EFI/Microsoft
  entries="$(windows_entry_numbers || true)"
  printf '%s\n' 'Windows EFI entries to remove:'
  if [[ -n "$entries" ]]; then
    while IFS= read -r entry; do
      [[ -n "$entry" ]] && printf '  Boot%s\n' "$entry"
    done <<< "$entries"
  else
    printf '%s\n' '  none'
  fi
  if [[ -d "$microsoft_dir" ]]; then
    printf '  directory: %s\n' "$microsoft_dir"
  else
    printf '%s\n' '  directory: absent'
  fi
  if [[ -z "$commit_token" ]]; then
    printf '%s\n' 'dry run only; rerun with --commit REMOVE-MICROSOFT-EFI'
    return 0
  fi
  [[ "$commit_token" == REMOVE-MICROSOFT-EFI ]] || die 'wrong EFI commit token'
  efibootmgr -v > "$STATE_DIR/efi-before-cleanup.txt"
  if [[ -d "$microsoft_dir" ]]; then
    tar --xattrs --acls --numeric-owner -cpf "$STATE_DIR/efi-microsoft.tar" -C /boot/efi EFI/Microsoft
  fi
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && efibootmgr -b "$entry" -B
  done <<< "$entries"
  if [[ -d "$microsoft_dir" ]]; then
    rm -rf -- "$microsoft_dir"
  fi
  sync
  efibootmgr -v > "$STATE_DIR/efi-after-cleanup.txt"
  grep -Fq '\EFI\fedora\shimx64.efi' "$STATE_DIR/efi-after-cleanup.txt" || die 'Bazzite EFI entry disappeared'
  grep -Fq '\EFI\Microsoft\' "$STATE_DIR/efi-after-cleanup.txt" && die 'a Microsoft EFI entry remains'
  [[ ! -e "$microsoft_dir" ]] || die 'Microsoft EFI directory remains'
  [[ -d /boot/efi/EFI/fedora && -d /boot/efi/EFI/Boot ]] || die 'Bazzite EFI directories changed unexpectedly'
  printf '%s\n' 'Microsoft EFI directory and matching firmware entries removed; Bazzite loaders verified'
}

main() {
  local command_name="${1:-help}"
  shift || true
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  case "$command_name" in
    preflight)
      [[ "$#" -eq 0 ]] || die 'preflight does not accept arguments'
      preflight
      ;;
    stage-gpt)
      [[ "$#" -le 2 ]] || die 'stage-gpt accepts only --commit TOKEN'
      if [[ "$#" -eq 0 ]]; then
        stage_gpt
      elif [[ "$1" == --commit ]]; then
        [[ "$#" -eq 2 ]] || die 'stage-gpt requires --commit TOKEN'
        stage_gpt "$2"
      else
        die 'stage-gpt accepts only --commit TOKEN'
      fi
      ;;
    verify-after-reboot)
      [[ "$#" -eq 0 ]] || die 'verify-after-reboot does not accept arguments'
      verify_after_reboot
      ;;
    add-members)
      [[ "$#" -le 2 ]] || die 'add-members accepts only --commit TOKEN'
      if [[ "$#" -eq 0 ]]; then
        add_members
      elif [[ "$1" == --commit ]]; then
        [[ "$#" -eq 2 ]] || die 'add-members requires --commit TOKEN'
        add_members "$2"
      else
        die 'add-members accepts only --commit TOKEN'
      fi
      ;;
    cleanup-efi)
      [[ "$#" -le 2 ]] || die 'cleanup-efi accepts only --commit TOKEN'
      if [[ "$#" -eq 0 ]]; then
        cleanup_efi
      elif [[ "$1" == --commit ]]; then
        [[ "$#" -eq 2 ]] || die 'cleanup-efi requires --commit TOKEN'
        cleanup_efi "$2"
      else
        die 'cleanup-efi accepts only --commit TOKEN'
      fi
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage >&2
      die "unknown command: $command_name"
      ;;
  esac
}

main "$@"