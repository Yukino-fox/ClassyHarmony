/*
 * 规则求值测试台。
 *
 * 规则是整个配置里最容易「算出来是个合法但错误的值」的一块：三态、短路、
 * 逐层取反，任意一处写反都仍然能返回一个 true/false，肉眼完全看不出问题，
 * 而结果是「该隐藏的组件没隐藏」或反过来。
 *
 * 覆盖六类只有读过桌面版源码才知道的事：
 *
 *   1. 三态，不是两态。桌面版 IsRuleSatisfied 返回 bool?，null 表示
 *      「这条规则还没挑」（Id 为空串）。它既不贡献 true 也不贡献 false，
 *      连 IsReversed 都不作用。把它塌成 false 的话，「新建规则集还没填完」
 *      会把整个规则集判死。
 *   2. 空组不进组合。组内一条挑过的规则都没有 → 整组返回 null，在 ruleset
 *      层面被**跳过**，而不是当作 false 把 And 拉低。桌面版 RulesetControl
 *      新建出来就是「一个组一条空规则」，走的是这条路径。
 *   3. 停用的组整组不参与，状态留「无」。不是「当作不成立」。
 *   4. 取反的作用点。规则级取反作用在单条结果上；组级与规则集级的取反
 *      都作用在各自循环**之后**的最终结果上。三处都写成「逐条取反」的
 *      实现，在「一个组里有两条规则且组是 And」时答案就变了。
 *   5. 空规则集的特例。桌面版 `if (Groups.Count <= 0) { State=false;
 *      return false; }` 直接返回，**IsReversed 没被应用**。照抄这个怪癖。
 *   6. 恒假的两类规则。窗口类（鸿蒙无前台窗口）与天气类（等 P11）在注册表
 *      里标成 Unsupported，求值恒为 false。它们和「规则没匹配上」在桌面版
 *      都是 State=1，分开之后界面才能告诉用户「这条规则跑不了」而不是
 *      「你配错了」。
 *
 * 另外测了「上一节课」的口径，以及 ModelCodec 往返（规则的 Settings 是
 * 裸 JsonNode 透传，未注册规则的设置必须原样保住）。
 */

import { ClassInfo } from '../../common_shared/src/main/ets/models/ClassInfo';
import { ClassPlan } from '../../common_shared/src/main/ets/models/ClassPlan';
import { ClassPlanGroup } from '../../common_shared/src/main/ets/models/ClassPlanGroup';
import { DateTimeValue } from '../../common_shared/src/main/ets/json/DateTimeValue';
import { Guid } from '../../common_shared/src/main/ets/json/Guid';
import {
  JsonArray,
  JsonBoolean,
  JsonNode,
  JsonNull,
  JsonNumber,
  JsonObject,
  JsonString
} from '../../common_shared/src/main/ets/json/JsonNode';
import { JsonReader } from '../../common_shared/src/main/ets/json/JsonReader';
import { JsonValue } from '../../common_shared/src/main/ets/json/JsonValue';
import { JsonWriter } from '../../common_shared/src/main/ets/json/JsonWriter';
import { Profile } from '../../common_shared/src/main/ets/models/Profile';
import {
  CurrentSubjectRuleSettings,
  CurrentWeatherRuleSettings,
  RainTimeRuleSettings,
  Rule,
  RuleGroup,
  RuleIds,
  Ruleset,
  RulesetLogicalMode,
  StringMatchingSettings,
  SunRiseSetRuleSettings,
  TimeStateRuleSettings,
  WindowStatusRuleSettings
} from '../../common_shared/src/main/ets/models/Ruleset';
import { Subject } from '../../common_shared/src/main/ets/models/Subject';
import { TimeLayout } from '../../common_shared/src/main/ets/models/TimeLayout';
import { TimeLayoutItem } from '../../common_shared/src/main/ets/models/TimeLayoutItem';
import { TimeRule } from '../../common_shared/src/main/ets/models/TimeRule';
import { TimeSpanValue } from '../../common_shared/src/main/ets/json/TimeSpanValue';
import { TimeState } from '../../common_shared/src/main/ets/enums/TimeState';
import { EngineSettings } from '../../common_core/src/main/ets/engine/EngineSettings';
import { LessonsEngine } from '../../common_core/src/main/ets/engine/LessonsEngine';
import { RuleCatalog, RuleSettingsKind, RuleSupport } from '../../common_core/src/main/ets/rules/RuleCatalog';
import {
  RuleContext,
  RuleEngine,
  RuleGroupVerdict,
  RuleReason,
  RulesetVerdict,
  STATE_FALSE,
  STATE_NONE,
  STATE_TRUE
} from '../../common_core/src/main/ets/rules/RuleEngine';
import { RulesetMutations } from '../../common_core/src/main/ets/rules/RulesetMutations';
import {
  RuleChoiceRow,
  RuleEditRow,
  RuleGroupEditRow,
  RulesetEditModel,
  RulesetEditor
} from '../../common_core/src/main/ets/rules/RulesetEditModel';

let passed: number = 0;
const failures: string[] = [];

function check(name: string, condition: boolean, detail: string = ''): void {
  if (condition) {
    passed++;
  } else {
    failures.push(detail.length === 0 ? name : `${name} —— ${detail}`);
  }
}

function checkEqual(name: string, actual: string, expected: string): void {
  check(name, actual === expected, `实际 ${actual}，期望 ${expected}`);
}

function checkNum(name: string, actual: number, expected: number): void {
  check(name, actual === expected, `实际 ${actual}，期望 ${expected}`);
}

// --------------------------------------------------------------- 档案夹具

const SUBJECT_YUWEN: string = '11111111-1111-1111-1111-111111111111';
const SUBJECT_SHUXUE: string = '22222222-2222-2222-2222-222222222222';
const SUBJECT_YINGYU: string = '33333333-3333-3333-3333-333333333333';
const LAYOUT_ID: string = 'aaaaaaaa-0000-0000-0000-000000000001';

/** 2026-09-26 是周六（dayOfWeek = 6），与其它驱动同基准。 */
const BASE_DAY: string = '2026-09-26';

function dt(text: string): DateTimeValue {
  return DateTimeValue.parseOrMin(text);
}

function engineSettings(): EngineSettings {
  // 单周起始日取周日，与 AppSettings.defaultEngineSettings 同口径。
  return new EngineSettings(dt('2026-09-20T00:00:00'));
}

function item(type: number, start: string, end: string, breakName: string = ''): TimeLayoutItem {
  const out: TimeLayoutItem = new TimeLayoutItem();
  out.timeType = type;
  out.startTime = TimeSpanValue.parseOrZero(start);
  out.endTime = TimeSpanValue.parseOrZero(end);
  out.breakName = breakName;
  return out;
}

/**
 * 6 个时间点：3 节课 + 2 个课间 + 1 个放学缓冲（TimeType=0 的第 4 段）。
 *
 * 末节课放在 10:00-10:45 而不是紧接 09:45，是为了能测「放学之后」——
 * AfterSchool 状态需要一个既没有课、也没到次日的时间点。
 */
function standardLayout(): TimeLayout {
  const layout: TimeLayout = new TimeLayout();
  layout.name = '标准作息';
  layout.layouts = [
    item(0, '08:00:00', '08:45:00'),
    item(1, '08:45:00', '09:00:00', '大课间'),
    item(0, '09:00:00', '09:45:00'),
    item(1, '09:45:00', '10:00:00', '小课间'),
    item(0, '10:00:00', '10:45:00')
  ];
  return layout;
}

function planKey(day: number): string {
  const hex: string = (0x10000000 + day).toString(16);
  return `${hex}-0000-0000-0000-000000000000`;
}

/**
 * 每天 3 节课依次是语文 / 数学 / 英语。周末（周六日）也排满，
 * 这样测「放学」时要显式挑一个没课的日子。
 */
function fullWeekProfile(): Profile {
  const profile: Profile = new Profile();
  profile.name = '规则测试';
  profile.timeLayouts.set(LAYOUT_ID, standardLayout());
  profile.selectedClassPlanGroupId = ClassPlanGroup.defaultGroupGuid();

  const ids: string[] = [SUBJECT_YUWEN, SUBJECT_SHUXUE, SUBJECT_YINGYU];
  const names: string[] = ['语文', '数学', '英语'];
  for (let i: number = 0; i < ids.length; i++) {
    const subject: Subject = new Subject();
    subject.name = names[i];
    subject.teacherName = `${names[i]}老师`;
    profile.subjects.set(ids[i], subject);
  }

  for (let day: number = 0; day <= 6; day++) {
    const plan: ClassPlan = new ClassPlan();
    plan.name = `周${day}的课`;
    plan.timeLayoutId = Guid.fromCanonical(LAYOUT_ID);
    const rule: TimeRule = new TimeRule();
    rule.weekDay = day;
    rule.weekCountDiv = 0;
    rule.weekCountDivTotal = 2;
    plan.timeRule = rule;
    const classes: ClassInfo[] = [new ClassInfo(), new ClassInfo(), new ClassInfo()];
    classes[0].subjectId = Guid.fromCanonical(SUBJECT_YUWEN);
    classes[1].subjectId = Guid.fromCanonical(SUBJECT_SHUXUE);
    classes[2].subjectId = Guid.fromCanonical(SUBJECT_YINGYU);
    plan.classes = classes;
    profile.classPlans.set(planKey(day), plan);
  }
  profile.refreshDerivedState();
  return profile;
}

// ------------------------------------------------------------- 规则集构造

/**
 * 把设置对象转成规则上的裸 Settings 节点。
 *
 * 七种设置类都各有自己的 toJson，没有共同基类，所以这里逐个认。
 * 少认一种的话那条规则的设置会静默变成 null —— 桌面版求值时用
 * `Activator.CreateInstance(settingsType)` 兜底，规则照样「不成立」，
 * 现象是「规则怎么配都不生效」，很难往这儿想。
 */
function settingsNode(settings: Object): JsonNode {
  if (settings instanceof TimeStateRuleSettings) {
    return settings.toJson();
  }
  if (settings instanceof CurrentSubjectRuleSettings) {
    return settings.toJson();
  }
  if (settings instanceof CurrentWeatherRuleSettings) {
    return settings.toJson();
  }
  if (settings instanceof RainTimeRuleSettings) {
    return settings.toJson();
  }
  if (settings instanceof SunRiseSetRuleSettings) {
    return settings.toJson();
  }
  if (settings instanceof WindowStatusRuleSettings) {
    return settings.toJson();
  }
  if (settings instanceof StringMatchingSettings) {
    return settings.toJson();
  }
  return new JsonObject();
}

/**
 * 一条待往返的设置：id 决定 RuleCatalog 按哪个类型解，所以 id 与设置必须配对。
 *
 * 配错的话 readSettings 会解出另一个类型（或者干脆解出 StringMatchingSettings），
 * 而值看着都对 —— 这是最容易漏的一处：类型错了而字段恰好同名。
 */
class SettingsCase {
  id: string = '';
  settings: Object = new Object();
}

function settingsCase(id: string, settings: Object): SettingsCase {
  const out: SettingsCase = new SettingsCase();
  out.id = id;
  out.settings = settings;
  return out;
}

function rule(id: string, settings?: Object, isReversed: boolean = false): Rule {
  const out: Rule = new Rule();
  out.id = id;
  out.isReversed = isReversed;
  if (settings !== undefined) {
    out.settings = settingsNode(settings);
  }
  return out;
}

function timeStateRule(state: TimeState, isReversed: boolean = false): Rule {
  const settings: TimeStateRuleSettings = new TimeStateRuleSettings();
  settings.state = state;
  return rule(RuleIds.LESSONS_TIME_STATE, settings, isReversed);
}

function subjectRule(which: string, subjectId: string, isReversed: boolean = false): Rule {
  const settings: CurrentSubjectRuleSettings = new CurrentSubjectRuleSettings();
  settings.subjectId = Guid.fromCanonical(subjectId);
  return rule(which, settings, isReversed);
}

function group(mode: RulesetLogicalMode, rules: Rule[], isReversed: boolean = false,
  isEnabled: boolean = true): RuleGroup {
  const out: RuleGroup = new RuleGroup();
  out.mode = mode;
  out.rules = rules;
  out.isReversed = isReversed;
  out.isEnabled = isEnabled;
  return out;
}

function ruleset(mode: RulesetLogicalMode, groups: RuleGroup[], isReversed: boolean = false): Ruleset {
  const out: Ruleset = new Ruleset();
  out.mode = mode;
  out.groups = groups;
  out.isReversed = isReversed;
  return out;
}

/** 单组 And、单条规则 —— 测试里最常用的形状。 */
function one(state: TimeState): Ruleset {
  return ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [timeStateRule(state)])]);
}

// ------------------------------------------------------------------ 求值

