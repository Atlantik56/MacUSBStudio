#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
task_app='build/Mac USB Studio.app'
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Helpers" "$task_app/Contents/Resources" build
for task_arch in arm64 x86_64; do
  /usr/bin/xcrun swiftc -swift-version 5 -O -target "$task_arch-apple-macos13.0" -module-cache-path build/module-cache Sources/System.swift Sources/Domain.swift Sources/Catalog.swift Sources/Recorder.swift -o "build/MacUSBRecorder-$task_arch"
  /usr/bin/xcrun swiftc -swift-version 5 -O -target "$task_arch-apple-macos13.0" -module-cache-path build/module-cache -framework AppKit Sources/System.swift Sources/Domain.swift Sources/Catalog.swift Sources/Console.swift Sources/Monitoring.swift Sources/Ejection.swift Sources/App.swift -o "build/MacUSBStudio-$task_arch"
done
/usr/bin/lipo -create build/MacUSBRecorder-arm64 build/MacUSBRecorder-x86_64 -output "$task_app/Contents/Helpers/MacUSBRecorder"
/usr/bin/lipo -create build/MacUSBStudio-arm64 build/MacUSBStudio-x86_64 -output "$task_app/Contents/MacOS/MacUSBStudio"
cp Info.plist "$task_app/Contents/Info.plist"
cp releases.json AppIcon.icns "$task_app/Contents/Resources/"
/usr/bin/codesign --force --sign - --identifier local.mac-usb-studio.recorder "$task_app/Contents/Helpers/MacUSBRecorder"
/usr/bin/codesign --force --sign - "$task_app"
/usr/bin/codesign --verify --strict "$task_app"
/usr/bin/codesign --verify --strict "$task_app/Contents/Helpers/MacUSBRecorder"
"$task_app/Contents/Helpers/MacUSBRecorder" --self-check
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path build/module-cache Sources/System.swift Sources/Domain.swift Sources/Catalog.swift Sources/Console.swift Sources/Monitoring.swift Sources/Ejection.swift Tests/Checks.swift -o build/checks
build/checks
echo "Built Mac USB Studio: $task_app"
