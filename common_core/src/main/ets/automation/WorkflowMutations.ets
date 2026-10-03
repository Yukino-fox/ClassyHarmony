/*
 * 自动化配置的编辑操作。
 *
 * 与 RulesetMutations 同一条纪律：只做「改数据」，不做「判定」，也不碰界面。
 * 界面要的东西（哪些行动能不能回滚、哪个触发器有没有实现）从两个 Catalog 查，
 * 不在这里另抄一份 —— 抄一份就会有两份不同步的真相。
 *
 * 为什么 action item 上没有「可恢复」开关
 * ------------------------------------
 * 桌面版 ActionItem 上那两个字段是**未启用**的：IsRevertEnabled 恒为 true、
 * IsRevertActionItem 恒为 false，setter 都是空的（源码里那两行 ObservableProperty
 * 被注释掉了）。所以鸿蒙侧也不加这个开关 —— 加了就得回答「勾上有什么用」，
 * 而答案在桌面版那儿是「没用」。
 *
 * 真正决定能不能回滚的是两件事，都不在 ActionItem 上：
 *   行动组层面 ActionSet.IsRevertEnabled（这个是有的、也真的生效）
 *   行动层面 ActionCatalog 里那条的 isRevertable（只有 classicsettings 一条）
 */

import {
  ActionItem,
  ActionSetStatus,
  CronTriggerSettings,
  Guid,
  JsonArray,
  JsonNode,
  JsonObject,
  ModifyAppSettingsActionSettings,
  NotificationActionSettings,
  PreTimePointTriggerSettings,
  Ruleset,
  RunActionSettings,
  SignalTriggerSettings,
  SleepActionSettings,
  TriggerSettings,
  TrayMenuTriggerSettings,
  UriTriggerSettings,
  Workflow
} from 'common_shared';
import { ActionCatalog, ActionSettingsKind } from './ActionCatalog';
import { TriggerCatalog, TriggerSettingsKind } from './TriggerCatalog';
import { t } from '../i18n/I18n';

/** 行动组名的默认文案，与桌面版 ActionSet._name 的初值一致。 */
export const DEFAULT_ACTION_SET_NAME: string = t('wf_default_action_set');

export class WorkflowMutations {
  /* ---- 读 ---- */

  /**
   * 取某个工作流里第 index 个触发器的设置。
   *
   * 未注册的 id 返回 undefined —— 与 RulesetMutations.readSettings 一样不给
   * 「空设置」冒充：那会让界面给一个陌生触发器显示别人的设置默认值。
   */
  static readTriggerSettings(workflow: Workflow, triggerIndex: number): Object | undefined {
    if (triggerIndex < 0 || triggerIndex >= workflow.triggers.length) {
      return undefined;
    }
    return TriggerCatalog.settingsOf(workflow.triggers[triggerIndex]);
  }

  /**
   * 取某个行动组里第 index 个行动的设置。
   *
   * 与读触发器设置一个口径：陌生 id 给 undefined，不拿默认设置顶替。
   */
  static readActionSettings(workflow: Workflow, actionIndex: number): Object | undefined {
    if (actionIndex < 0 || actionIndex >= workflow.actionSet.actions.length) {
      return undefined;
    }
    return ActionCatalog.settingsOf(workflow.actionSet.actions[actionIndex]);
  }

  /**
   * 这个行动组恢复时会跑哪些行动。
   *
   * 桌面版 RevertActionSetAsync 遍历 `x.IsRevertActionItem || x.IsRevertEnabled`，
   * 而 IsRevertActionItem 恒 false、IsRevertEnabled 恒 true，所以实际上遍历全部，
   * 再逐条问 `ActionInfos[id].IsRevertable` 决定跑不跑。这里照抄这个结果：
   * 遍历全部，只留可恢复的。返回下标，给界面标出「这一条会被回滚」。
   */
  static revertableActionIndexes(workflow: Workflow): number[] {
    const out: number[] = [];
    const actions: ActionItem[] = workflow.actionSet.actions;
    for (let i: number = 0; i < actions.length; i++) {
      if (ActionCatalog.isRevertable(actions[i].id)) {
        out.push(i);
      }
    }
    return out;
  }

  /* ---- 写：条件 ---- */

  static setConditionEnabled(workflow: Workflow, enabled: boolean): void {
    workflow.isConditionEnabled = enabled;
  }

  static setRuleset(workflow: Workflow, ruleset: Ruleset): void {
    workflow.ruleset = ruleset.toJson();
  }

  /* ---- 写：行动组 ---- */

  static setActionSetName(workflow: Workflow, name: string): void {
    workflow.actionSet.name = name;
  }

  static setActionSetEnabled(workflow: Workflow, enabled: boolean): void {
    workflow.actionSet.isEnabled = enabled;
  }

