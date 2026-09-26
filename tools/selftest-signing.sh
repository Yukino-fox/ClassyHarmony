#!/usr/bin/env bash
#
# 实验：hvigor 到底校不校验 p7b 的 CMS 签名？
#
# 动机：若 hvigor 只解析 p7b 取 bundleName / 开发证书而不验签，则可完全离线自签调试包，
#       不必依赖 AGC。已知 AGC 下发的 profile 签名链是
#       Huawei CBG Root CA G20 -> Huawei CBG Software Signing Service CA
#       -> HOS Profile Management Debug（叶子），自签不在链上。
#       本脚本造一份自签 p7b 接进工程，用真实构建结果回答这个问题。
#
# 用法：
#   ./tools/selftest-signing.sh gen     造自签材料
#   ./tools/selftest-signing.sh wire    接进 build-profile.json5
#   ./tools/selftest-signing.sh unwire  从 build-profile.json5 撤下
#
# 产物在 .certs/selftest/（.gitignore 已排除），不入库。
set -euo pipefail

DEVECO_HOME="${DEVECO_HOME:-/mnt/data/devecostudio-26.0.0.621}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="/tmp/opencode/signtest"
OUT="$ROOT/.certs/selftest"
DEV_ID="2850086000375336848"
# 真机 udid（与现有两套 p7b 一致，即当初签发时在用的那台设备）
UDID="110141E5A2094FA4195B16B074A0AB5F2CC37D75B7E5957578A73FEA6BF5E935"
PW="classyharmony"
CMD="${1:-gen}"

gen() {
  rm -rf "$WORK"
  mkdir -p "$WORK" "$OUT"

  # 证书链：hap-sign-tool 要求 cert.cer 必须是链（11013004 Profile cert must a cert chain）。
  # 原厂 .cer 的结构是 Root -> Intermediate -> 开发证书(叶子)，这里照抄这个拓扑。
  #   1) 根 CA（自签）
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$WORK/root.key" -out "$WORK/root.cer" -days 3650 \
    -subj "/C=CN/O=ClassyHarmony/OU=Debug PKI/CN=ClassyHarmony Debug Root CA G2" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"

  #   2) 中间 CA（由根签发）
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$WORK/int.key" -out "$WORK/int.csr" \
    -subj "/C=CN/O=ClassyHarmony/OU=Debug PKI/CN=ClassyHarmony Debug CA G2"
  openssl x509 -req -in "$WORK/int.csr" -CA "$WORK/root.cer" -CAkey "$WORK/root.key" \
    -CAcreateserial -out "$WORK/int.cer" -days 3650 -sha256 \
    -extfile <(printf "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n")

  #   3) 开发证书（叶子，由中间 CA 签发）
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$WORK/dev.key" -out "$WORK/dev.csr" \
    -subj "/C=CN/O=于家强/OU=$DEV_ID/CN=于家强($DEV_ID)\\,Development"
  openssl x509 -req -in "$WORK/dev.csr" -CA "$WORK/int.cer" -CAkey "$WORK/int.key" \
    -CAcreateserial -out "$WORK/dev.cer" -days 3650 -sha256

  # cert.cer = 根 + 中间 + 叶子，顺序与原厂一致
  cat "$WORK/root.cer" "$WORK/int.cer" "$WORK/dev.cer" > "$OUT/cert.cer"

  # p12 私钥库（对应 signingConfigs.storeFile），只含叶子密钥
  openssl pkcs12 -export -inkey "$WORK/dev.key" -in "$WORK/dev.cer" -certfile "$WORK/int.cer" \
    -out "$OUT/key.p12" -passout "pass:$PW" -name classyharmony

  # 4. profile 签名者（自签，冒充 HOS Profile Management Debug）
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$WORK/ps.key" -out "$WORK/ps.cer" -days 3650 \
    -subj "/CN=HOS Profile Management Debug/O=Huawei CBG Software Signing Service CA"

  # 5. profile JSON，字段名与 AGC 下发的逐字对齐
  #    development-certificate 只放叶子（与原厂 profile 一致，链在 cert.cer 里）
  node -e '
    const fs = require("fs");
    const [nb, na, devId, udid, cerFile, outFile] = process.argv.slice(1);
    const profile = {
      "version-name": "2.0.0",
      "version-code": 2,
      "uuid": "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
      "validity": { "not-before": Number(nb), "not-after": Number(na) },
      "type": "debug",
      "bundle-info": {
        "developer-id": devId,
        "development-certificate": fs.readFileSync(cerFile, "utf8"),
        "bundle-name": "com.yukinofox.classyharmony",
        "apl": "normal",
        "app-feature": "hos_normal_app",
        "app-identifier": "6918743238171177337"
      },
      "baseapp-info": {},
      "permissions": {},
      "debug-info": { "device-ids": [udid], "device-id-type": "udid" },
      "acls": {},
      "issuer": "app_gallery"
    };
    fs.writeFileSync(outFile, JSON.stringify(profile));
  ' "$(date +%s)" "$(( $(date +%s) + 31536000 ))" "$DEV_ID" "$UDID" \
    "$WORK/dev.cer" "$WORK/profile.json"

  # 6. CMS SignedData 封装为 p7b
  openssl cms -sign -in "$WORK/profile.json" -signer "$WORK/ps.cer" \
    -inkey "$WORK/ps.key" -outform DER -out "$OUT/profile.p7b" \
    -nodetach -binary -md sha256

  # decryptPwd 要读 storeFile 同级的 material/ 密钥目录
  ln -sfn "$HOME/.ohos/config/material" "$OUT/material"

  echo "自签材料已生成："
  ls -la "$OUT" | sed 's/^/  /'
  echo
  echo "cert.cer 链（$(grep -c 'BEGIN CERTIFICATE' "$OUT/cert.cer") 张）："
  for c in "$WORK/root.cer" "$WORK/int.cer" "$WORK/dev.cer"; do
    printf "  %-28s <- %s\n" \
      "$(openssl x509 -in "$c" -noout -subject | sed 's/subject=//;s/^ *//')" \
      "$(openssl x509 -in "$c" -noout -issuer | sed 's/issuer=//;s/^ *//')"
  done
  echo
  echo "profile 签名者（自签，不在华为链上）："
  openssl x509 -in "$WORK/ps.cer" -noout -subject | sed 's/^/  /'
}