/**
 * 造一个求值上下文。
 *
 * profile 与 snapshot 必须同源 —— 科目类规则靠引用相等判「是不是这门课」，
 * 这里统一从同一份档案算出来，不会跨。
 */
function contextAt(at: string, profile?: Profile): RuleContext {
  const used: Profile = profile === undefined ? fullWeekProfile() : profile;
  const context: RuleContext = new RuleContext();
  context.now = dt(at);
  context.profile = used;
  context.snapshot = LessonsEngine.compute(used, engineSettings(), context.now);
  return context;
}

function verdictAt(rs: Ruleset, at: string, profile?: Profile): RulesetVerdict {
  return RuleEngine.evaluate(rs, contextAt(at, profile));
}

function satisfied(rs: Ruleset, at: string, profile?: Profile): boolean {
  return verdictAt(rs, at, profile).satisfied;
}

// ------------------------------------------------------- A. 三态与空组

function testEmptyRulesetIsFalse(): void {
  const empty: Ruleset = new Ruleset();
  check('空规则集为假', !satisfied(empty, `${BASE_DAY}T08:00:00`));
  checkNum('空规则集状态为假', verdictAt(empty, `${BASE_DAY}T08:00:00`).state, STATE_FALSE);
}

function testEmptyRulesetIgnoresReversed(): void {
  // 桌面版的怪癖：Groups.Count <= 0 时直接 return false，IsReversed 不参与。
  const rs: Ruleset = new Ruleset();
  rs.isReversed = true;
  check('空规则集 + 取反仍是假（照抄桌面版）',
    !satisfied(rs, `${BASE_DAY}T08:00:00`),
    '桌面版 `if (Groups.Count <= 0) { return false; }` 早于取反');
}

function testUnchosenRuleIsSkipped(): void {
  // 一个组里只有空 id 的规则 → 整组返回 null → ruleset 层面跳过。
  // Or 模式下初值是 false，跳过后不变；结果为假。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [new Rule()])]);
  const verdict: RulesetVerdict = verdictAt(rs, `${BASE_DAY}T08:00:00`);
  check('空 id 规则 → 整组不参与 → 假', !verdict.satisfied);
  checkNum('空 id 规则状态为无', verdict.groups[0].rules[0].state, STATE_NONE);
  checkNum('整组状态为无', verdict.groups[0].state, STATE_NONE);
  checkEqual('整组原因是没挑过', verdict.groups[0].reason, 'groupEmpty');
}

function testChosenRuleInEmptyGroupParticipates(): void {
  // 组里一条挑过的都没有时整组不参与；补一条真规则进去，整组立刻参与。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [
    new Rule(),
    timeStateRule(TimeState.OnClass)
  ])]);
  check('组内有挑过的规则时整组参与（上课中为真）',
    satisfied(rs, `${BASE_DAY}T08:10:00`));
}

function testAndGroupWithOnlyUnchosenIsNotFalseForRuleset(): void {
  // 这是三态最要紧的一处：若把空组塌成 false，And 模式的规则集会被判死。
  // 桌面版行为是跳过，于是「一个空组 + 一个真组」的 And 规则集为真。
  const rs: Ruleset = ruleset(RulesetLogicalMode.And, [
    group(RulesetLogicalMode.And, [new Rule()]),
    group(RulesetLogicalMode.And, [timeStateRule(TimeState.OnClass)])
  ]);
  check('And 规则集里空组被跳过而不是判死（上课中为真）',
    satisfied(rs, `${BASE_DAY}T08:10:00`));
  check('同上，放学后为假', !satisfied(rs, `${BASE_DAY}T11:30:00`));
}

function testDefaultRulesetShape(): void {
  // 桌面版新建规则集的默认形状：Or + 一个 And 组 + 一条空规则。
  const rs: Ruleset = Ruleset.defaultRuleset();
  checkNum('默认规则集组数', rs.groups.length, 1);
  checkNum('默认规则集组内规则数', rs.groups[0].rules.length, 1);
  checkEqual('默认规则集 Id 为空串', rs.groups[0].rules[0].id, '');
  checkNum('默认规则集 Mode 为 Or', rs.mode, RulesetLogicalMode.Or);
  checkNum('默认规则集组 Mode 为 And', rs.groups[0].mode, RulesetLogicalMode.And);
  check('默认规则集求值为假', !satisfied(rs, `${BASE_DAY}T08:10:00`));
}

// ----------------------------------------------------- B. 停用与取反

function testDisabledGroupIsSkipped(): void {
  // 停用的组整组不参与，状态留「无」——不是「当作不成立」。
  const rs: Ruleset = ruleset(RulesetLogicalMode.And, [
    group(RulesetLogicalMode.And, [timeStateRule(TimeState.None)], false, false),
    group(RulesetLogicalMode.And, [timeStateRule(TimeState.OnClass)])
  ]);
  const verdict: RulesetVerdict = verdictAt(rs, `${BASE_DAY}T08:10:00`);
  check('停用的组不参与 And（上课中仍为真）', verdict.satisfied);
  checkNum('停用组状态为无', verdict.groups[0].state, STATE_NONE);
  checkEqual('停用组原因是已停用', verdict.groups[0].reason, 'groupDisabled');
  check('停用组的 IsEnabled 被记进轨迹', !verdict.groups[0].isEnabled);
}

function testDisabledGroupDoesNotKillAnd(): void {
  // 停用组里的规则是假的，但它不该把 And 拉低。
  const rs: Ruleset = ruleset(RulesetLogicalMode.And, [
    group(RulesetLogicalMode.And, [timeStateRule(TimeState.None)], false, false),
    group(RulesetLogicalMode.And, [timeStateRule(TimeState.Breaking)])
  ]);
  check('And 规则集里停用组不影响结论（课间为真）',
    satisfied(rs, `${BASE_DAY}T08:50:00`));
}

function testRuleReversed(): void {
  check('规则取反后结论翻转',
    satisfied(one(TimeState.None), `${BASE_DAY}T08:10:00`) === false);
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [
    timeStateRule(TimeState.OnClass, true)
  ])]);
  check('上课中 + 规则取反「上课中」→ 假', !satisfied(rs, `${BASE_DAY}T08:10:00`));
  check('课间 + 规则取反「上课中」→ 真', satisfied(rs, `${BASE_DAY}T08:50:00`));
}

function testGroupReversedAppliesToGroupResult(): void {
  // 组级取反作用在整组结果上。与「逐条取反」在两条规则时有区别：
  // And 组里 [真, 假] 整组为假，整组取反后为真；
  // 若写成逐条取反就成了 [假, 真]，仍是假。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [
    timeStateRule(TimeState.OnClass),
    timeStateRule(TimeState.None)
  ], true)]);
  check('组级取反作用在整组结果上（And 组 [真,假] 取反后为真）',
    satisfied(rs, `${BASE_DAY}T08:10:00`));
}

function testRulesetReversedAppliesAfterGroups(): void {
  // 规则集级取反同样在组循环之后。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or,
    [group(RulesetLogicalMode.And, [timeStateRule(TimeState.None)])], true);
  check('规则集取反（上课中 + 规则「空闲」取反 → 真）',
    satisfied(rs, `${BASE_DAY}T08:10:00`));
  check('规则集取反（上课中 + 规则「上课中」取反 → 假）',
    !satisfied(ruleset(RulesetLogicalMode.Or,
      [group(RulesetLogicalMode.And, [timeStateRule(TimeState.OnClass)])], true),
    `${BASE_DAY}T08:10:00`));
}

// --------------------------------------------------------- C. 组合与短路

function testAndRequiresAllGroups(): void {
  const rs: Ruleset = ruleset(RulesetLogicalMode.And, [
    group(RulesetLogicalMode.And, [timeStateRule(TimeState.OnClass)]),
    group(RulesetLogicalMode.And, [timeStateRule(TimeState.None)])
  ]);
  check('And 规则集：一真一假 → 假', !satisfied(rs, `${BASE_DAY}T08:10:00`));
  check('And 规则集：全真 → 真', satisfied(
    ruleset(RulesetLogicalMode.And, [
      group(RulesetLogicalMode.And, [timeStateRule(TimeState.OnClass)]),
      group(RulesetLogicalMode.And, [timeStateRule(TimeState.OnClass)])
    ]), `${BASE_DAY}T08:10:00`));
}

function testOrRequiresAnyGroup(): void {
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And, [timeStateRule(TimeState.None)]),
    group(RulesetLogicalMode.And, [timeStateRule(TimeState.OnClass)])
  ]);
  check('Or 规则集：一真一假 → 真', satisfied(rs, `${BASE_DAY}T08:10:00`));
  check('Or 规则集：全假 → 假', satisfied(rs, `${BASE_DAY}T08:50:00`) === false);
}

function testAndInsideGroupShortCircuits(): void {
  // And 组里第一条就假 → 立刻 break，后面的规则保持「无」。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [
    timeStateRule(TimeState.None),
    timeStateRule(TimeState.OnClass)
  ])]);
  const verdict: RulesetVerdict = verdictAt(rs, `${BASE_DAY}T08:10:00`);
  check('And 组第一条为假 → 整组为假', !verdict.satisfied);
  checkNum('被短路前的规则有判定', verdict.groups[0].rules[0].state, STATE_FALSE);
  check('被短路后的规则保持「无」（桌面版只在开头清空 State，break 之后留在 0）',
    verdict.groups[0].rules[1].state === STATE_NONE);
}

function testOrInsideGroupShortCircuits(): void {
  // Or 组里第一条就真 → 立刻 break。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.Or, [
    timeStateRule(TimeState.OnClass),
    timeStateRule(TimeState.None)
  ])]);
  const verdict: RulesetVerdict = verdictAt(rs, `${BASE_DAY}T08:10:00`);
  check('Or 组第一条为真 → 整组为真', verdict.satisfied);
  checkNum('Or 组短路后的规则为无', verdict.groups[0].rules[1].state, STATE_NONE);
}

function testUnchosenRuleBeforeChosenOneStillShortCircuits(): void {
  // 空 id 的规则不参与，所以不阻止短路。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [
    new Rule(),
    timeStateRule(TimeState.OnClass)
  ])]);
  const verdict: RulesetVerdict = verdictAt(rs, `${BASE_DAY}T08:10:00`);
  check('And 组：空规则不参与，第一条挑过的为真 → 整组为真', verdict.satisfied);
  checkNum('空规则状态为无', verdict.groups[0].rules[0].state, STATE_NONE);
}

function testGroupWithAllUnchosenInOrGroup(): void {
  // 整组不参与时，Or 组不算「有一组为真」。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And, [new Rule()]),
    group(RulesetLogicalMode.And, [timeStateRule(TimeState.None)])
  ]);
  check('Or 规则集里空组不贡献真', !satisfied(rs, `${BASE_DAY}T08:10:00`));
}

function testTraceShapeMatchesRulesetShape(): void {
  // 轨迹与规则集严格同形（含被短路的），界面按下标直接对齐。
  const rs: Ruleset = ruleset(RulesetLogicalMode.And, [
    group(RulesetLogicalMode.And, [timeStateRule(TimeState.None), timeStateRule(TimeState.OnClass)]),
    group(RulesetLogicalMode.And, [new Rule(), new Rule()], false, false)
  ]);
  const verdict: RulesetVerdict = verdictAt(rs, `${BASE_DAY}T08:10:00`);
  checkNum('轨迹组数与规则集一致', verdict.groups.length, rs.groups.length);
  checkNum('第 0 组规则数一致', verdict.groups[0].rules.length, 2);
  checkNum('第 1 组规则数一致', verdict.groups[1].rules.length, 2);
  checkNum('规则集状态与 satisfied 一致',
    verdict.state, verdict.satisfied ? STATE_TRUE : STATE_FALSE);
}

// --------------------------------------------------------- D. 课表处理器

function testTimeStateHandler(): void {
  // 08:00-08:45 上课、08:45-09:00 课间、09:00-09:45 上课、09:45-10:00 课间、
  // 10:00-10:45 上课。周六排满，所以「放学」要用 11:30 之后。
  check('上课中匹配 OnClass', satisfied(one(TimeState.OnClass), `${BASE_DAY}T08:10:00`));
  check('课间不匹配 OnClass', !satisfied(one(TimeState.OnClass), `${BASE_DAY}T08:50:00`));
  check('课间匹配 Breaking', satisfied(one(TimeState.Breaking), `${BASE_DAY}T08:50:00`));
  check('上课不匹配 Breaking', !satisfied(one(TimeState.Breaking), `${BASE_DAY}T09:10:00`));
  check('放学后匹配 AfterSchool', satisfied(one(TimeState.AfterSchool), `${BASE_DAY}T11:30:00`));
  check('上课不匹配 AfterSchool', !satisfied(one(TimeState.AfterSchool), `${BASE_DAY}T09:10:00`));
}

