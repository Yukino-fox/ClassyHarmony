/*
 * 行动项。对应 ClassIsland.Shared/Models/Automation/ActionItem.cs
 *
 * 序列化顺序（System.Text.Json 按 C# 属性声明顺序，基类属性在后）：
 *   IsCompleted, Id, Settings, IsActive
 *
 * Settings 是多态裸 JSON（object?），桌面版带 JsonIgnoreCondition.WhenWritingNull，
 * 即为 null 时整个字段不出现。此处保留原节点并以同样规则省略。
 *
 * 被 [JsonIgnore] 排除的字段：IsRevertEnabled、IsRevertActionItem、Exception、
 * IsWorking、Progress、IsNewAdded。
 */

import { JsonBoolean, JsonNode, JsonObject, JsonString } from '../../json/JsonNode';
import { ModelCodec } from '../ModelCodec';

export class ActionItem {
  /** 行动已执行完成。 */
  isCompleted: boolean = false;

  /** 行动项 ID。 */
  id: string = '';

  /**
   * 行动项设置（多态裸 JSON，原样透传）。
   * undefined 等价于 C# 的 null，写出时整个字段被省略。
   */
  settings: JsonNode | undefined = undefined;

  /** 来自 ObservableRecipient，桌面版会持久化。 */
  isActive: boolean = false;

  constructor() {
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('IsCompleted', new JsonBoolean(this.isCompleted));
    out.set('Id', new JsonString(this.id));
    if (this.settings !== undefined) {
      out.set('Settings', this.settings);
    }
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): ActionItem {
    const out: ActionItem = new ActionItem();
    out.isCompleted = ModelCodec.bool(node, 'IsCompleted', false);
    out.id = ModelCodec.string(node, 'Id', '');
    const settings: JsonNode | undefined = node.tryGet('Settings');
    if (settings !== undefined) {
      out.settings = ModelCodec.cloneNode(settings);
    }
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }
}
