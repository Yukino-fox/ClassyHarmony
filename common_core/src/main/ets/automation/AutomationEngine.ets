/*
 * 自动化链路求值。对应桌面版 AutomationService 里那三个事件处理器
 * （TriggerTriggered / TriggerTriggeredRevert / RulesetServiceOnStatusUpdated）
 * 加上 PreTimePointTrigger 与 CronTrigger 的定时逻辑。
 *
 * 这一层只回答「这一帧该触发哪些行动组、是触发还是恢复」，不执行任何行动
 * ------------------------------------------------------------------
 * 执行要碰系统能力（弹通知、退进程、写设置），那是 entry 的事。所以这里产出
 * 一份「决定」，由调用方照着做。这条分工不是洁癖：把执行也放进来就得依赖
 * @kit.*，于是整个文件进不了 Node 测试台，而这套链路最容易出错的地方恰恰是
 * 「谁在什么时刻被判成触发」—— 那是纯逻辑，能测就必须能测。
 *
 * 状态**留在**这一层，但只有一样
 * ----------------------------
 * preTimePoint 要记住上次检查时刻（判据是「跨过了那个时刻」，不记就没有边界）。
 * 桌面版把它放在触发器实例的 LastCheckTime 上；鸿蒙侧触发器配置是纯数据
 * （TriggerSettings），重排一下就与下标对不上，所以按「工作流下标 + 触发器下标」
 * 记，并在 reset() 里整份丢掉。
 *
 * 其余都不需要状态：时间状态类触发器直接读快照上的 transitionTo（见下），
 * cron 每秒重问，条件类每 tick 重算。
 *
 * 时间状态类触发器为什么不需要「上一帧」
 * -----------------------------------
 * 桌面版挂事件（ILessonsService.OnClass / OnBreakingTime / OnAfterSchool /
 * CurrentTimeStateChanged），事件是在状态机里「状态变成 X」那一刻响的，所以
 * 「上一帧是什么状态」是状态机内部的事，触发器不必自己记。鸿蒙侧是轮询，
 * 但 LessonsSnapshot.transitionTo 记的就是同一件事 —— 上一份快照的状态与这一份
 * 不同就是 transitionTo（引擎算快照时顺手填的，不额外留状态）。所以照抄口径
 * 一行就够：`transitionTo === OnClass` 等价于桌面版 OnClass 事件响了一次。
 *
 * 照抄桌面版的判据，一处不改
 * --------------------------
 * 1. 触发时：自动化总开关关着 → 不动；ActionSet.IsEnabled 关着 → 不动；
 *    IsRevertEnabled 开着而 Status 不是 Normal → 不动（正在生效中，别重复触发）；
 *    IsConditionEnabled 开着而规则集不满足 → 不动。
 * 2. 触发器主动要求恢复时：Status 不是 IsOn → 不动。
 * 3. 条件掉了要恢复时：只在 Status == IsOn && IsRevertEnabled && IsConditionEnabled
 *    时逐个检查，规则集不再满足就恢复。
 *
 * 有意的偏离，两处
 * ----------------
 * 只读不写：桌面版 TriggerTriggered 直接调 InvokeActionSetAsync，
 * ActionSet.Status 被就地改成 Invoking 再改回 IsOn/Normal。这里不改模型 ——
 * 与规则求值器同一条纪律（P8a 的「不在模型上就地改 State」）。调用方执行完
 * 要写回 Status 时自己写。代价是「判定」与「写回」之间有一帧的窗口，调用方
 * 要保证同一个 tick 内做完。
 *
 * 档案不可信时课表类触发器一律不动：桌面版只把 `IsCurrentProfileTrusted` 这一句
 * 挡在「时间点行动」上，课表类触发器是靠事件驱动的、档案不可信时那些事件压根
 * 不会来。鸿蒙侧是轮询，没有那个天然的挡，所以显式挡一次 —— 否则「无课程」
 * 会被当成「放学了」去触发放学时工作流。
 */

import {
  ActionSetStatus,
  CronTriggerSettings,
  DateTimeValue,
  PreTimePointTriggerSettings,
  TimeLayoutItem,
  TimeState,
  TriggerSettings,
  Workflow
} from 'common_shared';
import { LessonsSnapshot } from '../engine/LessonsSnapshot';
import { RuleContext, RuleEngine } from '../rules/RuleEngine';
import { CronExpression } from './CronExpression';
import { TriggerCatalog, TriggerInfo, TriggerSettingsKind, TriggerSupport } from './TriggerCatalog';

