#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM=${0##*/}
SERIAL=""
BACKUP_DIR=""
DEVICE_NAME=""
ASSUME_YES=0
NO_SHARED_STORAGE=0
KEEP_TEMP=0
ADB=(adb)
TWRP_BIN=""
BACKUP_FORMAT=""
SHARED_FORMAT="none"

usage() {
  cat <<EOF
Usage: $PROGRAM --name DEVICE_NAME [OPTIONS] BACKUP_DIR

Restore a backup made by backup-lineage.sh or an older version of the script.

Options:
  --name NAME            persistent Android device name (required)
  --serial SERIAL        select the target device
  --yes                  skip interactive serial-number confirmation
  --no-shared-storage    do not restore /sdcard
  --no-sdcard            alias for --no-shared-storage
  --keep-temp            keep temporary restore files on the target
  -h, --help             show this help

Environment:
  TWRP_PASSWORD          PIN/password used by TWRP to decrypt target /data

Supported backup formats:
  twrp-data/             native directory format (preferred)
  twrp-data.tar.gz       legacy archive format
  data.ab                legacy adb/TWRP format, when non-empty
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

remote_quote() {
  local value=$1
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

set_adb_serial() {
  SERIAL=$1
  ADB=(adb -s "$SERIAL")
}

device_state() {
  adb devices | awk -v serial="$SERIAL" '$1 == serial { print $2; exit }'
}

prop() {
  "${ADB[@]}" shell getprop "$1" 2>/dev/null | tr -d '\r'
}

manifest_value() {
  awk -F '\t' -v key="$1" '$1 == key { sub(/^[^\t]*\t/, ""); print; exit }' "$BACKUP_DIR/manifest.tsv"
}

resolve_initial_device() {
  local devices count state
  adb start-server >/dev/null

  if [[ -n "$SERIAL" ]]; then
    set_adb_serial "$SERIAL"
    state=$(device_state)
    case "$state" in
      device|recovery) return ;;
      unauthorized) die "Device $SERIAL is unauthorized; accept the USB debugging dialog" ;;
      sideload) die "Device $SERIAL is in sideload mode; leave ADB Sideload first" ;;
      *) die "Device $SERIAL is not available through adb" ;;
    esac
  fi

  devices=$(adb devices | awk '$2 == "device" || $2 == "recovery" { print $1 }')
  count=$(printf '%s\n' "$devices" | awk 'NF { n++ } END { print n+0 }')
  [[ "$count" -eq 1 ]] || die "Expected one adb device; found $count. Use --serial."
  set_adb_serial "$(printf '%s\n' "$devices" | awk 'NF { print; exit }')"
}

find_connected_twrp() {
  local candidate version matches found
  matches=0
  found=""
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    version=$(adb -s "$candidate" shell getprop ro.twrp.version 2>/dev/null | tr -d '\r' || true)
    if [[ -n "$version" ]]; then
      found=$candidate
      matches=$((matches + 1))
    fi
  done < <(adb devices | awk '$2 == "device" || $2 == "recovery" { print $1 }')

  if [[ "$matches" -eq 1 ]]; then
    set_adb_serial "$found"
    return 0
  fi
  return 1
}

wait_for_twrp() {
  local attempt version
  echo "Waiting for TWRP..."
  for ((attempt=1; attempt<=300; attempt++)); do
    version=$(prop ro.twrp.version || true)
    if [[ -n "$version" ]]; then
      return
    fi
    if find_connected_twrp; then
      return
    fi
    sleep 1
  done
  die "TWRP did not become available within 5 minutes"
}

detect_twrp_binary() {
  local candidate
  for candidate in twrp /sbin/twrp /system/bin/twrp; do
    if "${ADB[@]}" shell "test -x '$candidate' || command -v '$candidate' >/dev/null 2>&1" >/dev/null 2>&1; then
      TWRP_BIN=$candidate
      return
    fi
  done
  die "The TWRP command-line tool was not found in recovery"
}

data_is_decrypted() {
  "${ADB[@]}" shell 'test -r /data/system/packages.xml' >/dev/null 2>&1
}

data_is_fresh_and_writable() {
  # shellcheck disable=SC2016 # Expanded by the recovery shell, not the host.
  "${ADB[@]}" shell '
    grep -qE "^[^ ]+ /data " /proc/mounts &&
    test -w /data &&
    test ! -e /data/system/packages.xml &&
    test ! -d /data/system/users &&
    probe=/data/.lineage-restore-write-test &&
    : > "$probe" && rm -f "$probe"
  ' >/dev/null 2>&1
}

