#!/bin/zsh
set -euo pipefail
SOURCE_DIR="${0:A:h}"
OUTPUT_DIR="${1:-${SOURCE_DIR}/dist}"
OUTPUT_DIR="${OUTPUT_DIR:A}"
APP_DIR="$OUTPUT_DIR/网络修复.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$SOURCE_DIR/build/Icon.iconset" "$SOURCE_DIR/build/icons"
/usr/bin/xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -framework AppKit -framework SwiftUI -framework SystemConfiguration "$SOURCE_DIR/ResetCore.swift" "$SOURCE_DIR/NetworkDiagnostics.swift" "$SOURCE_DIR/main.swift" -o "$APP_DIR/Contents/MacOS/NetworkFirstAid"
/usr/bin/xcrun swift "$SOURCE_DIR/MakeIcon.swift" "$SOURCE_DIR/build/icons"
for pixels in 16 32 128 256 512; do
    /bin/cp "$SOURCE_DIR/build/icons/$pixels.png" "$SOURCE_DIR/build/Icon.iconset/icon_${pixels}x${pixels}.png"
    double=$((pixels * 2))
    /bin/cp "$SOURCE_DIR/build/icons/$double.png" "$SOURCE_DIR/build/Icon.iconset/icon_${pixels}x${pixels}@2x.png"
done
/usr/bin/iconutil -c icns "$SOURCE_DIR/build/Icon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
/bin/cat > "$APP_DIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string><string>en</string></array>
<key>CFBundleExecutable</key><string>NetworkFirstAid</string>
<key>CFBundleIdentifier</key><string>local.networkfirstaid.mac</string>
<key>CFBundleName</key><string>网络修复</string>
<key>CFBundleDisplayName</key><string>网络修复</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>© 2026 电动轮椅
抖音 / 小红书：@aigclunyi
X：AIGC电动轮椅 @cheese069696</string>
</dict></plist>
EOF
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
print -r -- "$APP_DIR"
