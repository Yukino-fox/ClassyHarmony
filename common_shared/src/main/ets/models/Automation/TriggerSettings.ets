/*
 * 触发器设置项。对应 ClassIsland.Core/Models/Automation/TriggerSettings.cs
 *
 * 与 ActionItem 的对照
 * -------------------
 * 结构几乎一样（Id + 多态裸 Settings + IsActive），但有三处差别，抄错就静默丢配置：
 *
 * 1. Settings **不**带 JsonIgnore(WhenWritingNull)。ActionItem.Settings 为 null
 *    时整个字段被省略，TriggerSettings.Settings 一定会写出 "Settings":null。
 *    两处都照抄各自的行为，不统一。
 *
 * 2. AssociatedTriggerInfo / TriggerInstance 是 [JsonIgnore] / internal，不落盘。
 *    前者是「按 Id 从注册表反查出来的那个对象」，反查是运行时的事。
 *
 * 3. TriggerSettings 没有像 ActionItem 那样把 IsRevertEnabled / IsRevertActionItem
 *    标成「未启用但保留」的属性。这两个字段在 ActionItem 上是有的（恒 true / 恒
 *    false 的空 setter，标了 JsonIgnore）—— 那是历史包袱，鸿蒙侧不实现。
 *    后果是**恢复语义不一样**，见下。
 *
 * 恢复语义为什么不一样（照抄，别顺手改）
 * ------------------------------------
 * ActionItem.IsRevertEnabled 在 C# 里恒为 true（setter 是空的），
 * ActionService.RevertActionSetAsync 于是走到 `x.IsRevertEnabled` 分支，
 * 按 ActionInfo.IsRevertable 逐个决定能不能恢复 —— 而七个行动里只有
 * classisland.settings 覆写了 OnRevert，也就是只有它真能恢复。
 *
 * 鸿蒙侧照这个口径实现：ActionItem 上不存「是否可恢复」，可恢复性只看
 * ActionCatalog 里那一条的 isRevertable。
 */

import { JsonBoolean, JsonNode, JsonNull, JsonObject, JsonString } from '../../json/JsonNode';
import { ModelCodec } from '../ModelCodec';

/** 一个触发器的配置。 */
export class TriggerSettings {
  /** 触发器 ID，例如 classisland.lessons.onClass。空串表示还没挑。 */
  id: string = '';

  /** 触发器设置，按 id 决定实际形状（见 Triggers.ets）。 */
  settings: JsonNode | undefined = undefined;

  /** 来自 ObservableRecipient。 */
  isActive: boolean = false;

  constructor() {
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Id', new JsonString(this.id));
    out.set('Settings', this.settings === undefined ? new JsonNull() : this.settings);
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): TriggerSettings {
    const out: TriggerSettings = new TriggerSettings();
    out.id = ModelCodec.string(node, 'Id', '');
    const settings: JsonNode | undefined = node.tryGet('Settings');
    if (settings !== undefined) {
      out.settings = ModelCodec.cloneNode(settings);
    }
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }
}