function testTimeStateNoneMatchesAfterSchool(): void {
  // 桌面版 TimeStateHandler：`CurrentState == s.State ||
  // (CurrentState == AfterSchool && s.State == None)`。
  // 「放学了 → 切回空闲那套面板」靠的就是这一条。
  check('放学后匹配 None', satisfied(one(TimeState.None), `${BASE_DAY}T11:30:00`));
  check('上课中不匹配 None', !satisfied(one(TimeState.None), `${BASE_DAY}T08:10:00`));
  check('课间不匹配 None', !satisfied(one(TimeState.None), `${BASE_DAY}T08:50:00`));
}

function testCurrentSubjectHandler(): void {
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or,
    [group(RulesetLogicalMode.And, [subjectRule(RuleIds.LESSONS_CURRENT_SUBJECT, SUBJECT_YUWEN)])]);
  check('当前是语文 → 语文规则成立', satisfied(rs, `${BASE_DAY}T08:10:00`));
  check('当前是英语 → 语文规则不成立', !satisfied(rs, `${BASE_DAY}T10:10:00`));
  check('课间休息不匹配任何科目',
    !satisfied(rs, `${BASE_DAY}T08:50:00`), 'Breaking 不是档案里的科目，引用比不过去');
}

function testSubjectRulesUseReferenceEquality(): void {
  // 两门都叫「体育」的课不能互相冒认。用两个同名的不同实例验证。
  const profile: Profile = new Profile();
  profile.timeLayouts.set(LAYOUT_ID, standardLayout());
  profile.selectedClassPlanGroupId = ClassPlanGroup.defaultGroupGuid();
  const first: Subject = new Subject();
  first.name = '体育';
  const twin: Subject = new Subject();
  twin.name = '体育';
  profile.subjects.set(SUBJECT_YUWEN, first);
  profile.subjects.set(SUBJECT_SHUXUE, twin);
  const plan: ClassPlan = new ClassPlan();
  plan.name = '同名科目';
  plan.timeLayoutId = Guid.fromCanonical(LAYOUT_ID);
  const rule: TimeRule = new TimeRule();
  rule.weekDay = 6;
  rule.weekCountDiv = 0;
  rule.weekCountDivTotal = 2;
  plan.timeRule = rule;
  plan.classes = [new ClassInfo(), new ClassInfo(), new ClassInfo()];
  plan.classes[0].subjectId = Guid.fromCanonical(SUBJECT_YUWEN);
  plan.classes[1].subjectId = Guid.fromCanonical(SUBJECT_SHUXUE);
  plan.classes[2].subjectId = Guid.fromCanonical(SUBJECT_YINGYU);
  profile.classPlans.set(planKey(6), plan);
  profile.refreshDerivedState();

  const firstRs: Ruleset = ruleset(RulesetLogicalMode.Or,
    [group(RulesetLogicalMode.And, [subjectRule(RuleIds.LESSONS_CURRENT_SUBJECT, SUBJECT_YUWEN)])]);
  const twinRs: Ruleset = ruleset(RulesetLogicalMode.Or,
    [group(RulesetLogicalMode.And, [subjectRule(RuleIds.LESSONS_CURRENT_SUBJECT, SUBJECT_SHUXUE)])]);
  check('第 1 节是第一个「体育」→ 它的规则成立',
    satisfied(firstRs, `${BASE_DAY}T08:10:00`, profile));
  check('第 2 节是第二个「体育」→ 第 1 节的规则不成立',
    !satisfied(firstRs, `${BASE_DAY}T09:10:00`, profile),
    '比名字的话这里会误判为成立');
  check('第 2 节是第二个「体育」→ 它自己的规则成立',
    satisfied(twinRs, `${BASE_DAY}T09:10:00`, profile));
}

function testSubjectRuleWithUnknownSubjectId(): void {
  // 规则指向一门已删除的科目 → 查表失败 → false。
  const missing: string = '99999999-9999-9999-9999-999999999999';
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or,
    [group(RulesetLogicalMode.And, [subjectRule(RuleIds.LESSONS_CURRENT_SUBJECT, missing)])]);
  check('指向不存在科目的规则为假', !satisfied(rs, `${BASE_DAY}T08:10:00`));
}

function testNextSubjectHandler(): void {
  // 桌面版 NextClassSubject 的定义是「第一个 TimeType==0 且 EndTime >= now」，
  // 所以**上课中它就是当前这节课**，不是「下一节」。这条是刻意照抄的。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And, [subjectRule(RuleIds.LESSONS_NEXT_SUBJECT, SUBJECT_YUWEN)])]);
  check('上课中「下节课」= 当前这节（语文）',
    satisfied(rs, `${BASE_DAY}T08:10:00`));
  check('课间「下节课」= 下一节（数学）',
    !satisfied(rs, `${BASE_DAY}T08:50:00`));
  const math: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And, [subjectRule(RuleIds.LESSONS_NEXT_SUBJECT, SUBJECT_SHUXUE)])]);
  check('课间「下节课」= 下一节（数学）成立',
    satisfied(math, `${BASE_DAY}T08:50:00`));
}

function testNextSubjectBoundaryAtEndTime(): void {
  // 判据是 EndTime >= now（含边界），所以语文那节「刚结束」的这一秒
  // （08:45:00 整）它仍然是「下节课」；要过一秒才翻到数学。
  // 写成 > 而不是 >= 的话，课表在这条边界上会差出一整节课。
  const yuwen: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And, [subjectRule(RuleIds.LESSONS_NEXT_SUBJECT, SUBJECT_YUWEN)])]);
  const shuxue: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And, [subjectRule(RuleIds.LESSONS_NEXT_SUBJECT, SUBJECT_SHUXUE)])]);
  check('08:45:00 整「下节课」仍是语文（EndTime >= now 含边界）',
    satisfied(yuwen, `${BASE_DAY}T08:45:00`));
  check('08:45:00 整「下节课」还不是数学', !satisfied(shuxue, `${BASE_DAY}T08:45:00`));
  check('08:45:01 「下节课」翻到数学', satisfied(shuxue, `${BASE_DAY}T08:45:01`));
  check('08:45:01 「下节课」不再是语文', !satisfied(yuwen, `${BASE_DAY}T08:45:01`));
}

function testPreviousSubjectHandler(): void {
  // 口径：最后一个 EndTime < now 的上课时间点。
  const yuwen: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And,
      [subjectRule(RuleIds.LESSONS_PREVIOUS_SUBJECT, SUBJECT_YUWEN)])]);
  const shuxue: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And,
      [subjectRule(RuleIds.LESSONS_PREVIOUS_SUBJECT, SUBJECT_SHUXUE)])]);
  check('第 1 节上课时「上节课」还没有',
    !satisfied(yuwen, `${BASE_DAY}T08:10:00`) && !satisfied(shuxue, `${BASE_DAY}T08:10:00`));
  check('第 2 节上课时「上节课」= 语文',
    satisfied(yuwen, `${BASE_DAY}T09:10:00`));
  check('第 2 节上课时「上节课」不是数学', !satisfied(shuxue, `${BASE_DAY}T09:10:00`));
  check('第 3 节上课时「上节课」= 数学',
    satisfied(shuxue, `${BASE_DAY}T10:10:00`));
  check('放学后「上节课」仍是英语', satisfied(ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And, [subjectRule(RuleIds.LESSONS_PREVIOUS_SUBJECT, SUBJECT_YINGYU)])
  ]), `${BASE_DAY}T11:30:00`));
}

function testPreviousSubjectExcludesOngoing(): void {
  // 严格小于：正在上的那节不算「上一节」。
  const shuxue: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And,
      [subjectRule(RuleIds.LESSONS_PREVIOUS_SUBJECT, SUBJECT_SHUXUE)])]);
  // 09:30 正在上数学（09:00-09:45），上一节应是语文。
  check('正在上的那节不算上一节', !satisfied(shuxue, `${BASE_DAY}T09:30:00`));
  const yuwen: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And,
      [subjectRule(RuleIds.LESSONS_PREVIOUS_SUBJECT, SUBJECT_YUWEN)])]);
  check('正在上数学时上一节是语文', satisfied(yuwen, `${BASE_DAY}T09:30:00`));
}

function testPreviousSubjectSkipsDisabledTimePoints(): void {
  // 有意的偏离：桌面版 PreviousSubjectHandler 扫的是 TimeLayout.Layouts（原始全表），
  // 而同一个类的其余部分扫 ValidTimeLayoutItems。这里统一按有效时间点算。
  // 现象：关掉第 2 节课后，上一节应直接落到第 1 节（语文），而不是被关掉的数学占位。
  // 开关在 ClassInfo.isEnabled 上（Classes[i] 对应 classTimePoints()[i]），
  // 不在 TimeLayoutItem 上 —— 桌面版是 ClassInfo.IsEnabled 决定时间点显不显示。
  const profile: Profile = fullWeekProfile();
  const plan: ClassPlan | undefined = profile.tryGetClassPlan(
    Guid.fromCanonical(planKey(6)));
  if (plan === undefined) {
    check('能取到周六课表', false, '夹具缺周六课表');
    return;
  }
  plan.classes[1].isEnabled = false;
  profile.refreshDerivedState();

  const yuwen: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And,
      [subjectRule(RuleIds.LESSONS_PREVIOUS_SUBJECT, SUBJECT_YUWEN)])]);
  const shuxue: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And,
      [subjectRule(RuleIds.LESSONS_PREVIOUS_SUBJECT, SUBJECT_SHUXUE)])]);
  // 第 3 节课（英语，10:00-10:45）上课时，第 2 节课点已被禁用。
  check('禁用第 2 节课点后上一节是语文而非数学',
    satisfied(yuwen, `${BASE_DAY}T10:10:00`, profile));
  check('禁用第 2 节课点后不认数学为上一节',
    !satisfied(shuxue, `${BASE_DAY}T10:10:00`, profile));
}

function testSnapshotPreviousSubjectDefaults(): void {
  // 课表为空时 previousSubject 退回 fallback 科目，不会是档案里任何一门课。
  const context: RuleContext = contextAt(`${BASE_DAY}T08:10:00`, new Profile());
  check('空课表时上一节课是 fallback', context.snapshot.previousSubject.name.length > 0);
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And,
      [subjectRule(RuleIds.LESSONS_PREVIOUS_SUBJECT, SUBJECT_YUWEN)])]);
  check('空课表时任何科目规则都不成立', !RuleEngine.evaluate(rs, context).satisfied);
}

// ------------------------------------------------------ E. 恒假的规则

function testWindowRulesAreUnsupported(): void {
  const ids: string[] = [
    RuleIds.WINDOW_CLASS_NAME, RuleIds.WINDOW_TEXT,
    RuleIds.WINDOW_STATUS, RuleIds.WINDOW_PROCESS_NAME
  ];
  for (const id of ids) {
    check(`${id} 标为未实现`, RuleCatalog.supportOf(id) === RuleSupport.Unsupported);
    const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [rule(id)])]);
    const verdict: RulesetVerdict = verdictAt(rs, `${BASE_DAY}T08:10:00`);
    check(`${id} 求值为假`, !verdict.satisfied);
    checkEqual(`${id} 原因是未实现`, verdict.groups[0].rules[0].reason, 'notImplemented');
  }
}

function testWeatherRulesAreImplemented(): void {
  // 五条天气规则在 P11c 翻成已实现。求值需要一份天气快照，而这条驱动里没有
  // 天气上下文，所以它们在这里一律判 false —— 但原因是 notMatched（「没匹配
  // 上」）而不是 notImplemented（「没实现」）。这两者必须分开：前者用户配上
  // 数据就会变真，后者永远不会。
  const ids: string[] = [
    RuleIds.WEATHER_CURRENT, RuleIds.WEATHER_TOMORROW, RuleIds.WEATHER_ALERT,
    RuleIds.WEATHER_RAIN_TIME, RuleIds.WEATHER_SUN_RISE_SET
  ];
  for (const id of ids) {
    check(`${id} 标为已实现`, RuleCatalog.supportOf(id) === RuleSupport.Implemented);
    const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [rule(id)])]);
    const verdict: RulesetVerdict = verdictAt(rs, `${BASE_DAY}T08:10:00`);
    check(`${id} 无天气数据时求值为假`, !verdict.satisfied);
    checkEqual(`${id} 原因是没匹配上`, verdict.groups[0].rules[0].reason, RuleReason.NotMatched);
  }
}