/** 判定原因代码。界面按它翻译文案，这一层不写界面文案。 */
export class AutomationReason {
  /** 触发器触发了，或要求恢复。 */
  static readonly Fired: string = 'fired';
  /** 自动化总开关关着。 */
  static readonly AutomationDisabled: string = 'automationDisabled';
  /** 行动组自己关着。 */
  static readonly ActionSetDisabled: string = 'actionSetDisabled';
  /** 行动组已在生效中（IsRevertEnabled 且 Status 不是 Normal），不重复触发。 */
  static readonly AlreadyOn: string = 'alreadyOn';
  /** 条件不满足。 */
  static readonly ConditionFailed: string = 'conditionFailed';
  /** 要恢复但行动组不在「等待恢复」状态。 */
  static readonly NotWaitingRevert: string = 'notWaitingRevert';
  /** 触发器已注册但鸿蒙侧无对应物。 */
  static readonly NotImplemented: string = 'notImplemented';
  /** 陌生 id。 */
  static readonly UnknownTrigger: string = 'unknownTrigger';
  /** 触发器还没挑。 */
  static readonly NotChosen: string = 'notChosen';
  /** 这一帧没到点（cron 不匹配 / 状态没变 / 提前量还没到）。 */
  static readonly NotYet: string = 'notYet';
  /** 设置配坏了（cron 表达式解不出来之类）。 */
  static readonly BadSettings: string = 'badSettings';
  /** 档案不可信，课表类触发器不算。 */
  static readonly UntrustedProfile: string = 'untrustedProfile';
}

/** 一次 tick 的输入。 */
export class AutomationTick {
  /** 当前时刻。 */
  now: DateTimeValue;

  /** 课表快照。课表类触发器要读 transitionTo。 */
  snapshot: LessonsSnapshot | undefined = undefined;

  /** 是否有可用的档案。桌面版 ProfileService.IsCurrentProfileTrusted。 */
  hasTrustedProfile: boolean = false;

  /** 应用自动化总开关（settings.IsAutomationEnabled）。 */
  isAutomationEnabled: boolean = false;

  /** 本次 tick 是应用启动后的第一次。lifetime.startup 只在这一次响。 */
  isAppStartup: boolean = false;

  /** 本次 tick 是应用退出前的最后一次。lifetime.stopping 只在这一次响。 */
  isAppStopping: boolean = false;

  /** 规则条件求值要用的时刻与档案快照。桌面版 RulesetService 拿的是同一份。 */
  ruleContext: RuleContext | undefined = undefined;

  constructor(now: DateTimeValue) {
    this.now = now;
  }
}

/** 一个触发器这一帧的判定。给界面显示用。 */
export class TriggerVerdict {
  /** 在哪个工作流里。 */
  workflowIndex: number = -1;
  /** 工作流里的第几个触发器。 */
  triggerIndex: number = -1;
  /** 触发器 id。 */
  id: string = '';
  /** 显示名。 */
  displayName: string = '';
  support: TriggerSupport = TriggerSupport.Unknown;
  /** 这一帧是不是「要求恢复」而不是「触发」。 */
  isRevert: boolean = false;
  /** 有没有触发。 */
  fired: boolean = false;
  /** 判定原因。 */
  reason: string = AutomationReason.NotYet;
  /** 附加说明：未实现的原因、cron 解不出来的原因之类。 */
  detail: string = '';
  /**
   * 这个触发器会不会要求恢复。
   *
   * 与行动的 isRevertable（能不能被回滚）不是一回事：这里是「触发器能不能
   * 说出「撤销」两个字」。12 个触发器里只有 preTimePoint 与 signal 说得出来。
   */
  canRevert: boolean = false;
}

/** 一次 tick 里该跑的一个行动组。 */
export class AutomationRun {
  /** 在哪个工作流里。 */
  workflowIndex: number = -1;
  /** 行动组名（给日志用）。 */
  actionSetName: string = '';
  /** 行动组 Guid（给日志与去重用）。 */
  actionSetGuid: string = '';
  /** false = 触发，true = 恢复。 */
  isRevert: boolean = false;
  /** 因为什么才跑。给界面显示「上次是 XX 触发的」。 */
  causeText: string = '';
}

