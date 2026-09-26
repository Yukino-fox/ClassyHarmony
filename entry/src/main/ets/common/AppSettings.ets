/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 引擎参数的默认值。
 *
 * 全部照搬桌面版 ClassIsland/Models/Settings.cs 的字段初始值。原因很直接：
 * 同一个档案在两端必须算出同一份课表，而单双周轮转的结果完全取决于参照时间，
 * 取不同的默认值会让「这周上不上这节课」在两端不一致 —— 这属于必须保持一致的
 * 行为，不是可以随手定的偏好。
 *
 * 目前这些值是写死的。设置页（P10）会把它们落到 preferences 里，
 * 那时这里改成「读设置，缺失时回落到下面的默认值」。
 */

import { DateTimeValue } from 'common_shared';
import { EngineSettings } from 'common_core';

/**
 * 单周起始日：今天之前（含今天）最近的一个周日。
 *
 * 对应桌面版 `DateTime.Today.AddDays(-(int)DateTime.Today.DayOfWeek)`。
 * 桌面版把「取周一」的那行注释掉了，说明作者权衡过：改取周一会让既有用户的
 * 单双周编号整体错位，所以保持取周日。这里照抄，包括那个取舍。
 */
export function defaultSingleWeekStartTime(today: DateTimeValue): DateTimeValue {
  return today.dateOnly().addDays(-today.dayOfWeek());
}

/** 默认引擎参数。multiWeekRotationOffset / MaxCycle 用 EngineSettings 自身的默认值。 */
export function defaultEngineSettings(today: DateTimeValue): EngineSettings {
  return new EngineSettings(defaultSingleWeekStartTime(today));
}