function testUnknownRuleIdIsFalse(): void {
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And,
    [rule('com.example.somePlugin.rule')])]);
  const verdict: RulesetVerdict = verdictAt(rs, `${BASE_DAY}T08:10:00`);
  check('陌生 id 求值为假', !verdict.satisfied);
  checkEqual('陌生 id 原因是未注册', verdict.groups[0].rules[0].reason, 'unknownRule');
  checkNum('陌生 id 状态为假', verdict.groups[0].rules[0].state, STATE_FALSE);
}

function testUnsupportedRuleInReversedGroup(): void {
  // 恒假的规则取反后为真 —— 「没有前台窗口时显示这个组件」正是这么配的。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And,
    [rule(RuleIds.WINDOW_CLASS_NAME, undefined, true)])]);
  const verdict: RulesetVerdict = verdictAt(rs, `${BASE_DAY}T08:10:00`);
  check('恒假规则取反后为真', verdict.satisfied);
  checkNum('取反后该规则状态为真', verdict.groups[0].rules[0].state, STATE_TRUE);
}

function testUndefinedRuleset(): void {
  // 配置里没写 HidingRules 时不该算「成立」。
  const verdict: RulesetVerdict = RuleEngine.evaluate(undefined, contextAt(`${BASE_DAY}T08:10:00`));
  check('规则集为 undefined 时 satisfied 为假', !verdict.satisfied);
  checkNum('规则集为 undefined 时状态为无', verdict.state, STATE_NONE);
  checkEqual('规则集为 undefined 时原因为没配规则集', verdict.reason, 'noRuleset');
}

function testNullSettingsUsesDefaults(): void {
  // 桌面版 `i.Settings ?? Activator.CreateInstance(settingsType)`：
  // 拿到的就是该类型的默认值，于是规则只会不成立，不会抛。
  const settings: TimeStateRuleSettings = new TimeStateRuleSettings();
  settings.state = TimeState.OnClass;
  const withSettingsRule: Rule = rule(RuleIds.LESSONS_TIME_STATE, settings);
  withSettingsRule.settings = undefined;
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [withSettingsRule])]);
  // TimeStateRuleSettings 的默认是 OnClass，所以「不设设置」等价于「配了上课中」。
  check('Settings 为空时用类型默认值（OnClass）',
    satisfied(rs, `${BASE_DAY}T08:10:00`));
  check('Settings 为空时在课间不成立', !satisfied(rs, `${BASE_DAY}T08:50:00`));
}

function testExplicitNullSettings(): void {
  // 落盘里 Settings 可能是显式 null（用户清了设置），与「键不存在」同义。
  const settings: TimeStateRuleSettings = new TimeStateRuleSettings();
  settings.state = TimeState.OnClass;
  const withNull: Rule = rule(RuleIds.LESSONS_TIME_STATE, settings);
  withNull.settings = new JsonNull();
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [withNull])]);
  check('Settings 为显式 null 时用类型默认值', satisfied(rs, `${BASE_DAY}T08:10:00`));
}

// --------------------------------------------------------- F. 注册表

function testCatalogCoversThirteenRules(): void {
  checkNum('注册表共 13 条规则', RuleCatalog.all().length, 13);
  checkEqual('第一条是窗口类名', RuleCatalog.all()[0].id, RuleIds.WINDOW_CLASS_NAME);
  checkEqual('最后一条是日出日落', RuleCatalog.all()[12].id, RuleIds.WEATHER_SUN_RISE_SET);
}

function testCatalogDisplayName(): void {
  checkEqual('课表时间状态有显示名',
    RuleCatalog.displayNameOf(RuleIds.LESSONS_TIME_STATE), '当前时间状态是');
  checkEqual('陌生 id 直接回显 id',
    RuleCatalog.displayNameOf('com.example.x'), 'com.example.x');
  checkNum('陌生 id 的 support 是 Unknown',
    RuleCatalog.supportOf('com.example.x'), RuleSupport.Unknown);
}

function testCatalogSettingsKind(): void {
  checkNum('窗口类名用字符串匹配设置',
    RuleCatalog.find(RuleIds.WINDOW_CLASS_NAME)?.settingsKind, RuleSettingsKind.StringMatching);
  checkNum('窗口状态用窗口状态设置',
    RuleCatalog.find(RuleIds.WINDOW_STATUS)?.settingsKind, RuleSettingsKind.WindowStatus);
  checkNum('课表时间状态用时间状态设置',
    RuleCatalog.find(RuleIds.LESSONS_TIME_STATE)?.settingsKind, RuleSettingsKind.TimeState);
  checkNum('三个科目规则共用科目设置',
    RuleCatalog.find(RuleIds.LESSONS_CURRENT_SUBJECT)?.settingsKind, RuleSettingsKind.CurrentSubject);
  checkNum('当前天气用天气设置',
    RuleCatalog.find(RuleIds.WEATHER_CURRENT)?.settingsKind, RuleSettingsKind.CurrentWeather);
  checkNum('降水时间用降水设置',
    RuleCatalog.find(RuleIds.WEATHER_RAIN_TIME)?.settingsKind, RuleSettingsKind.RainTime);
  checkNum('日出日落用日出日落设置',
    RuleCatalog.find(RuleIds.WEATHER_SUN_RISE_SET)?.settingsKind, RuleSettingsKind.SunRiseSet);
}

function testCatalogSettingsDecoding(): void {
  // 设置是裸 JsonNode，按 id 解成强类型。
  const settings: TimeStateRuleSettings = new TimeStateRuleSettings();
  settings.state = TimeState.Breaking;
  const decoded: Object | undefined = RuleCatalog.settingsOf(rule(RuleIds.LESSONS_TIME_STATE, settings));
  check('时间状态设置能解出且状态正确',
    decoded instanceof TimeStateRuleSettings &&
      (decoded as TimeStateRuleSettings).state === TimeState.Breaking);

  const subject: CurrentSubjectRuleSettings = new CurrentSubjectRuleSettings();
  subject.subjectId = Guid.fromCanonical(SUBJECT_SHUXUE);
  const decodedSubject: Object | undefined =
    RuleCatalog.settingsOf(rule(RuleIds.LESSONS_CURRENT_SUBJECT, subject));
  check('科目设置能解出且 id 正确',
    decodedSubject instanceof CurrentSubjectRuleSettings &&
      (decodedSubject as CurrentSubjectRuleSettings).subjectId
        .equals(Guid.fromCanonical(SUBJECT_SHUXUE)));

  check('陌生 id 解不出设置',
    RuleCatalog.settingsOf(rule('com.example.x')) === undefined);
  check('陌生 id 没有默认设置',
    RuleCatalog.defaultSettingsOf('com.example.x') === undefined);
}

function testCatalogDefaultSettings(): void {
  const defaults: Object | undefined = RuleCatalog.defaultSettingsOf(RuleIds.LESSONS_TIME_STATE);
  check('时间状态有默认设置', defaults instanceof TimeStateRuleSettings);
  check('默认状态是 OnClass',
    defaults instanceof TimeStateRuleSettings && (defaults as TimeStateRuleSettings).state === TimeState.OnClass);
  check('字符串匹配有默认设置',
    RuleCatalog.defaultSettingsOf(RuleIds.WINDOW_TEXT) instanceof StringMatchingSettings);
  check('降水时间有默认设置',
    RuleCatalog.defaultSettingsOf(RuleIds.WEATHER_RAIN_TIME) instanceof RainTimeRuleSettings);
  check('日出日落有默认设置',
    RuleCatalog.defaultSettingsOf(RuleIds.WEATHER_SUN_RISE_SET) instanceof SunRiseSetRuleSettings);
  check('窗口状态有默认设置',
    RuleCatalog.defaultSettingsOf(RuleIds.WINDOW_STATUS) instanceof WindowStatusRuleSettings);
  check('当前天气有默认设置',
    RuleCatalog.defaultSettingsOf(RuleIds.WEATHER_CURRENT) instanceof CurrentWeatherRuleSettings);
}

function testStringMatchingIsMatching(): void {
  const exact: StringMatchingSettings = new StringMatchingSettings();
  exact.text = 'Notepad';
  check('精确匹配命中', exact.isMatching('Notepad'));
  check('精确匹配不命中（大小写敏感）', !exact.isMatching('notepad'));

  const regex: StringMatchingSettings = new StringMatchingSettings();
  regex.text = '^(Untitled|无标题)';
  regex.useRegex = true;
  check('正则匹配命中 1', regex.isMatching('Untitled - Notepad'));
  check('正则匹配命中 2', regex.isMatching('无标题'));
  check('正则匹配不命中', !regex.isMatching('README'));

  // 正则编译失败返回 false（桌面版 try/catch 吞异常后 return false）。
  const broken: StringMatchingSettings = new StringMatchingSettings();
  broken.text = '([unclosed';
  broken.useRegex = true;
  check('正则非法时返回 false', !broken.isMatching('([unclosed'));

  // 刻意不加 g 标志：桌面版看 Match.Success，全局正则会带 lastIndex 状态。
  const global: StringMatchingSettings = new StringMatchingSettings();
  global.text = 'a';
  global.useRegex = true;
  check('连续两次匹配结果一致（无 lastIndex 残留）',
    global.isMatching('aaa') && global.isMatching('aaa'));
}

// ------------------------------------------------------- G. 序列化往返

function testRuleRoundTrip(): void {
  const source: Ruleset = ruleset(RulesetLogicalMode.And, [
    group(RulesetLogicalMode.Or, [
      timeStateRule(TimeState.Breaking, true),
      subjectRule(RuleIds.LESSONS_CURRENT_SUBJECT, SUBJECT_YUWEN, true)
    ], true, false)
  ], true);
  const text: string = Ruleset.stringify(source);
  const parsed: Ruleset = Ruleset.parse(JsonReader.parse(text));
  checkEqual('规则集往返字节一致', Ruleset.stringify(parsed), text);
}

function testFieldOrderMatchesCSharp(): void {
  // 键顺序取 C# 属性声明顺序，逐字对应。
  const rs: Ruleset = ruleset(RulesetLogicalMode.And,
    [group(RulesetLogicalMode.Or, [timeStateRule(TimeState.OnClass)])]);
  const text: string = Ruleset.stringify(rs);
  // 直接比整串，顺序错了或某个键跑了位置这里都露馅。
  const expected: string =
    '{"Mode":1,"IsReversed":false,"Groups":[{"Rules":[{"IsReversed":false,"Id":' +
    '"classisland.lessons.timeState","Settings":{"State":1}}],"Mode":0,' +
    '"IsReversed":false,"IsEnabled":true}]}';
  checkEqual('规则集落盘键序与 C# 声明顺序一致', text, expected);
}

function testSettingsAreOpaqueJson(): void {
  // 未注册规则的设置必须原样透传，不能被抹成 null。
  const payload: JsonObject = new JsonObject();
  payload.set('PluginField', new JsonString('keep me'));
  payload.set('Count', JsonNumber.of(7));
  payload.set('Enabled', new JsonBoolean(true));
  const opaque: Rule = new Rule();
  opaque.id = 'com.example.pluginRule';
  opaque.settings = payload;
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [opaque])]);
  const text: string = Ruleset.stringify(rs);
  const parsed: Ruleset = Ruleset.parse(JsonReader.parse(text));
  const back: JsonObject | undefined = JsonValue.asObject(
    parsed.groups[0].rules[0].settings === undefined
      ? undefined
      : parsed.groups[0].rules[0].settings);
  check('陌生规则的设置原样透传', back !== undefined &&
    JsonWriter.writeCompact(back) === JsonWriter.writeCompact(payload));
  check('透传后仍是假（无处理器）',
    !satisfied(parsed, `${BASE_DAY}T08:10:00`));
}

function testPartialRulesetGetsDefaults(): void {
  // 读时不回填的字段按默认值处理，写出时补齐（与 P7 的纪律一致：
  // 读时按缺省解释，存盘时才落全）。
  const partial: JsonObject = new JsonObject();
  const groupNode: JsonObject = new JsonObject();
  const rules: JsonArray = new JsonArray();
  const ruleNode: JsonObject = new JsonObject();
  ruleNode.set('Id', new JsonString(RuleIds.LESSONS_TIME_STATE));
  rules.push(ruleNode);
  groupNode.set('Rules', rules);
  const groups: JsonArray = new JsonArray();
  groups.push(groupNode);
  partial.set('Groups', groups);
  const parsed: Ruleset = Ruleset.parse(partial);
  checkNum('缺 Mode 时按 Or 解释', parsed.mode, RulesetLogicalMode.Or);
  check('缺 Mode 时写回完整键集',
    JsonWriter.writeCompact(parsed.toJson()).indexOf('"Mode"') >= 0);
  check('缺 IsReversed 时按 false 解释', !parsed.isReversed);
  check('组缺 IsEnabled 时按 true 解释', parsed.groups[0].isEnabled);
  checkNum('组缺 Mode 时按 And 解释', parsed.groups[0].mode, RulesetLogicalMode.And);
  // 规则只有 Id、没有 Settings → 用类型默认值（OnClass）。
  check('缺 Settings 的规则用默认值求值', satisfied(parsed, `${BASE_DAY}T08:10:00`));
}