/** 一次 tick 的全部产出。 */
export class AutomationTickResult {
  /**
   * 要跑的。顺序 = 工作流顺序 × 触发器顺序。
   *
   * 桌面版是事件驱动的，同一 tick 内谁先到取决于事件排队顺序，那不可复现也没
   * 必要复现：多条工作流同时触发时彼此独立。
   */
  runs: AutomationRun[] = [];

  /** 逐个触发器的判定，长度与「工作流数 × 触发器数」相等（配置为空时为 0）。 */
  verdicts: TriggerVerdict[] = [];
}

/** 一个 preTimePoint 触发器要记的东西。 */
class TriggerSlot {
  lastCheck: DateTimeValue | undefined = undefined;
  /** 缓存的 cron 解析结果。只在表达式文本变了才重解。 */
  cron: CronExpression | undefined = undefined;
  cronText: string = '';
}

export class AutomationEngine {
  private slots: TriggerSlot[] = [];

  /**
   * 忘掉所有触发器的历史。
   *
   * 不这么做的话，重排一下触发器就会让某个 preTimePoint 拿着别人的上次检查
   * 时刻 —— 那一次要么误触发、要么漏触发。桌面版没这个问题，它的触发器是实例，
   * 换 id 时会 Unload 再 Load，LastCheckTime 随实例一起没了。鸿蒙侧配置是纯
   * 数据，只能整份重记。调用方在工作流列表变动后调一次即可。
   */
  reset(): void {
    this.slots = [];
  }

  /**
   * 走一帧。
   *
   * workflows 是整份配置（对应 Automations/{方案名}.json 那个数组）。
   */
  tick(workflows: Workflow[], input: AutomationTick): AutomationTickResult {
    const out: AutomationTickResult = new AutomationTickResult();
    this.ensureSlots(workflows);

    // 条件掉了先算恢复，后算触发。桌面版这两条是两个事件，到达顺序不定；这里
    // 定成「先恢复」，理由是恢复把 Status 从 IsOn 挪走，随后的触发就能正常进入
    // （第 1 条判据里的 IsRevertEnabled && Status != Normal 那条只在 Status 还是
    // IsOn 时挡住重复触发）；反过来则会把一次本该发生的触发吞掉。
    this.collectConditionReverts(workflows, input, out);
    this.collectTriggered(workflows, input, out);
    return out;
  }

  private ensureSlots(workflows: Workflow[]): void {
    let needed: number = 0;
    for (const workflow of workflows) {
      needed += workflow.triggers.length;
    }
    while (this.slots.length < needed) {
      this.slots.push(new TriggerSlot());
    }
  }

  /** 按「工作流下标 + 触发器下标」定位到那一格。 */
  private slotOf(workflows: Workflow[], workflowIndex: number, triggerIndex: number): TriggerSlot {
    let base: number = 0;
    for (let w: number = 0; w < workflowIndex; w++) {
      base += workflows[w].triggers.length;
    }
    return this.slots[base + triggerIndex];
  }

  /**
   * 恢复：条件掉了。
   *
   * 照抄 RulesetServiceOnStatusUpdated 的筛选条件
   * （Status == IsOn && IsRevertEnabled && IsConditionEnabled），一条不差。
   */
  private collectConditionReverts(workflows: Workflow[], input: AutomationTick,
    out: AutomationTickResult): void {
    if (!input.isAutomationEnabled) {
      return;
    }
    for (let w: number = 0; w < workflows.length; w++) {
      const workflow: Workflow = workflows[w];
      if (workflow.actionSet.status !== ActionSetStatus.IsOn ||
        !workflow.actionSet.isRevertEnabled || !workflow.isConditionEnabled) {
        continue;
      }
      if (this.conditionSatisfied(workflow, input)) {
        continue;
      }
      out.runs.push(AutomationEngine.runOf(w, workflow, true, '条件不再满足'));
    }
  }

