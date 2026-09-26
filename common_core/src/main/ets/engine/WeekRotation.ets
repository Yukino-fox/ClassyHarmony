/*
 * 单双周轮转。对应 LessonsService.GetCyclePositionsByDate
 *
 * 语义：给定一个日期，算出它在 2 周 ~ 最大周期 各轮转周期中的位置（1 起）。
 * 课表的 TimeRule.WeekCountDiv / WeekCountDivTotal 就是「本表要求自己在
 * 长度为 WeekCountDivTotal 的轮转里处于第 WeekCountDiv 位」，引擎靠这里的
 * 位置判断某张课表今天是否该生效。
 *
 * 位置数组的下标 0 与 1 恒为 -1，是桌面版留下的占位（未使用的周期长度）。
 * 调用方按 WeekCountDivTotal 直接下标取值，因此下标必须与周期长度对齐，
 * 不能压缩数组。
 */

import { DateTimeValue } from 'common_shared';
import { EngineSettings } from './EngineSettings';

export class WeekRotation {
  /**
   * 距单周起点已过的整周数（可为负，表示起点在将来）。
   *
   * 只比日期部分：桌面版写的是
   * `(referenceTime.Value.Date - Settings.SingleWeekStartTime.Date).TotalDays / 7`，
   * 两边都先取 .Date，时刻被丢弃。
   *
   * 走历日而非毫秒：单周起点通常是几周前的某个周日，跨过 DST 切换日时
   * 毫秒差里会少或多出 1 小时，向下取整成周数就可能整整差一周。
   */
  static elapsedWeeks(referenceTime: DateTimeValue, settings: EngineSettings): number {
    const days: number =
      referenceTime.dateOnly().epochDay() - settings.singleWeekStartTime.dateOnly().epochDay();
    // Math.floor 而非截断：起点在将来时差值为负，截断会把 -3.5 算成 -3。
    return Math.floor(days / 7);
  }

  /**
   * 各周期长度下的轮转位置，下标 0/1 恒为 -1，其余为周期长度对应的 1 起位置。
   * 对应 LessonsService.GetCyclePositionsByDate。
   */
  static cyclePositions(referenceTime: DateTimeValue, settings: EngineSettings): number[] {
    const out: number[] = [-1, -1];
    const elapsedWeeks: number = WeekRotation.elapsedWeeks(referenceTime, settings);
    for (let cycleLength: number = 2; cycleLength <= settings.multiWeekRotationMaxCycle; cycleLength++) {
      let position: number = (elapsedWeeks + settings.offsetFor(cycleLength)) % cycleLength;
      // ArkTS 的 % 沿用 C# 语义（符号跟被除数），负数取模会得负值，需回绕。
      if (position < 0) {
        position += cycleLength;
      }
      out.push(position + 1);
    }
    return out;
  }

  /**
   * 该日期在指定周期长度下的轮转位置（1 起）。周期长度越界返回 0。
   *
   * 越界返回 0 而非抛错：桌面版在 rotation[WeekCountDivTotal] 越界时会直接
   * 抛 ArgumentOutOfRangeException，把整个 50ms 轮询打崩。手改档案写出
   * WeekCountDivTotal=0 这类脏数据时，返回 0（永不为真）是最合理的降级。
   */
  static positionOf(referenceTime: DateTimeValue, settings: EngineSettings,
    cycleLength: number): number {
    if (cycleLength < 2 || cycleLength > settings.multiWeekRotationMaxCycle) {
      return 0;
    }
    let position: number = (WeekRotation.elapsedWeeks(referenceTime, settings) +
      settings.offsetFor(cycleLength)) % cycleLength;
    if (position < 0) {
      position += cycleLength;
    }
    return position + 1;
  }
}