decrypt_data_if_needed() {
  local quoted
  if data_is_decrypted; then
    echo "TWRP: /data is readable"
    return
  fi

  if data_is_fresh_and_writable; then
    echo "TWRP: fresh /data is mounted and writable"
    return
  fi

  [[ -n "${TWRP_PASSWORD:-}" ]] || die "/data is encrypted. Decrypt it in TWRP or set TWRP_PASSWORD."
  [[ "$TWRP_PASSWORD" != *$'\n'* ]] || die "TWRP_PASSWORD must not contain a newline"
  quoted=$(remote_quote "$TWRP_PASSWORD")
  "${ADB[@]}" shell "$TWRP_BIN decrypt $quoted"
  data_is_decrypted || die "TWRP could not decrypt /data"
}

ensure_shared_storage() {
  "${ADB[@]}" shell 'test -d /sdcard' >/dev/null 2>&1 || \
    "${ADB[@]}" shell "$TWRP_BIN mount data" >/dev/null 2>&1 || true
  "${ADB[@]}" shell 'test -d /sdcard' >/dev/null 2>&1 || die "/sdcard is not available in TWRP"
}

detect_remote_archive_tools() {
  if "${ADB[@]}" shell 'command -v gzip >/dev/null 2>&1' >/dev/null 2>&1; then
    REMOTE_GZIP=gzip
  elif "${ADB[@]}" shell 'command -v pigz >/dev/null 2>&1' >/dev/null 2>&1; then
    REMOTE_GZIP=pigz
  elif "${ADB[@]}" shell 'command -v busybox >/dev/null 2>&1' >/dev/null 2>&1; then
    REMOTE_GZIP='busybox gzip'
  else
    die "Legacy .tar.gz restore needs gzip, pigz, or busybox in TWRP"
  fi

  if "${ADB[@]}" shell 'command -v tar >/dev/null 2>&1' >/dev/null 2>&1; then
    REMOTE_TAR=tar
  elif "${ADB[@]}" shell 'command -v busybox >/dev/null 2>&1' >/dev/null 2>&1; then
    REMOTE_TAR='busybox tar'
  else
    die "Legacy .tar.gz restore needs tar or busybox in TWRP"
  fi
}

detect_backup_formats() {
  local data_ab_size
  if [[ -d "$BACKUP_DIR/twrp-data" ]] && \
     find "$BACKUP_DIR/twrp-data" -type f \( -name '*.win' -o -name '*.win[0-9][0-9][0-9]' \) | grep -q .; then
    BACKUP_FORMAT=native
  elif [[ -s "$BACKUP_DIR/twrp-data.tar.gz" ]]; then
    command -v gzip >/dev/null 2>&1 || die "gzip is required to validate twrp-data.tar.gz"
    gzip -t "$BACKUP_DIR/twrp-data.tar.gz"
    BACKUP_FORMAT=archive
  elif [[ -s "$BACKUP_DIR/data.ab" ]]; then
    data_ab_size=$(wc -c < "$BACKUP_DIR/data.ab" | tr -d ' ')
    [[ "$data_ab_size" -gt 1024 ]] || die "data.ab is empty or incomplete"
    BACKUP_FORMAT=adb
  else
    die "No supported TWRP data backup found in $BACKUP_DIR"
  fi

  if [[ "$NO_SHARED_STORAGE" -eq 0 ]]; then
    if [[ -d "$BACKUP_DIR/shared-storage" ]]; then
      SHARED_FORMAT=directory
    elif [[ -s "$BACKUP_DIR/sdcard.tar.gz" ]]; then
      command -v gzip >/dev/null 2>&1 || die "gzip is required to validate sdcard.tar.gz"
      gzip -t "$BACKUP_DIR/sdcard.tar.gz"
      SHARED_FORMAT=archive
    else
      echo "WARNING: no shared-storage backup found; /sdcard will not be restored" >&2
    fi
  fi
}

wait_for_android() {
  local attempt candidate completed state
  echo "Waiting for Android to finish booting..."
  for ((attempt=1; attempt<=600; attempt++)); do
    state=$(device_state)
    if [[ "$state" == "device" ]]; then
      completed=$(prop sys.boot_completed || true)
      [[ "$completed" == "1" ]] && return
    elif [[ -z "$state" ]]; then
      candidate=$(adb devices | awk '$2 == "device" { print $1; exit }')
      [[ -n "$candidate" ]] && set_adb_serial "$candidate"
    elif [[ "$state" == "unauthorized" ]]; then
      echo "Authorize USB debugging on the target device..." >&2
    fi
    sleep 1
  done
  die "Android did not finish booting within 10 minutes"
}

