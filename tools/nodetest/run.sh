#!/usr/bin/env bash
#
# Node 测试台：在 Node 中跑 common_shared / common_core 的真实源码。
#
# 为什么不在设备上跑：ArkTS 侧要用 Local Test（ohosTest）执行，但
# 1) 工程含 HAR 模块，无华为侧 p7b 签名材料时连任务图都建不起来；
# 2) 本机模拟器是 OpenHarmony 6.1（API 24），而工程目标 API 26，装不上。
#
# 因此改为在 Node 中直接跑源码：这些文件只用 TypeScript 层语法
# （class / 类型标注 / 泛型 / enum），经 tsc 剥类型后运行期语义与 ArkTS 一致。
# ArkTS 语言层合规性由单模块校验工程（/tmp/opencode/verify-arkts.sh）保证，
# 两者互补——本台子抓「逻辑错」，校验工程抓「语法违规」。
#
# 两个驱动：
#   src/driver.ts        字节级往返（序列化保真）
#   src/engine-driver.ts 课表引擎行为（状态机、轮转、临时层）
#   src/grid-driver.ts  课表网格视图数据推导
#   src/edit-driver.ts   档案改动的自洽性与落盘往返
#   src/widget-driver.ts 小组件视图数据推导与编解码
#   src/reminder-driver.ts 课前提醒的编排（触发时刻 / 额度降级 / 差异比对）
#   src/component-driver.ts 主界面组件布局（往返保真 / 注册表 / 增删移）
#   src/panel-driver.ts     面板渲染模型（倒计时格式 / 样式合成 / 课表边界 / 深度上限）
#   src/ruleset-driver.ts   规则求值（三态 / 短路 / 逐层取反 / 课表处理器 / 往返）
#   src/automation-driver.ts 自动化链路（cron / 八个触发器 / 四个判据 / 条件恢复 / 往返）
#   src/time-driver.ts       精确时间（NTP 纪元换算 / 偏差公式 / 冻结 / 反向保持）
#   src/speech-driver.ts     语音朗读（UTF-8 / MD5 / 提供方选择 / 队列）
#   src/weather-driver.ts    天气（码表 / 预警筛选 / 日出日落 / 规则 / 简报）
#   src/ipc-driver.ts        跨设备公开状态（会话 ID / 事件映射 / 快照 / 编解码）
#   src/keepalive-driver.ts  后台保活（长时任务类型选择 / 错误码翻译）
#   src/plugin-driver.ts     声明式插件（版本闸 / 校验 / 日程 / 模板 / 装卸 / 引擎端到端）
set -euo pipefail

DEVECO_HOME="${DEVECO_HOME:-/mnt/data/devecostudio-26.0.0.621}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${NODETEST_WORK:-/tmp/opencode/nodetest}"

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
copy_ets "$ROOT/common_core/src/main/ets" core

# 导出入口在模块根而非 sources 内，其路径前缀是 './src/main/ets/'，需改写
sed "s|'./src/main/ets/|'./|g" "$ROOT/common_shared/Index.ets" > "$WORK/src/shared/Index.ts"
sed "s|'./src/main/ets/|'./|g" "$ROOT/common_core/Index.ets"   > "$WORK/src/core/Index.ts"

# core 在真工程里通过包名 'common_shared' 引用 shared；本台子里两者同在
# src/ 下，core 的源在 src/core/engine/ 一层，故改写为 ../../shared/Index
# 必须写全 Index：文件名首字母大写，Linux 大小写敏感，写目录名解析不到
find "$WORK/src/core" -name '*.ts' -print0 \
  | xargs -0 sed -i "s|from 'common_shared'|from '../../shared/Index'|g"

