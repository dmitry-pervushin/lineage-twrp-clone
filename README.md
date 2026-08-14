# LineageOS/TWRP device cloning tools

Two host-side Bash scripts for copying a LineageOS installation between devices of the same
model using TWRP and ADB:

- `backup-lineage.sh` creates a native TWRP `Data` backup and optionally copies shared storage;
- `restore-lineage.sh` restores the backup, optionally restores shared storage, and assigns a
  new Android device name.

The scripts favor compatibility over speed. Native TWRP backup files and shared-storage files
are transferred with `adb pull` and `adb push`; binary archives are not streamed through an
interactive recovery shell. This is important for older recovery builds whose `adbd` only
supports PTY shell sessions.

## Compatibility and limitations

The scripts are intended for macOS or Linux and require Bash, ADB, and a recovery that provides
the TWRP command-line utility. They include compatibility handling for older TWRP releases such
as 3.2.3 as well as newer releases, but no backup procedure can be universal across all Android
devices.

For a reliable restore:

- source and target must be the same device model and hardware revision;
- install the same firmware, LineageOS build, and GApps/microG package on the target first;
- boot the target system once and authorize USB debugging before restoration;
- TWRP must be able to decrypt and mount `/data` on both devices;
- keep enough free space on internal storage for a temporary native TWRP backup;
- preferably remove the source screen lock before backup.

The scripts deliberately do not copy hardware-specific partitions such as EFS, persist, modem,
metadata, keystore, bootloader, or device calibration partitions. Copying those partitions can
duplicate identifiers or brick the target.

Hardware-backed application keys do not transfer between physical devices. Banking clients,
VPN applications, DRM clients, authenticators, and similar applications may require a new login
or re-enrollment after restoration.

## Requirements

Install recent Android Platform Tools and verify ADB:

```bash
adb version
adb devices
```

Enable USB debugging on LineageOS under **Settings → System → Developer options** and accept the
computer's authorization prompt.

Make the scripts executable:

```bash
chmod +x backup-lineage.sh restore-lineage.sh
```

## Create a backup

Connect the source device while Android is running:

```bash
./backup-lineage.sh ./device-backup
```

If more than one ADB device is connected:

```bash
./backup-lineage.sh --serial SOURCE_SERIAL ./device-backup
```

If TWRP needs a PIN or password to decrypt `/data`:

```bash
TWRP_PASSWORD=1234 ./backup-lineage.sh ./device-backup
```

Options:

- `--no-shared-storage` skips `/sdcard`;
- `--no-reboot` leaves the source in TWRP after completion.

The preferred backup layout is:

```text
device-backup/
├── manifest.tsv
├── twrp-data/
│   ├── data.ext4.win...
│   └── recovery.log
└── shared-storage/
```

Shared storage is copied before the new TWRP backup is created, preventing that backup from
being included recursively in the shared-storage copy. TWRP's on-device copy is retained as a
safety copy, and its exact path is printed at completion.

## Restore a target

Install and boot the same LineageOS build on a fresh target, enable USB debugging, and connect
the target to the computer:

```bash
./restore-lineage.sh \
  --serial TARGET_SERIAL \
  --name lineage-02 \
  ./device-backup
```

The script verifies the device codename and asks you to type the target serial number before it
overwrites application data. For an already verified unattended target, add `--yes`:

```bash
./restore-lineage.sh \
  --serial TARGET_SERIAL \
  --name lineage-02 \
  --yes \
  ./device-backup
```

If TWRP needs the target's current unlock credential:

```bash
TWRP_PASSWORD=1234 ./restore-lineage.sh \
  --serial TARGET_SERIAL \
  --name lineage-02 \
  ./device-backup
```

Options:

- `--no-shared-storage` or `--no-sdcard` restores applications and private data without
  restoring `/sdcard`;
- `--keep-temp` retains uploaded recovery files for troubleshooting;
- `--yes` skips the serial-number confirmation.

The restore script supports three generations of backups:

1. native `twrp-data/` directories created by the current backup script;
2. legacy `twrp-data.tar.gz` archives;
3. non-empty legacy `data.ab` backups when supported by that TWRP/ADB combination.

Installed applications and their private data are part of TWRP's `Data` backup. Shared storage
is separate. After the first boot, Android may spend several minutes scanning applications and
optimizing bytecode.

## Device name and hostname

`--name` sets Android's persistent `device_name`. If root and Magisk are detected, the restore
script also installs a Magisk `service.d` script that reapplies the Linux kernel hostname after
each boot. Without root, only Android's device name is changed.

Modern Android versions generally do not send the Linux hostname to DHCP servers. Assign the
display name in the router or local DNS service when a network-visible name is required.

## Troubleshooting

### Device is unauthorized

Unlock Android, accept the USB debugging prompt, and run:

```bash
adb kill-server
adb start-server
adb devices
```

### TWRP does not appear as `device`

Older TWRP versions often appear as `recovery`. The scripts poll both states and verify
`ro.twrp.version`; they do not assume `adb wait-for-device` works in recovery.

### Recovery only supports allocating a PTY

This is expected on some old builds. The current scripts use `adb push`/`adb pull` rather than
feeding binary TAR data to `adb shell`, so a raw non-PTY shell is not required.

### Restore reports `Unable to locate backup 'D'`

Old TWRP command-line versions expect the backup path before the partition selector. The restore
script uses the compatible form:

```text
twrp restore BACKUP_PATH D
```

It also checks TWRP's textual output because some old versions return exit status zero even when
they did not restore anything.

### Collect the recovery log

Before rebooting from TWRP:

```bash
adb pull /tmp/recovery.log ./recovery.log
adb shell "grep -iE 'restore|backup|error|failed|data' /tmp/recovery.log | tail -200"
```
