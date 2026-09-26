/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 提醒的通知渠道。
 *
 * 为什么要自己注册一个渠道
 * ----------------------
 * 不注册的话提醒落进系统默认渠道，关掉它就是关掉本应用的全部通知 —— 连
 * 小组件刷新失败之类的提示也一起没了。用户想「课前提醒太吵，先静音」时，
 * 没有只针对提醒的开关可用。注册一个专用渠道之后，系统设置里会多出一项
 * 「课前提醒」，用户可以单独调级别、单独静音。
 *
 * 渠道名与说明用中文写死
 * --------------------
 * 系统设置里的渠道名直接显示这段文字，而本应用只面向中文用户；放到
 * string.json 里要多一次资源查找，还要为其它语言留一份永远不会更新的翻译。
 * 更好的做法是有第二语言时再搬过去。
 *
 * level 定在 LEVEL_DEFAULT 而不是 LEVEL_HIGH
 * -----------------------------------------
 * LEVEL_HIGH 会强制横幅 + 持续响铃。一节课前响一次横幅还能接受，响铃就过了 ——
 * 而且「响多久」我们控制不了（那是系统按渠道级别定的）。LEVEL_DEFAULT 是
 * 「有声音、状态栏可见、但不抢屏」，是提醒类通知的合适档位。真正想更显眼
 * 的话，让用户在系统设置里往上调，而不是替用户决定。
 *
 * 不设 bypassDnd
 * -------------
 * 「免打扰也要穿透」是个很重的承诺，不该由应用替用户做。用户在系统设置里
 * 打开这个开关是他自己的决定。
 *
 * 不设 sound
 * ---------
 * 留空用系统默认提示音。自己塞一个 rawfile 音频意味着要在仓库里放二进制资源、
 * 还要处理不同设备的音量曲线，换来的只是个性和别的应用一样。
 */

import { notificationManager } from '@kit.NotificationKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { common } from '@kit.AbilityKit';

/** 渠道说明。显示在系统设置的通知管理里。 */
const CHANNEL_DESC: string = '上课前的提醒';

/**
 * 注册提醒渠道。幂等，可以每次同步前都调。
 *
 * 必须在 publishReminder **之前**调用：先发出去再注册，那条提醒已经落进默认
 * 渠道了，之后的注册对它无效 —— 表现是「明明建了专用渠道，提醒还是从默认
 * 渠道出来」，而且没有任何报错。
 *
 * 失败不抛：渠道注册失败的后果只是提醒落到默认渠道，提醒本身照样能响。
 * 而抛出去会让整个同步失败，用户连提醒都收不到 —— 为一个「更好」牺牲
 * 一个「能好」不划算。失败记在返回值上，由界面如实告知。
 *
 * @returns true 表示渠道可用。
 */
export async function ensureReminderChannel(context: common.Context): Promise<boolean> {
  try {
    // 用 notificationType / notificationLevel 而不是同名的 type / level：
    // 后者声明的是 @ohos.notification 里的旧枚举，整个模块从 API 9 起就废弃了
    // （同名、同值，只是类型身份不同），而前者是 notificationManager 里的现行枚举。
    // 两者语义一致，选后者只是为了不把废弃警告引进构建日志。
    const slot: notificationManager.NotificationSlot = {
      notificationType: notificationManager.SlotType.SERVICE_INFORMATION,
      notificationLevel: notificationManager.SlotLevel.LEVEL_DEFAULT,
      desc: CHANNEL_DESC,
      // 角标不显示：一次课前提醒不值得在应用图标上留一个数字，
      // 而角标数字既没有含义（本应用只有提醒这一类通知）也没地方能点进去。
      badgeFlag: false,
      vibrationEnabled: true
    };
    await reminderAgentManager.addNotificationSlot(slot);
    return true;
  } catch (err) {
    // err 是 any（ArkTS 的 catch 变量不带类型），不能直接 throw 出去，
    // 也不能赋给 Object 以外的推断类型。只记一句，不外传。
    console.warn(`[ClassyHarmony] 注册提醒渠道失败：${err}`);
    return false;
  }
}

/**
 * 请系统允许本应用发通知。
 *
 * 必须在 publishReminder 之前调用，否则报 1700001（通知未开启）。
 * 第一次调用会弹窗；用户拒绝后每次调用都不弹窗、直接失败，所以
 * 「失败」要如实报给界面，让用户知道自己得去系统设置里开，而不是
 * 反复重试。
 *
 * @returns true 表示通知权限可用。
 */
export async function ensureNotificationEnabled(context: common.Context): Promise<boolean> {
  try {
    await notificationManager.requestEnableNotification(context as common.UIAbilityContext);
    return true;
  } catch (err) {
    console.warn(`[ClassyHarmony] 请求通知权限失败：${err}`);
    return false;
  }
}
