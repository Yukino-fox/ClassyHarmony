/*
 * 隐藏规则的编辑操作。对应桌面版 RulesetControl 的那一堆增删改。
 *
 * 为什么要单独一个文件，而不像 ComponentLayoutMutations 那样挂在布局上
 * --------------------------------------------------------------------
 * 隐藏规则挂在两个地方（ComponentSettings 与 MainWindowLineSettings 各一份），
 * 两处的字段名与语义完全一样，桌面版也是两个类各写一套 UI 后共用同一个
 * RulesetControl。所以操作只认 Ruleset，不认宿主 —— 谁想改谁把 Ruleset 递进来，
 * 改完自己写回 hidingRules 节点。
 *
 * 就地改，不返回新对象
 * -------------------
 * 与 ComponentLayoutMutations 一致：调用方改完整个草稿存盘，不需要逐次
 * 接住返回值。返回值只表示「有没有改成」，用来拒绝非法下标。
 *
 * 设置怎么读写
 * ------------
 * 规则上的 Settings 是裸 JsonNode（未注册规则的设置要原样透传，见
 * Ruleset.ets 文件头）。所以这里只提供两个口子：
 *   - readSettings  解成强类型对象给界面绑
 *   - writeSettings 把改过的强类型对象序列化回去
 * 不提供「逐字段改裸节点」的路子：那样每个设置类都要写一遍字段映射，
 * 而界面本来就需要一个强类型对象来驱动控件。
 *
 * 换规则 id 时设置会被重置
 * ----------------------
 * 把「当前时间状态」改成「科目是」之后，原来那个 State:1 挂在新规则上
 * 毫无意义，桌面版是换 id 时连带把 Settings 换成新类型的默认值
 * （`RulesetControl` 换 id 后重新 new 一个 settingsType 实例）。
 * 照抄 —— 留着旧设置会让用户在界面上看到「科目是」配着一个时间状态的值。
 */

import {
  CurrentSubjectRuleSettings,
  CurrentWeatherRuleSettings,
  JsonNode,
  RainTimeRuleSettings,
  Rule,
  RuleGroup,
  Ruleset,
  RulesetLogicalMode,
  StringMatchingSettings,
  SunRiseSetRuleSettings,
  TimeStateRuleSettings,
  WindowStatusRuleSettings
} from 'common_shared';
import { RuleCatalog } from './RuleCatalog';

/** 桌面版编辑器里一组的默认形状：一个 And 组、组里一条空规则。 */
export class RulesetMutations {
  // ---- 规则集级 --------------------------------------------------------

  /** 设规则集的组合方式。 */
  static setRulesetMode(ruleset: Ruleset, mode: RulesetLogicalMode): boolean {
    if (ruleset.mode === mode) {
      return false;
    }
    ruleset.mode = mode;
    return true;
  }

  /** 设规则集是否整体取反。 */
  static setRulesetReversed(ruleset: Ruleset, isReversed: boolean): boolean {
    if (ruleset.isReversed === isReversed) {
      return false;
    }
    ruleset.isReversed = isReversed;
    return true;
  }

  // ---- 规则组 ----------------------------------------------------------

  /**
   * 插入一个组。index 等于 groups.length 时追加到最后。
   *
   * 新组给桌面版的默认形状（And + 一条空规则），不是空组 ——
   * 空组整组不参与求值，用户插进去会看到「什么都没发生」。
   */
  static addGroup(ruleset: Ruleset, index: number): boolean {
    if (index < 0 || index > ruleset.groups.length) {
      return false;
    }
    const group: RuleGroup = new RuleGroup();
    group.rules.push(new Rule());
    ruleset.groups.splice(index, 0, group);
    return true;
  }

  static removeGroup(ruleset: Ruleset, index: number): boolean {
    if (index < 0 || index >= ruleset.groups.length) {
      return false;
    }
    ruleset.groups.splice(index, 1);
    return true;
  }

  /** 组内组合方式。 */
  static setGroupMode(ruleset: Ruleset, groupIndex: number, mode: RulesetLogicalMode): boolean {
    const group: RuleGroup | undefined = RulesetMutations.groupAt(ruleset, groupIndex);
    if (group === undefined || group.mode === mode) {
      return false;
    }
    group.mode = mode;
    return true;
  }

  /** 整组取反。作用在组内循环之后的最终结果上，见 RuleEngine 文件头。 */
  static setGroupReversed(ruleset: Ruleset, groupIndex: number, isReversed: boolean): boolean {
    const group: RuleGroup | undefined = RulesetMutations.groupAt(ruleset, groupIndex);
    if (group === undefined || group.isReversed === isReversed) {
      return false;
    }
    group.isReversed = isReversed;
    return true;
  }

  /** 停用/启用整组。停用的组不参与求值，状态留「无」。 */
  static setGroupEnabled(ruleset: Ruleset, groupIndex: number, isEnabled: boolean): boolean {
    const group: RuleGroup | undefined = RulesetMutations.groupAt(ruleset, groupIndex);
    if (group === undefined || group.isEnabled === isEnabled) {
      return false;
    }
    group.isEnabled = isEnabled;
    return true;
  }

  // ---- 组内规则 --------------------------------------------------------

  /**
   * 插入一条规则。ruleId 为空串时插一条「还没挑」的规则。
   *
   * index 等于组内规则数时追加到最后。给新规则带上该 id 的默认设置 ——
   * 桌面版 AddRule 之后是 new settingsType()，效果一样。
   */
  static addRule(ruleset: Ruleset, groupIndex: number, index: number, ruleId: string): boolean {
    const group: RuleGroup | undefined = RulesetMutations.groupAt(ruleset, groupIndex);
    if (group === undefined || index < 0 || index > group.rules.length) {
      return false;
    }
    const rule: Rule = new Rule();
    rule.id = ruleId;
    rule.settings = RulesetMutations.settingsNodeOf(ruleId);
    group.rules.splice(index, 0, rule);
    return true;
  }

