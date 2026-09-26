/*
 * 时间表中的一个时间段。对应 ClassIsland.Shared/Models/Profile/TimeLayoutItem.cs
 *
 * 序列化顺序：
 *   StartSecond, EndSecond, StartTime, EndTime, TimeType, IsHideDefault,
 *   DefaultClassId, BreakName, ActionSet, AttachedObjects, IsActive
 *
 * 关键怪癖：StartSecond / EndSecond 虽标注 [Obsolete(..., true)]（仅编译期报错），
 * 但仍是 public 且未标 [JsonIgnore]，System.Text.Json 反射时照样序列化。
 * 新建实例两者恒为空串，因此桌面版实际落盘为 "StartSecond":"","EndSecond":""。
 * 为保证字节级往返，这里照常输出，不可「顺手清理」。
 *
 * TimeType：0=课间休息，>0 为该时间点内第几节课（1 起）。课程时段比较依赖它。
 *
 * 被 [JsonIgnore] 排除：Last（= EndTime - StartTime）、BreakNameText（空名时
 * 显示「课间休息」的运行期派生值）。
 */

import { Guid } from '../json/Guid';
import { TimeSpanValue } from '../json/TimeSpanValue';
import { JsonBoolean, JsonNode, JsonNull, JsonObject, JsonString } from '../json/JsonNode';
import { JsonValue } from '../json/JsonValue';
import { KeyedMap } from '../collections/KeyedMap';
import { ModelCodec } from './ModelCodec';
import { ActionSet } from './Automation/ActionSet';

/** TimeType：课间休息。 */
export const TIME_TYPE_BREAK: number = 0;

export class TimeLayoutItem {
  /**
   * 已废弃字段，恒为空串。保留仅为兼容落盘格式，代码中不应读写。
   */
  startSecond: string = '';

  /** 同 startSecond。 */
  endSecond: string = '';

  /** 时间段开始（当天起算的 TimeSpan）。 */
  startTime: TimeSpanValue = TimeSpanValue.zero();

  /** 时间段结束（当天起算的 TimeSpan）。 */
  endTime: TimeSpanValue = TimeSpanValue.zero();

  /** 0=课间休息；>0 表示该时间点内第几节课。 */
  timeType: number = 0;

  isHideDefault: boolean = false;

  /** 课间休息的默认课程 ID。 */
  defaultClassId: Guid = Guid.empty();

  /** 课间休息名称，空串时显示为「课间休息」。 */
  breakName: string = '';

  /** 该时间点触发的行动组。 */
  actionSet: ActionSet | undefined = undefined;

  attachedObjects: KeyedMap<JsonNode> = new KeyedMap<JsonNode>();

  isActive: boolean = false;

  constructor() {
  }

  /** 时间段持续时长（对应只读属性 Last）。 */
  duration(): TimeSpanValue {
    return this.endTime.subtract(this.startTime);
  }

  /** 是否为课间休息时间点。 */
  isBreak(): boolean {
    return this.timeType === TIME_TYPE_BREAK;
  }

  /** 休息名称的回退显示（对应只读属性 BreakNameText）。 */
  breakNameText(): string {
    return this.breakName.length === 0 ? '课间休息' : this.breakName;
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('StartSecond', new JsonString(this.startSecond));
    out.set('EndSecond', new JsonString(this.endSecond));
    out.set('StartTime', new JsonString(this.startTime.toString()));
    out.set('EndTime', new JsonString(this.endTime.toString()));
    out.set('TimeType', ModelCodec.intNode(this.timeType));
    out.set('IsHideDefault', new JsonBoolean(this.isHideDefault));
    out.set('DefaultClassId', ModelCodec.guidNode(this.defaultClassId));
    out.set('BreakName', new JsonString(this.breakName));
    if (this.actionSet === undefined) {
      out.set('ActionSet', new JsonNull());
    } else {
      out.set('ActionSet', this.actionSet.toJson());
    }
    out.set('AttachedObjects', ModelCodec.writeAttachedObjects(this.attachedObjects));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): TimeLayoutItem {
    const out: TimeLayoutItem = new TimeLayoutItem();
    out.startSecond = ModelCodec.string(node, 'StartSecond', '');
    out.endSecond = ModelCodec.string(node, 'EndSecond', '');
    out.startTime = TimeSpanValue.parseOrZero(JsonValue.asString(node.tryGet('StartTime'), '00:00:00'));
    out.endTime = TimeSpanValue.parseOrZero(JsonValue.asString(node.tryGet('EndTime'), '00:00:00'));
    out.timeType = ModelCodec.int(node, 'TimeType', 0);
    out.isHideDefault = ModelCodec.bool(node, 'IsHideDefault', false);
    out.defaultClassId = ModelCodec.guid(node, 'DefaultClassId');
    out.breakName = ModelCodec.string(node, 'BreakName', '');
    const actionSetNode: JsonObject | undefined = JsonValue.asObject(node.tryGet('ActionSet'));
    if (actionSetNode !== undefined) {
      out.actionSet = ActionSet.fromJson(actionSetNode);
    }
    out.attachedObjects = ModelCodec.readAttachedObjects(node);
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }

  /** 空时间点哨兵（对应 TimeLayoutItem.Empty）。 */
  static empty(): TimeLayoutItem {
    return new TimeLayoutItem();
  }
}