  /** 触发：任一触发器响了且条件满足。 */
  private collectTriggered(workflows: Workflow[], input: AutomationTick,
    out: AutomationTickResult): void {
    for (let w: number = 0; w < workflows.length; w++) {
      const workflow: Workflow = workflows[w];
      for (let t: number = 0; t < workflow.triggers.length; t++) {
        const verdict: TriggerVerdict = this.evaluateTrigger(workflows, workflow.triggers[t],
          input, w, t);
        out.verdicts.push(verdict);
        if (!verdict.fired) {
          continue;
        }
        if (!input.isAutomationEnabled) {
          verdict.fired = false;
          verdict.reason = AutomationReason.AutomationDisabled;
          continue;
        }
        const set = workflow.actionSet;
        if (verdict.isRevert) {
          if (set.status !== ActionSetStatus.IsOn) {
            verdict.fired = false;
            verdict.reason = AutomationReason.NotWaitingRevert;
            continue;
          }
          out.runs.push(AutomationEngine.runOf(w, workflow, true,
            `${verdict.displayName} 要求撤销`));
          continue;
        }
        if (!set.isEnabled) {
          verdict.fired = false;
          verdict.reason = AutomationReason.ActionSetDisabled;
          continue;
        }
        if (set.isRevertEnabled && set.status !== ActionSetStatus.Normal) {
          verdict.fired = false;
          verdict.reason = AutomationReason.AlreadyOn;
          continue;
        }
        if (workflow.isConditionEnabled && !this.conditionSatisfied(workflow, input)) {
          verdict.fired = false;
          verdict.reason = AutomationReason.ConditionFailed;
          continue;
        }
        out.runs.push(AutomationEngine.runOf(w, workflow, false,
          `${verdict.displayName} 触发`));
      }
    }
  }

  private conditionSatisfied(workflow: Workflow, input: AutomationTick): boolean {
    if (input.ruleContext === undefined) {
      return false;
    }
    return RuleEngine.evaluate(workflow.rulesetView(), input.ruleContext).satisfied;
  }

  private static runOf(workflowIndex: number, workflow: Workflow, isRevert: boolean,
    causeText: string): AutomationRun {
    const out: AutomationRun = new AutomationRun();
    out.workflowIndex = workflowIndex;
    out.actionSetName = workflow.actionSet.name;
    out.actionSetGuid = workflow.actionSet.guid.toString();
    out.isRevert = isRevert;
    out.causeText = causeText;
    return out;
  }

  /**
   * 判一个触发器这一帧要不要响。
   *
   * 未注册与未实现的先被挡掉，所以下面只处理八个。
   */
  private evaluateTrigger(workflows: Workflow[], trigger: TriggerSettings, input: AutomationTick,
    workflowIndex: number, triggerIndex: number): TriggerVerdict {
    const verdict: TriggerVerdict = new TriggerVerdict();
    verdict.workflowIndex = workflowIndex;
    verdict.triggerIndex = triggerIndex;
    verdict.id = trigger.id;

    const info: TriggerInfo | undefined = TriggerCatalog.find(trigger.id);
    if (info === undefined) {
      verdict.displayName = trigger.id.length === 0 ? '（还没挑触发器）' : trigger.id;
      verdict.support = TriggerSupport.Unknown;
      verdict.reason = trigger.id.length === 0
        ? AutomationReason.NotChosen
        : AutomationReason.UnknownTrigger;
      return verdict;
    }
    verdict.displayName = info.name;
    verdict.support = info.support;
    verdict.canRevert = info.canRevert;
    verdict.detail = info.unsupportedReason;
    if (info.support !== TriggerSupport.Implemented) {
      verdict.reason = AutomationReason.NotImplemented;
      return verdict;
    }

    const slot: TriggerSlot = this.slotOf(workflows, workflowIndex, triggerIndex);
    if (info.settingsKind === TriggerSettingsKind.Cron) {
      return AutomationEngine.evaluateCron(trigger, input, verdict, slot);
    }
    if (info.settingsKind === TriggerSettingsKind.PreTimePoint) {
      return AutomationEngine.evaluatePreTimePoint(trigger, input, verdict, slot);
    }
    if (info.id === 'classisland.lifetime.startup') {
      return AutomationEngine.mark(verdict, input.isAppStartup);
    }
    if (info.id === 'classisland.lifetime.stopping') {
      return AutomationEngine.mark(verdict, input.isAppStopping);
    }
    if (info.id === 'classisland.lessons.currentTimeStateChanged') {
      return AutomationEngine.evaluateTimeState(input, verdict, -1);
    }
    // 剩下三个是「进入某个状态时」：onClass / onBreakingTime / onAfterSchool。
    // 桌面版各挂一个事件，判据都是「状态刚变成这个」，所以并到一处判。
    return AutomationEngine.evaluateTimeState(input, verdict, AutomationEngine.stateOf(info.id));
  }

  private static mark(verdict: TriggerVerdict, fired: boolean): TriggerVerdict {
    verdict.fired = fired;
    verdict.reason = fired ? AutomationReason.Fired : AutomationReason.NotYet;
    return verdict;
  }