  static setActionSetRevertEnabled(workflow: Workflow, enabled: boolean): void {
    workflow.actionSet.isRevertEnabled = enabled;
    // 桌面版 OnIsRevertEnabledChanged：关掉恢复时若正处于「等待恢复」，
    // 状态回 Normal。这一步不做的话，关掉恢复之后状态会永远卡在 2，
    // 而下次触发时 IsRevertEnabled 判据已经不看了 —— 看着像还在生效。
    if (!enabled && workflow.actionSet.status === ActionSetStatus.IsOn) {
      workflow.actionSet.status = ActionSetStatus.Normal;
    }
  }

  /* ---- 写：触发器 ---- */

  static addTrigger(workflow: Workflow, id: string): number {
    const trigger: TriggerSettings = new TriggerSettings();
    trigger.id = id;
    const defaults = TriggerCatalog.defaultSettingsOf(id);
    if (defaults !== undefined) {
      trigger.settings = WorkflowMutations.settingsToNode(defaults);
    }
    workflow.triggers.push(trigger);
    return workflow.triggers.length - 1;
  }

  static removeTrigger(workflow: Workflow, triggerIndex: number): boolean {
    if (triggerIndex < 0 || triggerIndex >= workflow.triggers.length) {
      return false;
    }
    workflow.triggers.splice(triggerIndex, 1);
    return true;
  }

  /**
   * 换触发器类型。
   *
   * 设置重置为新类型的默认值 —— 照抄桌面版 ActivateTrigger 的
   * `if (settingsReal?.GetType() != settingsType) settingsReal = new(settingsType)`。
   * 不重置的话，「上课时 60 秒前」会变成「cron 表达式 60 秒前」这种读不通的东西。
   */
  static setTriggerId(workflow: Workflow, triggerIndex: number, id: string): boolean {
    if (triggerIndex < 0 || triggerIndex >= workflow.triggers.length) {
      return false;
    }
    const trigger: TriggerSettings = workflow.triggers[triggerIndex];
    if (trigger.id === id) {
      return true;
    }
    trigger.id = id;
    const defaults = TriggerCatalog.defaultSettingsOf(id);
    if (defaults === undefined) {
      trigger.settings = undefined;
    } else {
      trigger.settings = WorkflowMutations.settingsToNode(defaults);
    }
    return true;
  }

  static writeTriggerSettings(workflow: Workflow, triggerIndex: number, value: Object): boolean {
    if (triggerIndex < 0 || triggerIndex >= workflow.triggers.length) {
      return false;
    }
    workflow.triggers[triggerIndex].settings = WorkflowMutations.settingsToNode(value);
    return true;
  }

  /* ---- 写：行动 ---- */

  static addAction(workflow: Workflow, id: string): number {
    const item: ActionItem = new ActionItem();
    item.id = id;
    const defaults = ActionCatalog.defaultSettingsOf(id);
    if (defaults !== undefined) {
      item.settings = WorkflowMutations.settingsToNode(defaults);
    }
    workflow.actionSet.actions.push(item);
    return workflow.actionSet.actions.length - 1;
  }

  static removeAction(workflow: Workflow, actionIndex: number): boolean {
    const actions: ActionItem[] = workflow.actionSet.actions;
    if (actionIndex < 0 || actionIndex >= actions.length) {
      return false;
    }
    actions.splice(actionIndex, 1);
    return true;
  }

  /** 换行动类型。设置同样重置为新类型的默认值。 */
  static setActionId(workflow: Workflow, actionIndex: number, id: string): boolean {
    const actions: ActionItem[] = workflow.actionSet.actions;
    if (actionIndex < 0 || actionIndex >= actions.length) {
      return false;
    }
    if (actions[actionIndex].id === id) {
      return true;
    }
    actions[actionIndex].id = id;
    const defaults = ActionCatalog.defaultSettingsOf(id);
    if (defaults === undefined) {
      actions[actionIndex].settings = undefined;
    } else {
      actions[actionIndex].settings = WorkflowMutations.settingsToNode(defaults);
    }
    return true;
  }

  static writeActionSettings(workflow: Workflow, actionIndex: number, value: Object): boolean {
    const actions: ActionItem[] = workflow.actionSet.actions;
    if (actionIndex < 0 || actionIndex >= actions.length) {
      return false;
    }
    actions[actionIndex].settings = WorkflowMutations.settingsToNode(value);
    return true;
  }

  /* ---- 运行状态 ---- */

  /**
   * 记一次「跑完了」，按桌面版 SetEndRunning 的规则算出新状态。
   *
   * 桌面版那条规则是 `!被中断 && 是触发 && IsRevertEnabled ? IsOn : Normal`，
   * 恢复时同理（IsRevertEnabled 关着就回 Normal）。这里把 isRevert 显式传进来，
   * 不从 Status 反推 —— 反推不了，因为调用方可能正在把 Status 改掉。
   */
  static statusAfterRun(workflow: Workflow, isRevert: boolean, wasCancelled: boolean): number {
    if (wasCancelled) {
      // 桌面版：true when Status is Invoking → Normal；is Reverting → IsOn
      return workflow.actionSet.status === ActionSetStatus.Reverting
        ? ActionSetStatus.IsOn
        : ActionSetStatus.Normal;
    }
    if (!workflow.actionSet.isRevertEnabled) {
      return ActionSetStatus.Normal;
    }
    return isRevert ? ActionSetStatus.Normal : ActionSetStatus.IsOn;
  }

