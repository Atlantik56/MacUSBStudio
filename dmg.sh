#!/bin/bash
# Local preview packaging. Signing and notarization are required before distribution.
set -euo pipefail
export LC_ALL=C
task_root=$(cd "$(dirname "$0")" && pwd)
if [[ "${1:-}" == '--help' ]]; then
  printf 'Usage: bash dmg.sh [path/to/Mac USB Studio.app]\nCreates a local unsigned DMG preview; does not publish or remove quarantine.\n'
  exit 0
fi
[[ $# -le 1 ]] || { printf 'Expected at most one application path.\n' >&2; exit 2; }
task_app=${1:-"$task_root/build/Mac USB Studio.app"}
[[ -d "$task_app" && ! -L "$task_app" ]] || { printf 'Application not found.\n' >&2; exit 1; }
task_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_app/Contents/Info.plist")
[[ "$task_identifier" == 'local.mac-usb-studio' ]] || { printf 'Unexpected application identity.\n' >&2; exit 1; }
task_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_app/Contents/Info.plist")
[[ "$task_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { printf 'Unexpected application version.\n' >&2; exit 1; }
/usr/bin/codesign --verify --strict --all-architectures "$task_app"
/usr/bin/codesign --verify --strict --all-architectures "$task_app/Contents/Helpers/MacUSBRecorder"
task_tmp=$(/usr/bin/mktemp -d /private/tmp/mac-usb-studio-dmg.XXXXXX)
trap '/bin/rm -rf "$task_tmp"' EXIT
/bin/mkdir "$task_tmp/payload"
/usr/bin/ditto "$task_app" "$task_tmp/payload/Mac USB Studio.app"
/bin/ln -s /Applications "$task_tmp/payload/Applications"
/usr/bin/hdiutil create -volname 'Mac USB Studio' -format UDZO -srcfolder "$task_tmp/payload" "$task_tmp/preview.dmg"
/usr/bin/hdiutil verify "$task_tmp/preview.dmg"
/bin/mkdir -p "$task_root/dist"
task_output="$task_root/dist/Mac.USB.Studio-$task_version-unsigned.dmg"
[[ ! -e "$task_output" && ! -L "$task_output" ]] || { printf 'Preview already exists; no file replaced.\n' >&2; exit 1; }
/bin/mv "$task_tmp/preview.dmg" "$task_output"
printf 'Local preview: %s\nDeveloper ID signing and Apple notarization are pending.\n' "$task_output"