  /**
   * 「状态变化时」与「进入某状态时」。
   *
   * targetState 传 -1 表示「只要变了就算」（currentTimeStateChanged）。
   * transitionTo 为 undefined 就是没变 —— 它由 LessonsEngine 算快照时顺手填好，
   * 不必在这一层留任何状态。
   */
  private static evaluateTimeState(input: AutomationTick, verdict: TriggerVerdict,
    targetState: number): TriggerVerdict {
    if (!AutomationEngine.lessonsUsable(input) || input.snapshot === undefined) {
      verdict.reason = AutomationReason.UntrustedProfile;
      return verdict;
    }
    const to: TimeState | undefined = input.snapshot.transitionTo;
    if (to === undefined) {
      return AutomationEngine.mark(verdict, false);
    }
    return AutomationEngine.mark(verdict, targetState < 0 || to === targetState);
  }

  private static stateOf(triggerId: string): number {
    if (triggerId === 'classisland.lessons.onClass') {
      return TimeState.OnClass;
    }
    if (triggerId === 'classisland.lessons.onBreakingTime') {
      return TimeState.Breaking;
    }
    if (triggerId === 'classisland.lessons.onAfterSchool') {
      return TimeState.AfterSchool;
    }
    return TimeState.None;
  }

  /**
   * 课表类触发器能不能算。
   *
   * 见文件头「有意的偏离」第二条。判据是「有档案 + 有快照」，两样缺一都算不算 ——
   * 没快照说明这一 tick 连课表都没加载出来，这时候报 UntrustedProfile 比报
   * NotYet 诚实：用户看到的是「这条触发器在这台设备上不工作」，而不是「还没到
   * 点」，后者会让人一直等。
   */
  private static lessonsUsable(input: AutomationTick): boolean {
    return input.hasTrustedProfile && input.snapshot !== undefined;
  }

  /**
   * cron 触发器。
   *
   * 桌面版是睡到 `GetSleepTimeSpan(now)` 醒过来就触发。鸿蒙侧改成每秒问一次
   * 「这一刻符不符合表达式」—— 结果一样，但省掉了「解析、算下次触发时刻、
   * 睡过去」这套自建调度器，也就不会有「应用在后台时定时器被冻结、醒来补触发」
   * 这类边缘行为。代价是每秒问一次，所以只精确到秒这一层是够用的。
   */
  private static evaluateCron(trigger: TriggerSettings, input: AutomationTick,
    verdict: TriggerVerdict, slot: TriggerSlot): TriggerVerdict {
    const decoded: Object | undefined = TriggerCatalog.settingsOf(trigger);
    if (decoded === undefined) {
      verdict.reason = AutomationReason.BadSettings;
      return verdict;
    }
    const text: string = (decoded as CronTriggerSettings).cronExpression;
    if (slot.cron === undefined || slot.cronText !== text) {
      // 只在表达式真的变了才重解 —— 每秒重新 parse 六个字段纯属浪费。
      slot.cron = CronExpression.parse(text);
      slot.cronText = text;
    }
    const cron: CronExpression = slot.cron;
    if (!cron.valid) {
      verdict.reason = AutomationReason.BadSettings;
      verdict.detail = `cron 表达式解不出来：${cron.reason}`;
      return verdict;
    }
    return AutomationEngine.mark(verdict, cron.matches(input.now));
  }

