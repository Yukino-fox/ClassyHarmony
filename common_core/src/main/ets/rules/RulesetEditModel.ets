/*
 * 规则编辑器的行数据。
 *
 * 为什么要一层行数据而不是让界面直接遍历 Ruleset
 * -------------------------------------------
 * 界面上要显示的不只是规则集本身，还有**求值结论**：每条规则过没过、整组过没过、
 * 规则集过没过，以及「为什么没过」。这些信息在 RuleEngine 返回的轨迹里，
 * 而轨迹与规则集是两份同形但不同的数据。界面要同时读两份，就得自己做下标对齐 ——
 * 一旦 RulesetMutations 改出过一个空组或空规则，对齐就会漏，界面上出现
 * 「结论是假」旁边却一条规则都没有的情况。
 *
 * 所以在 core 里合成一份：每行自带它在规则集里的坐标、显示名、设置对象、
 * 判定状态与原因。界面只管按数组渲染，删一个规则之后整体重建，
 * 下标自然重排，不用增量维护。
 *
 * 与 ArkUI 的关系
 * --------------
 * 组件入参全用标量（约定见 PanelNodeView），行对象只在 @Local 里整体替换。
 * 这里的类不是 @ObservedV2，就地改字段不触发重绘 —— 所以每次改动都要
 * 重新调 build() 换掉整个数组。这与 P4/P5/P6 的行数据做法一致。
 */

import { t } from '../i18n/I18n';
import { Rule, RuleGroup, Ruleset, RulesetLogicalMode } from 'common_shared';
import { RuleCatalog, RuleSettingsKind, RuleSupport } from './RuleCatalog';
import { RuleContext, RuleEngine, RuleVerdict, RulesetVerdict, STATE_NONE } from './RuleEngine';

/** 规则选择器里的一项。 */
export class RuleChoiceRow {
  id: string = '';
  /** 显示名。未知 id 直接回显 id。 */
  displayName: string = '';
  /** 是否在当前平台能算。界面据此加标记。 */
  support: RuleSupport = RuleSupport.Unknown;
  settingsKind: RuleSettingsKind = RuleSettingsKind.None;
  /**
   * 选它会配什么设置。界面的副标题用这句告诉用户「选了之后要填什么」，
   * 比让用户选完看到一片空白控件要好。
   */
  settingsHint: string = '';
}

/** 规则集里的一条规则，摊平成一行。 */
export class RuleEditRow {
  /** 在规则集里的坐标。点删除/取反时原样传回 RulesetMutations。 */
  groupIndex: number = 0;
  ruleIndex: number = 0;
  ruleId: string = '';
  displayName: string = '';
  support: RuleSupport = RuleSupport.Unknown;
  settingsKind: RuleSettingsKind = RuleSettingsKind.None;
  /** 这条规则要配什么设置。界面上写在规则名下面当副标题。 */
  settingsHint: string = '';
  isReversed: boolean = false;
  /**
   * 强类型设置对象。界面拿它绑控件，改完用
   * RulesetMutations.writeSettings 写回。
   *
   * 未注册规则会是一个空的 StringMatchingSettings —— 界面照 support 判，
   * 知道这种情况下这个对象没有意义。
   */
  settings: Object = new Object();
  /**
   * 三态判定。0 无 / 1 假 / 2 真，取值同桌面版 BoolToRuleObjectState。
   * 组内被短路跳过时是 0，界面上显示成灰色「未判定」。
   */
  state: number = STATE_NONE;
  /** 判定原因代码。界面按它翻译。 */
  reason: string = '';
  /** 是不是因为取值非法被跳过的（Id 为空串）。这类行只显示「还没挑规则」。 */
  isUnchosen: boolean = false;
  /** 这行能不能编辑设置。陌生 id 不能。 */
  isSettingsEditable: boolean = false;
}

/** 规则集里的一个组，摊平成一块。 */
export class RuleGroupEditRow {
  groupIndex: number = 0;
  mode: RulesetLogicalMode = RulesetLogicalMode.And;
  isReversed: boolean = false;
  isEnabled: boolean = true;
  state: number = STATE_NONE;
  reason: string = '';
  rules: RuleEditRow[] = [];
}

/** 整个规则集的编辑态。 */
export class RulesetEditModel {
  mode: RulesetLogicalMode = RulesetLogicalMode.Or;
  isReversed: boolean = false;
  /** 求值结论。界面用它显示「当前会隐藏 / 当前不隐藏」。 */
  satisfied: boolean = false;
  state: number = STATE_NONE;
  reason: string = '';
  groups: RuleGroupEditRow[] = [];
  /** 规则集整体没有任何一组（Groups 为空）。求值恒为假，且取反不参与。 */
  isEmpty: boolean = true;
}

export class RulesetEditor {
  /**
   * 规则选择器的数据源。一次建好，界面反复用。
   *
   * 静态持有：这张表是纯数据、不可变，跟 core 的可重入约束不冲突
   * （可重入约束针对的是**跨实例共享的可变状态**，这张表改了也没人看得见）。
   * 这样每次展开下拉不必重新拼一遍 13 项。
   */
  private static choicesCache: RuleChoiceRow[] = [];

