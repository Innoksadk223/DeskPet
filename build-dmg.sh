#!/bin/bash
# 打包 DeskPet.dmg（含最新构建 + Applications 快捷方式）
# 用法：./build-dmg.sh [版本号]   （默认 0.7.0）
# 产物：DeskPet-<版本>.dmg（项目根；不含任何 key——build-app.sh 强制剥离）
set -e
cd "$(dirname "$0")"

VERSION="${1:-0.7.0}"
DMG="DeskPet-${VERSION}.dmg"

echo "== 1/3 构建并组装 DeskPet.app =="
(cd DeskPet && ./build-app.sh)

echo "== 2/3 制作 DMG 镜像 =="
STAGE="$(mktemp -d /tmp/deskpet-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "DeskPet/DeskPet.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "DeskPet" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

echo "== 3/3 完成 =="
ls -lh "$DMG"
echo "安装：双击 dmg → 拖 DeskPet.app 到 Applications；若提示未验证，右键→打开"
