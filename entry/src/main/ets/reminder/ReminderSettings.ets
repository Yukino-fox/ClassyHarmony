/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 课前提醒的用户设置。
 *
 * 提前量默认值照搬桌面版 ClassIsland/Models/NotificationProviderSettings/
 * ClassNotificationSettings.cs：室内 60 秒、室外 600 秒。
 * 这两个数不是随手取的 —— 户外课要提前去操场，60 秒不够走到；
 * 而室内课提前十分钟会在整节课都在响，600 秒对户外课刚好。
 * 照抄而不是自己取整圆值：同一个用户在两端应该得到同样的提醒时机。
 *
 * 桌面版是「实时定时器 + 每次上课前重新判断」，鸿蒙侧改成平台周期提醒之后，
 * 提前量成了排提醒时一次性算进去的量。语义一致，但代价是提前量改了就得
 * 重新同步一批提醒 —— 所以 ReminderSyncService 是差异同步而不是全量重发。
 *
 * 为什么不提供「下课提醒」
 * ----------------------
 * 桌面版有准备上课 / 上课 / 下课三个渠道。下课提醒是「当前这节课的结束时刻」，
 * 与课表变更无关；上课提醒是提前量取 0 的情形。两条都已经能被
 * ReminderAdvance 表达，再单开一个设置项只会让人以为它多做了些什么。
 *
 * 为什么不提供自定义文案
 * --------------------
 * 桌面版能逐字自定义（ClassOnPreparingText 等）。这里的提醒文案由 core
 * 依据「提前几分钟 + 科目 + 时刻 + 老师」现算，自定义要牵动 key 的构成
 * （key 不含文案，所以改文案本可以只 update，但文案定制会让差异比对复杂到
 * 收益不成比例），留到 P10 之后再评估。
 */

import { common } from '@kit.AbilityKit';
import { ReminderAdvance, ReminderMode } from 'common_core';
import { AppPreferences, PrefKeys } from '../common/AppPreferences';

/** 提前量下界：0 表示「上课那一刻才提醒」。 */
const ADVANCE_MIN_SECONDS: number = 0;
/**
 * 提前量上界：一节课最多 45 分钟，跨一节课提醒没有意义。
 * 上界的作用是把「手滑输了个 999999」挡在外面 —— 提前量会参与触发时刻的
 * 计算，一个离谱的值会让触发时刻落到别的日子去，而界面上看不出任何异常。
 */
const ADVANCE_MAX_SECONDS: number = 3600;

/** 形态设置值。 */
export const REMINDER_MODE_AUTO: number = -1;
export const REMINDER_MODE_SPECIFIC: number = 0;
export const REMINDER_MODE_COLLAPSED: number = 1;

export class ReminderSettings {
  /** 总开关。关掉时同步会取消全部提醒，而不是「不新增」。 */
  enabled: boolean = true;
  /** 室内课提前量，秒。默认 60（照搬桌面版 InDoorClassPreparingDeltaTime）。 */
  advanceIndoorSeconds: number = 60;
  /** 室外课提前量，秒。默认 600（照搬桌面版 OutDoorClassPreparingDeltaTime）。 */
  advanceOutdoorSeconds: number = 600;
  /** 形态。默认自动（按额度决定精确还是折叠）。 */
  modeOverride: number = REMINDER_MODE_AUTO;

  /** 读设置。context 用于拿到 preferences 句柄。 */
  static load(prefs: AppPreferences): ReminderSettings {
    const out: ReminderSettings = new ReminderSettings();
    out.enabled = prefs.getBoolean(PrefKeys.REMINDER_ENABLED, true);
    out.advanceIndoorSeconds = clampAdvance(
      prefs.getNumber(PrefKeys.REMINDER_ADVANCE_INDOOR, 60));
    out.advanceOutdoorSeconds = clampAdvance(
      prefs.getNumber(PrefKeys.REMINDER_ADVANCE_OUTDOOR, 600));
    out.modeOverride = prefs.getNumber(PrefKeys.REMINDER_MODE, REMINDER_MODE_AUTO);
    return out;
  }

  /** 写设置。 */
  save(prefs: AppPreferences): void {
    prefs.put(PrefKeys.REMINDER_ENABLED, this.enabled);
    prefs.put(PrefKeys.REMINDER_ADVANCE_INDOOR, clampAdvance(this.advanceIndoorSeconds));
    prefs.put(PrefKeys.REMINDER_ADVANCE_OUTDOOR, clampAdvance(this.advanceOutdoorSeconds));
    prefs.put(PrefKeys.REMINDER_MODE, this.modeOverride);
    this.advanceIndoorSeconds = clampAdvance(this.advanceIndoorSeconds);
    this.advanceOutdoorSeconds = clampAdvance(this.advanceOutdoorSeconds);
  }

  /**
   * 当前形态设置对应的 ReminderMode。
   *
   * 「自动」时返回 undefined，由 ReminderSyncService 依额度自行决定 ——
   * 自动的判断要看编排结果（编排完才知道要不要截断），不在这里猜。
   */
  requestedMode(): ReminderMode | undefined {
    if (this.modeOverride === REMINDER_MODE_SPECIFIC) {
      return ReminderMode.Specific;
    }
    if (this.modeOverride === REMINDER_MODE_COLLAPSED) {
      return ReminderMode.Collapsed;
    }
    return undefined;
  }

  /** 转成 core 要的提前量。 */
  advance(): ReminderAdvance {
    const out: ReminderAdvance = new ReminderAdvance();
    out.indoorSeconds = clampAdvance(this.advanceIndoorSeconds);
    out.outdoorSeconds = clampAdvance(this.advanceOutdoorSeconds);
    return out;
  }

  /** 室内提前量（分钟），给界面用。 */
  indoorMinutes(): number {
    return Math.round(this.advanceIndoorSeconds / 60);
  }

  /** 室外提前量（分钟），给界面用。 */
  outdoorMinutes(): number {
    return Math.round(this.advanceOutdoorSeconds / 60);
  }
}

/**
 * 夹住提前量。
 *
 * 非有限数在这里被换成 0 而不是默认值：出现 NaN 说明上游算错了，而「提前 0
 * 分钟提醒」是所有取值里最不会出事的一个（顶多是响得晚一点），换成 60 或
 * 600 则是凭空给出一个用户没要求过的行为。
 */
function clampAdvance(seconds: number): number {
  if (!isFinite(seconds)) {
    return 0;
  }
  const rounded: number = Math.round(seconds);
  if (rounded < ADVANCE_MIN_SECONDS) {
    return ADVANCE_MIN_SECONDS;
  }
  if (rounded > ADVANCE_MAX_SECONDS) {
    return ADVANCE_MAX_SECONDS;
  }
  return rounded;
}

/** 由 context 直接装配一份设置。 */
export function loadReminderSettings(context: common.Context): ReminderSettings {
  return ReminderSettings.load(new AppPreferences(context));
}