mkdir -p "$WORK/src/tools"
# 驱动的 import 写的是仓库内布局（tools/nodetest/src/ 上溯两级到仓库根），
# 校验目录里共享代码与驱动同级编译到 out/，故只需上溯一级
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/driver.ts" > "$WORK/src/tools/driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/engine-driver.ts" > "$WORK/src/tools/engine-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/grid-driver.ts" > "$WORK/src/tools/grid-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/edit-driver.ts" > "$WORK/src/tools/edit-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/widget-driver.ts" > "$WORK/src/tools/widget-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/reminder-driver.ts" > "$WORK/src/tools/reminder-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/component-driver.ts" > "$WORK/src/tools/component-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/panel-driver.ts" > "$WORK/src/tools/panel-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/ruleset-driver.ts" > "$WORK/src/tools/ruleset-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/automation-driver.ts" > "$WORK/src/tools/automation-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/time-driver.ts" > "$WORK/src/tools/time-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/speech-driver.ts" > "$WORK/src/tools/speech-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/weather-driver.ts" > "$WORK/src/tools/weather-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/ipc-driver.ts" > "$WORK/src/tools/ipc-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/keepalive-driver.ts" > "$WORK/src/tools/keepalive-driver.ts"
sed "s|'../../common_shared/src/main/ets/|'../shared/|g; \
     s|'../../common_core/src/main/ets/|'../core/|g" \
  "$ROOT/tools/nodetest/src/plugin-driver.ts" > "$WORK/src/tools/plugin-driver.ts"

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
  "$WORK/src/core/Index.ts" \
  "$WORK/src/tools/driver.ts" \
  "$WORK/src/tools/engine-driver.ts" \
  "$WORK/src/tools/grid-driver.ts" \
  "$WORK/src/tools/edit-driver.ts" \
  "$WORK/src/tools/widget-driver.ts" \
  "$WORK/src/tools/reminder-driver.ts" \
  "$WORK/src/tools/component-driver.ts" \
  "$WORK/src/tools/panel-driver.ts" \
  "$WORK/src/tools/ruleset-driver.ts" \
  "$WORK/src/tools/automation-driver.ts" \
  "$WORK/src/tools/time-driver.ts" \
  "$WORK/src/tools/speech-driver.ts" \
  "$WORK/src/tools/weather-driver.ts" \
  "$WORK/src/tools/ipc-driver.ts" \
  "$WORK/src/tools/keepalive-driver.ts" \
  "$WORK/src/tools/plugin-driver.ts" 2>&1 | sed 's/^/  /' || true

cp -r "$ROOT/tools/nodetest/fixtures" "$WORK/out/fixtures"

status=0
echo "── 字节级往返 ──"
"$NODE" "$WORK/out/tools/driver.js" || status=1
echo ""
echo "── 课表引擎 ──"
"$NODE" "$WORK/out/tools/engine-driver.js" || status=1
echo ""
echo "── 课表网格 ──"
"$NODE" "$WORK/out/tools/grid-driver.js" || status=1
echo ""
echo "── 档案改动 ──"
"$NODE" "$WORK/out/tools/edit-driver.js" || status=1
echo ""
echo "── 小组件 ──"
"$NODE" "$WORK/out/tools/widget-driver.js" || status=1
echo ""
echo "── 课前提醒 ──"
"$NODE" "$WORK/out/tools/reminder-driver.js" || status=1
echo ""
echo "── 组件布局 ──"
"$NODE" "$WORK/out/tools/component-driver.js" || status=1
echo ""
echo "── 面板渲染 ──"
"$NODE" "$WORK/out/tools/panel-driver.js" || status=1
echo ""
echo "── 规则求值 ──"
"$NODE" "$WORK/out/tools/ruleset-driver.js" || status=1
echo ""
echo "── 自动化链路 ──"
"$NODE" "$WORK/out/tools/automation-driver.js" || status=1
echo ""
echo "── 精确时间 ──"
"$NODE" "$WORK/out/tools/time-driver.js" || status=1
echo ""
echo "── 语音朗读 ──"
"$NODE" "$WORK/out/tools/speech-driver.js" || status=1
echo ""
echo "── 天气 ──"
"$NODE" "$WORK/out/tools/weather-driver.js" || status=1
echo ""
echo "── 跨设备 ──"
"$NODE" "$WORK/out/tools/ipc-driver.js" || status=1
echo ""
echo "── 后台保活 ──"
"$NODE" "$WORK/out/tools/keepalive-driver.js" || status=1
echo ""
echo "── 插件系统 ──"
"$NODE" "$WORK/out/tools/plugin-driver.js" || status=1
exit $status