  static removeRule(ruleset: Ruleset, groupIndex: number, ruleIndex: number): boolean {
    const group: RuleGroup | undefined = RulesetMutations.groupAt(ruleset, groupIndex);
    if (group === undefined || ruleIndex < 0 || ruleIndex >= group.rules.length) {
      return false;
    }
    group.rules.splice(ruleIndex, 1);
    return true;
  }

  /** 组内换序。 */
  static moveRule(ruleset: Ruleset, groupIndex: number, from: number, to: number): boolean {
    const group: RuleGroup | undefined = RulesetMutations.groupAt(ruleset, groupIndex);
    if (group === undefined) {
      return false;
    }
    const last: number = group.rules.length;
    if (from < 0 || from >= last || to < 0 || to > last) {
      return false;
    }
    if (from === to) {
      return false;
    }
    const moved: Rule = group.rules.splice(from, 1)[0];
    // 移动完成后落点的语义：先摘再插，to 是摘掉之后的下标。
    group.rules.splice(to, 0, moved);
    return true;
  }

  /**
   * 换一条规则的 id，并把设置换成新 id 的默认设置。
   *
   * 换同一个 id 什么都不做（连带设置也不动）。
   */
  static setRuleId(ruleset: Ruleset, groupIndex: number, ruleIndex: number, ruleId: string): boolean {
    const rule: Rule | undefined = RulesetMutations.ruleAt(ruleset, groupIndex, ruleIndex);
    if (rule === undefined || rule.id === ruleId) {
      return false;
    }
    rule.id = ruleId;
    rule.settings = RulesetMutations.settingsNodeOf(ruleId);
    return true;
  }

  /** 单条规则取反。 */
  static setRuleReversed(ruleset: Ruleset, groupIndex: number, ruleIndex: number,
    isReversed: boolean): boolean {
    const rule: Rule | undefined = RulesetMutations.ruleAt(ruleset, groupIndex, ruleIndex);
    if (rule === undefined || rule.isReversed === isReversed) {
      return false;
    }
    rule.isReversed = isReversed;
    return true;
  }

  // ---- 设置读写 --------------------------------------------------------

  /**
   * 把规则上的 Settings 解成强类型对象给界面绑。
   *
   * id 未注册（陌生规则、插件规则）时返回一个空的 StringMatchingSettings，
   * 界面据此显示「这条规则在当前平台跑不了」并把设置控件置灰 ——
   * 界面照 RuleCatalog.supportOf 判就行，这里只保证不返回 undefined。
   */
  static readSettings(ruleset: Ruleset, groupIndex: number, ruleIndex: number): Object {
    const rule: Rule | undefined = RulesetMutations.ruleAt(ruleset, groupIndex, ruleIndex);
    if (rule === undefined) {
      return new StringMatchingSettings();
    }
    const decoded: Object | undefined = RuleCatalog.settingsOf(rule);
    return decoded === undefined ? new StringMatchingSettings() : decoded;
  }

  /**
   * 把改过的强类型设置写回规则的裸 Settings 节点。
   *
   * 认不出来的设置类型返回 false 并保持原样 —— 宁可保留用户在桌面版
   * 配好的东西，也不要因为这边多了一个不认识��类就把它抹掉。
   */
  static writeSettings(ruleset: Ruleset, groupIndex: number, ruleIndex: number,
    settings: Object): boolean {
    const rule: Rule | undefined = RulesetMutations.ruleAt(ruleset, groupIndex, ruleIndex);
    if (rule === undefined) {
      return false;
    }
    const node: JsonNode | undefined = RulesetMutations.nodeOf(settings);
    if (node === undefined) {
      return false;
    }
    rule.settings = node;
    return true;
  }

  // ---- 内部 ----------------------------------------------------------

  private static groupAt(ruleset: Ruleset, groupIndex: number): RuleGroup | undefined {
    if (groupIndex < 0 || groupIndex >= ruleset.groups.length) {
      return undefined;
    }
    return ruleset.groups[groupIndex];
  }

  private static ruleAt(ruleset: Ruleset, groupIndex: number, ruleIndex: number): Rule | undefined {
    const group: RuleGroup | undefined = RulesetMutations.groupAt(ruleset, groupIndex);
    if (group === undefined || ruleIndex < 0 || ruleIndex >= group.rules.length) {
      return undefined;
    }
    return group.rules[ruleIndex];
  }

  /** 该 id 的默认设置节点；没有默认（陌生 id）时给 null，与桌面版一致。 */
  private static settingsNodeOf(ruleId: string): JsonNode | undefined {
    const defaults: Object | undefined = RuleCatalog.defaultSettingsOf(ruleId);
    if (defaults === undefined) {
      return undefined;
    }
    return RulesetMutations.nodeOf(defaults);
  }

  /** 与 writeSettings 同一套识别，提取出公共部分。 */
  private static nodeOf(settings: Object): JsonNode | undefined {
    if (settings instanceof TimeStateRuleSettings) {
      return settings.toJson();
    }
    if (settings instanceof CurrentSubjectRuleSettings) {
      return settings.toJson();
    }
    if (settings instanceof CurrentWeatherRuleSettings) {
      return settings.toJson();
    }
    if (settings instanceof SunRiseSetRuleSettings) {
      return settings.toJson();
    }
    if (settings instanceof RainTimeRuleSettings) {
      return settings.toJson();
    }
    if (settings instanceof WindowStatusRuleSettings) {
      return settings.toJson();
    }
    if (settings instanceof StringMatchingSettings) {
      return settings.toJson();
    }
    return undefined;
  }
}
