#!/usr/bin/env bash
#
# 字节级往返测试。
#
# 为什么不在设备上跑：ArkTS 侧要用 Local Test（ohosTest）执行，但
# 1) 工程含 HAR 模块，无华为侧 p7b 签名材料时连任务图都建不起来；
# 2) 本机模拟器是 OpenHarmony 6.1（API 24），而工程目标 API 26，装不上。
#
# 因此改为在 Node 中跑 common_shared 的真实源码：这些文件只用 TypeScript
# 层语法（class / 类型标注 / 泛型 / enum），经 tsc 剥类型后运行期语义与
# ArkTS 一致。ArkTS 语言层合规性由单模块校验工程（verify-arkts.sh）保证，
# 两者互补。
set -euo pipefail

DEVECO_HOME="${DEVECO_HOME:-/mnt/data/devecostudio-26.0.0.621}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${ROUNDTRIP_WORK:-/tmp/opencode/roundtrip}"

TSC="$DEVECO_HOME/plugins/codelinter/node_modules/typescript/bin/tsc"
NODE="$DEVECO_HOME/tools/node/bin/node"
[ -x "$NODE" ] || NODE="$(command -v node)"

# @types/node 只在 DevEco 自带的若干 node_modules 下找得到，取第一处
TYPES_DIR="$(find "$DEVECO_HOME/plugins" -maxdepth 5 -type d -path '*/node_modules/@types' 2>/dev/null | head -1)"

if [ ! -f "$TSC" ]; then
  echo "找不到 tsc：$TSC" >&2
  echo "请确认 DEVECO_HOME 指向 DevEco Studio 安装目录。" >&2
  exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK/src"

# ArkTS 源码后缀为 .ets，tsc 不识别；内容本身是合法 TS，故改后缀即可。
# 保留目录结构，使源码内的相对 import 原样可用。
copy_ets() {
  local from="$1" to="$WORK/src/$2"
  local f rel
  while IFS= read -r f; do
    rel="${f#"$from"/}"
    mkdir -p "$to/$(dirname "$rel")"
    cp "$f" "$to/${rel%.ets}.ts"
  done < <(find "$from" -name '*.ets' | sort)
}

copy_ets "$ROOT/common_shared/src/main/ets" shared
# 导出入口在模块根而非 sources 内，其路径前缀是 './src/main/ets/'，需改写
sed "s|'./src/main/ets/|'./|g" "$ROOT/common_shared/Index.ets" > "$WORK/src/shared/Index.ts"
mkdir -p "$WORK/src/tools"
# 驱动的 import 写的是仓库内布局（tools/roundtrip/src/ 上溯两级到仓库根），
# 校验目录里共享代码与驱动同级编译到 out/，故只需上溯一级
sed "s|'../../common_shared/src/main/ets/|'../shared/|g" \
  "$ROOT/tools/roundtrip/src/driver.ts" > "$WORK/src/tools/driver.ts"

"$NODE" "$TSC" \
  --outDir "$WORK/out" \
  --rootDir "$WORK/src" \
  --module commonjs \
  --target es2021 \
  --moduleResolution node \
  --strict false \
  --skipLibCheck \
  --typeRoots "$TYPES_DIR" \
  --types node \
  "$WORK/src/shared/Index.ts" \
  "$WORK/src/tools/driver.ts" 2>&1 | sed 's/^/  /' || true

cp -r "$ROOT/tools/roundtrip/fixtures" "$WORK/out/fixtures"

"$NODE" "$WORK/out/tools/driver.js"
