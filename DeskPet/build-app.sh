#!/bin/bash
# 组装 DeskPet.app（SwiftPM 无 Xcode 方案）
# 用法：./build-app.sh
# 产物：DeskPet.app/（可 open DeskPet.app 运行；语音权限依赖 bundle Info.plist）
set -e
cd "$(dirname "$0")"

echo "== swift build =="
swift build -c release

APP="DeskPet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "== 组装 $APP =="
cp .build/release/DeskPet "$APP/Contents/MacOS/DeskPet"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Pets "$APP/Contents/Resources/Pets"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # App 图标（猫爪）
mkdir -p "$APP/Contents/Resources/config" "$APP/Contents/Resources/Scripts"
cp config/commands.json "$APP/Contents/Resources/config/"
cp config/voice-services.json "$APP/Contents/Resources/config/"   # 语音服务清单
cp config/SOUL.md "$APP/Contents/Resources/config/"   # v13 专属 SOUL 默认模板（首次 ensure 安装到 profile 根）
# 双保险（executor8）：打包前强制剥离敏感字段——分发 .app 永不携带 key。
# 源 config/deskpet-config.json 若被误填 key（运行时读的是 history/config/），打包产物必须为空。
# 显式清单：duoyunApiKey / asrApiKey / mimoApiKey（2026-08-16 MiMo 批次加入）；
# 模式兜底：字段名以 key/token/secret 结尾的字符串值置 ""（递归）。
# 剥离写入 bundle 临时文件（不污染源 config/）。
python3 - <<PYEOF
import json
SRC = "config/deskpet-config.json"
DST = "$APP/Contents/Resources/config/deskpet-config.json"
d = json.load(open(SRC, encoding="utf-8"))
SENSITIVE = {"duoyunApiKey", "asrApiKey", "mimoApiKey"}
def strip(o):
    if isinstance(o, dict):
        for k in list(o.keys()):
            if k in SENSITIVE or (k.lower().endswith(("key", "token", "secret")) and isinstance(o[k], str)):
                o[k] = ""
            elif isinstance(o[k], (dict, list)):
                strip(o[k])
    elif isinstance(o, list):
        for v in o:
            if isinstance(v, (dict, list)):
                strip(v)
strip(d)
json.dump(d, open(DST, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("敏感字段已剥离：" + ", ".join(sorted(SENSITIVE)))
PYEOF
cp config/personas.json "$APP/Contents/Resources/config/"   # ①③：首次运行复制到 AS
mkdir -p "$APP/Contents/Resources/config/prompts"
cp config/prompts/voice.json "$APP/Contents/Resources/config/prompts/"   # ①③
cp -R Scripts/. "$APP/Contents/Resources/Scripts/"
rm -rf "$APP/Contents/Resources/Scripts/__pycache__"

# 可写状态（会话索引 + 配置）放 Application Support（bundle 内只读——②修复：
# 配置写入固定 ~/Library/Application Support/DeskPet/config/，首次运行自动迁移）
mkdir -p "$HOME/Library/Application Support/DeskPet/config"
mkdir -p "$HOME/Library/Application Support/DeskPet/config/prompts"

# 固定代码签名（#22：TCC 权限稳定——ad-hoc 签名每次编译变化导致每次重启弹权限确认；
# 用自签名证书「DeskPet Dev」固定签名，授权一次永久有效）
if security find-identity -p codesigning -v 2>/dev/null | grep -q "DeskPet Dev"; then
    codesign --force --sign "DeskPet Dev" "$APP"
    echo "== 已签名：DeskPet Dev（固定证书——TCC 权限保持）"
else
    echo "== 警告：未找到「DeskPet Dev」证书——当前为 ad-hoc 签名，每次编译后权限会重新弹窗"
    echo "   运行 ./scripts/setup-codesign.sh 创建证书后重新打包"
fi
# 防 Gatekeeper 拦截（自签名未公证 app；如无隔离属性则无操作）
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "== 完成：open $APP =="
echo "   素材/指令表：bundle 内 Resources/（随 app 走）；会话索引：~/Library/Application Support/DeskPet/"
