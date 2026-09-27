/*
 * 规则求值器。对应 ClassIsland/Services/RulesetService.cs。
 *
 * 三态，不是两态
 * ------------
 * 桌面版 IsRuleSatisfied 返回 bool?：null 表示「这条规则还没挑」（Id 为空串），
 * 与「挑了但不成立」是两回事。区别在求值时是实打实的：
 *   - 组内：null 的规则被 continue 跳过，既不贡献 true 也不贡献 false，
 *     连 IsReversed 都不作用在它身上；
 *   - 组级：一个组里如果没有任何一条挑了规则，整组返回 null，
 *     整组在 ruleset 层面被跳过（而不是当作 false 把 And 拉低）。
 * 少一个状态，「还没配完的组」就会把整个规则集判死 —— 那正是新建规则集时
 * 界面上所有东西都变灰的原因。
 *
 * 求值顺序与短路
 * --------------
 * 逐字照抄桌面版，包括几处「看起来该优化但不能动」的地方：
 *   - 组内 And 遇到假立刻 break，Or 遇到真立刻 break；break 之后的规则保持
 *     「无」状态，编辑器里显示为未判定。
 *   - ruleset 级同理，And 遇到假 break、Or 遇到真 break。
 *   - 组的 IsReversed 在组内循环**之后**才异或，所以「整组取反」是对最终结果
 *     取反，不是对每条规则取反。
 *   - ruleset 的 IsReversed 在组循环之后异或，但**空组列表是例外**：
 *     `if (Groups.Count <= 0) { State = false; return false; }` 直接返回，
 *     取反没被应用。照抄 —— 这是桌面版真实行为，改掉会让「空规则集 + 取反」
 *     在两端给出不同答案。
 *
 * 为什么返回轨迹而不是就地写 State
 * ------------------------------
 * 桌面版在 Rule / RuleGroup / Ruleset 上各挂一个 [JsonIgnore] int State，
 * 求值时顺手写进去，编辑器读它显示「哪条没过」。那是模型对象上的运行时可变状态，
 * 与本工程「core 无跨实例可变单例、纯函数」的约束不合；这里改成每次求值返回一份
 * 与规则集同构的轨迹对象。
 * 顺带多了一样桌面版没有的东西：每条判定带一个 reason 代码。桌面版「规则没实现」
 * 和「规则没匹配上」都是 State=1，用户对着一个恒假的天气规则反复调参数也看不出
 * 问题在哪。分出这两个原因之后，编辑器可以直接告诉用户「这条规则在当前平台
 * 跑不了」，省掉一整类「以为是自己配错了」的报障。
 *
 * 轨迹的形状
 * ----------
 * 与规则集严格同形：RulesetVerdict.groups[i] 对应 groups[i]，
 * RuleGroupVerdict.rules[j] 对应 rules[j]——**包括被短路跳过的那几条**。
 * 形状先铺好再求值，短路掉的项留 STATE_NONE 占位，界面按数组下标直接对齐，
 * 不需要在界面上做「哪几条被跳过」的重新推算。
 */

import {
  CurrentSubjectRuleSettings,
  DateTimeValue,
  Guid,
  Profile,
  Rule,
  RuleGroup,
  RuleIds,
  Ruleset,
  RulesetLogicalMode,
  Subject,
  TimeState,
  TimeStateRuleSettings
} from 'common_shared';
import { LessonsSnapshot } from '../engine/LessonsSnapshot';
import { RuleCatalog, RuleInfo, RuleSupport } from './RuleCatalog';

/**
 * 判定状态。取值与桌面版 RulesetService.BoolToRuleObjectState 一致：
 * true→2，false→1，null→0。
 *
 * 沿用这三个数而不是换成 true/false/undefined：界面上的三态图标、
 * 「未判定」的灰态、以及将来若要与桌面版同文件比对，都靠它对齐。
 */
export const STATE_NONE: number = 0;
export const STATE_FALSE: number = 1;
export const STATE_TRUE: number = 2;

/**
 * 判定原因代码。界面按它翻译文案，core 里不写界面文案。
 *
 * 一律用字符串常量而不是枚举：core 不该知道界面的词表，
 * 而字符串在 JSON 化后能自解释，比裸数字好排查。
 */
