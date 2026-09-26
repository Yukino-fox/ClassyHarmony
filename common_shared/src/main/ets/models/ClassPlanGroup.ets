/*
 * 课表组（用于按场景切换课表，如「平时」「考试周」）。
 * 对应 ClassIsland.Shared/Models/Profile/ClassPlanGroup.cs
 *
 * 序列化顺序：Name, IsGlobal, IsActive
 */

import { Guid } from '../json/Guid';
import { JsonBoolean, JsonObject, JsonString } from '../json/JsonNode';
import { ModelCodec } from './ModelCodec';

export class ClassPlanGroup {
  name: string = '新课表群';
  isGlobal: boolean = false;
  isActive: boolean = false;

  constructor() {
  }

  /**
   * 桌面版内置的默认课表组 ID，新建档案时 SelectedClassPlanGroupId 取此值。
   * 源为 ClassPlanGroup.DefaultGroupGuid，此处按 Guid 规范格式归一为小写。
   */
  static defaultGroupGuid(): Guid {
    return Guid.fromCanonical('acaf4ef0-e261-4262-b941-34ea93cb4369');
  }

  /**
   * 全局课表组 ID，即 Guid.Empty。
   * 归属此群的课表在任何所选课表群下都生效，且在选择时优先级最高。
   * 源为 ClassPlanGroup.GlobalGroupGuid。
   */
  static globalGroupGuid(): Guid {
    return Guid.empty();
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Name', new JsonString(this.name));
    out.set('IsGlobal', new JsonBoolean(this.isGlobal));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): ClassPlanGroup {
    const out: ClassPlanGroup = new ClassPlanGroup();
    out.name = ModelCodec.string(node, 'Name', '新课表群');
    out.isGlobal = ModelCodec.bool(node, 'IsGlobal', false);
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }
}
