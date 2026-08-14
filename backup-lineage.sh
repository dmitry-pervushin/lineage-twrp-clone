#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM=${0##*/}
SERIAL=""
OUTPUT_DIR=""
NO_REBOOT=0
NO_SHARED_STORAGE=0
ADB=(adb)
TWRP_BIN=""

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTIONS] [OUTPUT_DIR]

Create a portable native TWRP data backup on a macOS/Linux computer.

Options:
  --serial SERIAL       select a device when more than one is connected
  --no-shared-storage   do not copy /sdcard
  --no-reboot           leave the source device in TWRP
  -h, --help            show this help

Environment:
  TWRP_PASSWORD         PIN/password used by TWRP to decrypt /data (optional)

Example:
  TWRP_PASSWORD=1234 ./$PROGRAM --serial ABC123 ./phone-backup
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
  awk -F '\t' -v key="$1" '$1 == key { sub(/^[^\t]*\t/, ""); print; exit }' "$OUTPUT_DIR/manifest.tsv"
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

decrypt_data_if_needed() {
  local quoted
  if data_is_decrypted; then
    echo "TWRP: /data is readable"
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

locate_twrp_backup() {
  local name=$1 result
  result=$("${ADB[@]}" shell \
    "find /data/media /sdcard /external_sd /usb_otg -type d -name '$name' 2>/dev/null | head -n 1" | tr -d '\r' || true)
  printf '%s' "$result"
}

create_twrp_backup() {
  local name=$1 remote_dir output rc

  echo "Creating compressed native TWRP /data backup..."
  set +e
  output=$("${ADB[@]}" shell "$TWRP_BIN backup DO '$name'" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$output"
  remote_dir=$(locate_twrp_backup "$name")

  if [[ "$rc" -ne 0 || -z "$remote_dir" ]]; then
    name="${name}-plain"
    echo "Compressed backup was unavailable; retrying without compression..."
    "${ADB[@]}" shell "$TWRP_BIN backup D '$name'"
    remote_dir=$(locate_twrp_backup "$name")
  fi

  [[ -n "$remote_dir" ]] || die "TWRP finished but its backup directory could not be found"
  case "$remote_dir" in
    */"$name") ;;
    *) die "Unexpected TWRP backup path: $remote_dir" ;;
  esac

  REMOTE_BACKUP_NAME=$name
  REMOTE_BACKUP_DIR=$remote_dir
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      [[ $# -ge 2 ]] || die "--serial requires a value"
      SERIAL=$2
      shift 2
      ;;
    --no-shared-storage)
      NO_SHARED_STORAGE=1
      shift
      ;;
    --no-reboot)
      NO_REBOOT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      [[ -z "$OUTPUT_DIR" ]] || die "Only one output directory may be supplied"
      OUTPUT_DIR=$1
      shift
      ;;
  esac
done

command -v adb >/dev/null 2>&1 || die "adb is not installed or not in PATH"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="lineage-backup-$(date +%Y%m%d-%H%M%S)"
fi
[[ ! -e "$OUTPUT_DIR/twrp-data" ]] || die "$OUTPUT_DIR/twrp-data already exists"
if [[ "$NO_SHARED_STORAGE" -eq 0 ]]; then
  [[ ! -e "$OUTPUT_DIR/shared-storage" ]] || die "$OUTPUT_DIR/shared-storage already exists"
fi
mkdir -p "$OUTPUT_DIR"

resolve_initial_device
INITIAL_STATE=$(device_state)

if [[ "$INITIAL_STATE" == "recovery" && -s "$OUTPUT_DIR/manifest.tsv" ]]; then
  SOURCE_MODEL=$(manifest_value model)
  SOURCE_DEVICE=$(manifest_value device)
  SOURCE_LINEAGE=$(manifest_value lineage)
  SOURCE_BUILD=$(manifest_value build)
else
  SOURCE_MODEL=$(prop ro.product.model)
  SOURCE_DEVICE=$(prop ro.product.device)
  SOURCE_LINEAGE=$(prop ro.lineage.version)
  SOURCE_BUILD=$(prop ro.build.version.incremental)
fi
[[ -n "$SOURCE_DEVICE" ]] || SOURCE_DEVICE=$(prop ro.build.product)
[[ -n "$SOURCE_DEVICE" ]] || die "Could not determine the source device codename"

if [[ "$INITIAL_STATE" == "device" || ! -s "$OUTPUT_DIR/manifest.tsv" ]]; then
  printf 'format\t2\nserial\t%s\nmodel\t%s\ndevice\t%s\nlineage\t%s\nbuild\t%s\ncreated_utc\t%s\n' \
    "$SERIAL" "$SOURCE_MODEL" "$SOURCE_DEVICE" "$SOURCE_LINEAGE" "$SOURCE_BUILD" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUTPUT_DIR/manifest.tsv"
fi

if [[ "$INITIAL_STATE" == "device" ]]; then
  "${ADB[@]}" shell getprop | tr -d '\r' > "$OUTPUT_DIR/getprop.txt" || true
  "${ADB[@]}" shell pm list packages -3 | tr -d '\r' > "$OUTPUT_DIR/user-packages.txt" || true
  "${ADB[@]}" shell settings list global | tr -d '\r' > "$OUTPUT_DIR/settings-global.txt" || true
  "${ADB[@]}" shell settings list secure | tr -d '\r' > "$OUTPUT_DIR/settings-secure.txt" || true
  "${ADB[@]}" shell settings list system | tr -d '\r' > "$OUTPUT_DIR/settings-system.txt" || true
fi

echo "Source: $SOURCE_MODEL ($SOURCE_DEVICE), serial $SERIAL"
if [[ -z "$(prop ro.twrp.version || true)" ]]; then
  echo "Rebooting to recovery..."
  "${ADB[@]}" reboot recovery
fi
wait_for_twrp
detect_twrp_binary
TWRP_VERSION=$(prop ro.twrp.version)
echo "TWRP: $TWRP_VERSION, command: $TWRP_BIN"

decrypt_data_if_needed
ensure_shared_storage

# Copy shared storage before making a new TWRP backup, so the new backup cannot
# recursively become part of the shared-storage copy.
if [[ "$NO_SHARED_STORAGE" -eq 0 ]]; then
  echo "Copying shared storage with adb pull..."
  mkdir -p "$OUTPUT_DIR/shared-storage"
  "${ADB[@]}" pull /sdcard/. "$OUTPUT_DIR/shared-storage/"
fi

REMOTE_BACKUP_NAME="lineage-data-$(date +%Y%m%d-%H%M%S)"
create_twrp_backup "$REMOTE_BACKUP_NAME"

echo "Copying native TWRP backup with adb pull..."
mkdir -p "$OUTPUT_DIR/twrp-data"
"${ADB[@]}" pull "$REMOTE_BACKUP_DIR/." "$OUTPUT_DIR/twrp-data/"

if ! find "$OUTPUT_DIR/twrp-data" -type f \( -name '*.win' -o -name '*.win[0-9][0-9][0-9]' \) | grep -q .; then
  die "No native TWRP .win files were copied"
fi

printf 'twrp_version\t%s\ntwrp_backup_name\t%s\ntwrp_backup_path\t%s\n' \
  "$TWRP_VERSION" "$REMOTE_BACKUP_NAME" "$REMOTE_BACKUP_DIR" >> "$OUTPUT_DIR/manifest.tsv"

echo "Backup completed: $OUTPUT_DIR"
du -sh "$OUTPUT_DIR/twrp-data" "$OUTPUT_DIR/shared-storage" 2>/dev/null || true
echo "Safety copy retained on source device: $REMOTE_BACKUP_DIR"

if [[ "$NO_REBOOT" -eq 0 ]]; then
  echo "Rebooting the source device..."
  "${ADB[@]}" reboot
fi
