#!/bin/bash
# build.sh — 编译 Plugiator ASX 控制台（菜单/窗口小工具）
# 产物：build/Plugiator ASX Console.app（universal2: x86_64 + arm64）
# 用法：bash build.sh

set -e
cd "$(dirname "$0")"

APP="build/Plugiator ASX Console.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

echo "==> 清理"
rm -rf build/ && mkdir -p build/clang-module-cache "$MACOS"

echo "==> 编译（x86_64 + arm64）"
clang -fobjc-arc -fmodules \
  -fmodules-cache-path="build/clang-module-cache" \
  -arch x86_64 -arch arm64 \
  -O2 \
  -Wno-poison-system-directories \
  -Wno-direct-ivar-access \
  -Wno-objc-missing-super-calls \
  -Wno-declaration-after-statement \
  src/main.m src/KnobView.m \
  -framework Cocoa -framework CoreMIDI -framework Foundation \
  -o "$MACOS/Plugiator ASX Console"

echo "==> 拷贝 CC 参数表"
mkdir -p "$CONTENTS/Resources/data"
for f in data/*.json; do
    [ -e "$f" ] || continue
    cp "$f" "$CONTENTS/Resources/data/"
done

echo "==> 生成图标"
mkdir -p build/clang-module-cache
clang -fobjc-arc -fmodules -fmodules-cache-path="build/clang-module-cache" \
  -framework Cocoa -o build/makeicon tools/makeicon.m
# iconutil 不能直接写外接盘，先在 /tmp 生成再拷回来
rm -rf /tmp/asx-icon-work && mkdir -p /tmp/asx-icon-work
build/makeicon /tmp/asx-icon-work/AppIcon.iconset
iconutil -c icns /tmp/asx-icon-work/AppIcon.iconset -o /tmp/asx-icon-work/AppIcon.icns
mkdir -p "$CONTENTS/Resources"
cp /tmp/asx-icon-work/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

echo "==> 写 Info.plist"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                  <string>Plugiator ASX Console</string>
  <key>CFBundleDisplayName</key>           <string>Plugiator ASX 控制台</string>
  <key>CFBundleIdentifier</key>            <string>local.cme.plugiator.console</string>
  <key>CFBundleExecutable</key>            <string>Plugiator ASX Console</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleShortVersionString</key>    <string>0.1.1</string>
  <key>CFBundleVersion</key>               <string>0.1.1</string>
  <key>LSMinimumSystemVersion</key>        <string>11.0</string>
  <key>NSHighResolutionCapable</key>       <true/>
  <key>NSPrincipalClass</key>              <string>NSApplication</string>
  <key>CFBundleIconFile</key>              <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "==> 架构检查"
lipo -archs "$MACOS/Plugiator ASX Console"

echo "==> 完成：$APP"
