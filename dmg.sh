#!/bin/bash
# Package the verified app for Finder installation, without Developer ID or notarization.
set -euo pipefail
export LC_ALL=C
task_root=$(cd "$(dirname "$0")" && pwd -P)
if [[ "${1:-}" == '--help' ]]; then
  printf 'Usage: bash dmg.sh [path/to/Mac USB Studio.app]\nCreates a DMG with the app and an Applications shortcut. Gatekeeper approval may be required.\n'
  exit 0
fi
[[ $# -le 1 ]] || { printf 'Expected at most one application path.\n' >&2; exit 2; }
task_app=${1:-"$task_root/build/Mac USB Studio.app"}
[[ -d "$task_app" && ! -L "$task_app" ]] || { printf 'Build the application with build.sh first.\n' >&2; exit 1; }
for task_key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$task_key" "$task_app/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c "Print :$task_key" "$task_root/Info.plist")" ]] || { printf 'Application metadata differs: %s\n' "$task_key" >&2; exit 1; }
done
task_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_app/Contents/Info.plist")
[[ "$task_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { printf 'Unexpected application version.\n' >&2; exit 1; }
/usr/bin/codesign --verify --strict --all-architectures "$task_app"
/usr/bin/codesign --verify --strict --all-architectures "$task_app/Contents/Helpers/MacUSBRecorder"
task_output="$task_root/dist/Mac.USB.Studio-$task_version.dmg"
[[ ! -e "$task_output" && ! -L "$task_output" ]] || { printf 'DMG already exists; no file replaced.\n' >&2; exit 1; }
task_tmp=$(/usr/bin/mktemp -d /private/tmp/mac-usb-studio-dmg.XXXXXX)
trap '/bin/rm -rf "$task_tmp"' EXIT
/bin/mkdir "$task_tmp/payload"
/usr/bin/ditto "$task_app" "$task_tmp/payload/Mac USB Studio.app"
/bin/ln -s /Applications "$task_tmp/payload/Applications"
/usr/bin/hdiutil create -volname 'Mac USB Studio' -fs HFS+ -format UDZO -srcfolder "$task_tmp/payload" "$task_tmp/release.dmg"
/usr/bin/hdiutil verify "$task_tmp/release.dmg"
/bin/mkdir -p "$task_root/dist"
/bin/mv "$task_tmp/release.dmg" "$task_output"
/usr/bin/shasum -a 256 "$task_output"
printf 'DMG: %s\nNo Developer ID or Apple notarization; first launch may need approval in Privacy & Security.\n' "$task_output"
