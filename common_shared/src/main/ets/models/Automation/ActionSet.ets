/*
 * 行动组。对应 ClassIsland.Shared/Models/Automation/ActionSet.cs
 *
 * 序列化顺序：
 *   Name, Actions, IsEnabled, IsRevertEnabled, Status, IsWorking, Guid, IsActive
 *
 * 三处易错点，均为桌面版实际行为而非笔误：
 *
 * 1. ActionItems 属性被 [property: JsonPropertyName("Actions")] 重命名为
 *    "Actions"，不是 "ActionItems"。
 *
 * 2. Status 走 ActionSetStatusJsonConverter，写出前把瞬时运行态折叠：
 *    Invoking -> Normal、Reverting -> IsOn。所以运行中的行动组落盘为 0 或 2。
 *
 * 3. IsWorking 是只读计算属性（Status is Invoking or Reverting），System.Text.Json
 *    仍会序列化它，且它读取的是**实时** Status 而非折叠后的值。因此一个正在
 *    执行的行动组会写出 "Status":0,"IsWorking":true 这种看似矛盾的组合。
 *    本实现按同一规则复刻。
 */

import { ActionSetStatus, ActionSetStatusCodec } from '../../enums/ActionSetStatus';
import { Guid } from '../../json/Guid';
import { JsonBoolean, JsonNode, JsonNumber, JsonObject, JsonString } from '../../json/JsonNode';
import { JsonValue } from '../../json/JsonValue';
import { ModelCodec } from '../ModelCodec';
import { ActionItem } from './ActionItem';

export class ActionSet {
  /** 行动组名。桌面版默认 "新行动组"。 */
  name: string = '新行动组';

  /** 行动项列表，落盘键名为 "Actions"。 */
  actions: ActionItem[] = [];

  isEnabled: boolean = true;

  isRevertEnabled: boolean = false;

  /** 实时状态，含运行态；落盘时会被折叠。 */
  status: number = ActionSetStatus.Normal;

  /** 行动组 Guid，用于标识设置叠层。 */
  guid: Guid = Guid.newGuid();

  /** 来自 ObservableRecipient。 */
  isActive: boolean = false;

  constructor() {
  }

  /** 是否处于运行态（对应只读计算属性 IsWorking）。 */
  isWorking(): boolean {
    return this.status === ActionSetStatus.Invoking || this.status === ActionSetStatus.Reverting;
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Name', new JsonString(this.name));
    out.set('Actions', ModelCodec.writeArray(this.actions, (item: ActionItem) => item.toJson()));
    out.set('IsEnabled', new JsonBoolean(this.isEnabled));
    out.set('IsRevertEnabled', new JsonBoolean(this.isRevertEnabled));
    out.set('Status', ModelCodec.intNode(ActionSetStatusCodec.toPersisted(this.status)));
    out.set('IsWorking', new JsonBoolean(this.isWorking()));
    out.set('Guid', new JsonString(this.guid.toString()));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): ActionSet {
    const out: ActionSet = new ActionSet();
    out.name = ModelCodec.string(node, 'Name', '新行动组');
    out.actions = ModelCodec.readArray(node, 'Actions', (item: JsonNode) => {
      // 元素类型不符时退化为默认实例，保住数组长度，避免静默丢项
      return ActionItem.fromJson(JsonValue.asObject(item) ?? new JsonObject());
    });
    out.isEnabled = ModelCodec.bool(node, 'IsEnabled', true);
    out.isRevertEnabled = ModelCodec.bool(node, 'IsRevertEnabled', false);

    const statusNode: JsonNode | undefined = node.tryGet('Status');
    if (statusNode instanceof JsonNumber) {
      out.status = ActionSetStatusCodec.parse(statusNode.value);
    } else if (statusNode instanceof JsonString) {
      out.status = ActionSetStatusCodec.parse(statusNode.value);
    } else {
      out.status = ActionSetStatus.Normal;
    }

    // IsWorking 是只读属性，落盘值不参与反序列化（与 System.Text.Json 一致），
    // 但 Status 折叠后可能处于 IsOn，运行态需由调用方按业务重新驱动。
    out.guid = ModelCodec.guid(node, 'Guid');
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }
}
