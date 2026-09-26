/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 时间段求交，用于编辑时间点时立刻提示「和第几节课撞了」。
 *
 * 为什么自己写而不用现成的区间库
 * ----------------------------
 * 整个工程没有第二个依赖，而这里的逻辑只有两行：`aStart < bEnd && bStart < aEnd`。
 * 为了两行代码引一个包不划算，ArkTS 的包引入还有编译期开销。
 *
 * 首尾相接不算撞
 * --------------
 * 08:00-08:45 与 08:45-09:00 是标准的课间排布。判成撞的话每张作息表都会在
 * 保存前弹一次「有冲突」，用户学会无视这个提示之后，它就再也不会被看见了 ——
 * 真正该报的那次也一并被无视。所以这里用严格小于：边界相接返回 false。
 *
 * 零长与负区间一律不撞
 * --------------------
 * 时间点被填成空时段（00:00-00:00）时，如果按「0 落在任何区间内」去判，
 * 它会与第一节课冲突，而用户根本不知道自己填了什么。一个空时段占不住任何时间。
 */

/** 一行时间，秒为单位。 */
export class TimeSpanRow {
  /** 起点，秒。 */
  start: number = 0;
  /** 终点，秒。 */
  end: number = 0;
  /** 显示用的名字（「第 1 节」「大课间」）。 */
  label: string = '';
  /** 这一行对应时间表里的第几行。 */
  rowIndex: number = 0;
  /** 停用的行不参与冲突判定。 */
  isEnabled: boolean = true;
}

export class TimeRange {
  /**
   * 两个时间段是否重叠。
   *
   * 首尾相接返回 false；零长与负区间返回 false。
   *
   * @param aStart A 起点（秒）
   * @param aEnd A 终点（秒）
   * @param bStart B 起点（秒）
   * @param bEnd B 终点（秒）
   */
  static overlap(aStart: number, aEnd: number, bStart: number, bEnd: number): boolean {
    if (aEnd <= aStart || bEnd <= bStart) {
      return false;
    }
    return aStart < bEnd && bStart < aEnd;
  }

  /**
   * 找出被 [start, end) 撞到的那一行下标。
   *
   * 返回 -1 表示不冲突。撞到多行时返回最先撞到的那一行：只提示一节已经够
   * 用户定位了，一次列三行反而不知道该先改哪个。
   *
   * @param rows 候选行
   * @param start 待判定区间的起点（秒）
   * @param end 待判定区间的终点（秒）
   */
  static conflictIndex(rows: TimeSpanRow[], start: number, end: number): number {
    for (let i: number = 0; i < rows.length; i++) {
      const row: TimeSpanRow = rows[i];
      if (!row.isEnabled) {
        continue;
      }
      if (TimeRange.overlap(start, end, row.start, row.end)) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 把两个时段重叠的分钟数算出来。
   *
   * 用于「这一节被压掉了多少」的提示。整分钟向下取：重叠 20 分半显示 20 分钟，
   * 比显示 20.5 更接近用户对课表精度的预期。
   *
   * @param aStart A 起点（秒）
   * @param aEnd A 终点（秒）
   * @param bStart B 起点（秒）
   * @param bEnd B 终点（秒）
   */
  static overlapMinutes(aStart: number, aEnd: number, bStart: number, bEnd: number): number {
    if (aEnd <= aStart || bEnd <= bStart) {
      return 0;
    }
    const from: number = Math.max(aStart, bStart);
    const to: number = Math.min(aEnd, bEnd);
    if (to <= from) {
      return 0;
    }
    return Math.floor((to - from) / 60);
  }
}

/** 建一行时间。参数按「起点在前」的顺序，名字次之，行下标最后。 */
export function newTimeSpanRow(rowIndex: number, start: number, end: number,
  label: string = ''): TimeSpanRow {
  const row: TimeSpanRow = new TimeSpanRow();
  row.rowIndex = rowIndex;
  row.start = start;
  row.end = end;
  row.label = label;
  return row;
}

/** 两个时间段是否重叠。首尾相接、零长、负区间都不算重叠。 */
export function timeRangeOverlap(aStart: number, aEnd: number, bStart: number, bEnd: number): boolean {
  return TimeRange.overlap(aStart, aEnd, bStart, bEnd);
}

/** 找出被 [start, end) 撞到的那一行下标，不冲突返回 -1。 */
export function timeRangeConflictIndex(rows: TimeSpanRow[], start: number, end: number): number {
  return TimeRange.conflictIndex(rows, start, end);
}

/** 两个时段重叠的整分钟数。 */
export function timeRangeOverlapMinutes(aStart: number, aEnd: number, bStart: number,
  bEnd: number): number {
  return TimeRange.overlapMinutes(aStart, aEnd, bStart, bEnd);
}
