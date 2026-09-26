/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 时钟抽象。
 *
 * core 层的引擎全是「传入档案 + 传入时间」的纯函数，从不自己取当前时间。
 * 但 UI 层、提醒链路总需要知道「现在」，而它们各有各的取法
 * （页面轮询、reminderAgent 的触发时刻、小组件的 10 秒窗口）。
 * 把取时间这件事收拢到一个可替换的接口上，好处是：
 *   - 单元测试可以注入固定时间，不必依赖真实时钟；
 *   - 小组件与主应用共用同一套「算今天几号第几节课」逻辑时，
 *     行为一致，不会因为两边取时间的口径不同而算出不同结果。
 */

import { DateTimeValue } from 'common_shared';

/** 取当前本地时间。 */
export interface AppClock {
  now(): DateTimeValue;
}

/** 真实时钟：跟随系统本地时区。 */
export class SystemClock implements AppClock {
  now(): DateTimeValue {
    return DateTimeValue.fromDate(new Date());
  }
}

/** 固定时钟：只在测试与预览里用。 */
export class FixedClock implements AppClock {
  private current: DateTimeValue;

  constructor(start: DateTimeValue) {
    this.current = start;
  }

  now(): DateTimeValue {
    return this.current;
  }

  /** 手动推进。 */
  advanceSeconds(seconds: number): void {
    this.current = this.current.addSeconds(seconds);
  }

  /** 手动设定。 */
  set(value: DateTimeValue): void {
    this.current = value;
  }
}
