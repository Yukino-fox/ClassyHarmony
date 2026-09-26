#!/usr/bin/env bash
#
# 把 DevEco 自动签名生成的 AGC 调试签名材料接进本工程。
#
# 为什么不能自己签：
#   hvigor 读 p7b 时会调 sdk 的 hap-sign-tool.jar verify-profile 做 CMS 密码学校验，
#   签发者不是华为 CA 就直接拒。自签 p7b 必定失败（这条路已实测走不通）。
#   而 p7b 内嵌了配套的 development-certificate，.p12/.cer/.p7b 三件套必须同源，
#   所以也不能「自签 cer + 借用别人的 p7b」拼凑。
#   结论：整套材料只能从 AGC 一次自动签名里拿。
#
# 前置：在 DevEco IDE 里执行过
#   File → Project Structure → Signing Configs → 勾自动签名 → 登录 AGC → Apply
# 材料会落在 ~/.ohos/config/。
#
# 产出（均不入库，见 .gitignore）：
#   .certs/classyharmony-debug/{key,cert,profile}.*   签名三件套
#   build-profile.json5 的 signingConfigs             就地改写为指向该目录
#
# 幂等：重复执行会重新从 ~/.ohos/config 同步，build-profile.json5 幂等重写。
set -euo pipefail

DEVECO_HOME="${DEVECO_HOME:-/mnt/data/devecostudio-26.0.0.621}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CONFIG="$HOME/.ohos/config"
CERT_DIR="$ROOT/.certs/classyharmony-debug"
BUNDLE_NAME="$(node -e '
  // build-profile 是 json5，这里只取一个字符串字面量，正则足够且不引额外依赖
  const t = require("fs").readFileSync(process.argv[1] + "/AppScope/app.json5", "utf8");
  const m = t.match(/"bundleName"\s*:\s*"([^"]+)"/);
  if (!m) { console.error("AppScope/app.json5 里读不到 bundleName"); process.exit(1); }
  process.stdout.write(m[1]);
' "$ROOT")"
KEYTOOL="$DEVECO_HOME/jbr/bin/keytool"
ENC_PWD_CLI=(node "$HOME/.config/opencode/skills/hmos-connect-api-cli-skill/scripts/connect-api-cli.js"
             provision encrypt-pwd --config-dir "$AGENT_CONFIG")

say() { printf '\033[1;36m%s\033[0m\n' "$*"; }
die() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 前置检查
[ -d "$AGENT_CONFIG" ] || die "找不到 $AGENT_CONFIG —— 先在 IDE 里跑一次自动签名。"
[ -x "$KEYTOOL" ] || die "找不到 keytool：$KEYTOOL（检查 DEVECO_HOME）"
for f in tools/hvigor/bin/hvigorw tools/ohpm/bin/ohpm \
         sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar \
         sdk/default/openharmony/toolchains/hdc; do
  [ -e "$DEVECO_HOME/$f" ] || die "DEVECO_HOME 不完整，缺 $f"
done
say "目标包名：$BUNDLE_NAME"

