/*
 * 课表引擎所需的设置子集。
 *
 * 桌面版这些量在 ClassIsland/Models/Settings.cs 中，属于应用设置而非档案。
 * 引擎只用到其中三项，故单独抽出——不要把整个 Settings 拖进本模块：
 * 设置里含主题、窗口规则、语音等大量与课表计算无关的字段，
 * 而本模块被小组件 Extension 引用，越轻越好。
 *
 * 默认值与桌面版一致：
 * - SingleWeekStartTime：取运行当周的周日（随日期变化，不写死）
 * - MultiWeekRotationOffset：[-1, -1, 0, 0, 0]，下标 0/1 是占位
 * - MultiWeekRotationMaxCycle：4
 */

import { DateTimeValue } from 'common_shared';

export class EngineSettings {
  /**
   * 单周起点。单双周轮转以此为基准，取其日期部分参与计算。
   * 对应 Settings.SingleWeekStartTime。
   */
  singleWeekStartTime: DateTimeValue;

  /**
   * 各周期长度的轮转偏移，下标即周期长度。
   * 桌面版为 Dictionary<int, int>，缺失项按 0 处理。
   * 对应 Settings.MultiWeekRotationOffset。
   */
  multiWeekRotationOffset: number[] = [-1, -1, 0, 0, 0];

  /**
   * 最大轮转周期长度。超过此长度的课表不参与匹配。
   * 对应 Settings.MultiWeekRotationMaxCycle。
   */
  multiWeekRotationMaxCycle: number = 4;

  constructor(singleWeekStartTime?: DateTimeValue) {
    this.singleWeekStartTime = singleWeekStartTime === undefined
      ? EngineSettings.sundayOfThisWeek(DateTimeValue.now())
      : singleWeekStartTime;
  }

  /**
   * 默认单周起点：运行当周的周日 00:00:00。
   * 对应桌面版 `DateTime.Today.AddDays(-(int)DateTime.Today.DayOfWeek)`。
   *
   * 注意这是「构造当刻」的默认值，而非固定常量：桌面版同样在进程启动时求值，
   * 用户改过设置后以落盘值为准。
   */
  static sundayOfThisWeek(today: DateTimeValue): DateTimeValue {
    const day: number = today.dayOfWeek();
    return today.dateOnly().addDays(-day);
  }

  /** 取某周期长度的偏移；缺失按 0（对应 Dictionary 的 GetValueOrDefault）。 */
  offsetFor(cycleLength: number): number {
    if (cycleLength < 0 || cycleLength >= this.multiWeekRotationOffset.length) {
      return 0;
    }
    return this.multiWeekRotationOffset[cycleLength];
  }
}
