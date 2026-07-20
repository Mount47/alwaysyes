#!/bin/bash
# 编译 ClaudePet 为 macOS .app bundle (菜单栏程序)
set -e
cd "$(dirname "$0")"

APP="ClaudePet.app"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "==> 清理旧构建"
rm -rf "$APP"
mkdir -p "$BIN_DIR" "$RES_DIR"

echo "==> 编译 Swift 源码"
swiftc -O \
  ClaudePet/main.swift \
  ClaudePet/AppDelegate.swift \
  ClaudePet/PetController.swift \
  ClaudePet/SpriteSheet.swift \
  -o "$BIN_DIR/ClaudePet"

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudePet</string>
  <key>CFBundleDisplayName</key><string>ClaudePet</string>
  <key>CFBundleIdentifier</key><string>com.local.claudepet</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>ClaudePet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "==> 完成: $(pwd)/$APP"
echo "    启动: open $APP   或   $BIN_DIR/ClaudePet"