export class RuleReason {
  /** Id 为空串：这条规则还没挑。 */
  static readonly NotChosen: string = 'notChosen';
  /** Id 在注册表里查不到（陌生 id，或桌面版插件注册的规则）。 */
  static readonly UnknownRule: string = 'unknownRule';
  /** 已注册，但鸿蒙侧无对应物（窗口类 / 天气类规则）。 */
  static readonly NotImplemented: string = 'notImplemented';
  /** 处理器执行时抛了异常。 */
  static readonly HandlerThrew: string = 'handlerThrew';
  /** 求值通过。 */
  static readonly Matched: string = 'matched';
  /** 求值不通过。 */
  static readonly NotMatched: string = 'notMatched';
  /** 组内一条挑过的规则都没有，整组不参与。 */
  static readonly GroupEmpty: string = 'groupEmpty';
  /** 规则集压根没配。 */
  static readonly NoRuleset: string = 'noRuleset';
  /** 组被停用，整组不参与。 */
  static readonly GroupDisabled: string = 'groupDisabled';
}

/** 求值输入。 */
export class RuleContext {
  /** 求值时刻。 */
  now: DateTimeValue = DateTimeValue.now();
  /**
   * 课表状态快照。
   *
   * 必须与 profile 同源：三个科目类规则靠引用相等来判「是不是这门课」
   * （桌面版 `CurrentSubject == subject` 就是引用相等），跨档案比必然为假。
   * 正常调用都从 LessonsEngine.compute 出来的快照，不会跨。
   */
  snapshot: LessonsSnapshot = new LessonsSnapshot();
  /** 与 snapshot 同源的档案。给科目类规则按 id 查科目用。 */
  profile: Profile | undefined = undefined;
}

/** 单条规则的判定结果。 */
export class RuleVerdict {
  state: number = STATE_NONE;
  reason: string = RuleReason.NotChosen;
}

/** 一组规则的判定结果。 */
export class RuleGroupVerdict {
  state: number = STATE_NONE;
  reason: string = RuleReason.GroupEmpty;
  /** 与原组内规则一一对应，含被短路跳过的那些（state 保持 STATE_NONE）。 */
  rules: RuleVerdict[] = [];
  /** 原组的 IsEnabled。界面用它显示「已停用」，避免与「未判定」混淆。 */
  isEnabled: boolean = true;
}

/** 整个规则集的判定结果。 */
export class RulesetVerdict {
  /** 求值结论。界面拿它决定「这一行 / 这个组件要不要隐藏」。 */
  satisfied: boolean = false;
  state: number = STATE_NONE;
  reason: string = RuleReason.NoRuleset;
  /** 与原规则集内规则组一一对应。 */
  groups: RuleGroupVerdict[] = [];
}

export class RuleEngine {
  /**
   * 求值一个规则集。
   *
   * ruleset 为 undefined（配置里没写 HidingRules）时返回 satisfied=false、
   * reason=NoRuleset —— 对应桌面版
   * `if (HidingRules != null && IsRulesetSatisfied(HidingRules))` 的前半段。
   *
   * 返回值是纯数据，重复调用无副作用；同一个 ruleset 可以被面板、编辑器、
   * 求值预览同时拿去用，互不干扰（桌面版靠写在对象上的 State 实现同一件事，
   * 那个状态下两个消费者会互相覆盖）。
   */
  static evaluate(ruleset: Ruleset | undefined, context: RuleContext): RulesetVerdict {
    const out: RulesetVerdict = new RulesetVerdict();
    if (ruleset === undefined) {
      return out;
    }

    // 先把轨迹的形状铺好，这样被短路跳过的部分也留得住位置。
    for (const group of ruleset.groups) {
      const groupVerdict: RuleGroupVerdict = new RuleGroupVerdict();
      groupVerdict.isEnabled = group.isEnabled;
      for (let i: number = 0; i < group.rules.length; i++) {
        groupVerdict.rules.push(new RuleVerdict());
      }
      out.groups.push(groupVerdict);
    }

    // 桌面版这里直接 return false，IsReversed 不参与。照抄，理由见文件头注。
    if (ruleset.groups.length === 0) {
      out.state = STATE_FALSE;
      out.reason = RuleReason.GroupEmpty;
      return out;
    }

    let satisfied: boolean = ruleset.mode === RulesetLogicalMode.And;
    for (let i: number = 0; i < ruleset.groups.length; i++) {
      const group: RuleGroup = ruleset.groups[i];
      const groupVerdict: RuleGroupVerdict = out.groups[i];
      if (!group.isEnabled) {
        // 停用的组整组不参与，状态留 STATE_NONE。
        groupVerdict.reason = RuleReason.GroupDisabled;
        continue;
      }
      const result: boolean | undefined = RuleEngine.evaluateGroup(group, groupVerdict, context);
      if (result === undefined) {
        continue;
      }
      if (!result && ruleset.mode === RulesetLogicalMode.And) {
        satisfied = false;
        break;
      }
      if (result && ruleset.mode === RulesetLogicalMode.Or) {
        satisfied = true;
        break;
      }
    }
    if (ruleset.isReversed) {
      satisfied = !satisfied;
    }
    out.satisfied = satisfied;
    out.state = satisfied ? STATE_TRUE : STATE_FALSE;
    out.reason = RuleReason.Matched;
    return out;
  }

