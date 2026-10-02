/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 后台保活的取舍（core，纯函数）。
 *
 * 鸿蒙对后台的限制：应用退到后台后会被逐步冻结，定时器、网络、分布式连接
 * 都会停。想让课表在后台继续算、继续在时间点边界弹通知，唯一合规的手段是
 * 申请一个「长时任务」（ContinuousTask）。但长时任务不是随便挑类型的：
 *
 *   1. 每个类型对应一个明确的使用场景（数据传输、音视频播放、录音、定位、
 *      蓝牙、多设备互联、通话、任务保持），乱报类型属于违规使用；
 *   2. 手机上申请 TASK_KEEPING（「任务保持」）需要受限权限
 *      ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM（ACL），普通应用拿不到；
 *      2in1 上不需要（API 21 起）；
 *   3. 申请成功后系统会在通知栏挂一条常驻通知，点它要能回到应用。
 *
 * 所以这里的策略是「按当前真正在跑的功能挑一个站得住脚的类型」：
 *   开了跨设备同步 → 多设备互联（本来就是它的场景，手机也认）
 *   否则开了自动化 → 任务保持（2in1 可用；手机申请失败后回落为「仅前台」）
 *   都没有         → 不申请
 *
 * 这一层不认识任何 SDK 类型，只吐字符串，由 entry 翻译成 BackgroundMode。
 * 好处是「什么情况下该申请」这件事可以在 Node 测试台里全量枚举。
 */

import { t } from '../i18n/I18n';

/** 连续任务类型：多设备互联。对应 BackgroundMode.MULTI_DEVICE_CONNECTION。 */
export const KEEP_ALIVE_MODE_MULTI_DEVICE: string = 'MULTI_DEVICE_CONNECTION';
/** 连续任务类型：任务保持。对应 BackgroundMode.TASK_KEEPING。 */
export const KEEP_ALIVE_MODE_TASK_KEEPING: string = 'TASK_KEEPING';

/** 一次后台保活申请要用什么类型、为什么。 */
export class KeepAlivePlan {
  /** 是否申请长时任务。 */
  request: boolean = false;
  /** 申请类型；不申请时为空串。取值见上面两个常量。 */
  mode: string = '';
  /** 选择理由（给设置页显示）。 */
  reason: string = '';
}

/**
 * 决定是否申请长时任务、申请哪一种。
 *
 * @param keepAliveEnabled 用户开关。关了就直接不申请 —— 长时任务会挂一条
 *        常驻通知，用户明确关掉之后不该再出现。
 * @param distributedEnabled 跨设备同步是否开启。
 * @param automationEnabled 自动化总开关。
 */
export function planKeepAlive(
  keepAliveEnabled: boolean,
  distributedEnabled: boolean,
  automationEnabled: boolean): KeepAlivePlan {
  const plan: KeepAlivePlan = new KeepAlivePlan();
  if (!keepAliveEnabled) {
    plan.reason = t('keepalive_disabled');
    return plan;
  }
  // 跨设备优先于自动化：多设备互联在手机上也能申请，自动化那条在手机上
  // 大概率申请不到。两者都开会挑能生效的那个。
  if (distributedEnabled) {
    plan.request = true;
    plan.mode = KEEP_ALIVE_MODE_MULTI_DEVICE;
    plan.reason = '跨设备同步需要在后台保持连接';
    return plan;
  }
  if (automationEnabled) {
    plan.request = true;
    plan.mode = KEEP_ALIVE_MODE_TASK_KEEPING;
    plan.reason = '自动化需要在后台继续运行';
    return plan;
  }
  plan.reason = t('keepalive_nothing_needed');
  return plan;
}

/**
 * 把 startBackgroundRunning 抛出的错误码翻译成人话。
 *
 * 只翻含义确定的几个；其余原样带出错误号 —— 编一个假解释比让用户看到一串
 * 数字更糟（至少数字能拿去搜）。错误码取自
 * @ohos.resourceschedule.backgroundTaskManager.d.ts 的 @throws。
 */
export function keepAliveErrorText(code: number): string {
  switch (code) {
    case 201:
      return t('keepalive_no_permission');
    case 202:
      return t('keepalive_not_system_app');
    case 401:
      return '申请参数不合法';
    case 9800004:
      return '系统服务操作失败';
    case 9800005:
      return '长时任务校验未通过（该设备 / 该类型不支持）';
    case 9800006:
      return '通知校验未通过';
    case 9800007:
      return '落盘失败';
    default:
      return `未知错误（${code}）`;
  }
}
