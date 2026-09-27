#!/usr/bin/env bash
#
# 把当前 HAP 装到模拟器上跑起来（用于图标/UI 的人工与自动核对）。
#
# 为什么需要这个脚本，而不是直接 assembleHap：
#   DevEco 26 的**模拟器镜像最高只到 HarmonyOS 6.1.1(API 24)**
#   （`devecocli emulator image list --all` 实测，OS 版本集合上限就是 24），
#   而工程 targetSdkVersion / compatibleSdkVersion 都是 26 —— 装不上。
#   所以临时把 compatibleSdkVersion 降到 24 编一版，装完再改回去。
#   targetSdkVersion 保持 26 不动：那只是「你按最高 API 编译」，与能否装机无关。
#
# 会不会触发 API 级别检查报错：
#   不会阻断。hvigor 对「用了高于 compatibleSdkVersion 的 API」只报 warn
#   （arkts/api-level check），不 fail。真正会崩的是运行期调到缺失的 API，
#   本工程在 API 24 上跑不满功能（提醒用 @since 12、日期选择器 @since 10，都在 24 内，
#   实际能跑通），所以拿它做 UI 核对够用。
#
# 幂等/安全：build-profile.json5 改前先备份，任何一步失败都用 trap 还原，
# 不会把工程留在 compatibleSdkVersion=24 的状态。
#
# 用法：
#   tools/run-on-emulator.sh                 # 默认连 127.0.0.1:5557（classy24 实例）
#   EMU_SERIAL=127.0.0.1:5555 tools/run-on-emulator.sh
#   SKIP_BUILD=1 tools/run-on-emulator.sh    # 只装不编
#   KEEP_SDK=24 tools/run-on-emulator.sh     # 编完不还原（需要反复调试时）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVECO_HOME="${DEVECO_HOME:-/mnt/data/devecostudio-26.0.0.621}"
PROFILE="$ROOT/build-profile.json5"
EMU_SERIAL="${EMU_SERIAL:-127.0.0.1:5557}"
EMU_SDK="${EMU_SDK:-24}"
HAP="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"

say()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

command -v node >/dev/null || die "缺 node"
[ -f "$PROFILE" ] || die "找不到 $PROFILE"
[ -d "$DEVECO_HOME" ] || die "找不到 DEVECO_HOME=$DEVECO_HOME"

# hdc 要能在 targets 里看到这台设备；模拟器是自动分配端口的（classy24 拿到 5557，
# Pura90Pro 占着 5555），所以先探一次，不在就 tconn。
if ! hdc list targets | grep -qx "$EMU_SERIAL"; then
  say "hdc 未连上 $EMU_SERIAL，尝试 tconn …"
  hdc tconn "$EMU_SERIAL" || die "连不上 $EMU_SERIAL。确认实例在跑：devecocli emulator list"
fi
hdc list targets | grep -qx "$EMU_SERIAL" || die "hdc targets 里没有 $EMU_SERIAL"
API="$(hdc -t "$EMU_SERIAL" shell param get const.ohos.apiversion 2>/dev/null | tr -d '\r')"
say "目标 $EMU_SERIAL  API=$API"
[ "$API" = "$EMU_SDK" ] || warn "注意：设备 API 是 $API，脚本按 $EMU_SDK 编，可能装不上"

# --------------------------------------------------- 备份 + trap 还原
BACKUP="$(mktemp)"
cp "$PROFILE" "$BACKUP"
restore() {
  if [ "${KEEP_SDK:-0}" != "24" ]; then
    cp "$BACKUP" "$PROFILE"
    say "已还原 build-profile.json5（compatibleSdkVersion 回到 26）"
  else
    warn "KEEP_SDK=24：build-profile.json5 保持 compatibleSdkVersion=$EMU_SDK"
  fi
  rm -f "$BACKUP"
}
trap restore EXIT

# ------------------------------------------------------------ 降 compatibleSdkVersion
# 只改 products 里 name=="default" 那一个的 compatibleSdkVersion。
# 用行级替换而不是整体重写：build-profile.json5 里的 signingConfigs 是
# devecocli signature generate 写进去的（含加密密码与 /home/... 绝对路径），
# 任何整体重写都可能顺手改坏它。
node -e '
const fs = require("fs");
const file = process.argv[1], want = process.argv[2];
let t = fs.readFileSync(file, "utf8");
const lines = t.split("\n");
let inDefault = false, hits = 0;
for (let i = 0; i < lines.length; i++) {
  const l = lines[i];
  if (/"name"\s*:\s*"default"/.test(l)) inDefault = true;
  else if (inDefault && /"name"\s*:/.test(l)) inDefault = false;
  if (inDefault && /"compatibleSdkVersion"\s*:/.test(l)) {
    lines[i] = l.replace(/("compatibleSdkVersion"\s*:\s*)"[^"]*"/, `$1"${want}.0.0"`);
    hits++;
  }
}
if (hits !== 1) { console.error(`命中 ${hits} 处，期望 1 处，放弃修改`); process.exit(1); }
fs.writeFileSync(file, lines.join("\n"));
console.log(`  compatibleSdkVersion -> ${want}.0.0`);
' "$PROFILE" "$EMU_SDK"

# ------------------------------------------------------------------- 构建
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  say "assembleHap（compatibleSdkVersion=$EMU_SDK）…"
  export DEVECO_SDK_HOME="$DEVECO_HOME/sdk"
  # 资源/签名产物要跟着重出：先清 loader_out 与上一次签名结果
  rm -rf "$ROOT/entry/build/default/intermediates/loader_out"
  ( cd "$ROOT" && "$DEVECO_HOME/tools/hvigor/bin/hvigorw" --mode module \
      -p product=default -p module=entry@default -p buildMode=debug \
      assembleHap --no-daemon ) 2>&1 \
    | grep -E 'ERROR|error:|BUILD |SignHap|ProcessResource|CompileArkTS' || true
  [ -f "$HAP" ] || die "没产出 $HAP"
fi

# ------------------------------------------------------------------- 装机
say "安装到 $EMU_SERIAL …"
hdc -t "$EMU_SERIAL" install -r "$HAP" 2>&1 | tail -2
say "完成。拉起：aa start -a EntryAbility -b com.yukinofox.classyharmony"