  /**
   * 求值一组规则，返回 undefined 表示「整组没参与」。
   *
   * 对应桌面版 `private bool? IsRulesetGroupSatisfied(RuleGroup ruleset)`。
   * verdict 就地填好。
   */
  private static evaluateGroup(group: RuleGroup, verdict: RuleGroupVerdict,
    context: RuleContext): boolean | undefined {
    // 组内一条「挑过的」规则都没有 → 整组返回 null，不参与上层组合。
    let hasChosen: boolean = false;
    for (const rule of group.rules) {
      if (rule.id.length > 0) {
        hasChosen = true;
        break;
      }
    }
    if (!hasChosen) {
      verdict.state = STATE_NONE;
      verdict.reason = RuleReason.GroupEmpty;
      return undefined;
    }

    // And 从 true 起、Or 从 false 起，于是「什么都没跑」时 And 组为真、Or 组为假。
    let satisfied: boolean = group.mode === RulesetLogicalMode.And;
    for (let i: number = 0; i < group.rules.length; i++) {
      const rule: Rule = group.rules[i];
      const ruleVerdict: RuleVerdict = verdict.rules[i];
      const raw: boolean | undefined = RuleEngine.evaluateRule(rule, context, ruleVerdict);
      if (raw === undefined) {
        // 没挑规则：不异或、不参与、不改 satisfied。
        ruleVerdict.state = STATE_NONE;
        ruleVerdict.reason = RuleReason.NotChosen;
        continue;
      }
      const result: boolean = rule.isReversed ? !raw : raw;
      ruleVerdict.state = result ? STATE_TRUE : STATE_FALSE;
      if (!RuleEngine.isDiagnostic(ruleVerdict.reason)) {
        // 只有真跑过处理器的规则才按匹配结果归类。
        // 「查不到注册」「没实现」「处理器抛了」是诊断结论，比「没匹配上」具体，
        // 覆盖掉它们等于把用户从「你配错了」引向「这条规则跑不了」的相反方向。
        //
        // 取反之后仍算「这条规则通过了」——IsReversed 之后它对组合确实贡献 true。
        // 界面想区分得自己去看 rule.isReversed。
        ruleVerdict.reason = result ? RuleReason.Matched : RuleReason.NotMatched;
      }
      if (!result && group.mode === RulesetLogicalMode.And) {
        satisfied = false;
        break;
      }
      if (result && group.mode === RulesetLogicalMode.Or) {
        satisfied = true;
        break;
      }
    }
    // 整组取反作用在最终结果上，不是作用在每条规则上。
    if (group.isReversed) {
      satisfied = !satisfied;
    }
    verdict.state = satisfied ? STATE_TRUE : STATE_FALSE;
    verdict.reason = RuleReason.Matched;
    return satisfied;
  }

  /** 这个原因是不是「求值过程本身的异常」，是的话别被匹配结果覆盖。 */
  private static isDiagnostic(reason: string): boolean {
    return reason === RuleReason.UnknownRule ||
      reason === RuleReason.NotImplemented ||
      reason === RuleReason.HandlerThrew;
  }