  /**
   * 特定时间点前。
   *
   * 判据与桌面版逐字对应：
   *   - 当前状态已经等于目标状态 → 要求恢复（桌面版调的是 TriggerRevert）
   *   - TimeSeconds < 0 → 不动
   *   - 目标时刻 = 目标时间点的开始时刻 − TimeSeconds
   *   - LastCheckTime < 目标时刻 <= now → 触发
   *   - 无论如何 LastCheckTime = now（桌面版的 finally）
   *
   * 目标状态是 AfterSchool 时，桌面版取「最后一个上课或课间时间点的**结束**时刻」
   * （`LastOrDefault(i => i.TimeType is 0 or 1)?.EndTime`），不是一个开始时刻 ——
   * 照抄：「放学」这个时刻本身就是最后一节课的结束。
   */
  private static evaluatePreTimePoint(trigger: TriggerSettings, input: AutomationTick,
    verdict: TriggerVerdict, slot: TriggerSlot): TriggerVerdict {
    const decoded: Object | undefined = TriggerCatalog.settingsOf(trigger);
    if (decoded === undefined) {
      verdict.reason = AutomationReason.BadSettings;
      return verdict;
    }
    const settings: PreTimePointTriggerSettings = decoded as PreTimePointTriggerSettings;

    if (!AutomationEngine.lessonsUsable(input) || input.snapshot === undefined) {
      verdict.reason = AutomationReason.UntrustedProfile;
      return verdict;
    }
    if (input.snapshot.state === settings.targetState) {
      // 桌面版这里是 TriggerRevert() 然后 return —— 只要求撤销，不再判提前量。
      verdict.isRevert = true;
      return AutomationEngine.mark(verdict, true);
    }
    if (settings.timeSeconds < 0) {
      return AutomationEngine.mark(verdict, false);
    }

    const targetSecond: number = AutomationEngine.preTimePointSecond(input, settings);
    if (targetSecond < 0) {
      return AutomationEngine.mark(verdict, false);
    }
    const now: DateTimeValue = input.now;
    const last: DateTimeValue | undefined = slot.lastCheck;
    let fired: boolean = false;
    if (last !== undefined) {
      // 严格「跨过」：last < 目标 <= now。写成秒数比较会在跨午夜时错判
      // （23:59:50 的 last=86350 与 00:00:10 的 target=10 谁大谁小是反的），
      // 所以比完整时刻。
      fired = AutomationEngine.sameDay(last, now) &&
        last.timeOfDaySeconds() < targetSecond && targetSecond <= now.timeOfDaySeconds();
    }
    slot.lastCheck = now;
    return AutomationEngine.mark(verdict, fired);
  }

  private static sameDay(a: DateTimeValue, b: DateTimeValue): boolean {
    return a.year === b.year && a.month === b.month && a.day === b.day;
  }

  /**
   * 算「目标时刻」的当日秒数。找不到返回 -1。
   *
   * 与桌面版的 `new DateTime(DateOnly.FromDateTime(now), TimeOnly.FromTimeSpan(targetTime))`
   * 等价：日期固定为今天、时刻固定为那个秒数。所以提前量跨过午夜时
   * （23:58 提前 10 分）桌面版会越界，这里返回 -1 当作「这一刻不适用」——
   * 桌面版那一步会抛，而抛出去会让整帧的其它触发器一起不工作。
   */
  private static preTimePointSecond(input: AutomationTick,
    settings: PreTimePointTriggerSettings): number {
    const snapshot: LessonsSnapshot = input.snapshot as LessonsSnapshot;
    let startSecond: number = -1;
    if (settings.targetState === TimeState.AfterSchool) {
      const plan = snapshot.currentClassPlan;
      if (plan === undefined) {
        return -1;
      }
      const items = plan.validTimeLayoutItems();
      for (let i: number = items.length - 1; i >= 0; i--) {
        if (items[i].timeType === 0 || items[i].timeType === 1) {
          startSecond = items[i].endTime.toSeconds();
          break;
        }
      }
    } else if (settings.targetState === TimeState.OnClass) {
      if (isEmptyItem(snapshot.nextClassTimeLayoutItem)) {
        return -1;
      }
      startSecond = snapshot.nextClassTimeLayoutItem.startTime.toSeconds();
    } else if (settings.targetState === TimeState.Breaking) {
      if (isEmptyItem(snapshot.nextBreakingTimeLayoutItem)) {
        return -1;
      }
      startSecond = snapshot.nextBreakingTimeLayoutItem.startTime.toSeconds();
    } else {
      // 目标状态是 None / PrepareOnClass：桌面版的 switch 落到
      // `_ => TimeLayoutItem.Empty`，紧接着 `if (targetTimePoint == Empty) return`。
      return -1;
    }
    if (startSecond < 0) {
      return -1;
    }
    const target: number = startSecond - Math.round(settings.timeSeconds);
    return target < 0 || target > 86399 ? -1 : target;
  }
}

/**
 * 是不是桌面版的 TimeLayoutItem.Empty。
 *
 * 桌面版是 `targetTimePoint == TimeLayoutItem.Empty` —— 一个**实例**比较，
 * 靠重载的 == 逐字段比。而 TimeLayoutItem 是 record，new 出来的新实例与 Empty
 * 的字段全一样，所以那个 == 实际判的是「没有任何内容」。这里照这个口径：时间
 * 起点与终点都是 0 就是空。
 */
function isEmptyItem(item: TimeLayoutItem): boolean {
  return item.startTime.toSeconds() === 0 && item.endTime.toSeconds() === 0;
}