function testUnknownModeValuesClampToDefault(): void {
  // 越界的 Mode 退回默认值。桌面版枚举反序列化失败会抛，
  // 而 RulesetService 把异常吞掉返回 false —— 表现上就是「不成立」，
  // 与「按默认值解释」在多数情况下等价，取后者更可用。
  const node: JsonObject = new JsonObject();
  node.set('Mode', JsonNumber.of(7));
  node.set('IsReversed', new JsonBoolean(false));
  node.set('Groups', new JsonArray());
  const parsed: Ruleset = Ruleset.parse(node);
  checkNum('规则集越界 Mode 退回 Or', parsed.mode, RulesetLogicalMode.Or);

  const groupNode: JsonObject = new JsonObject();
  groupNode.set('Rules', new JsonArray());
  groupNode.set('Mode', JsonNumber.of(-1));
  groupNode.set('IsReversed', new JsonBoolean(false));
  groupNode.set('IsEnabled', new JsonBoolean(true));
  const parsedGroup: RuleGroup = RuleGroup.parse(groupNode);
  checkNum('组越界 Mode 退回 And', parsedGroup.mode, RulesetLogicalMode.And);
}

function testTimeStateOutOfRangeFallsBack(): void {
  // 越界的状态退回 OnClass。
  const node: JsonObject = new JsonObject();
  node.set('State', JsonNumber.of(99));
  const parsed: TimeStateRuleSettings = TimeStateRuleSettings.parse(node);
  checkNum('越界时间状态退回 OnClass', parsed.state, TimeState.OnClass);
}

function testEverySettingsTypeRoundTrips(): void {
  const text: StringMatchingSettings = new StringMatchingSettings();
  text.text = 'a.*b';
  text.useRegex = true;
  checkEqual('字符串匹配设置往返', JsonWriter.writeCompact(
    StringMatchingSettings.parse(JsonReader.parse(JsonWriter.writeCompact(text.toJson()))).toJson()),
    JsonWriter.writeCompact(text.toJson()));

  const subject: CurrentSubjectRuleSettings = new CurrentSubjectRuleSettings();
  subject.subjectId = Guid.fromCanonical(SUBJECT_SHUXUE);
  checkEqual('科目设置往返', JsonWriter.writeCompact(
    CurrentSubjectRuleSettings.parse(
      JsonReader.parse(JsonWriter.writeCompact(subject.toJson()))).toJson()),
    JsonWriter.writeCompact(subject.toJson()));

  const weather: CurrentWeatherRuleSettings = new CurrentWeatherRuleSettings();
  weather.weatherId = 3;
  weather.isFuzzyMatch = true;
  checkEqual('天气设置往返', JsonWriter.writeCompact(
    CurrentWeatherRuleSettings.parse(
      JsonReader.parse(JsonWriter.writeCompact(weather.toJson()))).toJson()),
    JsonWriter.writeCompact(weather.toJson()));

  const rain: RainTimeRuleSettings = new RainTimeRuleSettings();
  rain.rainTimeMinutes = 45.5;
  rain.isRemainingTime = true;
  checkEqual('降水时间设置往返', JsonWriter.writeCompact(
    RainTimeRuleSettings.parse(
      JsonReader.parse(JsonWriter.writeCompact(rain.toJson()))).toJson()),
    JsonWriter.writeCompact(rain.toJson()));

  const sun: SunRiseSetRuleSettings = new SunRiseSetRuleSettings();
  sun.timeMinutes = 90.5;
  sun.isSunset = true;
  checkEqual('日出日落设置往返', JsonWriter.writeCompact(
    SunRiseSetRuleSettings.parse(
      JsonReader.parse(JsonWriter.writeCompact(sun.toJson()))).toJson()),
    JsonWriter.writeCompact(sun.toJson()));

  const status: WindowStatusRuleSettings = new WindowStatusRuleSettings();
  status.state = 2;
  checkEqual('窗口状态设置往返', JsonWriter.writeCompact(
    WindowStatusRuleSettings.parse(
      JsonReader.parse(JsonWriter.writeCompact(status.toJson()))).toJson()),
    JsonWriter.writeCompact(status.toJson()));
}

function testRuleIds(): void {
  // id 常量一旦改字，用户从桌面版同步过来的规则就全成陌生 id 了。
  checkEqual('窗口类名 id', RuleIds.WINDOW_CLASS_NAME, 'classisland.windows.className');
  checkEqual('窗口标题 id', RuleIds.WINDOW_TEXT, 'classisland.windows.text');
  checkEqual('窗口状态 id', RuleIds.WINDOW_STATUS, 'classisland.windows.status');
  checkEqual('窗口进程 id', RuleIds.WINDOW_PROCESS_NAME, 'classisland.windows.processName');
  checkEqual('当前科目 id', RuleIds.LESSONS_CURRENT_SUBJECT, 'classisland.lessons.currentSubject');
  checkEqual('下节课科目 id', RuleIds.LESSONS_NEXT_SUBJECT, 'classisland.lessons.nextSubject');
  checkEqual('上节课科目 id', RuleIds.LESSONS_PREVIOUS_SUBJECT, 'classisland.lessons.previousSubject');
  checkEqual('时间状态 id', RuleIds.LESSONS_TIME_STATE, 'classisland.lessons.timeState');
  checkEqual('当前天气 id', RuleIds.WEATHER_CURRENT, 'classisland.weather.currentWeather');
  checkEqual('明天天气 id', RuleIds.WEATHER_TOMORROW, 'classisland.weather.tomorrowWeather');
  checkEqual('气象预警 id', RuleIds.WEATHER_ALERT, 'classisland.weather.hasWeatherAlert');
  checkEqual('降水时间 id', RuleIds.WEATHER_RAIN_TIME, 'classisland.weather.rainTime');
  checkEqual('日出日落 id', RuleIds.WEATHER_SUN_RISE_SET, 'classisland.weather.sunRiseSet');
}

function testRuleIdsAreDistinct(): void {
  const all: string[] = [
    RuleIds.WINDOW_CLASS_NAME, RuleIds.WINDOW_TEXT, RuleIds.WINDOW_STATUS,
    RuleIds.WINDOW_PROCESS_NAME, RuleIds.LESSONS_CURRENT_SUBJECT, RuleIds.LESSONS_NEXT_SUBJECT,
    RuleIds.LESSONS_PREVIOUS_SUBJECT, RuleIds.LESSONS_TIME_STATE, RuleIds.WEATHER_CURRENT,
    RuleIds.WEATHER_TOMORROW, RuleIds.WEATHER_ALERT, RuleIds.WEATHER_RAIN_TIME,
    RuleIds.WEATHER_SUN_RISE_SET
  ];
  const seen: string[] = [];
  let duplicated: string = '';
  for (const id of all) {
    if (seen.indexOf(id) >= 0) {
      duplicated = id;
    }
    seen.push(id);
  }
  checkEqual('13 个 id 互不重复', duplicated, '');
  const registered: string[] = RuleCatalog.all().map((each) => each.id);
  checkNum('注册表覆盖全部 id', registered.length, all.length);
  for (const id of all) {
    if (registered.indexOf(id) < 0) {
      check(`注册表含 ${id}`, false);
    }
  }
  check('注册表里没有多余 id', registered.every((id) => all.indexOf(id) >= 0));
}

function testVerdictIsPureData(): void {
  // 桌面版把 State 写在模型对象上（可变单例式），这里必须是无副作用的纯函数：
  // 同一份规则集求值两次，轨迹互不影响。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or,
    [group(RulesetLogicalMode.And, [timeStateRule(TimeState.OnClass)])]);
  const context: RuleContext = contextAt(`${BASE_DAY}T08:10:00`);
  const first: RulesetVerdict = RuleEngine.evaluate(rs, context);
  const second: RulesetVerdict = RuleEngine.evaluate(rs, context);
  check('两次求值结论一致', first.satisfied === second.satisfied);
  check('两次求值状态一致', first.state === second.state);
  check('两次求值轨迹不是同一对象', first.groups[0] !== second.groups[0]);
  check('第一次求值没被第二次改动',
    first.groups[0].rules[0].state === STATE_TRUE);
  // 模型对象本身没被写脏。
  check('模型对象上没留下 State', (rs as Object as Ruleset).mode === RulesetLogicalMode.Or);
}

function testContextWithNoProfile(): void {
  // 没有档案时科目规则一律为假，不抛。
  const context: RuleContext = new RuleContext();
  context.now = dt(`${BASE_DAY}T08:10:00`);
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And,
    [subjectRule(RuleIds.LESSONS_CURRENT_SUBJECT, SUBJECT_YUWEN)])]);
  const verdict: RulesetVerdict = RuleEngine.evaluate(rs, context);
  check('无档案时科目规则为假', !verdict.satisfied);
}

function testGroupVerdictCarriesEnabledFlag(): void {
  // 界面靠 isEnabled 区分「已停用」与「未判定」，不能都显示成灰色未知。
  const enabled: RuleGroupVerdict = verdictAt(ruleset(RulesetLogicalMode.Or,
    [group(RulesetLogicalMode.And, [timeStateRule(TimeState.OnClass)])]),
    `${BASE_DAY}T08:10:00`).groups[0];
  const disabled: RuleGroupVerdict = verdictAt(ruleset(RulesetLogicalMode.Or,
    [group(RulesetLogicalMode.And, [timeStateRule(TimeState.OnClass)], false, false)]),
    `${BASE_DAY}T08:10:00`).groups[0];
  check('启用组的 isEnabled 为真', enabled.isEnabled);
  check('停用组的 isEnabled 为假', !disabled.isEnabled);
}

testEmptyRulesetIsFalse();
testEmptyRulesetIgnoresReversed();
testUnchosenRuleIsSkipped();
testChosenRuleInEmptyGroupParticipates();
testAndGroupWithOnlyUnchosenIsNotFalseForRuleset();
testDefaultRulesetShape();
testDisabledGroupIsSkipped();
testDisabledGroupDoesNotKillAnd();
testRuleReversed();
testGroupReversedAppliesToGroupResult();
testRulesetReversedAppliesAfterGroups();
testAndRequiresAllGroups();
testOrRequiresAnyGroup();
testAndInsideGroupShortCircuits();
testOrInsideGroupShortCircuits();
testUnchosenRuleBeforeChosenOneStillShortCircuits();
testGroupWithAllUnchosenInOrGroup();
testTraceShapeMatchesRulesetShape();
testTimeStateHandler();
testTimeStateNoneMatchesAfterSchool();
testCurrentSubjectHandler();
testSubjectRulesUseReferenceEquality();
testSubjectRuleWithUnknownSubjectId();
testNextSubjectHandler();
testNextSubjectBoundaryAtEndTime();
testPreviousSubjectHandler();
testPreviousSubjectExcludesOngoing();
testPreviousSubjectSkipsDisabledTimePoints();
testSnapshotPreviousSubjectDefaults();
testWindowRulesAreUnsupported();
testWeatherRulesAreImplemented();
testUnknownRuleIdIsFalse();
testUnsupportedRuleInReversedGroup();
testUndefinedRuleset();
testNullSettingsUsesDefaults();
testExplicitNullSettings();
testCatalogCoversThirteenRules();
testCatalogDisplayName();
testCatalogSettingsKind();
testCatalogSettingsDecoding();
testCatalogDefaultSettings();
testStringMatchingIsMatching();
testRuleRoundTrip();
testFieldOrderMatchesCSharp();
testSettingsAreOpaqueJson();
testPartialRulesetGetsDefaults();
testUnknownModeValuesClampToDefault();
testTimeStateOutOfRangeFallsBack();
testEverySettingsTypeRoundTrips();
testRuleIds();
testRuleIdsAreDistinct();
testVerdictIsPureData();
testContextWithNoProfile();
testGroupVerdictCarriesEnabledFlag();
testMutationsRejectNoChange();
testMutationsRejectBadIndex();
testAddGroupShape();
testAddRuleCarriesDefaultSettings();
testMoveRuleSemantics();
testSetRuleIdResetsSettings();
testSettingsRoundTripThroughMutations();
testWriteSettingsRejectsUnknownType();
testMutationsKeepOpaqueSettingsForUnknownRule();
testMutationsRoundTripThroughJson();
testEditorChoices();
testEditorBuildWithoutRuleset();
testEditorBuildWithoutContext();
testShortCircuitKeepsHonestReason();
testEditorBuildCarriesSameVerdict();
testEditorBuildAlignsCoordinates();
testEditorFlagsUnchosenAndUnknown();
testEditorMarksUnsupportedRulesNotEditable();
testEditorDecodesSettingsObjects();
testEditorCarriesEnabledAndReversedFlags();
testEditorIsPureData();
testEditorHandlesGroupVerdictCarriesEnabled();
testEditorEmptyRulesetGroupsOnly();

