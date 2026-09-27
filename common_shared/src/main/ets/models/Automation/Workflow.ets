/*
 * 自动化工作流。对应 ClassIsland.Core/Models/Automation/Workflow.cs
 *
 * 一个工作流 = 「什么时候（触发器） + 满足什么条件（规则集，可选） + 做什么
 * （行动组）」。桌面版整份 Automations/{方案名}.json 就是一个 Workflow[]。
 *
 * 落盘顺序：Triggers, IsConditionEnabled, Ruleset, ActionSet, IsActive
 *
 * 三个字段的语义
 * --------------
 * - Triggers：任意一个触发即触发（不是全部）。桌面版 AutomationService
 *   给每个 TriggerSettings 都挂上同一个 TriggerTriggered 处理器。
 * - IsConditionEnabled：关着时 Ruleset 压根不求值。这与 Ruleset 本身「不满足
 *   就返回 false」是两件事 —— 关着 = 无条件触发，不是「必然不触发」。
 * - ActionSet：恒非 null（桌面版给的是 new()，不是 new()?）。所以
 *   workflow.ActionSet.IsEnabled 有值可读，不会 NullReference。
 *
 * Ruleset 在这里不是 Ruleset 类的实例而是**裸 JsonNode**
 * -------------------------------------------------------
 * 与 Ruleset.ets 头部那条纪律一致：声明类型是 `Ruleset.Ruleset`，但插件可以
 * 注册我们不认识的规则，其设置是多态裸 JSON。存 JsonNode 保证逐字节透传；
 * 需要求值时由 common_core 的 RuleEngine 按 Ruleset 的形状解析一份。
 */

import { JsonArray, JsonBoolean, JsonNode, JsonObject, JsonString } from '../../json/JsonNode';
import { JsonValue } from '../../json/JsonValue';
import { ModelCodec } from '../ModelCodec';
import { Ruleset } from '../Ruleset';
import { ActionSet } from './ActionSet';
import { TriggerSettings } from './TriggerSettings';

export class Workflow {
  /** 触发器列表，任一触发即触发。 */
  triggers: TriggerSettings[] = [];

  /** 是否启用规则集条件。关着时 ruleset 不参与。 */
  isConditionEnabled: boolean = false;

  /**
   * 条件规则集（裸 JSON 透传）。
   *
   * C# 里是 `Ruleset.Ruleset _ruleset = new()`，恒非 null，所以 JSON 里恒有
   * 这个字段（值可以是 {}）。这里 undefined 就表示 null，读时按空规则集算
   * （空规则集恒不成立，与桌面版 RulesetService 的 `Groups.Count<=0 → false` 一致）。
   */
  ruleset: JsonNode | undefined = new Ruleset().toJson();

  /** 行动组。恒非 null。 */
  actionSet: ActionSet = new ActionSet();

  /** 来自 ObservableRecipient。 */
  isActive: boolean = false;

  constructor() {
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    const triggers: JsonArray = new JsonArray();
    for (const trigger of this.triggers) {
      triggers.push(trigger.toJson());
    }
    out.set('Triggers', triggers);
    out.set('IsConditionEnabled', new JsonBoolean(this.isConditionEnabled));
    out.set('Ruleset', this.ruleset === undefined ? new Ruleset().toJson() : this.ruleset);
    out.set('ActionSet', this.actionSet.toJson());
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): Workflow {
    const out: Workflow = new Workflow();
    out.triggers = ModelCodec.readArray(node, 'Triggers', (item: JsonNode) => {
      // 元素类型不符时退化为默认实例，保住数组长度，避免静默丢触发器
      return TriggerSettings.fromJson(JsonValue.asObject(item) ?? new JsonObject());
    });
    out.isConditionEnabled = ModelCodec.bool(node, 'IsConditionEnabled', false);
    const ruleset: JsonNode | undefined = node.tryGet('Ruleset');
    if (ruleset !== undefined) {
      out.ruleset = ModelCodec.cloneNode(ruleset);
    }
    const actionSet: JsonNode | undefined = node.tryGet('ActionSet');
    out.actionSet = ActionSet.fromJson(JsonValue.asObject(actionSet) ?? new JsonObject());
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }

  /**
   * 拿一份可求值的 Ruleset 视图。
   *
   * Ruleset 存的是裸 JSON，所以求值前要先按 Ruleset 的形状解一份出来。
   * 解不动（不是对象、字段形状不对）时退回空规则集 —— 空规则集恒不成立，
   * 与「没配条件」表现一致，界面上也不会说「条件成立」。
   */
  rulesetView(): Ruleset {
    return this.ruleset === undefined ? new Ruleset() : Ruleset.parse(this.ruleset);
  }
}