set_device_identity() {
  "${ADB[@]}" shell settings put global device_name "$DEVICE_NAME" || \
    echo "WARNING: could not set Android device_name" >&2

  if "${ADB[@]}" shell su -c id 2>/dev/null | grep -q 'uid=0'; then
    "${ADB[@]}" shell su -c "hostname '$DEVICE_NAME'" || true
    if "${ADB[@]}" shell su -c 'command -v magisk >/dev/null 2>&1' >/dev/null 2>&1; then
      local temporary_script
      temporary_script=$(mktemp "${TMPDIR:-/tmp}/lineage-hostname.XXXXXX")
      printf '#!/system/bin/sh\nhostname %s\nsettings put global device_name %s\n' \
        "$DEVICE_NAME" "$DEVICE_NAME" > "$temporary_script"
      "${ADB[@]}" push "$temporary_script" /data/local/tmp/10-hostname.sh >/dev/null
      rm -f "$temporary_script"
      "${ADB[@]}" shell su -c \
        'mkdir -p /data/adb/service.d && cp /data/local/tmp/10-hostname.sh /data/adb/service.d/10-hostname.sh && chmod 755 /data/adb/service.d/10-hostname.sh'
      echo "Persistent Linux hostname installed through Magisk"
    else
      echo "Linux hostname set for this boot only; Magisk was not detected"
    fi
  else
    echo "No root detected; Android device_name was set, Linux hostname was not changed"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      [[ $# -ge 2 ]] || die "--serial requires a value"
      SERIAL=$2
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      DEVICE_NAME=$2
      shift 2
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --no-shared-storage|--no-sdcard)
      NO_SHARED_STORAGE=1
      shift
      ;;
    --keep-temp)
      KEEP_TEMP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      [[ -z "$BACKUP_DIR" ]] || die "Only one backup directory may be supplied"
      BACKUP_DIR=$1
      shift
      ;;
  esac
done

command -v adb >/dev/null 2>&1 || die "adb is not installed or not in PATH"
[[ -n "$BACKUP_DIR" ]] || die "A backup directory is required"
[[ -s "$BACKUP_DIR/manifest.tsv" ]] || die "$BACKUP_DIR/manifest.tsv is missing"
[[ -n "$DEVICE_NAME" ]] || die "--name is required"
[[ "$DEVICE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Device name contains unsupported characters"
detect_backup_formats
resolve_initial_device
[[ "$SERIAL" =~ ^[A-Za-z0-9._:-]+$ ]] || die "Target serial contains unsupported characters"

SOURCE_DEVICE=$(manifest_value device)
SOURCE_MODEL=$(manifest_value model)
SOURCE_LINEAGE=$(manifest_value lineage)
TARGET_DEVICE=$(prop ro.product.device)
[[ -n "$TARGET_DEVICE" ]] || TARGET_DEVICE=$(prop ro.build.product)
TARGET_MODEL=$(prop ro.product.model)
TARGET_LINEAGE=$(prop ro.lineage.version)

[[ -n "$TARGET_DEVICE" ]] || die "Could not determine the target device codename"
[[ "$TARGET_DEVICE" == "$SOURCE_DEVICE" ]] || \
  die "Device mismatch: backup is for $SOURCE_MODEL ($SOURCE_DEVICE), target is $TARGET_MODEL ($TARGET_DEVICE)"

echo "Backup source: $SOURCE_MODEL ($SOURCE_DEVICE), Lineage $SOURCE_LINEAGE"
echo "Restore target: $TARGET_MODEL ($TARGET_DEVICE), serial $SERIAL, Lineage $TARGET_LINEAGE"
echo "Backup format: $BACKUP_FORMAT; shared storage: $SHARED_FORMAT"
if [[ -n "$SOURCE_LINEAGE" && -n "$TARGET_LINEAGE" && "$SOURCE_LINEAGE" != "$TARGET_LINEAGE" ]]; then
  echo "WARNING: LineageOS builds differ; exact build matching is strongly recommended" >&2
fi

if [[ "$ASSUME_YES" -eq 0 ]]; then
  echo
  echo "This will overwrite application data on target device $SERIAL."
  printf 'Type the target serial number to continue: '
  read -r confirmation
  [[ "$confirmation" == "$SERIAL" ]] || die "Confirmation did not match"
fi

if [[ -z "$(prop ro.twrp.version || true)" ]]; then
  echo "Rebooting target to recovery..."
  "${ADB[@]}" reboot recovery
fi
wait_for_twrp
detect_twrp_binary
TWRP_VERSION=$(prop ro.twrp.version)
echo "TWRP: $TWRP_VERSION, command: $TWRP_BIN"

decrypt_data_if_needed
ensure_shared_storage

TWRP_SERIAL=$(prop ro.serialno)
[[ "$TWRP_SERIAL" =~ ^[A-Za-z0-9._:-]+$ ]] || TWRP_SERIAL=$SERIAL
REMOTE_NAME="lineage-restore-$(date +%Y%m%d-%H%M%S)"
REMOTE_RESTORE_DIR="/sdcard/TWRP/BACKUPS/$TWRP_SERIAL/$REMOTE_NAME"
REMOTE_RESTORE_ARCHIVE="/sdcard/.$REMOTE_NAME.tar.gz"

if [[ "$BACKUP_FORMAT" == "native" ]]; then
  echo "Uploading native TWRP backup with adb push..."
  "${ADB[@]}" shell "rm -rf '$REMOTE_RESTORE_DIR' && mkdir -p '$REMOTE_RESTORE_DIR'"
  "${ADB[@]}" push "$BACKUP_DIR/twrp-data/." "$REMOTE_RESTORE_DIR/"
elif [[ "$BACKUP_FORMAT" == "archive" ]]; then
  detect_remote_archive_tools
  echo "Uploading archived TWRP backup with adb push..."
  "${ADB[@]}" shell "rm -rf '$REMOTE_RESTORE_DIR' '$REMOTE_RESTORE_ARCHIVE' && mkdir -p '$REMOTE_RESTORE_DIR'"
  "${ADB[@]}" push "$BACKUP_DIR/twrp-data.tar.gz" "$REMOTE_RESTORE_ARCHIVE"
  "${ADB[@]}" shell "$REMOTE_GZIP -dc '$REMOTE_RESTORE_ARCHIVE' | $REMOTE_TAR -C '$REMOTE_RESTORE_DIR' -xpf -"
fi

if [[ "$BACKUP_FORMAT" == "adb" ]]; then
  echo "Restoring legacy data.ab..."
  "${ADB[@]}" restore "$BACKUP_DIR/data.ab"
else
  echo "Restoring /data through native TWRP restore..."
  set +e
  RESTORE_OUTPUT=$("${ADB[@]}" shell "$TWRP_BIN restore '$REMOTE_RESTORE_DIR' D" 2>&1)
  RESTORE_STATUS=$?
  set -e
  printf '%s\n' "$RESTORE_OUTPUT"

  if [[ "$RESTORE_STATUS" -ne 0 ]] || \
     printf '%s\n' "$RESTORE_OUTPUT" | grep -Eqi \
       "Unable to locate backup|No partitions selected|restore failed|failed to restore"; then
    echo "Native TWRP restore failed; temporary files were retained at:" >&2
    echo "  $REMOTE_RESTORE_DIR" >&2
    die "TWRP did not restore /data"
  fi
fi

if [[ "$KEEP_TEMP" -eq 0 && "$BACKUP_FORMAT" != "adb" ]]; then
  echo "Removing temporary TWRP restore files..."
  "${ADB[@]}" shell "rm -rf '$REMOTE_RESTORE_DIR' '$REMOTE_RESTORE_ARCHIVE'"
fi

if [[ "$SHARED_FORMAT" == "directory" ]]; then
  echo "Restoring shared storage with adb push..."
  "${ADB[@]}" push "$BACKUP_DIR/shared-storage/." /sdcard/
elif [[ "$SHARED_FORMAT" == "archive" ]]; then
  detect_remote_archive_tools
  REMOTE_SHARED_ARCHIVE="/sdcard/.lineage-shared-$SERIAL.tar.gz"
  echo "Uploading archived shared storage with adb push..."
  "${ADB[@]}" shell "rm -f '$REMOTE_SHARED_ARCHIVE'"
  "${ADB[@]}" push "$BACKUP_DIR/sdcard.tar.gz" "$REMOTE_SHARED_ARCHIVE"
  "${ADB[@]}" shell "$REMOTE_GZIP -dc '$REMOTE_SHARED_ARCHIVE' | $REMOTE_TAR -C /sdcard -xpf -"
  if [[ "$KEEP_TEMP" -eq 0 ]]; then
    "${ADB[@]}" shell "rm -f '$REMOTE_SHARED_ARCHIVE'"
  fi
fi

echo "Rebooting target..."
"${ADB[@]}" reboot
wait_for_android
set_device_identity
echo "Restore completed for $SERIAL"
