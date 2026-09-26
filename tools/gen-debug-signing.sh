#!/usr/bin/env bash
#
# 生成本地调试签名材料（HAR 打包强制要求签名配置，HAP 仅告警）。
#
# 产出：
#   signing/classyharmony-debug.p12   私钥库（不入库）
#   signing/classyharmony-debug.cer   公钥证书（不入库）
#
# 说明：这是自签调试证书，只能用于本地构建与真机调试安装，
# 不具备应用市场发布所需的华为侧身份。正式发布签名由 AGC 托管，
# 不在本仓库存放。
#
# 幂等：已存在则直接退出，避免覆盖正在使用的密钥。
set -euo pipefail

DEVECO_HOME="${DEVECO_HOME:-/mnt/data/devecostudio-26.0.0.621}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYSTORE="$ROOT/signing/classyharmony-debug.p12"
CER="$ROOT/signing/classyharmony-debug.cer"
ALIAS="classyharmony"
PASSWORD="classyharmony"

KEYTOOL="$DEVECO_HOME/jbr/bin/keytool"
if [ ! -x "$KEYTOOL" ]; then
  echo "找不到 keytool：$KEYTOOL" >&2
  echo "请设置 DEVECO_HOME 后重试。" >&2
  exit 1
fi

if [ -f "$KEYSTORE" ]; then
  echo "已存在 $KEYSTORE，跳过生成。"
  exit 0
fi

mkdir -p "$ROOT/signing"

"$KEYTOOL" -genkeypair \
  -alias "$ALIAS" \
  -keyalg EC -groupname secp256r1 \
  -sigalg SHA256withECDSA \
  -dname "CN=ClassyHarmony Debug, OU=Engineering, O=ClassyHarmony, L=NA, ST=NA, C=CN" \
  -validity 3650 \
  -keystore "$KEYSTORE" \
  -storetype PKCS12 \
  -storepass "$PASSWORD" \
  -keypass "$PASSWORD"

"$KEYTOOL" -exportcert \
  -alias "$ALIAS" \
  -keystore "$KEYSTORE" \
  -storepass "$PASSWORD" \
  -file "$CER" \
  -rfc

echo "已生成："
echo "  $KEYSTORE"
echo "  $CER"