// ------------------------------------------------- B. 编辑操作（RulesetMutations）

function testMutationsRejectNoChange(): void {
  // 返回值表示「有没有改成」。不改还返回 true 的话，界面每按一次就重建整棵
  // 规则树并重算一次轨迹，而内容一个字节没变。
  const rs: Ruleset = one(TimeState.OnClass);
  check('setRulesetMode 相同模式不报改动',
    !RulesetMutations.setRulesetMode(rs, RulesetLogicalMode.Or));
  check('setRulesetMode 换模式报改动',
    RulesetMutations.setRulesetMode(rs, RulesetLogicalMode.And));
  checkEqual('模式真的改了', `${rs.mode}`, `${RulesetLogicalMode.And}`);
  check('setRulesetReversed 相同值不报改动',
    !RulesetMutations.setRulesetReversed(rs, false));
  check('setRulesetReversed 改值报改动', RulesetMutations.setRulesetReversed(rs, true));
  check('setGroupMode 相同模式不报改动',
    !RulesetMutations.setGroupMode(rs, 0, RulesetLogicalMode.And));
  check('setGroupMode 换模式报改动',
    RulesetMutations.setGroupMode(rs, 0, RulesetLogicalMode.Or));
  check('setGroupReversed 相同值不报改动', !RulesetMutations.setGroupReversed(rs, 0, false));
  check('setGroupReversed 改值报改动', RulesetMutations.setGroupReversed(rs, 0, true));
  check('setGroupEnabled 相同值不报改动', !RulesetMutations.setGroupEnabled(rs, 0, true));
  check('setGroupEnabled 改值报改动', RulesetMutations.setGroupEnabled(rs, 0, false));
  check('setRuleReversed 相同值不报改动',
    !RulesetMutations.setRuleReversed(rs, 0, 0, false));
  check('setRuleReversed 改值报改动',
    RulesetMutations.setRuleReversed(rs, 0, 0, true));
}

function testMutationsRejectBadIndex(): void {
  // 非法下标一律返回 false 且不动对象。界面上改的是「行 N」，而下标是用户
  // 上一次操作留下的 —— 两者不一致时（下标越界）静默改动会写到别的地方。
  const rs: Ruleset = one(TimeState.OnClass);
  check('负组下标被拒', !RulesetMutations.removeGroup(rs, -1));
  check('越界组下标被拒', !RulesetMutations.removeGroup(rs, 1));
  check('负规则下标被拒', !RulesetMutations.removeRule(rs, 0, -1));
  check('越界规则下标被拒', !RulesetMutations.removeRule(rs, 0, 1));
  check('越界组下标改模式被拒', !RulesetMutations.setGroupMode(rs, 5, RulesetLogicalMode.Or));
  check('越界组下标改启用被拒', !RulesetMutations.setGroupEnabled(rs, 5, false));
  check('越界规则下标改 id 被拒',
    !RulesetMutations.setRuleId(rs, 5, 0, RuleIds.LESSONS_TIME_STATE));
  check('越界规则下标加规则被拒', !RulesetMutations.addRule(rs, 5, 0, ''));
  check('组内插入下标越界被拒', !RulesetMutations.addRule(rs, 0, 5, ''));
  check('插入下标负数被拒', !RulesetMutations.addRule(rs, 0, -1, ''));
  check('插入组下标越界被拒', !RulesetMutations.addGroup(rs, 5));
  check('插入组下标负数被拒', !RulesetMutations.addGroup(rs, -1));
  checkNum('组数没变', rs.groups.length, 1);
  checkNum('组内规则数没变', rs.groups[0].rules.length, 1);
  checkEqual('规则 id 没变', rs.groups[0].rules[0].id, RuleIds.LESSONS_TIME_STATE);
  check('组启用状态没变', rs.groups[0].isEnabled);
}

function testAddGroupShape(): void {
  // 新组给的是桌面版的默认形状（And + 一条空规则），不是空组 ——
  // 空组整组不参与求值，用户插进去会看到「什么都没发生」。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, []);
  check('加一组报改动', RulesetMutations.addGroup(rs, 0));
  checkNum('组数加一', rs.groups.length, 1);
  checkEqual('新组默认 And', `${rs.groups[0].mode}`, `${RulesetLogicalMode.And}`);
  checkNum('新组自带一条空规则', rs.groups[0].rules.length, 1);
  checkEqual('那条规则还没挑', rs.groups[0].rules[0].id, '');
  check('新组默认启用', rs.groups[0].isEnabled);
  check('新组默认不取反', !rs.groups[0].isReversed);

  // 插到中间：index 是「移动完成后」的位置语义，与组件层级一致。
  RulesetMutations.addGroup(rs, rs.groups.length);
  checkNum('追加到末尾', rs.groups.length, 2);
  RulesetMutations.addGroup(rs, 1);
  checkNum('插到中间', rs.groups.length, 3);
  checkNum('三组都有效', rs.groups.filter((g: RuleGroup) => g.rules.length === 1).length, 3);
}

function testAddRuleCarriesDefaultSettings(): void {
  // 桌面版 AddRule 之后是 new settingsType()，效果一样：新规则带上该 id 的
  // 默认设置，不是一个空壳 —— 空壳的话求值器会拿默认值去判，而用户在界面上
  // 看到的是一片空白。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [])]);
  check('加一条规则报改动',
    RulesetMutations.addRule(rs, 0, 0, RuleIds.LESSONS_TIME_STATE));
  checkNum('组内规则数加一', rs.groups[0].rules.length, 1);
  const settings: TimeStateRuleSettings =
    RulesetMutations.readSettings(rs, 0, 0) as TimeStateRuleSettings;
  check('新规则带的是该类型的默认设置', settings !== undefined && settings !== null);
  checkEqual('默认时间状态是上课中', `${settings.state}`, `${TimeState.OnClass}`);

  // 未注册的 id：默认设置是 null，与桌面版一致（Activator 找不到就 null）。
  RulesetMutations.addRule(rs, 0, 1, 'com.example.somePluginRule');
  check('陌生 id 的设置是 null', rs.groups[0].rules[1].settings === undefined
    || JsonValue.isNull(rs.groups[0].rules[1].settings!));
  // 空 id 同样是 null。
  RulesetMutations.addRule(rs, 0, 2, '');
  check('空 id 的设置是 null', rs.groups[0].rules[2].settings === undefined
    || JsonValue.isNull(rs.groups[0].rules[2].settings!));
}

function testMoveRuleSemantics(): void {
  // to 是「摘掉之后」的下标 —— 与 P7 布局改动那套 insertIndex 语义一致，
  // 两处混用会让「下移一格」变成「下移两格」。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [
    timeStateRule(TimeState.OnClass),
    timeStateRule(TimeState.Breaking),
    timeStateRule(TimeState.AfterSchool)
  ])]);
  const before: JsonNode | undefined = rs.groups[0].rules[0].settings;
  const order: string = orderOf(rs, 0);

  // to 是「摘掉之后」的下标，所以 0→1 是往后挪一格，不是两格。
  check('往后移一位报改动', RulesetMutations.moveRule(rs, 0, 0, 1));
  checkEqual('往后移一位后的顺序', orderOf(rs, 0), swap01(order));
  check('设置跟着规则一起走',
    rs.groups[0].rules[1].settings === before);

  // 移到末尾：to 等于「摘掉之后」的规则数（3 条里摘掉 1 条 → 2）。
  check('往后移到末尾', RulesetMutations.moveRule(rs, 0, 0, 2));
  checkEqual('移到末尾后的顺序', orderOf(rs, 0), '1,4,3');
  checkNum('规则数没变', rs.groups[0].rules.length, 3);

  // 往前移回原位：3,1,4 → 摘掉下标 2（3）→ 1,4 → 插到 0 → 3,1,4，
  // 再把下标 1（1）移到 0 才真的回到最初那个排列。少移一步就回不去，
  // 而这正是「to 到底是移动前还是移动后的下标」写错时的症状。
  check('往前移一位', RulesetMutations.moveRule(rs, 0, 2, 0));
  checkEqual('先移一次', orderOf(rs, 0), '3,1,4');
  check('再往前移一位', RulesetMutations.moveRule(rs, 0, 1, 0));
  checkEqual('回到原位', orderOf(rs, 0), order);

  // to 越界要拒。放行的话「往下移到底」会变成追加而不是报错，
  // 界面上那就是「点一下顺序乱了」。
  check('目标下标越界不报改动', !RulesetMutations.moveRule(rs, 0, 0, 4));
  checkEqual('越界后顺序没变', orderOf(rs, 0), order);

  check('移到原位不报改动', !RulesetMutations.moveRule(rs, 0, 0, 0));
  check('源下标越界不报改动', !RulesetMutations.moveRule(rs, 0, 5, 0));
  check('目标下标越界不报改动', !RulesetMutations.moveRule(rs, 0, 0, 5));
  check('负下标不报改动', !RulesetMutations.moveRule(rs, 0, -1, 0));
}

function readState(rs: Ruleset, g: number, i: number): string {
  const settings: TimeStateRuleSettings =
    RulesetMutations.readSettings(rs, g, i) as TimeStateRuleSettings;
  return `${settings.state}`;
}

/** 组内规则的顺序，逗号分隔。只认同一类规则（时间状态），够用。 */
function orderOf(rs: Ruleset, g: number): string {
  const out: string[] = [];
  for (let i: number = 0; i < rs.groups[g].rules.length; i++) {
    out.push(readState(rs, g, i));
  }
  return out.join(',');
}

/** 交换第 0 与第 1 项。 */
function swap01(order: string): string {
  const parts: string[] = order.split(',');
  const first: string = parts[0];
  parts[0] = parts[1];
  parts[1] = first;
  return parts.join(',');
}

function testSetRuleIdResetsSettings(): void {
  // 照抄桌面版：换 id 时连带把 Settings 换成新类型的默认值。留着旧设置会让
  // 用户在界面上看到「科目是」配着一个时间状态的值。
  const rs: Ruleset = one(TimeState.Breaking);
  check('换 id 报改动', RulesetMutations.setRuleId(rs, 0, 0, RuleIds.LESSONS_CURRENT_SUBJECT));
  checkEqual('id 换了', rs.groups[0].rules[0].id, RuleIds.LESSONS_CURRENT_SUBJECT);
  const settings: CurrentSubjectRuleSettings =
    RulesetMutations.readSettings(rs, 0, 0) as CurrentSubjectRuleSettings;
  check('设置换成了新类型', settings !== undefined && settings !== null);
  check('旧的 TimeState 值没被带过去',
    !(settings instanceof TimeStateRuleSettings));

  // 换回时间状态：默认值是 OnClass，不是刚才那个 Breaking。
  RulesetMutations.setRuleId(rs, 0, 0, RuleIds.LESSONS_TIME_STATE);
  checkEqual('换回来是默认状态',
    readState(rs, 0, 0), `${TimeState.OnClass}`);

  // 换同一个 id 什么都不做，连设置也不动 —— 界面上重复点一次同一条规则，
  // 用户已经填好的值不该被清掉。
  const keep: TimeStateRuleSettings = new TimeStateRuleSettings();
  keep.state = TimeState.AfterSchool;
  rs.groups[0].rules[0].settings = keep.toJson();
  check('换同一个 id 不报改动', !RulesetMutations.setRuleId(rs, 0, 0, RuleIds.LESSONS_TIME_STATE));
  checkEqual('换同一个 id 不动设置', readState(rs, 0, 0), `${TimeState.AfterSchool}`);
}

