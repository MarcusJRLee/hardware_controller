#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  print "Usage: scripts/install_ios.sh [--device <identifier-or-name>] [--config <development|local_qa>]"
  print
  print "Build, install, and launch Voice Input on a connected iPhone."
  print
  print "Options:"
  print "  --device   Select a connected iPhone without prompting."
  print "  --config   Select Development (Debug) or Local QA (Release)."
  print "  -h, --help Show this help."
}

canonical_config() {
  case "$1" in
    development)
      print "development"
      ;;
    local_qa)
      print "local_qa"
      ;;
    *)
      print -u2 "Unsupported config '$1'. Use development or local_qa."
      return 1
      ;;
  esac
}

device_selector=""
config=""
while (( $# > 0 )); do
  case "$1" in
    --device)
      (( $# >= 2 )) || {
        print -u2 "--device requires a value."
        exit 1
      }
      device_selector="$2"
      shift 2
      ;;
    --config)
      (( $# >= 2 )) || {
        print -u2 "--config requires a value."
        exit 1
      }
      config="$(canonical_config "$2")"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown option: $1"
      usage >&2
      exit 1
      ;;
  esac
done

command -v jq >/dev/null || {
  print -u2 "jq is required. Install it with: brew install jq"
  exit 1
}
command -v xcrun >/dev/null || {
  print -u2 "Xcode command-line tools are required."
  exit 1
}

temporary_root="$(mktemp -d /tmp/install_ios.XXXXXX)"
trap 'rm -rf "$temporary_root"' EXIT
devices_json="$temporary_root/devices.json"
available_devices="$temporary_root/available_devices.tsv"

xcrun devicectl list devices --json-output "$devices_json" >/dev/null
jq -r '
  .result.devices
  | map(select(
      .hardwareProperties.deviceType == "iPhone"
      and .hardwareProperties.reality == "physical"
      and .connectionProperties.pairingState == "paired"
      and .connectionProperties.tunnelState != "unavailable"
    ))
  | sort_by(.deviceProperties.name)
  | .[]
  | [
      .identifier,
      .deviceProperties.name,
      .hardwareProperties.marketingName,
      .hardwareProperties.udid
    ]
  | @tsv
' "$devices_json" > "$available_devices"

[[ -s "$available_devices" ]] || {
  print -u2 "No available paired iPhone was found. Connect and unlock an iPhone with Developer Mode enabled."
  exit 1
}

typeset -a device_ids device_names device_models device_udids
while IFS=$'\t' read -r identifier name model udid; do
  device_ids+=("$identifier")
  device_names+=("$name")
  device_models+=("$model")
  device_udids+=("$udid")
done < "$available_devices"

selected_index=0
if [[ -n "$device_selector" ]]; then
  for index in {1..${#device_ids}}; do
    if [[ "$device_selector" == "${device_ids[$index]}" \
      || "$device_selector" == "${device_names[$index]}" \
      || "$device_selector" == "${device_udids[$index]}" ]]; then
      (( selected_index == 0 )) || {
        print -u2 "Device selector '$device_selector' is ambiguous. Use its identifier."
        exit 1
      }
      selected_index=$index
    fi
  done
  (( selected_index > 0 )) || {
    print -u2 "Device '$device_selector' is not an available paired iPhone."
    exit 1
  }
else
  print -u2 "Available iPhones:"
  for index in {1..${#device_ids}}; do
    print -u2 "  $index. ${device_names[$index]} (${device_models[$index]})"
  done
  print -n -u2 "Install to device [1]: "
  IFS= read -r selection
  selection="${selection:-1}"
  [[ "$selection" == <-> ]] || {
    print -u2 "Choose a device number."
    exit 1
  }
  (( selection >= 1 && selection <= ${#device_ids} )) || {
    print -u2 "Device selection is out of range."
    exit 1
  }
  selected_index=$selection
fi

if [[ -z "$config" ]]; then
  print -u2 "Build configuration:"
  print -u2 "  1. Development (Debug)"
  print -u2 "  2. Local QA (Release, Apple Development signed)"
  print -n -u2 "Choose configuration [1]: "
  IFS= read -r config_selection
  case "${config_selection:-1}" in
    1)
      config="development"
      ;;
    2)
      config="local_qa"
      ;;
    *)
      print -u2 "Choose configuration 1 or 2."
      exit 1
      ;;
  esac
fi

selected_device="${device_ids[$selected_index]}"
build_script="${HC_INSTALL_IOS_BUILD_SCRIPT:-$repo_root/scripts/build_ios_device.sh}"
[[ -x "$build_script" ]] || {
  print -u2 "iOS build script is not executable: $build_script"
  exit 1
}

print -u2 "Building $config for ${device_names[$selected_index]}..."
build_log="$temporary_root/build.log"
"$build_script" --config "$config" | tee "$build_log"
app_bundle="$(tail -n 1 "$build_log")"
[[ -d "$app_bundle" ]] || {
  print -u2 "The build did not produce an app bundle: $app_bundle"
  exit 1
}
bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$app_bundle/Info.plist")"

print -u2 "Installing on ${device_names[$selected_index]}..."
if ! install_output="$(xcrun devicectl device install app \
  --device "$selected_device" "$app_bundle" 2>&1)"; then
  print -u2 "$install_output"
  if [[ "${install_output:l}" == *"free developer profile"* \
    || "${install_output:l}" == *"free development profile"* \
    || "${install_output:l}" == *"maximum number of installed apps"* ]]; then
    print -u2 "The iPhone's free development profile app limit is full. Remove an unneeded development app manually, then retry; this script never removes apps."
  fi
  exit 1
fi
[[ -z "$install_output" ]] || print "$install_output"

print -u2 "Launching $bundle_identifier..."
xcrun devicectl device process launch --device "$selected_device" "$bundle_identifier"
print "Installed and launched Voice Input on ${device_names[$selected_index]}."