  /**
   * 求值单条规则，返回 undefined 表示「没挑规则」。
   *
   * 对应桌面版 `private bool? IsRuleSatisfied(Rule i)` 的四层兜底：
   * 空 id → null；查不到注册 → false；处理器缺失 → false；处理器抛 → false。
   * 每一层都往 verdict.reason 上留痕迹。
   */
  private static evaluateRule(rule: Rule, context: RuleContext, verdict: RuleVerdict):
    boolean | undefined {
    if (rule.id.length === 0) {
      return undefined;
    }
    const info: RuleInfo | undefined = RuleCatalog.find(rule.id);
    if (info === undefined) {
      verdict.state = STATE_FALSE;
      verdict.reason = RuleReason.UnknownRule;
      return false;
    }
    if (info.support !== RuleSupport.Implemented) {
      verdict.state = STATE_FALSE;
      verdict.reason = RuleReason.NotImplemented;
      return false;
    }
    const settings: Object | undefined = RuleCatalog.settingsOf(rule);
    if (settings === undefined) {
      verdict.state = STATE_FALSE;
      verdict.reason = RuleReason.NotImplemented;
      return false;
    }
    let outcome: boolean;
    try {
      outcome = RuleEngine.handle(rule.id, settings, context);
    } catch (error) {
      // 桌面版 catch 后记日志并返回 false。这里不记（core 不该打日志），
      // 结果一致，界面从 reason 上能看出是抛了。
      verdict.state = STATE_FALSE;
      verdict.reason = RuleReason.HandlerThrew;
      return false;
    }
    verdict.state = outcome ? STATE_TRUE : STATE_FALSE;
    return outcome;
  }

  /**
   * 四条已实现规则的处理器。
   *
   * 对应 LessonsService 的 TimeStateHandler / CurrentSubjectHandler /
   * NextSubjectHandler / PreviousSubjectHandler。
   *
   * 走到末尾说明注册表把某条规则的 support 标成了 Implemented 却没给实现 ——
   * 返回 false 而不是抛，让一次疏漏表现为「这条规则不成立」，
   * 与桌面版「没有处理器时返回 false」的口径一致。
   */
  private static handle(id: string, settings: Object, context: RuleContext): boolean {
    if (id === RuleIds.LESSONS_TIME_STATE) {
      const stateSettings: TimeStateRuleSettings = settings as TimeStateRuleSettings;
      // 「放学」也算「无」：桌面版 CurrentState 是 AfterSchool 时，
      // 配成 None 的规则同样成立（放学了就该切回空闲那套面板）。
      return context.snapshot.state === stateSettings.state ||
        (context.snapshot.state === TimeState.AfterSchool && stateSettings.state === TimeState.None);
    }
    if (id === RuleIds.LESSONS_CURRENT_SUBJECT) {
      return RuleEngine.subjectMatches(context,
        (settings as CurrentSubjectRuleSettings).subjectId, context.snapshot.currentSubject);
    }
    if (id === RuleIds.LESSONS_NEXT_SUBJECT) {
      return RuleEngine.subjectMatches(context,
        (settings as CurrentSubjectRuleSettings).subjectId, context.snapshot.nextClassSubject);
    }
    if (id === RuleIds.LESSONS_PREVIOUS_SUBJECT) {
      return RuleEngine.subjectMatches(context,
        (settings as CurrentSubjectRuleSettings).subjectId, context.snapshot.previousSubject);
    }
    return false;
  }

  /**
   * 「当前 / 下节 / 上节课的科目是这一门吗」。
   *
   * 用引用相等而非比名字，与桌面版 `CurrentSubject == subject` 一致 —— 那边
   * subject 是从 Profile.Subjects 里按 id 取出来的同一个实例。若改成比名字，
   * 两门都叫「体育」的课会互相冒认。
   *
   * Subject.fallback() / breaking() 每次新建，永远匹配不上：它们不在档案里，
   * 档案里也不可能有同一个引用。桌面版同理（那边是进程级单例，同样不在字典里）。
   */
  private static subjectMatches(context: RuleContext, subjectId: Guid,
    actual: Subject): boolean {
    if (context.profile === undefined) {
      return false;
    }
    const wanted: Subject | undefined = context.profile.tryGetSubject(subjectId);
    if (wanted === undefined) {
      // 规则指向一门已经不存在的科目。桌面版 TryGetValue 失败 → false。
      return false;
    }
    return wanted === actual;
  }
}