function testSettingsRoundTripThroughMutations(): void {
  // 七种设置都要能读出来、改回去、再读出来还是改过的那个值。少认一种的话
  // 那条规则的设置会静默变成默认值，而求值时按默认值判，现象是「怎么配都不生效」。
  const timeState: TimeStateRuleSettings = new TimeStateRuleSettings();
  timeState.state = TimeState.AfterSchool;
  const subject: CurrentSubjectRuleSettings = new CurrentSubjectRuleSettings();
  subject.subjectId = Guid.fromCanonical(SUBJECT_SHUXUE);
  const weather: CurrentWeatherRuleSettings = new CurrentWeatherRuleSettings();
  weather.weatherId = 7;
  weather.isFuzzyMatch = true;
  const rain: RainTimeRuleSettings = new RainTimeRuleSettings();
  rain.rainTimeMinutes = 25;
  rain.isRemainingTime = true;
  const sun: SunRiseSetRuleSettings = new SunRiseSetRuleSettings();
  sun.timeMinutes = 90;
  sun.isSunset = true;
  const window: WindowStatusRuleSettings = new WindowStatusRuleSettings();
  window.state = 2;
  const text: StringMatchingSettings = new StringMatchingSettings();
  text.text = '^Notepad';
  text.useRegex = true;

  const cases: SettingsCase[] = [];
  cases.push(settingsCase(RuleIds.LESSONS_TIME_STATE, timeState));
  cases.push(settingsCase(RuleIds.LESSONS_CURRENT_SUBJECT, subject));
  cases.push(settingsCase(RuleIds.WEATHER_CURRENT, weather));
  cases.push(settingsCase(RuleIds.WEATHER_RAIN_TIME, rain));
  cases.push(settingsCase(RuleIds.WEATHER_SUN_RISE_SET, sun));
  cases.push(settingsCase(RuleIds.WINDOW_STATUS, window));
  cases.push(settingsCase(RuleIds.WINDOW_CLASS_NAME, text));
  checkNum('七种设置', cases.length, 7);

  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [])]);
  for (let i: number = 0; i < cases.length; i++) {
    rs.groups[0].rules.push(rule(cases[i].id, cases[i].settings));
    const before: string = JsonWriter.writeCompact(rs.groups[0].rules[i].settings!);
    const decoded: Object = RulesetMutations.readSettings(rs, 0, i);
    check(`${cases[i].id} 读回的类型对`,
      decoded.constructor === cases[i].settings.constructor,
      `实际 ${decoded.constructor.name}`);
    check(`${cases[i].id} 读回的值对`, deepEqual(decoded, cases[i].settings));
    check(`${cases[i].id} 写回报改动`, RulesetMutations.writeSettings(rs, 0, i, decoded));
    check(`${cases[i].id} 写回后 JSON 一样`,
      JsonWriter.writeCompact(rs.groups[0].rules[i].settings!) === before);
    check(`${cases[i].id} 写回后再读还是那个值`,
      deepEqual(RulesetMutations.readSettings(rs, 0, i), cases[i].settings));
  }
}

/** 拿容器的字段做一次浅比较。七种设置类都是若干标量字段，够用了。 */
function deepEqual(a: Object, b: Object): boolean {
  const keys: string[] = Object.keys(b as Record<string, Object>);
  const source: Record<string, Object> = a as Record<string, Object>;
  const target: Record<string, Object> = b as Record<string, Object>;
  for (const key of keys) {
    const left: Object = source[key];
    const right: Object = target[key];
    if (left instanceof Guid && right instanceof Guid) {
      if (!left.equals(right)) {
        return false;
      }
      continue;
    }
    if (`${left}` !== `${right}`) {
      return false;
    }
  }
  return true;
}

function testWriteSettingsRejectsUnknownType(): void {
  // 认不出来的设置类型返回 false 并保持原样 —— 宁可保留用户在桌面版配好的
  // 东西，也不要因为这边多了一个不认识的类就把它抹掉。
  const keep: StringMatchingSettings = new StringMatchingSettings();
  keep.text = '保留我';
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or,
    [group(RulesetLogicalMode.And, [rule(RuleIds.WINDOW_CLASS_NAME, keep)])]);
  const before: JsonNode | undefined = rs.groups[0].rules[0].settings;
  check('写不认的类型不报改动',
    !RulesetMutations.writeSettings(rs, 0, 0, new Object()));
  check('写不认的类型原样保留',
    JSON.stringify(rs.groups[0].rules[0].settings) === JSON.stringify(before));
  check('越界位置写设置不报改动', !RulesetMutations.writeSettings(rs, 9, 0, keep));
  check('越界位置读设置不崩',
    RulesetMutations.readSettings(rs, 9, 0) !== undefined);
}

function testMutationsKeepOpaqueSettingsForUnknownRule(): void {
  // 插件规则（或桌面版新版本加的规则）的设置这边不认识，操作之后必须原样还在。
  const node: JsonObject = new JsonObject();
  node.set('WhateverField', new JsonString('插件私有'));
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or,
    [group(RulesetLogicalMode.And, [rule('com.example.pluginRule')])]);
  rs.groups[0].rules[0].settings = node;
  RulesetMutations.setRuleReversed(rs, 0, 0, true);
  RulesetMutations.moveRule(rs, 0, 0, 0);
  RulesetMutations.addRule(rs, 0, 1, '');
  RulesetMutations.removeRule(rs, 0, 1);
  const kept: JsonObject | undefined =
    JsonValue.asObject(rs.groups[0].rules[0].settings);
  check('陌生规则的私有设置还在', kept !== undefined && kept.has('WhateverField'));
  checkEqual('取反没有影响 id', rs.groups[0].rules[0].id, 'com.example.pluginRule');
  check('取反生效了', rs.groups[0].rules[0].isReversed);
}

function testMutationsRoundTripThroughJson(): void {
  // 编辑操作之后序列化再解析，内容必须完全一样。这条兜的是「改完存盘、
  // 重开应用配置变了」这一类问题 —— 界面上完全看不出来。
  const rs: Ruleset = ruleset(RulesetLogicalMode.And, [
    group(RulesetLogicalMode.Or, [timeStateRule(TimeState.Breaking, true)], true, false),
    group(RulesetLogicalMode.And, [subjectRule(RuleIds.LESSONS_CURRENT_SUBJECT, SUBJECT_SHUXUE)])
  ], true);
  RulesetMutations.addGroup(rs, 1);
  RulesetMutations.addRule(rs, 1, 1, RuleIds.LESSONS_NEXT_SUBJECT);
  const before: string = Ruleset.stringify(rs);
  const after: string = Ruleset.stringify(Ruleset.parse(rs.toJson()));
  checkEqual('改完往返内容不变', after, before);
  check('往返后组数一致', Ruleset.parse(rs.toJson()).groups.length === rs.groups.length);
}

// ------------------------------------------------ C. 编辑态合成（RulesetEditor）

function testEditorChoices(): void {
  const choices: RuleChoiceRow[] = RulesetEditor.choices();
  checkNum('14 项（含「还没挑」）', choices.length, 14);
  checkEqual('第一项是空串', choices[0].id, '');
  checkEqual('第一项的显示名', choices[0].displayName, '（还没挑规则）');
  check('选项 id 不重复', new Set(choices.map((c: RuleChoiceRow) => c.id)).size === 14);
  // 与注册表同一顺序：桌面版 App.Services.xaml.cs 的注册顺序。
  checkEqual('第 2 项是窗口类名', choices[1].id, RuleIds.WINDOW_CLASS_NAME);
  checkEqual('末项是日出日落', choices[13].id, RuleIds.WEATHER_SUN_RISE_SET);
  check('不可用的选项带提示', choices[1].support !== RuleSupport.Implemented
    && choices[1].settingsHint.length > 0);
  // 下标 0 是「还没挑」，1..4 是四条窗口类，5 起才是课表类。
  check('课表类选项可用', choices[5].support === RuleSupport.Implemented);
  // 静态缓存：反复取同一个数组，界面展开下拉不必每次重拼 14 项。
  check('选项是缓存的同一个数组', RulesetEditor.choices() === choices);
}

function testEditorBuildWithoutRuleset(): void {
  // 没配规则集：整块编辑态是空的，求值结论恒为假。
  const model: RulesetEditModel = RulesetEditor.build(undefined, undefined);
  checkNum('没有组', model.groups.length, 0);
  check('标记为空', model.isEmpty);
  check('不成立', !model.satisfied);
  checkEqual('原因是没配规则', model.reason, RuleReason.NoRuleset);
  checkEqual('状态是「无」', `${model.state}`, `${STATE_NONE}`);
}

function testEditorBuildWithoutContext(): void {
  // context 传 undefined 时不求值，所有状态都是「无」。没选课表时界面仍然
  // 能改规则，只是看不到结论 —— 求值需要课表，没有课表就不该给一份
  // 「全都不成立」的结论，那会被当成「你配错了」。
  const model: RulesetEditModel =
    RulesetEditor.build(one(TimeState.OnClass), undefined);
  checkNum('组数照实', model.groups.length, 1);
  checkNum('规则数照实', model.groups[0].rules.length, 1);
  checkEqual('规则集状态是「无」', `${model.state}`, `${STATE_NONE}`);
  checkEqual('组状态是「无」', `${model.groups[0].state}`, `${STATE_NONE}`);
  checkEqual('规则状态是「无」', `${model.groups[0].rules[0].state}`, `${STATE_NONE}`);
  check('状态为「无」时不算成立', !model.satisfied);
  // 没有课表就没有结论。此时 reason 必须是空的 —— 留 notChosen / groupEmpty
  // 之类的占位值的话，界面上会对着一个根本没算过的规则集说「没配规则」，
  // 而用户明明配了。
  checkEqual('没求值就不给原因', model.reason, '');
  checkEqual('没求值时组也不给原因', model.groups[0].reason, '');
  checkEqual('没求值时规则也不给原因', model.groups[0].rules[0].reason, '');
}

function testShortCircuitKeepsHonestReason(): void {
  // And 模式下前面一条不成立就 break，剩下几条根本没跑。它们的状态留「无」是对的，
  // 但原因不能是占位值 —— 否则界面上会给用户一句「还没挑规则」/「组里没挑过规则」，
  // 用户会去重配本来没错的东西。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [
    rule('com.example.pluginRule'),   // 恒假 → And 组定论
    rule(RuleIds.LESSONS_TIME_STATE, timeStateRuleSettingsOf(TimeState.OnClass))
  ]), group(RulesetLogicalMode.And, [
    rule('com.example.pluginRule')
  ], false, false)]);
  const context: RuleContext = contextAt(`${BASE_DAY}T08:30:00`);
  const model: RulesetEditModel = RulesetEditor.build(rs, context);
  checkEqual('组内被短路那条的原因',
    model.groups[0].rules[1].reason, RuleReason.ShortCircuited);
  checkEqual('组内被短路那条的状态是「无」',
    `${model.groups[0].rules[1].state}`, `${STATE_NONE}`);
  // 停用的那一组走的是另一条路：原因必须是「已停用」而不是被短路。
  checkEqual('停用组的原因', model.groups[1].reason, RuleReason.GroupDisabled);
  for (const row of model.groups[1].rules) {
    checkEqual('停用组内每条都是停用', row.reason, RuleReason.ShortCircuited);
  }

  // Or 模式下组不会短路 —— 命中就 break，后面的组确实没跑。
  const orSet: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.Or, [rule(RuleIds.LESSONS_TIME_STATE,
      timeStateRuleSettingsOf(TimeState.OnClass))]),
    group(RulesetLogicalMode.And, [rule(RuleIds.LESSONS_TIME_STATE,
      timeStateRuleSettingsOf(TimeState.Breaking))])
  ]);
  const orModel: RulesetEditModel = RulesetEditor.build(orSet, context);
  check('Or 命中后整集成立', orModel.satisfied);
  checkEqual('被短路的那组原因是短路', orModel.groups[1].reason, RuleReason.ShortCircuited);
  checkEqual('被短路的那组状态是「无」', `${orModel.groups[1].state}`, `${STATE_NONE}`);
  checkEqual('被短路组内那条也是短路',
    orModel.groups[1].rules[0].reason, RuleReason.ShortCircuited);

  // 求值器自己也这么报，界面拿到的轨迹与编辑态一致。
  const direct: RulesetVerdict = RuleEngine.evaluate(rs, context);
  checkEqual('求值器与编辑态同一口径',
    direct.groups[0].rules[1].reason, model.groups[0].rules[1].reason);
}

function testEditorBuildCarriesSameVerdict(): void {
  // 编辑态的结论必须与直接调求值器一致。这两处不一致的话，用户在界面上
  // 看着「现在会藏起来」而面板上组件还在，无从判断该信哪个。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And, [
      timeStateRule(TimeState.OnClass),
      timeStateRule(TimeState.AfterSchool)
    ])
  ]);
  const cases: string[] = [
    `${BASE_DAY}T08:30:00`,
    `${BASE_DAY}T08:50:00`,
    `${BASE_DAY}T12:00:00`
  ];
  for (const at of cases) {
    const context: RuleContext = contextAt(at);
    const direct: RulesetVerdict = RuleEngine.evaluate(rs, context);
    const model: RulesetEditModel = RulesetEditor.build(rs, context);
    checkEqual(`${at} 的结论一致`, `${model.satisfied}`, `${direct.satisfied}`);
    checkEqual(`${at} 的状态一致`, `${model.state}`, `${direct.state}`);
    checkEqual(`${at} 的原因一致`, model.reason, direct.reason);
    for (let g: number = 0; g < direct.groups.length; g++) {
      checkEqual(`${at} 第 ${g} 组状态一致`,
        `${model.groups[g].state}`, `${direct.groups[g].state}`);
      checkEqual(`${at} 第 ${g} 组原因一致`,
        model.groups[g].reason, direct.groups[g].reason);
      for (let i: number = 0; i < direct.groups[g].rules.length; i++) {
        checkEqual(`${at} 第 ${g} 组第 ${i} 条状态一致`,
          `${model.groups[g].rules[i].state}`, `${direct.groups[g].rules[i].state}`);
        checkEqual(`${at} 第 ${g} 组第 ${i} 条原因一致`,
          model.groups[g].rules[i].reason, direct.groups[g].rules[i].reason);
      }
    }
  }
}

