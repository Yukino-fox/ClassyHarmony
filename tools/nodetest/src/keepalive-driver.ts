/*
 * 后台保活测试台（长时任务类型选择 / 错误码翻译）。
 *
 * P11e 的失败模式是「要么什么也不做，要么做了不该做的」：
 *
 *   1. 用户关了保活却还在申请长时任务 —— 通知栏上挂着一条用户以为关掉了的
 *      常驻通知。
 *   2. 开了跨设备同步却申请「任务保持」—— 手机上前者能批、后者被拒，
 *      结果是「明明开了同步，后台还是断」。
 *   3. 申请失败后的错误码翻译错位 —— 用户看到「没有权限」，实际是设备根本
 *      不支持这种类型，于是往错误的方向排查。
 *
 * 所以下面把四个开关的所有组合都枚举一遍，并逐个核对确定的错误码文案。
 */

import {
  KEEP_ALIVE_MODE_MULTI_DEVICE,
  KEEP_ALIVE_MODE_TASK_KEEPING,
  KeepAlivePlan,
  keepAliveErrorText,
  planKeepAlive
} from '../../common_core/src/main/ets/background/KeepAlivePolicy';

let passed: number = 0;
const failures: string[] = [];

function check(name: string, condition: boolean, detail: string = ''): void {
  if (condition) {
    passed++;
  } else {
    failures.push(detail.length === 0 ? name : `${name} —— ${detail}`);
  }
}

function checkEqual(name: string, actual: string, expected: string): void {
  check(name, actual === expected, `实际「${actual}」，期望「${expected}」`);
}

function checkBool(name: string, actual: boolean, expected: boolean): void {
  check(name, actual === expected, `实际 ${actual}，期望 ${expected}`);
}

// --------------------------------------------------------------- 开关组合

function testPlan(): void {
  // 关了就是关了：不管别的开关怎么样都不申请。
  const offAll: KeepAlivePlan = planKeepAlive(false, false, false);
  checkBool('关 + 无功能：不申请', offAll.request, false);
  checkEqual('关 + 无功能：类型为空', offAll.mode, '');

  const offDistributed: KeepAlivePlan = planKeepAlive(false, true, true);
  checkBool('关 + 有功能：仍不申请', offDistributed.request, false);
  checkEqual('关 + 有功能：理由是已关闭', offDistributed.reason, "已关闭后台保活");

  // 开着但没有值得后台跑的功能：不申请，理由要能解释「为什么什么也没发生」。
  const nothing: KeepAlivePlan = planKeepAlive(true, false, false);
  checkBool('开 + 无功能：不申请', nothing.request, false);
  checkEqual('开 + 无功能：类型为空', nothing.mode, '');
  checkEqual('开 + 无功能：理由', nothing.reason, "当前没有需要后台运行的功能");

  // 只有自动化：任务保持（2in1 可用，手机大概率被拒）。
  const automation: KeepAlivePlan = planKeepAlive(true, false, true);
  checkBool('开 + 仅自动化：申请', automation.request, true);
  checkEqual('开 + 仅自动化：任务保持', automation.mode, KEEP_ALIVE_MODE_TASK_KEEPING);
  checkEqual('开 + 仅自动化：理由', automation.reason, '自动化需要在后台继续运行');

  // 只有跨设备：多设备互联。
  const distributed: KeepAlivePlan = planKeepAlive(true, true, false);
  checkBool('开 + 仅跨设备：申请', distributed.request, true);
  checkEqual('开 + 仅跨设备：多设备互联', distributed.mode, KEEP_ALIVE_MODE_MULTI_DEVICE);
  checkEqual('开 + 仅跨设备：理由', distributed.reason, '跨设备同步需要在后台保持连接');

  // 两个都开：跨设备优先 —— 多设备互联在手机上也能批，任务保持不能。
  const both: KeepAlivePlan = planKeepAlive(true, true, true);
  checkBool('开 + 都开：申请', both.request, true);
  checkEqual('开 + 都开：优先跨设备', both.mode, KEEP_ALIVE_MODE_MULTI_DEVICE);

  // 两个类型常量不能相等，否则上面的「优先」判断会失效。
  check('两种类型常量不同',
    KEEP_ALIVE_MODE_MULTI_DEVICE !== KEEP_ALIVE_MODE_TASK_KEEPING);
}

// --------------------------------------------------------------- 错误码

function testErrorText(): void {
  // 有确定含义的码：翻成人话，且不提错误号（用户不需要看）。
  checkEqual('201 是权限', keepAliveErrorText(201), "没有后台运行权限");
  checkEqual('202 是系统应用', keepAliveErrorText(202), "非系统应用不能申请该类型");
  checkEqual('401 是参数', keepAliveErrorText(401), '申请参数不合法');
  checkEqual('9800004 是服务失败', keepAliveErrorText(9800004), '系统服务操作失败');
  // 9800005 是手机上申请「任务保持」最可能遇到的那个。
  checkEqual('9800005 是校验不过', keepAliveErrorText(9800005),
    '长时任务校验未通过（该设备 / 该类型不支持）');
  checkEqual('9800006 是通知', keepAliveErrorText(9800006), '通知校验未通过');
  checkEqual('9800007 是落盘', keepAliveErrorText(9800007), '落盘失败');

  // 未知码：带出数字，不编解释。
  checkEqual('未知码带出数字', keepAliveErrorText(123456), '未知错误（123456）');
  checkEqual('零码也当未知', keepAliveErrorText(0), '未知错误（0）');
}

// --------------------------------------------------------------- 主入口

testPlan();
testErrorText();

if (failures.length > 0) {
  console.log(`后台保活：${failures.length} 项失败（共 ${passed + failures.length} 项）`);
  for (const failure of failures) {
    console.log(`  ✗ ${failure}`);
  }
  process.exit(1);
}
console.log(`后台保活：${passed} 项全部通过`);