wire() {
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const pw = process.argv[2];
    let t = fs.readFileSync(file, "utf8");
    if (t.charCodeAt(0) === 0xFEFF) t = t.slice(1);
    // cfg 首行不带前导缩进：正则从 "signingConfigs" 起匹配，原文缩进天然保留。
    // 若 cfg 自带缩进，会与原文叠加（4 -> 8），且 unwire 补不回来，往返有损。
    // 内层各行仍用绝对缩进，所以嵌套视觉上是对的。
    const cfg = `"signingConfigs": [
      {
        "name": "default",
        "type": "HarmonyOS",
        "material": {
          "certpath": "./.certs/selftest/cert.cer",
          "keyAlias": "classyharmony",
          "keyPassword": "${pw}",
          "profile": "./.certs/selftest/profile.p7b",
          "signAlg": "SHA256withECDSA",
          "storeFile": "./.certs/selftest/key.p12",
          "storePassword": "${pw}"
        }
      }
    ],`;
    // 两点要紧：
    // 1) 顺序：空数组必须先判。否则宽模式 \[...\] 会跨过 "[]" 去吃下一个
    //    "\n    ],"（products 的收尾），把 products 数组一起替换掉。
    // 2) cfg 结尾的逗号必须与正则的 ,? 配平：cfg 带逗号、正则吞掉原地逗号。
    //    只改一边会得到 ",,"（非法）或整个缺逗号。
    const reEmpty = /"signingConfigs"\s*:\s*\[\s*\],?/;
    const reFilled = /"signingConfigs"\s*:\s*\[[\s\S]*?\n    \],?/;
    if (reEmpty.test(t)) {
      fs.writeFileSync(file, t.replace(reEmpty, cfg));
    } else if (reFilled.test(t)) {
      fs.writeFileSync(file, t.replace(reFilled, cfg));
    } else {
      console.error("build-profile.json5 里找不到 signingConfigs"); process.exit(1);
    }
    console.log("  已接上 .certs/selftest");
  ' "$ROOT/build-profile.json5" "$PW"
}

unwire() {
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    let t = fs.readFileSync(file, "utf8");
    if (t.charCodeAt(0) === 0xFEFF) t = t.slice(1);
    // 顺序同上：空数组先判，否则宽模式会吃掉 products 的收尾。
    const reFilled = /"signingConfigs"\s*:\s*\[[\s\S]*?\n    \],?/;
    if (reFilled.test(t)) {
      // 替换串不带前导空白：正则从 "signingConfigs" 起匹配，它前面的缩进原样保留。
      // 之前硬写 4 个空格，把原有的 4 空格缩进写成了 12 空格。
      fs.writeFileSync(file, t.replace(reFilled, "\"signingConfigs\": [],"));
      console.log("  已撤下，signingConfigs 复位为空");
    } else {
      console.error("build-profile.json5 里找不到已写入的 signingConfigs"); process.exit(1);
    }
  ' "$ROOT/build-profile.json5"
}

case "$CMD" in
  gen) gen ;;
  wire) wire ;;
  unwire) unwire ;;
  *) echo "用法: $0 {gen|wire|unwire}" >&2; exit 2 ;;
esac
