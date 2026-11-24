#!/bin/bash
# make-dmg.sh — 打 DMG 安装包（需要 hdiutil，沙箱里跑不了，必须在你自己终端里跑）
# 用法：bash make-dmg.sh
# 产物：release/Plugiator ASX Console-0.1.1.dmg

set -e
cd "$(dirname "$0")"

NAME="Plugiator ASX Console"
VERSION="0.1.1"
BUILD="build/$NAME.app"
STAGE="/tmp/asx-dmg-stage"
DMG="release/$NAME-$VERSION.dmg"

if [ ! -d "$BUILD" ]; then
  echo "✗ 没有 $BUILD，先跑：bash build.sh"
  exit 1
fi

echo "==> 编译检查"
bash build.sh >/dev/null

echo "==> 组装临时卷"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$BUILD" "$STAGE/"
cp README.md "$STAGE/使用说明.md"
# macOS 会给外来卷里的文件加 ._* 残渣，去掉
find "$STAGE" -name "._*" -delete

# 软链接到 Applications，方便拖装
ln -s /Applications "$STAGE/Applications"

echo "==> 生成 DMG"
rm -f "$DMG"
mkdir -p release
hdiutil create \
  -volname "$NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG"

# 加个背景图和窗口位置，纯粹好看一点
# （不影响功能，失败也不影响 DMG 本身）
echo "==> 校验"
hdiutil verify "$DMG"

rm -rf "$STAGE"

echo
echo "✅ 完成：$DMG"
ls -la "$DMG"
echo
echo "装法：双击 DMG → 把 App 拖到左边 Applications → 右键打开（首次要这样，Gatekeeper）"
