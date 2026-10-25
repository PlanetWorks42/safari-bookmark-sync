#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p dist/ModuleCache
APP="dist/Safari 收藏夹同步.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 -module-cache-path dist/ModuleCache Sources/Localization.swift Sources/Core.swift Sources/Bookmarks.swift Sources/Bidirectional.swift Sources/MenuBarSupport.swift Sources/main.swift -framework AppKit -framework ServiceManagement -o "$APP/Contents/MacOS/SafariTabSync"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon-v3.icns "$APP/Contents/Resources/AppIcon-v3.icns"
ditto Resources "$APP/Contents/Resources"
codesign --force --sign - --options runtime --entitlements entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
echo "已生成：$PWD/$APP"