  /* ---- 新建 ---- */

  /**
   * 新建一个空工作流。
   *
   * 桌面版没有「新建」这一说（配置文件是手写的），这里给编辑页用。给一份默认
   * 规则集而不是空对象，是为了让 IsConditionEnabled 打开时立刻有东西可看。
   */
  static newWorkflow(): Workflow {
    const out: Workflow = new Workflow();
    out.ruleset = new Ruleset().toJson();
    out.actionSet.name = DEFAULT_ACTION_SET_NAME;
    out.actionSet.guid = Guid.newGuid();
    return out;
  }

  /* ---- 设置对象与 JSON 之间的转换 ---- */

  /**
   * 把一份强类型设置转成要落盘的 JSON 节点。
   *
   * 每个设置类都恰好有 toJson()。这里用一张显式表而不是「找 toJson 方法」——
   * 后者在 ArkTS 里要么写不出类型安全的写法，要么就得引反射，那就把整个 core
   * 的「无反射」纪律破掉，而它换来的是每次多写一个 case。
   */
  static settingsToNode(value: Object): JsonNode {
    // 已经是节点树的原样带走（复制一份）。
    //
    // 声明式触发器与行动的默认设置就是裸 JsonObject（TriggerCatalog.defaultSettingsOf
    // 与 ActionCatalog.defaultSettingsOf 的 Plugin 分支直接返回清单条目转出来的节点）。
    // 不接这一支的话，新增一个声明式触发器会写进一个**空对象** —— 用户在编辑器里
    // 看到的是「没设日程」，而清单里明明写了每天 7 点。
    if (value instanceof JsonObject) {
      return value;
    }
    if (value instanceof JsonArray) {
      return value;
    }
    if (value instanceof CronTriggerSettings) {
      return value.toJson();
    }
    if (value instanceof PreTimePointTriggerSettings) {
      return value.toJson();
    }
    if (value instanceof SignalTriggerSettings) {
      return value.toJson();
    }
    if (value instanceof TrayMenuTriggerSettings) {
      return value.toJson();
    }
    if (value instanceof UriTriggerSettings) {
      return value.toJson();
    }
    if (value instanceof ModifyAppSettingsActionSettings) {
      return value.toJson();
    }
    if (value instanceof NotificationActionSettings) {
      return value.toJson();
    }
    if (value instanceof RunActionSettings) {
      return value.toJson();
    }
    if (value instanceof SleepActionSettings) {
      return value.toJson();
    }
    return new JsonObject();
  }

  /**
   * 一份设置是不是「没配过」。
   *
   * 界面用它决定要不要把控件收起来：新建出来的一堆默认值与「用户自己配成
   * 刚好等于默认值」在数据上分不开，桌面版也分不开。这里不试图分 —— 分不开
   * 就按「配过」处理，控件一律显示。多显示几个控件不会出错，藏起来才会。
   */
  static isSettingsTouched(node: JsonNode | undefined): boolean {
    return node !== undefined;
  }
}

/** 供界面做「新建一个带默认设置的 X」时用的空白清单。 */
export class AutomationDefaults {
  /**
   * 预热所有默认设置对象。
   *
   * 这不是给界面调的，是为了在开发期就暴露一件事：两个 Catalog 里的
   * settingsKind 与 settingsToNode 的分支必须一一对应，漏一个的话
   * 「新建这一条 → 保存 → 再打开」会把它变成空对象。这里在测试里跑一遍，
   * 漏了立刻炸。
   */
  static verifyKinds(): string[] {
    const problems: string[] = [];
    for (const info of TriggerCatalog.all()) {
      const made = TriggerCatalog.defaultSettingsOf(info.id);
      if (info.settingsKind === TriggerSettingsKind.None) {
        if (made !== undefined) {
          problems.push(`${info.id} 标着无设置却造出了默认设置`);
        }
        continue;
      }
      if (made === undefined) {
        problems.push(`${info.id} 标着要设置却造不出默认设置`);
        continue;
      }
      const node = WorkflowMutations.settingsToNode(made);
      if (!(node instanceof JsonObject)) {
        problems.push(`${info.id} 的默认设置转不成对象`);
      }
    }
    for (const info of ActionCatalog.all()) {
      const made = ActionCatalog.defaultSettingsOf(info.id);
      if (info.settingsKind === ActionSettingsKind.None) {
        if (made !== undefined) {
          problems.push(`${info.id} 标着无设置却造出了默认设置`);
        }
        continue;
      }
      if (made === undefined) {
        problems.push(`${info.id} 标着要设置却造不出默认设置`);
        continue;
      }
      const node = WorkflowMutations.settingsToNode(made);
      if (!(node instanceof JsonObject)) {
        problems.push(`${info.id} 的默认设置转不成对象`);
      }
    }
    return problems;
  }
}
