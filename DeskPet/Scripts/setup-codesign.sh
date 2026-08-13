#!/bin/bash
# 固定代码签名证书（一次性设置）——解决「每次重启弹权限确认」。
#
# 背景：DeskPet.app 原为 ad-hoc 签名（codesign -dv → Signature=adhoc）。
# 每次 swift build 重新编译后二进制哈希变化 → ad-hoc 签名变化 → macOS TCC
# （麦克风/语音识别权限）按签名匹配授权记录 → 每次重建/重启弹权限确认。
# 用固定自签名证书「DeskPet Dev」签名 → 签名稳定 → 授权一次永久有效。
#
# 用法：./scripts/setup-codesign.sh（幂等：证书已存在则跳过）
# 证书有效期 10 年；已实测 macOS 26 可用（openssl 生成 + security import 到 login keychain）。
set -e
cd "$(dirname "$0")/.."

CERT_NAME="DeskPet Dev"

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "== 证书已存在：$CERT_NAME（跳过创建）"
    security find-identity -p codesigning -v | grep "$CERT_NAME"
    exit 0
fi

echo "== 创建自签名代码签名证书：$CERT_NAME（有效期 3650 天）"
TMP=$(mktemp -d /tmp/deskpet-codesign.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# 1. 密钥 + 自签名证书（必须带 codeSigning EKU + digitalSignature keyUsage，
#    否则 codesign 策略判定 Invalid Key Usage——已实测）
openssl genrsa -out "$TMP/deskpet.key" 2048 2>/dev/null
openssl req -new -x509 -key "$TMP/deskpet.key" -out "$TMP/deskpet.crt" -days 3650 \
  -subj "/CN=$CERT_NAME" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null

# 2. 打包 p12（用 3DES/SHA1 老算法——security 对 openssl 默认 AES p12 兼容失败，已实测）
openssl pkcs12 -export -inkey "$TMP/deskpet.key" -in "$TMP/deskpet.crt" -out "$TMP/deskpet.p12" \
  -passout pass:deskpet -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

# 3. 导入 login keychain（-A 允许所有应用访问；-T codesign 信任签名工具）
security import "$TMP/deskpet.p12" -k ~/Library/Keychains/login.keychain-db -P deskpet -A -T /usr/bin/codesign
# 4. 设信任（root 信任域，find-identity 才能判 valid）
security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db "$TMP/deskpet.crt"

echo "== 完成："
security find-identity -p codesigning -v | grep "$CERT_NAME"