  /** 13 条规则的选项，含「还没挑」这一项。 */
  static choices(): RuleChoiceRow[] {
    if (RulesetEditor.choicesCache.length > 0) {
      return RulesetEditor.choicesCache;
    }
    const none: RuleChoiceRow = new RuleChoiceRow();
    none.id = '';
    none.displayName = t('re_no_rule_chosen');
    none.support = RuleSupport.Unknown;
    none.settingsHint = t('re_pick_rule_hint');
    const out: RuleChoiceRow[] = [none];
    for (const info of RuleCatalog.all()) {
      const row: RuleChoiceRow = new RuleChoiceRow();
      row.id = info.id;
      row.displayName = info.name;
      row.support = info.support;
      row.settingsKind = info.settingsKind;
      row.settingsHint = RulesetEditor.settingsHintOf(info.settingsKind, info.support);
      out.push(row);
    }
    RulesetEditor.choicesCache = out;
    return out;
  }

  /**
   * 合成编辑态。
   *
   * @param ruleset 当前草稿。空组 / 空规则 / 停用的组都照实收进来。
   * @param context 求值上下文。传 undefined 时不求值，所有 state 都是「无」——
   *               还没选课表时（编辑档案之前）界面仍然能改，只是看不到结论。
   */
  static build(ruleset: Ruleset | undefined, context: RuleContext | undefined): RulesetEditModel {
    const out: RulesetEditModel = new RulesetEditModel();
    if (ruleset === undefined) {
      out.reason = 'noRuleset';
      return out;
    }
    out.mode = ruleset.mode;
    out.isReversed = ruleset.isReversed;
    out.isEmpty = ruleset.groups.length === 0;

    const verdict: RulesetVerdict | undefined =
      context === undefined ? undefined : RuleEngine.evaluate(ruleset, context);
    out.satisfied = verdict !== undefined && verdict.satisfied;
    out.state = verdict === undefined ? STATE_NONE : verdict.state;
    if (verdict !== undefined) {
      out.reason = verdict.reason;
    }

    for (let g: number = 0; g < ruleset.groups.length; g++) {
      const group: RuleGroup = ruleset.groups[g];
      const groupRow: RuleGroupEditRow = new RuleGroupEditRow();
      groupRow.groupIndex = g;
      groupRow.mode = group.mode;
      groupRow.isReversed = group.isReversed;
      groupRow.isEnabled = group.isEnabled;
      if (verdict !== undefined) {
        groupRow.state = verdict.groups[g].state;
        groupRow.reason = verdict.groups[g].reason;
      }
      for (let i: number = 0; i < group.rules.length; i++) {
        const rule: Rule = group.rules[i];
        const ruleRow: RuleEditRow = new RuleEditRow();
        ruleRow.groupIndex = g;
        ruleRow.ruleIndex = i;
        ruleRow.ruleId = rule.id;
        ruleRow.isReversed = rule.isReversed;
        ruleRow.isUnchosen = rule.id.length === 0;
        const info = RuleCatalog.find(rule.id);
        if (info === undefined) {
          ruleRow.displayName = rule.id.length === 0 ? t('re_no_rule_chosen') : rule.id;
          ruleRow.support = RuleSupport.Unknown;
          ruleRow.settingsHint = t('re_unknown_rule_hint');
        } else {
          ruleRow.displayName = info.name;
          ruleRow.support = info.support;
          ruleRow.settingsKind = info.settingsKind;
          ruleRow.settingsHint = RulesetEditor.settingsHintOf(info.settingsKind, info.support);
        }
        ruleRow.isSettingsEditable = ruleRow.support === RuleSupport.Implemented;
        // 未注册规则解不出设置，给一个空对象即可：界面照 isSettingsEditable
        // 判成 false，根本不会去读它。
        const decoded: Object | undefined = RuleCatalog.settingsOf(rule);
        ruleRow.settings = decoded === undefined ? new Object() : decoded;
        if (verdict !== undefined) {
          const ruleVerdict: RuleVerdict = verdict.groups[g].rules[i];
          ruleRow.state = ruleVerdict.state;
          ruleRow.reason = ruleVerdict.reason;
        }
        groupRow.rules.push(ruleRow);
      }
      out.groups.push(groupRow);
    }
    return out;
  }

  /** 这类规则要配什么设置。界面上写在规则名下面当副标题。 */
  private static settingsHintOf(kind: RuleSettingsKind, support: RuleSupport): string {
    if (support === RuleSupport.Unsupported) {
      return t('re_hint_unsupported');
    }
    if (kind === RuleSettingsKind.StringMatching) {
      return t('re_hint_string');
    }
    if (kind === RuleSettingsKind.TimeState) {
      return t('re_hint_time_state');
    }
    if (kind === RuleSettingsKind.CurrentSubject) {
      return t('re_hint_subject');
    }
    if (kind === RuleSettingsKind.CurrentWeather) {
      return t('re_hint_weather');
    }
    if (kind === RuleSettingsKind.RainTime) {
      return t('re_hint_rain_time');
    }
    if (kind === RuleSettingsKind.SunRiseSet) {
      return t('re_hint_sun_rise_set');
    }
    if (kind === RuleSettingsKind.WindowStatus) {
      return t('re_hint_window_status');
    }
    return t('re_hint_no_settings');
  }
}
