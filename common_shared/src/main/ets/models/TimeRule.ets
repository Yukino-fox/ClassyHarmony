/*
 * 时间规则（单双周/星期几）。对应 ClassIsland.Shared/Models/Profile/TimeRule.cs
 *
 * 序列化顺序：WeekDay, WeekCountDiv, WeekCountDivTotal, IsActive
 *
 * WeekCountDivTotal 默认 2 而非 0——单双周语义下 0 为无意义除数。
 */

import { JsonBoolean, JsonObject } from '../json/JsonNode';
import { ModelCodec } from './ModelCodec';

export class TimeRule {
  /** 星期几：0=周日 … 6=周六（与 C# DayOfWeek 对齐）。 */
  weekDay: number = 0;
  /** 周期除数。 */
  weekCountDiv: number = 0;
  /** 周期总数。 */
  weekCountDivTotal: number = 2;

  isActive: boolean = false;

  constructor() {
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('WeekDay', ModelCodec.intNode(this.weekDay));
    out.set('WeekCountDiv', ModelCodec.intNode(this.weekCountDiv));
    out.set('WeekCountDivTotal', ModelCodec.intNode(this.weekCountDivTotal));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): TimeRule {
    const out: TimeRule = new TimeRule();
    out.weekDay = ModelCodec.int(node, 'WeekDay', 0);
    out.weekCountDiv = ModelCodec.int(node, 'WeekCountDiv', 0);
    out.weekCountDivTotal = ModelCodec.int(node, 'WeekCountDivTotal', 2);
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }

  /**
   * 判断给定日期是否命中此规则。
   *
   * 对应 ClassIsland.Core 的规则求值：weekCountDivTotal <= 0 视为不限制周次。
   * weeksSinceEpoch 取自调用方，保证同一 Profile 内各规则的周次基准一致。
   */
  matches(weekDay: number, weeksSinceEpoch: number): boolean {
    if (this.weekDay !== weekDay) {
      return false;
    }
    if (this.weekCountDivTotal <= 0) {
      return true;
    }
    return weeksSinceEpoch % this.weekCountDivTotal === this.weekCountDiv;
  }
}
