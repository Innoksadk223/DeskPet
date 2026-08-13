#!/bin/bash
# 启动桌宠（双击入口，类似 Windows exe）
# 作用：增量构建（有改动才重编译）→ 组装 DeskPet.app → 启动
# 依赖：Xcode 命令行工具（swift build）；首次打包可能需要创建代码签名证书（见 build-app.sh）
# 说明：若桌宠已在运行，新实例会被单实例锁拒绝（属正常，不会开双份）

# 切换到脚本所在目录（兼容路径含空格/中文）
cd "$(dirname "$0")" || {
    echo "❌ 无法进入脚本目录"
    read -p "按回车关闭窗口…" _
    exit 1
}

echo "=============================================="
echo "  桌宠启动器（构建 + 启动）"
echo "=============================================="
echo "· 首次启动若提示「麦克风权限」，请到"
echo "  系统设置 → 隐私与安全性 → 麦克风/语音识别 中允许桌宠"
echo ""

# 构建 + 组装 .app（幂等：无改动时增量秒过）
echo "== 构建并组装 DeskPet.app =="
if ! ./build-app.sh; then
    echo ""
    echo "❌ 构建失败（详见上方输出）"
    echo "  常见原因：未安装 Xcode 命令行工具（运行：xcode-select --install）"
    read -p "按回车关闭窗口…" _
    exit 1
fi

echo ""
echo "== 启动 DeskPet.app =="
open DeskPet.app

echo ""
echo "✅ 桌宠已启动（若未见桌宠，请检查右上角菜单栏图标；已在运行则本次启动被忽略）"
sleep 3
# 双击场景自动关闭终端窗口（仅匹配本脚本标题的窗口——手动在终端里运行不受影响）
osascript -e 'tell application "Terminal" to close (every window whose name contains "启动桌宠")' 2>/dev/null || true