# ------------------------------------------------- 1. 按 p7b 内的 bundle-name 定位
# 不能靠文件名猜：DevEco 的文件名里是工程名/应用名（见过 Solliana、sollin-harmony），
# 与 bundleName 无关（那两个实际绑的是 com.yukinofox.solliana / .sollinplayer）。
P7B=""
for f in "$AGENT_CONFIG"/*.p7b; do
  [ -e "$f" ] || continue
  bn="$(strings -n 8 "$f" | grep -o '"bundle-name":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
  [ -n "$bn" ] || continue
  printf '  候选 %-52s -> %s\n' "$(basename "$f")" "$bn"
  if [ "$bn" = "$BUNDLE_NAME" ]; then P7B="$f"; fi
done
[ -n "$P7B" ] || die "$AGENT_CONFIG 下没有 bundleName 为 $BUNDLE_NAME 的 p7b。
   请在 IDE 里确认 Signing Configs 的包名是 $BUNDLE_NAME 后重新 Apply。"

PREFIX="${P7B%.p7b}"
P12="$PREFIX.p12"
CER="$PREFIX.cer"
[ -f "$P12" ] || die "找到 p7b 但同名前缀的 p12 不存在：$P12"
[ -f "$CER" ] || die "找到 p7b 但同名前缀的 cer 不存在：$CER"
say "已定位：$(basename "$PREFIX").{p12,cer,p7b}"

# ------------------------------------------------------- 2. 校验 p7b 自身三要素
# type 必须是 debug（release Profile 无 device 绑定，装真机报 not trusted app source）
# validity 与 device-ids 要如实报给用户，不做静默兜底
TYPE="$(strings -n 8 "$P7B" | grep -o '"type":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
NOT_AFTER="$(strings -n 8 "$P7B" | grep -o '"not-after":[0-9]*' | head -1 | cut -d: -f2 || true)"
UDIDS="$(strings -n 8 "$P7B" | grep -o '"device-ids":\[[^]]*\]' | head -1 || true)"
say "  type=$TYPE  有效期至 $(node -e 'process.stdout.write(new Date(Number(process.argv[1])*1000).toLocaleDateString("en-CA",{timeZone:"Asia/Shanghai"}))' "${NOT_AFTER:-0}")"
[ "$TYPE" = "debug" ] || die "p7b 的 type 是 '$TYPE'，不是 debug。发布 Profile 没有设备绑定，装不上真机。"

# 目标设备 udid（可选）：给了就校验是否在授权列表里
if [ -n "${DEVICE_UDID:-}" ]; then
  case "$UDIDS" in
    *"$DEVICE_UDID"*) say "  目标设备已在 p7b 授权列表内 ✓" ;;
    *) die "目标设备 $DEVICE_UDID 不在 p7b 的 device-ids 里。
   授权列表：$UDIDS
   回到 IDE Signing Configs 勾选该设备后重新 Apply。" ;;
  esac
fi

# ------------------------------------------------------------ 3. 试出 p12 密码
# DevEco 自动签名固定用 123456；仍留几个候选以便自定义
ALIAS=""
PWD_USED=""
for pw in "${P12_PASSWORD:-}" 123456 000000; do
  [ -n "$pw" ] || continue
  if out="$("$KEYTOOL" -list -keystore "$P12" -storetype PKCS12 -storepass "$pw" 2>&1)"; then
    PWD_USED="$pw"
    ALIAS="$(printf '%s' "$out" | grep -oE 'classyharmony[^,]*|your_alias[^,]*|^[[:space:]]*[a-zA-Z0-9_-]+,' | head -1 | tr -d ' ,' || true)"
    # 兜底：取别名列表第一项
    if [ -z "$ALIAS" ]; then
      ALIAS="$(printf '%s' "$out" | sed -n 's/^[[:space:]]*\([A-Za-z0-9_.-]\+\),\{0,1\}[[:space:]]*\(PrivateKeyEntry\|trustedCertEntry\).*/\1/p' | head -1)"
    fi
    break
  fi
done
[ -n "$PWD_USED" ] || die "试不出 p12 密码。用 P12_PASSWORD=<密码> 显式指定。"
say "  p12 密码已确认，keyAlias=$ALIAS"

# ------------------------------------------------------------ 4. 复制进工程
mkdir -p "$CERT_DIR"
cp "$P12" "$CERT_DIR/key.p12"
cp "$CER" "$CERT_DIR/cert.cer"
cp "$P7B" "$CERT_DIR/profile.p7b"
chmod 600 "$CERT_DIR/key.p12"
# encrypt-pwd 依赖 p12 同级（或 STORE 旁）的 material/ 加密密钥目录
if [ ! -e "$CERT_DIR/material" ]; then
  [ -d "$AGENT_CONFIG/material" ] && ln -s "$AGENT_CONFIG/material" "$CERT_DIR/material"
fi
say "已同步到 $CERT_DIR"

# ------------------------------------------------------------ 5. 加密密码
say "加密签名密码（需 material/ 密钥目录）…"
ENC_JSON="$("${ENC_PWD_CLI[@]}" --pwd "$PWD_USED" 2>/dev/null)" || die "encrypt-pwd 失败，检查 $AGENT_CONFIG/material"
ENC="$(printf '%s' "$ENC_JSON" | node -e '
let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s);
  if(!j.keyPassword){console.error("encrypt-pwd 未返回 keyPassword");process.exit(1);}
  process.stdout.write(j.keyPassword);
});')"
say "  已加密（不显示明文）"

# ------------------------------------------------------------ 6. 改写 build-profile
node -e '
const fs = require("fs");
const [file, dir, alias, enc] = process.argv.slice(1);
let t = fs.readFileSync(file, "utf8");
if (t.charCodeAt(0) === 0xFEFF) t = t.slice(1);
// cfg 首行不带前导缩进：正则从 "signingConfigs" 起匹配，原文缩进天然保留，
// 否则会与原文叠加。内层各行仍用绝对缩进。
const cfg = `"signingConfigs": [
      {
        "name": "default",
        "type": "HarmonyOS",
        "material": {
          "certpath": "./.certs/classyharmony-debug/cert.cer",
          "keyAlias": "${alias}",
          "keyPassword": "${enc}",
          "profile": "./.certs/classyharmony-debug/profile.p7b",
          "signAlg": "SHA256withECDSA",
          "storeFile": "./.certs/classyharmony-debug/key.p12",
          "storePassword": "${enc}"
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
  console.error("build-profile.json5 里找不到 signingConfigs，请人工检查");
  process.exit(1);
}
console.log("  build-profile.json5 已指向 .certs/classyharmony-debug");
' "$ROOT/build-profile.json5" "$CERT_DIR" "$ALIAS" "$ENC"

say "完成。下一步：$DEVECO_HOME/tools/hvigor/bin/hvigorw --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap"
