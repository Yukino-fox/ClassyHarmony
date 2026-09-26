/*
 * 指定日期的课表安排（Profile.OrderedSchedules 的值）。
 * 对应 ClassIsland.Shared/Models/Profile/OrderedSchedule.cs
 *
 * 序列化顺序：ClassPlanId, IsActive
 *
 * 宿主字典 Profile.OrderedSchedules 的键是 DateTime，以 ISO 8601 字符串承载，
 * 见 ModelCodec.readDateKeyMap。
 */

import { Guid } from '../json/Guid';
import { JsonBoolean, JsonObject } from '../json/JsonNode';
import { ModelCodec } from './ModelCodec';

export class OrderedSchedule {
  /** 该日适用的课表。 */
  classPlanId: Guid = Guid.empty();

  isActive: boolean = false;

  constructor() {
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('ClassPlanId', ModelCodec.guidNode(this.classPlanId));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): OrderedSchedule {
    const out: OrderedSchedule = new OrderedSchedule();
    out.classPlanId = ModelCodec.guid(node, 'ClassPlanId');
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }
}
