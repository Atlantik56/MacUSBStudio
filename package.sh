#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

task_app="${1:-build/Mac USB Studio.app}"
if [[ ! -d "$task_app" ]]; then
  if [[ $# -gt 0 ]]; then
    echo "Application not found: $task_app" >&2
    exit 1
  fi
  bash build.sh
fi
task_app="$(cd "$task_app" && pwd)"
task_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
task_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)
task_min_os=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
task_identifier='local.mac-usb-studio.installer'
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_app/Contents/Info.plist")" != 'local.mac-usb-studio' ||
      "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_app/Contents/Info.plist")" != "$task_version" ||
      "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$task_app/Contents/Info.plist")" != "$task_build" ]]; then
  echo 'The application identity/version does not match Info.plist. Rebuild it first.' >&2
  exit 1
fi
/usr/bin/codesign --verify --strict "$task_app"
/usr/bin/codesign --verify --strict "$task_app/Contents/Helpers/MacUSBRecorder"
task_temp=$(/usr/bin/mktemp -d /private/tmp/mac-usb-studio-package.XXXXXX)
trap 'rm -rf "$task_temp"' EXIT
mkdir -p "$task_temp/root/Applications" "$task_temp/scripts" dist
/usr/bin/ditto "$task_app" "$task_temp/root/Applications/Mac USB Studio.app"
cp Packaging/postinstall "$task_temp/scripts/postinstall"
chmod 755 "$task_temp/scripts/postinstall"
/bin/bash -n "$task_temp/scripts/postinstall"
/usr/bin/pkgbuild --analyze --root "$task_temp/root" "$task_temp/components.plist"
python3 - "$task_temp" "$task_min_os" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
components_path = root / 'components.plist'
components = plistlib.loads(components_path.read_bytes())
if len(components) != 1 or components[0]['RootRelativeBundlePath'] != 'Applications/Mac USB Studio.app':
    raise SystemExit('Unexpected application payload')
components[0].update(BundleIsRelocatable=False, BundleIsVersionChecked=True,
                     BundleHasStrictIdentifier=True, BundleOverwriteAction='upgrade')
components_path.write_bytes(plistlib.dumps(components))
(root / 'requirements.plist').write_bytes(plistlib.dumps({
    'os': [sys.argv[2]], 'arch': ['arm64', 'x86_64'], 'home': False,
}))
PY
/usr/bin/pkgbuild --root "$task_temp/root" --component-plist "$task_temp/components.plist" \
  --scripts "$task_temp/scripts" --identifier "$task_identifier" --version "$task_version" \
  --install-location / --ownership recommended "$task_temp/MacUSBStudio-component.pkg"
/usr/bin/productbuild --synthesize --product "$task_temp/requirements.plist" \
  --package "$task_temp/MacUSBStudio-component.pkg" "$task_temp/Distribution.xml"
python3 - "$task_temp/Distribution.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
ET.SubElement(root, 'title').text = 'Mac USB Studio'
ET.SubElement(root, 'domains', enable_anywhere='false', enable_currentUserHome='false', enable_localSystem='true')
ET.SubElement(root, 'welcome', file='welcome.html', **{'mime-type': 'text/html'})
ET.SubElement(root, 'conclusion', file='conclusion.html', **{'mime-type': 'text/html'})
options = root.find('options')
if options is None:
    raise SystemExit('Missing productbuild options')
options.set('customize', 'never')
ET.indent(tree)
tree.write(path, encoding='utf-8', xml_declaration=True)
PY
task_output="dist/Mac.USB.Studio-$task_version.pkg"
/usr/bin/productbuild --distribution "$task_temp/Distribution.xml" --package-path "$task_temp" \
  --resources Packaging/Resources --identifier "$task_identifier" --version "$task_version" \
  "$task_temp/MacUSBStudio.pkg"
/usr/sbin/installer -pkginfo -pkg "$task_temp/MacUSBStudio.pkg"
mv -f "$task_temp/MacUSBStudio.pkg" "$task_output"
/usr/bin/shasum -a 256 "$task_output"
echo "Built installer: $task_output (application $task_version, build $task_build)"