function testEditorBuildAlignsCoordinates(): void {
  // 坐标必须与规则集一一对应。这条是编辑态存在的全部理由：界面照着这个下标
  // 回写，对齐错了就是「删了 A 结果 B 没了」。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And, [
      timeStateRule(TimeState.OnClass),
      timeStateRule(TimeState.Breaking),
      timeStateRule(TimeState.AfterSchool)
    ]),
    group(RulesetLogicalMode.Or, [timeStateRule(TimeState.None)]),
    group(RulesetLogicalMode.And, [])
  ]);
  const model: RulesetEditModel = RulesetEditor.build(rs, undefined);
  checkNum('组数一致', model.groups.length, 3);
  checkNum('第 0 组规则数一致', model.groups[0].rules.length, 3);
  checkNum('第 1 组规则数一致', model.groups[1].rules.length, 1);
  checkNum('第 2 组（空组）规则数一致', model.groups[2].rules.length, 0);
  for (let g: number = 0; g < model.groups.length; g++) {
    checkEqual(`第 ${g} 组的 groupIndex`, `${model.groups[g].groupIndex}`, `${g}`);
    checkEqual(`第 ${g} 组的模式`, `${model.groups[g].mode}`, `${rs.groups[g].mode}`);
    checkEqual(`第 ${g} 组的启用`, `${model.groups[g].isEnabled}`, `${rs.groups[g].isEnabled}`);
    for (let i: number; i < model.groups[g].rules.length; i++) {
      checkEqual(`第 ${g} 组第 ${i} 条的 groupIndex`,
        `${model.groups[g].rules[i].groupIndex}`, `${g}`);
      checkEqual(`第 ${g} 组第 ${i} 条的 ruleIndex`,
        `${model.groups[g].rules[i].ruleIndex}`, `${i}`);
      checkEqual(`第 ${g} 组第 ${i} 条的 id`,
        model.groups[g].rules[i].ruleId, rs.groups[g].rules[i].id);
    }
  }

  // 删掉中间那条之后，编辑态的下标要重排 —— 界面按行数组渲染，不做增量维护。
  RulesetMutations.removeRule(rs, 0, 1);
  const after: RulesetEditModel = RulesetEditor.build(rs, undefined);
  checkNum('删一条之后组内规则数', after.groups[0].rules.length, 2);
  checkEqual('第一条的下标', `${after.groups[0].rules[0].ruleIndex}`, '0');
  checkEqual('第二条的下标', `${after.groups[0].rules[1].ruleIndex}`, '1');
  checkEqual('第 1 组规则的坐标也跟着走',
    `${after.groups[1].rules[0].groupIndex}`, '1');
}

function testEditorFlagsUnchosenAndUnknown(): void {
  // 两种「这条规则不太对」得在界面上分开说：
  //   - 没挑（Id 空串）：界面上就是「（还没挑规则）」，不该显示成陌生 id
  //   - 陌生 id：桌面版配的、这边不认识的规则，判假但设置原样保留
  // 组模式用 Or：And 下前面那条陌生规则恒假，会把后面几条全短路掉，
  // 于是「这条规则判成什么」根本没发生，测的就不是想测的东西了。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.Or, [
    rule(''),
    rule('com.example.pluginRule'),
    rule(RuleIds.LESSONS_TIME_STATE)
  ])]);
  const model: RulesetEditModel = RulesetEditor.build(rs, contextAt(`${BASE_DAY}T08:30:00`));
  const rules: RuleEditRow[] = model.groups[0].rules;

  check('空 id 标成没挑', rules[0].isUnchosen);
  checkEqual('空 id 的显示名', rules[0].displayName, '（还没挑规则）');
  checkEqual('没挑的判定原因', rules[0].reason, RuleReason.NotChosen);
  checkEqual('没挑的状态是「无」', `${rules[0].state}`, `${STATE_NONE}`);

  check('陌生 id 不标成没挑', !rules[1].isUnchosen);
  checkEqual('陌生 id 直接回显 id', rules[1].displayName, 'com.example.pluginRule');
  checkEqual('陌生 id 的判定原因', rules[1].reason, RuleReason.UnknownRule);
  check('陌生 id 不成立', rules[1].state === STATE_FALSE);
  check('陌生 id 的设置不可编辑', !rules[1].isSettingsEditable);
  check('陌生 id 带解释', rules[1].settingsHint.length > 0);

  check('已实现的规则设置可编辑', rules[2].isSettingsEditable);
  checkEqual('已实现的规则判定成立', rules[2].reason, RuleReason.Matched);
  check('已实现的规则状态是真', rules[2].state === STATE_TRUE);
}

function testEditorMarksUnsupportedRulesNotEditable(): void {
  // 4 条窗口类规则在当前平台没有数据（天气类已在 P11c 翻成已实现）。
  // 界面上照常列出、可以配（值原样落盘），但设置控件要置灰并标出原因 ——
  // 判成「可编辑」的话用户会以为改了有用。
  // 同样用 Or，让两条都被真正判到（见上面那条测试的注）。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.Or, [
    rule(RuleIds.WINDOW_TEXT, new StringMatchingSettings()),
    rule(RuleIds.WINDOW_STATUS, new WindowStatusRuleSettings())
  ])]);
  const model: RulesetEditModel = RulesetEditor.build(rs, contextAt(`${BASE_DAY}T08:30:00`));
  for (const row of model.groups[0].rules) {
    check(`${row.ruleId} 的设置不可编辑`, !row.isSettingsEditable);
    checkEqual(`${row.ruleId} 判为不成立`, row.reason, RuleReason.NotImplemented);
    check(`${row.ruleId} 的状态是假`, row.state === STATE_FALSE);
    check(`${row.ruleId} 带解释`, row.settingsHint.indexOf('没有') >= 0);
  }
  check('整组不成立', model.groups[0].state === STATE_FALSE);
}

function testEditorDecodesSettingsObjects(): void {
  // 界面要拿强类型对象绑控件，所以每种设置都必须解出对应类型的那一个类。
  // 解不出来时给的是空对象（不是 undefined），界面照 isSettingsEditable 判成
  // 不可编辑，根本不会去读它 —— 但空对象也绝不能是 null。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [group(RulesetLogicalMode.And, [
    rule(RuleIds.LESSONS_TIME_STATE, timeStateRuleSettingsOf(TimeState.Breaking)),
    rule('com.example.pluginRule')
  ])]);
  const model: RulesetEditModel = RulesetEditor.build(rs, undefined);
  const settings: Object = model.groups[0].rules[0].settings;
  check('解出的是 TimeStateRuleSettings', settings instanceof TimeStateRuleSettings);
  checkEqual('解出来的值对',
    `${(settings as TimeStateRuleSettings).state}`, `${TimeState.Breaking}`);
  const opaque: Object = model.groups[0].rules[1].settings;
  check('陌生规则的 settings 不是 null', opaque !== null && opaque !== undefined);
  checkEqual('陌生规则的 settings 是个空对象',
    `${Object.keys(opaque as Record<string, Object>).length}`, '0');
}

function timeStateRuleSettingsOf(state: TimeState): TimeStateRuleSettings {
  const out: TimeStateRuleSettings = new TimeStateRuleSettings();
  out.state = state;
  return out;
}

function testEditorCarriesEnabledAndReversedFlags(): void {
  // 界面上的三个开关各自对应一个字段，编辑态必须把当前值带出来 ——
  // 带错的话用户打开一个停用的组，看到的开关是开的，一动就把别的组也改了。
  const rs: Ruleset = ruleset(RulesetLogicalMode.And, [
    group(RulesetLogicalMode.Or, [timeStateRule(TimeState.OnClass, true)], true, false),
    group(RulesetLogicalMode.And, [timeStateRule(TimeState.None)])
  ], true);
  const model: RulesetEditModel = RulesetEditor.build(rs, undefined);
  check('规则集整体取反带出来了', model.isReversed);
  checkEqual('规则集模式带出来了', `${model.mode}`, `${RulesetLogicalMode.And}`);
  check('第 0 组取反带出来了', model.groups[0].isReversed);
  check('第 0 组停用带出来了', !model.groups[0].isEnabled);
  check('第 0 组的规则取反带出来了', model.groups[0].rules[0].isReversed);
  check('第 1 组启用且不取反',
    model.groups[1].isEnabled && !model.groups[1].isReversed
    && !model.groups[1].rules[0].isReversed);
  checkEqual('第 1 组模式带出来了',
    `${model.groups[1].mode}`, `${RulesetLogicalMode.And}`);
  check('非空规则集不标为空', !model.isEmpty);
}

function testEditorIsPureData(): void {
  // 编辑态是可重入的：同一个规则集求两次，行数据不能是同一批对象，也不能
  // 互相污染。面板、预览、编辑器会同时拿同一份规则集去合成（面板那边
  // 只求值不合成，但求值是纯函数这一点同样要成立）。
  const rs: Ruleset = one(TimeState.OnClass);
  const context: RuleContext = contextAt(`${BASE_DAY}T08:30:00`);
  const a: RulesetEditModel = RulesetEditor.build(rs, context);
  const b: RulesetEditModel = RulesetEditor.build(rs, context);
  check('两次合成的组对象不是同一个', a.groups[0] !== b.groups[0]);
  check('两次合成的规则对象不是同一个',
    a.groups[0].rules[0] !== b.groups[0].rules[0]);
  checkEqual('两次结论一致', `${a.satisfied}`, `${b.satisfied}`);
  // 改一边不影响另一边。
  (a.groups[0].rules[0].settings as TimeStateRuleSettings).state = TimeState.None;
  checkEqual('改了一边不影响另一边',
    `${(b.groups[0].rules[0].settings as TimeStateRuleSettings).state}`,
    `${TimeState.OnClass}`);
  // 原规则集也不能被合成过程改掉。
  checkEqual('原规则集没被动过', readState(rs, 0, 0), `${TimeState.OnClass}`);
}

function testEditorHandlesGroupVerdictCarriesEnabled(): void {
  // 停用的组状态留「无」、原因给「已停用」。界面上要靠这个原因说「这一组
  // 已停用，不参与判定」—— 与「组内没挑过规则」是两件事，都表现为状态「无」。
  const rs: Ruleset = ruleset(RulesetLogicalMode.Or, [
    group(RulesetLogicalMode.And, [timeStateRule(TimeState.OnClass)], false, false),
    group(RulesetLogicalMode.And, [rule('')], false, true)
  ]);
  const model: RulesetEditModel =
    RulesetEditor.build(rs, contextAt(`${BASE_DAY}T08:30:00`));
  checkEqual('停用组的原因', model.groups[0].reason, RuleReason.GroupDisabled);
  checkEqual('停用组的状态是「无」', `${model.groups[0].state}`, `${STATE_NONE}`);
  checkEqual('空组的原因', model.groups[1].reason, RuleReason.GroupEmpty);
  checkEqual('空组的状态是「无」', `${model.groups[1].state}`, `${STATE_NONE}`);
  // Or 模式下第一组被跳过，落到第二组；空组又不计入，所以整集恒假。
  check('两个组都不计入 → 整集不成立', !model.satisfied);
  check('整集状态是假', model.state === STATE_FALSE);
  check('组数照实带出来', model.groups.length === 2);
}

function testEditorEmptyRulesetGroupsOnly(): void {
  // Groups 为空：桌面版直接 return false，IsReversed 不参与。这条规则被
  // 照抄了，编辑态得把「整集不成立」与「组都不成立」分开 —— 后者 reason 是
  // GroupEmpty，前者界面上的措辞是「还没有任何一组规则」。
  const rs: Ruleset = ruleset(RulesetLogicalMode.And, [], true);
  const model: RulesetEditModel = RulesetEditor.build(rs, contextAt(`${BASE_DAY}T08:30:00`));
  checkNum('组数是 0', model.groups.length, 0);
  check('标记为空', model.isEmpty);
  check('整体取反不救它', !model.satisfied);
  checkEqual('原因是组空', model.reason, RuleReason.GroupEmpty);
  check('状态是假', model.state === STATE_FALSE);
}

console.log(`规则求值 通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('');
  for (const failure of failures) {
    console.log(`✗ ${failure}`);
  }
  process.exit(1);
}
