/*
 * 自动化链路测试台。
 *
 * 这套东西出错时最典型的现象是「什么都不发生」：少配一个开关、条件里某条
 * 规则算反、状态机那一刻没赶上，用户看到的都是同一句话。所以这里逐条把
 * 桌面版 AutomationService 的判据钉住 —— 每一条判据一个用例。
 *
 * 覆盖只有读过桌面版源码才知道的事：
 *
 *   1. 触发条件是四个「与」，不是一条判断。桌面版 TriggerTriggered 里依次是
 *      总开关 → ActionSet.IsEnabled → IsRevertEnabled 时 Status 必须 Normal
 *      → IsConditionEnabled 时规则集必须满足。少一个就会在工作流「正在生效
 *      中」时重复触发。
 *   2. 恢复有两条完全不同的入口。触发器主动要求恢复（只有 preTimePoint 与
 *      signal 说得出来），与「条件掉了」被动恢复。后者还要额外卡
 *      IsConditionEnabled —— 条件压根没开的话，规则集是否满足与它无关。
 *   3. 恢复后的落点状态不等于 Normal。IsRevertEnabled 关着时才是 Normal；
 *      开着而这次是触发，就落在 IsOn（=2）等着被恢复。而这个 2 会被
 *      ActionSetStatusJsonConverter 原样落盘 —— 应用上次退出时正处于等待恢复
 *      状态，重开后仍然是等待恢复。
 *   4. 「上课时」是**进入**而非「处于」。桌面版挂的是事件，事件只在状态变成
 *      OnClass 那一刻响；用「当前状态 == OnClass」实现的话，一节课 45 分钟
 *      会每 tick 触发一次。
 *   5. preTimePoint 的判据是「跨过」不是「到达」：last < 目标 <= now。
 *      写成 <= now - target <= now 之类的话，上一次 tick 就在目标之后时会
 *      永久漏触发。同一个动作，判据差一点就是每次都触发或永远不触发。
 *   6. preTimePoint 在「当前状态已经等于目标状态」时改为要求恢复，而且
 *      **不再判提前量**。这条顺序反了的话，提前提醒会在上课那一刻撤销自己
 *      （触发与撤销同帧到达，恢复先算，正好把刚触发的撤掉）。
 *   7. 预计算「目标时刻」：OnClass / Breaking 取下一个时间点的**开始**时刻，
 *      AfterSchool 取最后一个上课或课间时间点的**结束**时刻。后者不是开始
 *      时刻 —— 放学那一刻就是最后一节课的结束。
 *   8. 提前量为负 = 停用。不当成「提前 0 秒」（那会让它每节课都触发）。
 *   9. 12 个触发器里 4 个恒不触发、7 个行动里 4 个跑不了。分档的理由与
 *      规则那边不同：触发器恒不触发是「这台设备上不存在这个功能」，所以
 *      报 notImplemented 而不是假装判定过。
 *  10. 换触发器 / 行动类型时设置重置为新类型的默认值。照抄桌面版
 *      ActivateTrigger 的 `if (settingsReal?.GetType() != settingsType) settingsReal = new(...)`。
 *
 * 另外测了往返保真（触发器与行动设置是裸 JSON 透传，陌生 id 的设置必须
 * 原样保住）与自动化默认设置的可构造性（两个 Catalog 的 settingsKind 与
 * 转换分支必须一一对应，漏一个就是「新建 → 保存 → 再打开变空对象」）。
 */

import { ActionItem } from '../../common_shared/src/main/ets/models/Automation/ActionItem';
import { ActionSet } from '../../common_shared/src/main/ets/models/Automation/ActionSet';
import { ActionSetStatus } from '../../common_shared/src/main/ets/enums/ActionSetStatus';
import {
  ActionIds,
  AppRestartActionSettings,
  ModifyAppSettingsActionSettings,
  NotificationActionSettings,
  RunActionRunType,
  RunActionSettings,
  SleepActionSettings,
  WeatherNotificationActionSettings
} from '../../common_shared/src/main/ets/models/Automation/Actions';
import { TriggerSettings } from
  '../../common_shared/src/main/ets/models/Automation/TriggerSettings';
import {
  CronTriggerSettings,
  PreTimePointTriggerSettings,
  SignalTriggerSettings,
  TriggerIds,
  TrayMenuTriggerSettings,
  UriTriggerSettings
} from '../../common_shared/src/main/ets/models/Automation/Triggers';
import { Workflow } from '../../common_shared/src/main/ets/models/Automation/Workflow';
import { ClassInfo } from '../../common_shared/src/main/ets/models/ClassInfo';
import { ClassPlan } from '../../common_shared/src/main/ets/models/ClassPlan';
import { ClassPlanGroup } from '../../common_shared/src/main/ets/models/ClassPlanGroup';
import { DateTimeValue } from '../../common_shared/src/main/ets/json/DateTimeValue';
import { Guid } from '../../common_shared/src/main/ets/json/Guid';
import {
  JsonArray,
  JsonBoolean,
  JsonNode,
  JsonNumber,
  JsonObject,
  JsonString
} from '../../common_shared/src/main/ets/json/JsonNode';
import { JsonReader } from '../../common_shared/src/main/ets/json/JsonReader';
import { JsonValue } from '../../common_shared/src/main/ets/json/JsonValue';
import { JsonWriter } from '../../common_shared/src/main/ets/json/JsonWriter';
import { Profile } from '../../common_shared/src/main/ets/models/Profile';

import { RuleIds, Ruleset, RulesetLogicalMode, TimeStateRuleSettings } from
  '../../common_shared/src/main/ets/models/Ruleset';
import { Subject } from '../../common_shared/src/main/ets/models/Subject';
import { TimeLayout } from '../../common_shared/src/main/ets/models/TimeLayout';
import { TimeLayoutItem } from '../../common_shared/src/main/ets/models/TimeLayoutItem';
import { TimeRule } from '../../common_shared/src/main/ets/models/TimeRule';
import { TimeSpanValue } from '../../common_shared/src/main/ets/json/TimeSpanValue';
import { TimeState } from '../../common_shared/src/main/ets/enums/TimeState';
import { EngineSettings } from '../../common_core/src/main/ets/engine/EngineSettings';
import { LessonsEngine } from '../../common_core/src/main/ets/engine/LessonsEngine';
import { LessonsSnapshot } from '../../common_core/src/main/ets/engine/LessonsSnapshot';
import { RuleContext } from '../../common_core/src/main/ets/rules/RuleEngine';
import { ActionCatalog, ActionSettingsKind, ActionSupport } from
  '../../common_core/src/main/ets/automation/ActionCatalog';
import {
  AutomationEngine,
  AutomationReason,
  AutomationTick,
  AutomationTickResult,
  TriggerVerdict
} from '../../common_core/src/main/ets/automation/AutomationEngine';
import { CronExpression } from '../../common_core/src/main/ets/automation/CronExpression';
import { TriggerCatalog, TriggerSettingsKind, TriggerSupport } from
  '../../common_core/src/main/ets/automation/TriggerCatalog';
import { AutomationDefaults, WorkflowMutations } from
  '../../common_core/src/main/ets/automation/WorkflowMutations';

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

/** 2026-09-26 是周六（dayOfWeek = 6），与其它驱动同基准。 */
const BASE_DAY: string = '2026-09-26';
const SUBJECT_YUWEN: string = '11111111-1111-1111-1111-111111111111';
const LAYOUT_ID: string = 'aaaaaaaa-0000-0000-0000-000000000001';

function dt(text: string): DateTimeValue {
  return DateTimeValue.parseOrMin(text);
}

function engineSettings(): EngineSettings {
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
 * 6 个时间点：3 节课 + 2 个课间。
 *
 * 第一节 08:00 开始，第三节 10:45 结束 —— preTimePoint 的「上课前 60 秒」
 * 落在 07:59:00，「放学前 60 秒」落在 10:44:00，两处都不与任何时间点重合，
 * 免得「目标时刻正好等于某个时间点起点」这种边界混进别的用例里。
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

/** 只排周六（= 其它驱动的基准日），其余日子无课。 */
function saturdayProfile(): Profile {
  const profile: Profile = new Profile();
  profile.name = '自动化测试';
  profile.timeLayouts.set(LAYOUT_ID, standardLayout());
  profile.selectedClassPlanGroupId = ClassPlanGroup.defaultGroupGuid();

  const subject: Subject = new Subject();
  subject.name = '语文';
  profile.subjects.set(SUBJECT_YUWEN, subject);

  const plan: ClassPlan = new ClassPlan();
  plan.name = '周六的课';
  plan.timeLayoutId = Guid.fromCanonical(LAYOUT_ID);
  const rule: TimeRule = new TimeRule();
  rule.weekDay = 6;
  rule.weekCountDiv = 0;
  rule.weekCountDivTotal = 2;
  plan.timeRule = rule;
  plan.classes = [new ClassInfo(), new ClassInfo(), new ClassInfo()];
  profile.classPlans.set(planKey(6), plan);
  profile.refreshDerivedState();
  return profile;
}

// ------------------------------------------------------------- 构造工具

function trigger(id: string, settings?: Object): TriggerSettings {
  const out: TriggerSettings = new TriggerSettings();
  out.id = id;
  if (settings !== undefined) {
    out.settings = WorkflowMutations.settingsToNode(settings);
  }
  return out;
}

function action(id: string, settings?: Object): ActionItem {
  const out: ActionItem = new ActionItem();
  out.id = id;
  if (settings !== undefined) {
    out.settings = WorkflowMutations.settingsToNode(settings);
  }
  return out;
}

/** 只带一个触发器、行动组是开着的空工作流。 */
function workflowOf(triggerId: string, settings?: Object): Workflow {
  const out: Workflow = new Workflow();
  out.triggers.push(trigger(triggerId, settings));
  out.actionSet = new ActionSet();
  out.actionSet.isEnabled = true;
  out.actionSet.isRevertEnabled = false;
  out.actionSet.status = ActionSetStatus.Normal;
  out.actionSet.guid = Guid.fromCanonical('dddddddd-0000-0000-0000-000000000001');
  return out;
}

/**
 * 造「当前时间状态 == state 时成立」的规则集：单组、组内 And、单条规则。
 *
 * 这里刻意走 JSON 而不是直接 new Ruleset 再 new RuleGroup —— Workflow.ruleset
 * 存的是**裸节点**，而链路求值时每次都要现解一份。直接 new 出来的对象塞不进
 * 那个字段，走一遍 JSON 才测得到真实路径。
 */
function timeStateRuleset(state: TimeState): Ruleset {
  const settings: TimeStateRuleSettings = new TimeStateRuleSettings();
  settings.state = state;

  const ruleJson: JsonObject = new JsonObject();
  ruleJson.set('IsReversed', new JsonBoolean(false));
  ruleJson.set('Id', new JsonString(RuleIds.LESSONS_TIME_STATE));
  ruleJson.set('Settings', settings.toJson());

  const rules: JsonArray = new JsonArray();
  rules.push(ruleJson);

  const groupJson: JsonObject = new JsonObject();
  groupJson.set('Rules', rules);
  groupJson.set('Mode', JsonNumber.of(RulesetLogicalMode.And));
  groupJson.set('IsReversed', new JsonBoolean(false));
  groupJson.set('IsEnabled', new JsonBoolean(true));

  const groups: JsonArray = new JsonArray();
  groups.push(groupJson);

  const root: JsonObject = new JsonObject();
  root.set('Mode', JsonNumber.of(RulesetLogicalMode.Or));
  root.set('IsReversed', new JsonBoolean(false));
  root.set('Groups', groups);
  return Ruleset.parse(root);
}

// ------------------------------------------------------------------ tick

const PROFILE: Profile = saturdayProfile();

function snapshotAt(at: string, previous?: LessonsSnapshot): LessonsSnapshot {
  return LessonsEngine.compute(PROFILE, engineSettings(), dt(at), previous);
}

/** 造一次 tick 的输入。默认开着总开关、档案可信。 */
function tickAt(at: string, previous?: LessonsSnapshot): AutomationTick {
  const out: AutomationTick = new AutomationTick(dt(at));
  out.hasTrustedProfile = true;
  out.isAutomationEnabled = true;
  out.snapshot = snapshotAt(at, previous);
  const context: RuleContext = new RuleContext();
  context.now = out.now;
  context.profile = PROFILE;
  context.snapshot = out.snapshot;
  out.ruleContext = context;
  return out;
}

function reasonOf(result: AutomationTickResult, index: number): string {
  return index < result.verdicts.length ? result.verdicts[index].reason : '(没有这条判定)';
}

function firesAt(workflow: Workflow, at: string, previous?: LessonsSnapshot): boolean {
  const engine: AutomationEngine = new AutomationEngine();
  const result: AutomationTickResult = engine.tick([workflow], tickAt(at, previous));
  return result.runs.length > 0;
}

// =========================================================== A. 注册表

function testCatalogs(): void {
  checkNum('注册表里有 12 个触发器', TriggerCatalog.all().length, 12);
  checkNum('注册表里有 7 个行动', ActionCatalog.all().length, 7);

  // 12 个触发器的 id 逐个核对。少一个就意味着用户从桌面版同步过来的那条
  // 触发器在鸿蒙侧变成「陌生 id」，而界面上只能显示一串英文。
  const expectedTriggers: string[] = [
    TriggerIds.LIFETIME_STARTUP,
    TriggerIds.LIFETIME_STOPPING,
    TriggerIds.CRON,
    TriggerIds.LESSONS_CURRENT_TIME_STATE_CHANGED,
    TriggerIds.LESSONS_ON_AFTER_SCHOOL,
    TriggerIds.LESSONS_ON_BREAKING_TIME,
    TriggerIds.LESSONS_ON_CLASS,
    TriggerIds.LESSONS_PRE_TIME_POINT,
    TriggerIds.RULESET_CHANGED,
    TriggerIds.SIGNAL,
    TriggerIds.TRAY_MENU,
    TriggerIds.URI
  ];
  for (const id of expectedTriggers) {
    check(`触发器已注册：${id}`, TriggerCatalog.find(id) !== undefined);
  }
  check('陌生触发器查不到', TriggerCatalog.find('classisland.nope') === undefined);
  checkEqual('陌生触发器回显 id 本身', TriggerCatalog.displayNameOf('classisland.nope'),
    'classisland.nope');
  check('陌生触发器分档为 Unknown',
    TriggerCatalog.supportOf('classisland.nope') === TriggerSupport.Unknown);
  check('空 id 不是 Unknown（是「还没挑」）',
    TriggerCatalog.supportOf('') === TriggerSupport.Unknown);

  // 8 个已实现、4 个未实现。这条比例是「鸿蒙侧能力边界」的快照：改动任何一个
  // 分档都要同时改这个断言，否则测试不会提醒。
  let implemented: number = 0;
  for (const info of TriggerCatalog.all()) {
    if (info.support === TriggerSupport.Implemented) {
      implemented++;
    } else {
      // 未实现必须给出原因，否则界面上只能显示一个光秃秃的「不支持」。
      check(`未实现的触发器给出了原因：${info.id}`, info.unsupportedReason.length > 0);
    }
  }
  checkNum('8 个触发器已实现', implemented, 8);
  checkEqual('托盘菜单在鸿蒙上没有对应物',
    TriggerCatalog.supportOf(TriggerIds.TRAY_MENU) === TriggerSupport.Unsupported
      ? 'unsupported' : 'implemented', 'unsupported');
  checkEqual('Uri 也还没有对应物',
    TriggerCatalog.supportOf(TriggerIds.URI) === TriggerSupport.Unsupported
      ? 'unsupported' : 'implemented', 'unsupported');

  // 只有两个触发器说得出来「撤销」，且 preTimePoint 是已实现的那一个。
  check('preTimePoint 能要求撤销',
    TriggerCatalog.find(TriggerIds.LESSONS_PRE_TIME_POINT).canRevert);
  check('signal 能要求撤销', TriggerCatalog.find(TriggerIds.SIGNAL).canRevert);
  let canRevert: number = 0;
  for (const info of TriggerCatalog.all()) {
    if (info.canRevert) {
      canRevert++;
    }
  }
  checkNum('只有两个触发器能要求撤销', canRevert, 2);

  // 行动：5 个已实现、2 个未实现；只有 settings 那条可恢复。
  let actionImplemented: number = 0;
  for (const info of ActionCatalog.all()) {
    if (info.support === ActionSupport.Implemented) {
      actionImplemented++;
    } else {
      check(`未实现的行动给出了原因：${info.id}`, info.unsupportedReason.length > 0);
    }
  }
  checkNum('5 个行动已实现', actionImplemented, 5);
  check('只有「应用设置」可恢复', ActionCatalog.isRevertable(ActionIds.SETTINGS));
  check('「等待时长」不可恢复', !ActionCatalog.isRevertable(ActionIds.SLEEP));
  check('「退出应用」不可恢复', !ActionCatalog.isRevertable(ActionIds.APP_QUIT));
  check('陌生行动不可恢复', !ActionCatalog.isRevertable('classisland.nope'));

  // 两个 Catalog 的 settingsKind 与「默认设置能不能造出来」必须一一对应。
  // 漏一个的现场表现是：新建这一条 → 保存 → 再打开，设置变成空对象。
  const problems: string[] = AutomationDefaults.verifyKinds();
  check('默认设置全部可构造', problems.length === 0, problems.join('；'));
}

// =========================================================== B. cron

function testCronParsing(): void {
  const everyMinute: CronExpression = CronExpression.parse('* * * * *');
  check('五段式能解', everyMinute.valid, everyMinute.reason);
  checkNum('五段式的段数是 5', everyMinute.fieldCount(), 5);
  check('每分钟在 07:59:00 命中', everyMinute.matches(dt('2026-09-26T07:59:00')));
  check('每分钟在 23:59:00 命中', everyMinute.matches(dt('2026-09-26T23:59:00')));
  // 桌面版默认配置就是 "* * * * *"，而它调的是 6 段解析器（TimeCrontab 默认
  // 带秒），按 6 段会抛，于是「刚加进来的 cron 触发器」永远不响。收下 5 段
  // 正是为了让这个默认值在鸿蒙侧是好的。
  check('五段式只在每分钟的第 0 秒命中', !everyMinute.matches(dt('2026-09-26T07:59:01')));
  check('五段式在 00:00:00 也命中', everyMinute.matches(dt('2026-09-26T00:00:00')));

  const withSeconds: CronExpression = CronExpression.parse('30 0 8 * * 1-5');
  check('六段式能解', withSeconds.valid, withSeconds.reason);
  checkNum('六段式的段数是 6', withSeconds.fieldCount(), 6);
  check('工作日 08:00:30 命中', withSeconds.matches(dt('2026-09-28T08:00:30')));
  check('工作日 08:00:31 不命中', !withSeconds.matches(dt('2026-09-28T08:00:31')));
  // 2026-09-28 是周一，2026-09-26 是周六
  check('周六不命中（周限 1-5）', !withSeconds.matches(dt('2026-09-26T08:00:30')));

  const everyTen: CronExpression = CronExpression.parse('0 */10 * * * *');
  check('步长能解', everyTen.valid, everyTen.reason);
  check('整点命中', everyTen.matches(dt('2026-09-26T08:00:00')));
  check('08:10:00 命中', everyTen.matches(dt('2026-09-26T08:10:00')));
  check('08:05:00 不命中', !everyTen.matches(dt('2026-09-26T08:05:00')));

  const listExpr: CronExpression = CronExpression.parse('0 0 8,12,18 * * *');
  check('列表能解', listExpr.valid, listExpr.reason);
  check('12:00:00 命中', listExpr.matches(dt('2026-09-26T12:00:00')));
  check('13:00:00 不命中', !listExpr.matches(dt('2026-09-26T13:00:00')));

  const range: CronExpression = CronExpression.parse('0 0 8-10 * * *');
  check('区间能解', range.valid, range.reason);
  check('09:00 命中', range.matches(dt('2026-09-26T09:00:00')));
  check('11:00 不命中', !range.matches(dt('2026-09-26T11:00:00')));

  // 「7 = 周日」这个老约定。cron 文档里 0 和 7 都指周日，用户多半写 7；
  // 不认的话「每周日」这条得写成 0，而用户不会知道为什么。
  const sunday: CronExpression = CronExpression.parse('0 0 9 * * 7');
  check('周可以写 7 当周日', sunday.valid && sunday.matches(dt('2026-09-27T09:00:00')),
    sunday.reason);
  const sundayZero: CronExpression = CronExpression.parse('0 0 9 * * 0');
  check('周也可以写 0 当周日', sundayZero.valid && sundayZero.matches(dt('2026-09-27T09:00:00')));

  const names: CronExpression = CronExpression.parse('0 0 9 * Jan mon');
  check('月与周可以写英文', names.valid, names.reason);

  // 问号只在日/周有意义，其余段位上按 * 处理而不是报错。理由：坏表达式最坏的
  // 结果是触发得太频繁，界面上会标出「解析成功」，而抛异常会让这一条
  // 触发器彻底不工作且看不出原因。
  const question: CronExpression = CronExpression.parse('0 0 9 ? * mon');
  check('问号能解', question.valid, question.reason);
  check('问号当日约束被放开', question.matches(dt('2026-09-28T09:00:00')));
  check('周六不命中（周限 mon）', !question.matches(dt('2026-09-26T09:00:00')));

  // 日与周同时写死按「或」匹配：这是经典 cron 的老规则，也是用户预期的那条。
  const orExpr: CronExpression = CronExpression.parse('0 0 9 15 * mon');
  check('日与周同时写死能解', orExpr.valid, orExpr.reason);
  check('15 号命中（日那条）', orExpr.matches(dt('2026-09-15T09:00:00')));
  check('周一命中（周那条）', orExpr.matches(dt('2026-09-21T09:00:00')));
  check('都不命中时确实不命中', !orExpr.matches(dt('2026-09-22T09:00:00')));

  // 坏表达式一律 valid=false 且有话可说，界面上直接显示 reason。
  for (const bad of ['', '* * *', '* * * * * * *', '60 * * * *', 'a * * * *', '*/0 * * * *',
    '5-1 * * * *', '* * * * 8']) {
    const parsed: CronExpression = CronExpression.parse(bad);
    check(`坏表达式被判失败：${bad.length === 0 ? '(空)' : bad}`,
      !parsed.valid && parsed.reason.length > 0, parsed.reason);
    check(`坏表达式不匹配任何时刻：${bad.length === 0 ? '(空)' : bad}`,
      !parsed.matches(dt('2026-09-26T08:00:00')));
  }
  checkNum('坏表达式的段数报 0', CronExpression.parse('* * *').fieldCount(), 0);
}

// ================================================ C. 触发器逐个求值

function testTimeStateTriggers(): void {
  // 08:10 是第一节课上；07:58 那帧是 None。
  const before: LessonsSnapshot = snapshotAt('2026-09-26T07:58:00');
  const during: LessonsSnapshot = snapshotAt('2026-09-26T08:10:00', before);
  checkNum('课表真的进了上课状态', during.state, TimeState.OnClass);
  check('迁移被记下来了', during.transitionTo === TimeState.OnClass);

  const engine: AutomationEngine = new AutomationEngine();
  const result: AutomationTickResult = engine.tick([workflowOf(TriggerIds.LESSONS_ON_CLASS)],
    tickAt('2026-09-26T08:10:00', before));
  checkNum('上课时触发了一次', result.runs.length, 1);
  checkEqual('原因记的是「触发」', reasonOf(result, 0), AutomationReason.Fired);

  // 关键：留在上课状态时**不该**每 tick 都触发。桌面版挂的是事件，
  // 「当前状态 == OnClass」这种实现会让一节课触发 2700 次。
  const stay: LessonsSnapshot = snapshotAt('2026-09-26T08:10:10', during);
  check('状态没变时迁移是 undefined', stay.transitionTo === undefined);
  const again: AutomationEngine = new AutomationEngine();
  const resultAgain: AutomationTickResult = again.tick(
    [workflowOf(TriggerIds.LESSONS_ON_CLASS)], tickAt('2026-09-26T08:10:10', during));
  checkNum('还停在上课时不再触发', resultAgain.runs.length, 0);
  checkEqual('原因是「还没到」', reasonOf(resultAgain, 0), AutomationReason.NotYet);

  // 课间
  const inClass: LessonsSnapshot = snapshotAt('2026-09-26T08:40:00');
  const inBreak: LessonsSnapshot = snapshotAt('2026-09-26T08:50:00', inClass);
  checkNum('课间状态对', inBreak.state, TimeState.Breaking);
  const breakEngine: AutomationEngine = new AutomationEngine();
  const breakResult: AutomationTickResult = breakEngine.tick(
    [workflowOf(TriggerIds.LESSONS_ON_BREAKING_TIME)], tickAt('2026-09-26T08:50:00', inClass));
  checkNum('课间休息时触发', breakResult.runs.length, 1);
  // 放学：档案只排了周六，11:00 既没课也没到次日 → AfterSchool。
  const afterClass: LessonsSnapshot = snapshotAt('2026-09-26T10:40:00');
  const afterSchool: LessonsSnapshot = snapshotAt('2026-09-26T11:00:00', afterClass);
  checkNum('放学状态对', afterSchool.state, TimeState.AfterSchool);
  const schoolEngine: AutomationEngine = new AutomationEngine();
  const schoolResult: AutomationTickResult = schoolEngine.tick(
    [workflowOf(TriggerIds.LESSONS_ON_AFTER_SCHOOL)], tickAt('2026-09-26T11:00:00', afterClass));
  checkNum('放学时触发', schoolResult.runs.length, 1);

  // 状态变化时：None → OnClass 之外的状态迁移也要算「变了」。
  const changed: LessonsSnapshot = snapshotAt('2026-09-26T08:50:00', inClass);
  const changedEngine: AutomationEngine = new AutomationEngine();
  const changedResult: AutomationTickResult = changedEngine.tick(
    [workflowOf(TriggerIds.LESSONS_CURRENT_TIME_STATE_CHANGED)],
    tickAt('2026-09-26T08:50:00', inClass));
  checkNum('状态变化时触发', changedResult.runs.length, 1);
  check('迁移到课间也算变化', changed.transitionTo === TimeState.Breaking);
}

function testLifetimeTriggers(): void {
  const startup: Workflow = workflowOf(TriggerIds.LIFETIME_STARTUP);
  const startupEngine: AutomationEngine = new AutomationEngine();
  const input: AutomationTick = tickAt('2026-09-26T08:00:00');
  input.isAppStartup = true;
  const result: AutomationTickResult = startupEngine.tick([startup], input);
  checkNum('启动时触发', result.runs.length, 1);
  check('仅启动时触发，不是普通帧',
    !firesAt(workflowOf(TriggerIds.LIFETIME_STARTUP), '2026-09-26T08:00:00'));

  // 退出时：只在 isAppStopping 那一帧响，且是「触发」不是「撤销」。
  // 桌面版 AppStoppingTrigger 调的是 Trigger()。
  const stoppingInput: AutomationTick = tickAt('2026-09-26T22:00:00');
  stoppingInput.isAppStopping = true;
  const stoppingEngine: AutomationEngine = new AutomationEngine();
  const stoppingResult: AutomationTickResult =
    stoppingEngine.tick([workflowOf(TriggerIds.LIFETIME_STOPPING)], stoppingInput);
  checkNum('退出时触发', stoppingResult.runs.length, 1);
  check('退出时是触发而不是撤销', !stoppingResult.runs[0].isRevert);
  check('普通帧不触发退出时',
    !firesAt(workflowOf(TriggerIds.LIFETIME_STOPPING), '2026-09-26T22:00:00'));
}

function testCronTrigger(): void {
  const settings: CronTriggerSettings = new CronTriggerSettings();
  settings.cronExpression = '0 0 8 * * *';
  const workflow: Workflow = workflowOf(TriggerIds.CRON, settings);

  const engine: AutomationEngine = new AutomationEngine();
  const at: AutomationTickResult = engine.tick([workflow], tickAt('2026-09-26T08:00:00'));
  checkNum('cron 命中时触发', at.runs.length, 1);
  check('cron 未到点时不触发',
    !firesAt(workflow, '2026-09-26T08:00:01'));

  // 表达式改了要重解。缓存按文本比对，所以这里刻意先命中一次再改，
  // 验证「改完立刻生效」而不是「要等下一次配置变更」。
  //
  // 注意改设置必须走 writeTriggerSettings：设置在 TriggerSettings 上是**裸
  // JSON 节点**，改那个强类型对象不会写回节点，引擎读的仍是旧值。
  settings.cronExpression = '0 0 9 * * *';
  check('改 cron 设置成功', WorkflowMutations.writeTriggerSettings(workflow, 0, settings));
  const engine2: AutomationEngine = new AutomationEngine();
  engine2.tick([workflow], tickAt('2026-09-26T08:00:00'));
  const after: AutomationTickResult = engine2.tick([workflow], tickAt('2026-09-26T08:00:01'));
  checkNum('改完表达式立刻不再按旧的命中', after.runs.length, 0);
  const engine3: AutomationEngine = new AutomationEngine();
  const later: AutomationTickResult = engine3.tick([workflow], tickAt('2026-09-26T09:00:00'));
  checkNum('改完表达式按新的命中', later.runs.length, 1);

  // 坏表达式：不触发，且把解不出来的原因写在 detail 里。界面上直接显示这句，
  // 否则用户只会看到「我的 cron 怎么不响」。
  const broken: CronTriggerSettings = new CronTriggerSettings();
  broken.cronExpression = '不是 cron';
  const brokenEngine: AutomationEngine = new AutomationEngine();
  const brokenResult: AutomationTickResult =
    brokenEngine.tick([workflowOf(TriggerIds.CRON, broken)], tickAt('2026-09-26T08:00:00'));
  checkNum('坏表达式不触发', brokenResult.runs.length, 0);
  checkEqual('坏表达式的原因是设置坏了', reasonOf(brokenResult, 0),
    AutomationReason.BadSettings);
  check('坏表达式给出了人话', brokenResult.verdicts[0].detail.length > 0,
    brokenResult.verdicts[0].detail);

  // Settings 为 null 时按「空对象」解，等价于桌面版
  // `i.Settings ?? Activator.CreateInstance(settingsType)` —— 于是拿到的是一份
  // 刚建出来的默认设置（每分钟一次），不是「设置坏了」。
  const nullEngine: AutomationEngine = new AutomationEngine();
  const nullResult: AutomationTickResult =
    nullEngine.tick([workflowOf(TriggerIds.CRON)], tickAt('2026-09-26T08:00:00'));
  checkNum('设置为空按默认设置算（每分钟一次）', nullResult.runs.length, 1);
}

function testPreTimePoint(): void {
  const settings: PreTimePointTriggerSettings = new PreTimePointTriggerSettings();
  settings.targetState = TimeState.OnClass;
  settings.timeSeconds = 60;
  const workflow: Workflow = workflowOf(TriggerIds.LESSONS_PRE_TIME_POINT, settings);

  // 目标时刻 = 08:00:00 - 60 = 07:59:00。判据是「跨过」：
  //   07:58:59 -> 07:59:00 触发（last < 07:59:00 <= now）
  //   07:59:00 -> 07:59:01 不再触发（last 已经不小于目标）
  const engine: AutomationEngine = new AutomationEngine();
  engine.tick([workflow], tickAt('2026-09-26T07:58:59'));
  const crossed: AutomationTickResult = engine.tick([workflow], tickAt('2026-09-26T07:59:00'));
  checkNum('跨过目标时刻时触发', crossed.runs.length, 1);

  // 中间那帧落在目标时刻上，于是 last == 目标，「last < 目标」不成立，
  // 后面每一帧都不再触发。这是判据里那个严格小于的实际作用。
  const engine2: AutomationEngine = new AutomationEngine();
  engine2.tick([workflow], tickAt('2026-09-26T07:58:59'));
  engine2.tick([workflow], tickAt('2026-09-26T07:59:00'));
  const after: AutomationTickResult = engine2.tick([workflow], tickAt('2026-09-26T07:59:01'));
  checkNum('已经过了就不再触发', after.runs.length, 0);

  // 反向漏触发：上一次 tick 已经在目标之后，就永远不会再触发。
  // 这正是「判据写成「到达」而不是「跨过」」的现场后果，必须钉住。
  const engine3: AutomationEngine = new AutomationEngine();
  engine3.tick([workflow], tickAt('2026-09-26T07:59:30'));
  const late: AutomationTickResult = engine3.tick([workflow], tickAt('2026-09-26T08:30:00'));
  checkNum('起点就在目标之后则本轮不触发', late.runs.length, 0);

  // 第一次 tick（刚加载配置）不触发。桌面版 Loaded() 里把 LastCheckTime
  // 设成当时，所以第一次必然不触发 —— 这条是「开机时不补触发」。
  const fresh: AutomationEngine = new AutomationEngine();
  const first: AutomationTickResult = fresh.tick([workflow], tickAt('2026-09-26T07:59:00'));
  checkNum('第一次 tick 不触发', first.runs.length, 0);

  // 当前状态已经等于目标状态 → 要求恢复，而且**不再判提前量**。
  // 顺序反了的话，提前提醒会在上课那一刻撤销自己。
  const inClass: LessonsSnapshot = snapshotAt('2026-09-26T08:10:00');
  const revertEngine: AutomationEngine = new AutomationEngine();
  const revertResult: AutomationTickResult = revertEngine.tick([workflow],
    tickAt('2026-09-26T08:10:00', inClass));
  check('进入目标状态时判成要求撤销', revertResult.verdicts[0].isRevert);

  // 提前量为负 = 停用。不当成「提前 0 秒」—— 那会让它每节课都触发。
  const off: PreTimePointTriggerSettings = new PreTimePointTriggerSettings();
  off.targetState = TimeState.OnClass;
  off.timeSeconds = -1;
  const offEngine: AutomationEngine = new AutomationEngine();
  offEngine.tick([workflowOf(TriggerIds.LESSONS_PRE_TIME_POINT, off)],
    tickAt('2026-09-26T07:59:00'));
  const offResult: AutomationTickResult = offEngine.tick(
    [workflowOf(TriggerIds.LESSONS_PRE_TIME_POINT, off)], tickAt('2026-09-26T07:59:01'));
  checkNum('提前量为负不触发', offResult.runs.length, 0);

  // 放学前：目标时刻取的是**最后一个上课/课间时间点的结束时刻**（10:45），
  // 不是任何一个开始时刻。提前 60 秒 → 10:44:00。
  const school: PreTimePointTriggerSettings = new PreTimePointTriggerSettings();
  school.targetState = TimeState.AfterSchool;
  school.timeSeconds = 60;
  const schoolWorkflow: Workflow = workflowOf(TriggerIds.LESSONS_PRE_TIME_POINT, school);
  const schoolEngine: AutomationEngine = new AutomationEngine();
  schoolEngine.tick([schoolWorkflow], tickAt('2026-09-26T10:43:59'));
  const schoolResult: AutomationTickResult =
    schoolEngine.tick([schoolWorkflow], tickAt('2026-09-26T10:44:00'));
  checkNum('放学前 60 秒触发', schoolResult.runs.length, 1);

  // 目标状态是 None / PrepareOnClass：桌面版的 switch 落到空时间点，然后
  // `if (targetTimePoint == Empty) return` —— 也就是永远不触发。
  for (const target of [TimeState.None, TimeState.PrepareOnClass]) {
    const odd: PreTimePointTriggerSettings = new PreTimePointTriggerSettings();
    odd.targetState = target;
    odd.timeSeconds = 60;
    const oddWorkflow: Workflow = workflowOf(TriggerIds.LESSONS_PRE_TIME_POINT, odd);
    const oddEngine: AutomationEngine = new AutomationEngine();
    oddEngine.tick([oddWorkflow], tickAt('2026-09-26T07:00:00'));
    const oddResult: AutomationTickResult =
      oddEngine.tick([oddWorkflow], tickAt('2026-09-26T23:00:00'));
    checkNum(`目标状态 ${target} 时不触发`, oddResult.runs.length, 0);
  }

  // 跨午夜的提前量：23:58 提前 10 分钟。桌面版那一步会越界抛异常，
  // 鸿蒙侧按「这一刻不适用」处理 —— 抛出去会让整帧其它触发器一起不工作。
  const cross: PreTimePointTriggerSettings = new PreTimePointTriggerSettings();
  cross.targetState = TimeState.OnClass;
  cross.timeSeconds = 10 * 3600;
  const crossEngine: AutomationEngine = new AutomationEngine();
  crossEngine.tick([workflowOf(TriggerIds.LESSONS_PRE_TIME_POINT, cross)],
    tickAt('2026-09-26T07:00:00'));
  const crossResult: AutomationTickResult = crossEngine.tick(
    [workflowOf(TriggerIds.LESSONS_PRE_TIME_POINT, cross)], tickAt('2026-09-26T07:59:00'));
  checkNum('提前量跨过午夜时不触发', crossResult.runs.length, 0);

  // 档案不可信：课表类触发器一律不算。桌面版靠事件驱动天然不会有这一格，
  // 鸿蒙侧是轮询，硬算的话「无课程」会被当成「放学了」。
  const untrusted: AutomationTick = tickAt('2026-09-26T08:10:00',
    snapshotAt('2026-09-26T07:58:00'));
  untrusted.hasTrustedProfile = false;
  const untrustedEngine: AutomationEngine = new AutomationEngine();
  const untrustedResult: AutomationTickResult = untrustedEngine.tick(
    [workflowOf(TriggerIds.LESSONS_ON_CLASS)], untrusted);
  checkNum('档案不可信时不触发', untrustedResult.runs.length, 0);
  checkEqual('原因是档案不可信', reasonOf(untrustedResult, 0),
    AutomationReason.UntrustedProfile);

  // 没给快照同样算「算不了」。理由同不可信：报 NotYet 会让人一直等。
  const noSnapshot: AutomationTick = tickAt('2026-09-26T08:10:00');
  noSnapshot.snapshot = undefined;
  const noSnapshotEngine: AutomationEngine = new AutomationEngine();
  const noSnapshotResult: AutomationTickResult = noSnapshotEngine.tick(
    [workflowOf(TriggerIds.LESSONS_ON_CLASS)], noSnapshot);
  checkEqual('没有快照也报档案不可信', reasonOf(noSnapshotResult, 0),
    AutomationReason.UntrustedProfile);
}

function testUnsupportedTriggers(): void {
  // 4 个未实现：判成 notImplemented，**且不产生任何 run**。
  // 这一档与规则那边的 Unknown 不一样：触发器恒不触发是「这台设备上不存在
  // 这个功能」，报成「还没到点」会让用户以为时间没到。
  for (const id of [TriggerIds.RULESET_CHANGED, TriggerIds.SIGNAL, TriggerIds.TRAY_MENU,
    TriggerIds.URI]) {
    const engine: AutomationEngine = new AutomationEngine();
    const result: AutomationTickResult = engine.tick([workflowOf(id)],
      tickAt('2026-09-26T08:10:00', snapshotAt('2026-09-26T07:58:00')));
    checkNum(`未实现的触发器不产生 run：${id}`, result.runs.length, 0);
    checkEqual(`未实现的触发器报 notImplemented：${id}`, reasonOf(result, 0),
      AutomationReason.NotImplemented);
    check(`未实现的触发器带了解释：${id}`, result.verdicts[0].detail.length > 0);
    check(`未实现的触发器分档为 Unsupported：${id}`,
      result.verdicts[0].support === TriggerSupport.Unsupported);
  }

  // 陌生 id 与「还没挑」要分开。两者都不触发，但界面上措辞不同：
  // 一个是「你在桌面版用的这条鸿蒙侧没实现」，另一个是「这里还没挑」。
  const engine: AutomationEngine = new AutomationEngine();
  const unknown: AutomationTickResult = engine.tick([workflowOf('classisland.plugin.thing')],
    tickAt('2026-09-26T08:10:00'));
  checkEqual('陌生 id 报 unknownTrigger', reasonOf(unknown, 0), AutomationReason.UnknownTrigger);
  check('陌生 id 分档为 Unknown', unknown.verdicts[0].support === TriggerSupport.Unknown);

  const emptyEngine: AutomationEngine = new AutomationEngine();
  const empty: AutomationTickResult = emptyEngine.tick([workflowOf('')],
    tickAt('2026-09-26T08:10:00'));
  checkEqual('空 id 报 notChosen', reasonOf(empty, 0), AutomationReason.NotChosen);
  check('空 id 的显示名是「还没挑」',
    empty.verdicts[0].displayName.indexOf('还没挑') >= 0, empty.verdicts[0].displayName);
}

// ================================================ D. 链路的四个判据

function testChainGuards(): void {
  // 判据一：自动化总开关。
  const off: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  const offInput: AutomationTick = tickAt('2026-09-26T08:10:00', snapshotAt('2026-09-26T07:58:00'));
  offInput.isAutomationEnabled = false;
  const offEngine: AutomationEngine = new AutomationEngine();
  const offResult: AutomationTickResult = offEngine.tick([off], offInput);
  checkNum('总开关关着不触发', offResult.runs.length, 0);
  checkEqual('原因是总开关关着', reasonOf(offResult, 0), AutomationReason.AutomationDisabled);

  // 判据二：行动组自己关着。
  const disabled: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  disabled.actionSet.isEnabled = false;
  const disabledEngine: AutomationEngine = new AutomationEngine();
  const disabledResult: AutomationTickResult = disabledEngine.tick([disabled],
    tickAt('2026-09-26T08:10:00', snapshotAt('2026-09-26T07:58:00')));
  checkNum('行动组关着不触发', disabledResult.runs.length, 0);
  checkEqual('原因是行动组关着', reasonOf(disabledResult, 0), AutomationReason.ActionSetDisabled);

  // 判据三：开了恢复时，Status 必须回到 Normal 才允许再次触发。
  // 这条最容易漏：漏了的话一节课 45 分钟里每 tick 都重新触发一次整套行动。
  const running: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  running.actionSet.isRevertEnabled = true;
  running.actionSet.status = ActionSetStatus.IsOn;
  const runningEngine: AutomationEngine = new AutomationEngine();
  const runningResult: AutomationTickResult = runningEngine.tick([running],
    tickAt('2026-09-26T08:10:00', snapshotAt('2026-09-26T07:58:00')));
  checkNum('等待恢复期间不重复触发', runningResult.runs.length, 0);
  checkEqual('原因是已在生效中', reasonOf(runningResult, 0), AutomationReason.AlreadyOn);

  // 同一个 Status 关着恢复时不挡 —— 因为压根没人会来恢复它。
  const noRevert: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  noRevert.actionSet.status = ActionSetStatus.IsOn;
  const noRevertEngine: AutomationEngine = new AutomationEngine();
  const noRevertResult: AutomationTickResult = noRevertEngine.tick([noRevert],
    tickAt('2026-09-26T08:10:00', snapshotAt('2026-09-26T07:58:00')));
  checkNum('没开恢复时 Status 不挡触发', noRevertResult.runs.length, 1);

  // 判据四：条件。
  const conditional: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  conditional.isConditionEnabled = true;
  conditional.ruleset = timeStateRuleset(TimeState.Breaking).toJson();
  const condEngine: AutomationEngine = new AutomationEngine();
  const condResult: AutomationTickResult = condEngine.tick([conditional],
    tickAt('2026-09-26T08:10:00', snapshotAt('2026-09-26T07:58:00')));
  checkNum('条件不满足时不触发', condResult.runs.length, 0);
  checkEqual('原因是条件不满足', reasonOf(condResult, 0), AutomationReason.ConditionFailed);

  // 条件满足就放行。
  const ok: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  ok.isConditionEnabled = true;
  ok.ruleset = timeStateRuleset(TimeState.OnClass).toJson();
  const okEngine: AutomationEngine = new AutomationEngine();
  const okResult: AutomationTickResult = okEngine.tick([ok],
    tickAt('2026-09-26T08:10:00', snapshotAt('2026-09-26T07:58:00')));
  checkNum('条件满足时放行', okResult.runs.length, 1);

  // 条件开关关着时规则集压根不参与 —— 这与「规则集不满足」是两件事。
  // 关着 = 无条件触发，不是「必然不触发」。
  const ignores: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  ignores.isConditionEnabled = false;
  ignores.ruleset = timeStateRuleset(TimeState.Breaking).toJson();
  const ignoresEngine: AutomationEngine = new AutomationEngine();
  const ignoresResult: AutomationTickResult = ignoresEngine.tick([ignores],
    tickAt('2026-09-26T08:10:00', snapshotAt('2026-09-26T07:58:00')));
  checkNum('条件开关关着时无视规则集', ignoresResult.runs.length, 1);

  // 四个判据是一起的：总开关关着时，行动组开着、条件也满足，照样不触发。
  const combo: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  combo.isConditionEnabled = true;
  combo.ruleset = timeStateRuleset(TimeState.OnClass).toJson();
  const comboInput: AutomationTick = tickAt('2026-09-26T08:10:00',
    snapshotAt('2026-09-26T07:58:00'));
  comboInput.isAutomationEnabled = false;
  const comboEngine: AutomationEngine = new AutomationEngine();
  const comboResult: AutomationTickResult = comboEngine.tick([combo], comboInput);
  checkNum('总开关优先级最高', comboResult.runs.length, 0);
  checkEqual('报的是总开关而不是条件', reasonOf(comboResult, 0),
    AutomationReason.AutomationDisabled);
}

// ================================================ E. 条件掉了要恢复

function testConditionRevert(): void {
  // 桌面版 RulesetServiceOnStatusUpdated 的筛选条件是三者同时成立：
  // Status == IsOn && IsRevertEnabled && IsConditionEnabled。少任何一个都会
  // 恢复错：少了 Status 会把没生效的行动组也「恢复」一遍，
  // 少了 IsRevertEnabled 会把没记住旧值的行动组也「恢复」一遍。
  const on: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  on.isConditionEnabled = true;
  // 条件写的是「当前是课间」，而这一帧在上课 —— 条件掉了。
  on.ruleset = timeStateRuleset(TimeState.Breaking).toJson();
  on.actionSet.isRevertEnabled = true;
  on.actionSet.status = ActionSetStatus.IsOn;

  // 条件掉了（现在在上课，但条件要求课间）→ 恢复。
  const nowInClass: LessonsSnapshot = snapshotAt('2026-09-26T08:10:00');
  const dropEngine: AutomationEngine = new AutomationEngine();
  const dropped: AutomationTickResult = dropEngine.tick([on],
    tickAt('2026-09-26T08:10:00', nowInClass));
  checkNum('条件掉了要恢复', dropped.runs.length, 1);
  check('恢复而非触发', dropped.runs[0].isRevert);
  check('恢复原因写的是「条件不再满足」', dropped.runs[0].causeText.indexOf('条件') >= 0,
    dropped.runs[0].causeText);

  // 条件仍满足 → 不恢复。
  const keep: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  keep.isConditionEnabled = true;
  keep.ruleset = timeStateRuleset(TimeState.OnClass).toJson();
  keep.actionSet.isRevertEnabled = true;
  keep.actionSet.status = ActionSetStatus.IsOn;
  const keepEngine: AutomationEngine = new AutomationEngine();
  const kept: AutomationTickResult = keepEngine.tick([keep],
    tickAt('2026-09-26T08:10:00', nowInClass));
  checkNum('条件还满足时不恢复', kept.runs.length, 0);

  // 三个筛选条件各缺一个的后果。
  const noStatus: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  noStatus.isConditionEnabled = true;
  noStatus.ruleset = timeStateRuleset(TimeState.Breaking).toJson();
  noStatus.actionSet.isRevertEnabled = true;
  noStatus.actionSet.status = ActionSetStatus.Normal;
  const noStatusEngine: AutomationEngine = new AutomationEngine();
  const noStatusResult: AutomationTickResult = noStatusEngine.tick([noStatus],
    tickAt('2026-09-26T08:10:00', nowInClass));
  checkNum('不在等待恢复状态时不恢复', noStatusResult.runs.length, 0);

  const noRevertFlag: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  noRevertFlag.isConditionEnabled = true;
  noRevertFlag.ruleset = timeStateRuleset(TimeState.Breaking).toJson();
  noRevertFlag.actionSet.isRevertEnabled = false;
  noRevertFlag.actionSet.status = ActionSetStatus.IsOn;
  const noRevertEngine: AutomationEngine = new AutomationEngine();
  const noRevertResult: AutomationTickResult = noRevertEngine.tick([noRevertFlag],
    tickAt('2026-09-26T08:10:00', nowInClass));
  checkNum('没开恢复时不恢复', noRevertResult.runs.length, 0);

  const noCondition: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  noCondition.isConditionEnabled = false;
  noCondition.ruleset = timeStateRuleset(TimeState.Breaking).toJson();
  noCondition.actionSet.isRevertEnabled = true;
  noCondition.actionSet.status = ActionSetStatus.IsOn;
  const noConditionEngine: AutomationEngine = new AutomationEngine();
  const noConditionResult: AutomationTickResult = noConditionEngine.tick([noCondition],
    tickAt('2026-09-26T08:10:00', nowInClass));
  checkNum('条件没开时不因为规则集而恢复', noConditionResult.runs.length, 0);

  // 总开关关着时也不恢复。
  const globalOff: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  globalOff.isConditionEnabled = true;
  globalOff.ruleset = timeStateRuleset(TimeState.Breaking).toJson();
  globalOff.actionSet.isRevertEnabled = true;
  globalOff.actionSet.status = ActionSetStatus.IsOn;
  const globalOffInput: AutomationTick = tickAt('2026-09-26T08:10:00', nowInClass);
  globalOffInput.isAutomationEnabled = false;
  const globalOffEngine: AutomationEngine = new AutomationEngine();
  const globalOffResult: AutomationTickResult = globalOffEngine.tick([globalOff], globalOffInput);
  checkNum('总开关关着时不恢复', globalOffResult.runs.length, 0);

  // 触发器主动要求恢复：preTimePoint 进了目标状态，但行动组不在等待恢复 →
  // 不恢复。这一格很容易被当成「什么也没发生」而漏测。
  const revertTrigger: Workflow = workflowOf(TriggerIds.LESSONS_PRE_TIME_POINT,
    new PreTimePointTriggerSettings());
  revertTrigger.actionSet.isRevertEnabled = true;
  revertTrigger.actionSet.status = ActionSetStatus.Normal;
  const busy: AutomationEngine = new AutomationEngine();
  const notWaiting: AutomationTickResult = busy.tick([revertTrigger],
    tickAt('2026-09-26T08:10:00', snapshotAt('2026-09-26T07:58:00')));
  checkNum('不在等待恢复时不会被要求恢复', notWaiting.runs.length, 0);
  checkEqual('原因是「不在等待恢复」', reasonOf(notWaiting, 0),
    AutomationReason.NotWaitingRevert);
}

function testStatusAfterRun(): void {
  // 跑完之后落点状态。照抄桌面版 SetEndRunning：
  //   没被中断 && 是触发 && IsRevertEnabled → IsOn，否则 Normal
  // 恢复时 IsRevertEnabled 关着就回 Normal —— 因为压根没记住旧值。
  const plain: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  checkEqual('不开恢复时跑完回 Normal',
    String(WorkflowMutations.statusAfterRun(plain, false, false)), String(ActionSetStatus.Normal));

  const revertable: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  revertable.actionSet.isRevertEnabled = true;
  checkEqual('开了恢复时跑完落在 IsOn',
    String(WorkflowMutations.statusAfterRun(revertable, false, false)),
    String(ActionSetStatus.IsOn));
  checkEqual('恢复跑完回 Normal',
    String(WorkflowMutations.statusAfterRun(revertable, true, false)),
    String(ActionSetStatus.Normal));

  // 被中断：桌面版 true when Status is Invoking → Normal；Reverting → IsOn
  const cancelled: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  cancelled.actionSet.isRevertEnabled = true;
  cancelled.actionSet.status = ActionSetStatus.Reverting;
  checkEqual('恢复途中被中断则回到 IsOn',
    String(WorkflowMutations.statusAfterRun(cancelled, true, true)), String(ActionSetStatus.IsOn));
  const cancelledInvoke: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  cancelledInvoke.actionSet.isRevertEnabled = true;
  cancelledInvoke.actionSet.status = ActionSetStatus.Invoking;
  checkEqual('触发途中被中断回 Normal',
    String(WorkflowMutations.statusAfterRun(cancelledInvoke, false, true)),
    String(ActionSetStatus.Normal));

  // 落盘的 2 会被原样保留：ActionSetStatusJsonConverter 只把 1↔Normal、
  // 3↔IsOn 折一下，2 照原样存。所以「上次退出时正在等待恢复」会被恢复出来。
  const waiting: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  waiting.actionSet.isRevertEnabled = true;
  waiting.actionSet.status = ActionSetStatus.IsOn;
  const text: string = JsonWriter.writeCompact(waiting.toJson());
  check('等待恢复状态落盘为 2', text.indexOf('"Status":2') >= 0, text.slice(0, 200));

  // 关掉恢复时若正处于等待恢复，状态要拉回 Normal。不做这一步的话，关掉恢复
  // 之后状态永远卡在 2，而下次触发时那条判据已经不看了 —— 看着像还在生效。
  const toggle: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  toggle.actionSet.isRevertEnabled = true;
  toggle.actionSet.status = ActionSetStatus.IsOn;
  WorkflowMutations.setActionSetRevertEnabled(toggle, false);
  checkEqual('关掉恢复时把 IsOn 拉回 Normal', String(toggle.actionSet.status),
    String(ActionSetStatus.Normal));
  const keepNormal: Workflow = workflowOf(TriggerIds.LESSONS_ON_CLASS);
  keepNormal.actionSet.status = ActionSetStatus.Normal;
  WorkflowMutations.setActionSetRevertEnabled(keepNormal, false);
  checkEqual('本来就不在等待恢复时不动它', String(keepNormal.actionSet.status),
    String(ActionSetStatus.Normal));
}

// ================================================ F. 编辑操作

function testMutations(): void {
  // 增删触发器
  const workflow: Workflow = WorkflowMutations.newWorkflow();
  checkEqual('新建工作流的名字', workflow.actionSet.name, '新行动组');
  check('新建工作流带一份空规则集', workflow.ruleset !== undefined);
  const added: number = WorkflowMutations.addTrigger(workflow, TriggerIds.CRON);
  checkNum('新增触发器后长度是 1', workflow.triggers.length, 1);
  checkNum('返回的是新下标', added, 0);
  const cron: CronTriggerSettings =
    WorkflowMutations.readTriggerSettings(workflow, 0) as CronTriggerSettings;
  check('新增时带上了默认设置', cron !== undefined && cron.cronExpression === '* * * * *');
  checkNum('删掉一个触发器', WorkflowMutations.removeTrigger(workflow, 0) ? 1 : 0, 1);
  checkNum('删完长度归零', workflow.triggers.length, 0);
  check('越界删除返回 false', !WorkflowMutations.removeTrigger(workflow, 0));
  check('负下标删除返回 false', !WorkflowMutations.removeTrigger(workflow, -1));

  // 换触发器类型 → 设置重置为新类型的默认值。照抄桌面版 ActivateTrigger。
  const swap: Workflow = workflowOf(TriggerIds.LESSONS_PRE_TIME_POINT,
    new PreTimePointTriggerSettings());
  const before = (WorkflowMutations.readTriggerSettings(swap, 0) as PreTimePointTriggerSettings)
    .timeSeconds;
  checkNum('换之前提前量是 60', before, 60);
  check('换触发器类型成功', WorkflowMutations.setTriggerId(swap, 0, TriggerIds.CRON));
  const cronNow: CronTriggerSettings =
    WorkflowMutations.readTriggerSettings(swap, 0) as CronTriggerSettings;
  check('换过去的设置是 cron 的默认值',
    cronNow !== undefined && cronNow.cronExpression === '* * * * *');
  // 不重置的话「上课前 60 秒」会变成「cron 表达式 60 秒前」，读不通。
  checkNum('同 id 不重置（返回 true 但不换）',
    WorkflowMutations.setTriggerId(swap, 0, TriggerIds.CRON) ? 1 : 0, 1);
  check('越界换 id 返回 false', !WorkflowMutations.setTriggerId(swap, 9, TriggerIds.CRON));

  // 换到无设置的触发器 → Settings 清空（不是留一份读不通的旧设置）
  const toNone: Workflow = workflowOf(TriggerIds.CRON, new CronTriggerSettings());
  WorkflowMutations.setTriggerId(toNone, 0, TriggerIds.LESSONS_ON_CLASS);
  check('换到无设置的触发器后 Settings 为空', toNone.triggers[0].settings === undefined);
  // 落盘仍是 "Settings":null —— TriggerSettings 没有 WhenWritingNull 条件，
  // 而 ActionItem 有。这处不一致是桌面版行为，不统一。
  const noneText: string = JsonWriter.writeCompact(toNone.toJson());
  check('TriggerSettings.Settings 为空时仍写出 null', noneText.indexOf('"Settings":null') >= 0,
    noneText);

  // 读设置：陌生 id 给 undefined，不拿默认设置顶替。
  // 顶替的话界面会给一个陌生触发器显示别人的设置默认值。
  const stranger: Workflow = workflowOf('classisland.plugin.thing');
  check('陌生触发器读不出设置',
    WorkflowMutations.readTriggerSettings(stranger, 0) === undefined);
  check('越界读设置返回 undefined',
    WorkflowMutations.readTriggerSettings(stranger, 3) === undefined);

  // 增删行动
  const actions: Workflow = WorkflowMutations.newWorkflow();
  checkNum('新增行动返回的是新下标', WorkflowMutations.addAction(actions, ActionIds.SLEEP), 0);
  checkNum('新增行动后长度是 1', actions.actionSet.actions.length, 1);
  const sleep: SleepActionSettings =
    WorkflowMutations.readActionSettings(actions, 0) as SleepActionSettings;
  check('新增行动带上了默认设置', sleep !== undefined && sleep.value === 5);
  check('陌生行动读不出设置',
    WorkflowMutations.readActionSettings(workflowOf('x'), 0) === undefined);

  // 换行动类型同样重置设置
  const swapAction: Workflow = WorkflowMutations.newWorkflow();
  WorkflowMutations.addAction(swapAction, ActionIds.SLEEP);
  check('换行动类型成功',
    WorkflowMutations.setActionId(swapAction, 0, ActionIds.APP_QUIT));
  check('换到无设置的行动后 Settings 为空', swapAction.actionSet.actions[0].settings === undefined);
  check('越界换行动 id 返回 false', !WorkflowMutations.setActionId(swapAction, 5, ActionIds.SLEEP));
  check('越界删行动返回 false', !WorkflowMutations.removeAction(swapAction, 5));

  // 可恢复行动的下标
  const revertables: Workflow = WorkflowMutations.newWorkflow();
  WorkflowMutations.addAction(revertables, ActionIds.SLEEP);
  WorkflowMutations.addAction(revertables, ActionIds.SETTINGS);
  WorkflowMutations.addAction(revertables, ActionIds.APP_QUIT);
  const indexes: number[] = WorkflowMutations.revertableActionIndexes(revertables);
  checkNum('只有一个可恢复行动', indexes.length, 1);
  checkNum('就是中间那个（应用设置）', indexes[0], 1);

  // 改设置
  const tuned: Workflow = WorkflowMutations.newWorkflow();
  WorkflowMutations.addAction(tuned, ActionIds.SLEEP);
  const changed: SleepActionSettings = new SleepActionSettings();
  changed.value = 3;
  check('写行动设置成功', WorkflowMutations.writeActionSettings(tuned, 0, changed));
  checkNum('改完读到新值',
    (WorkflowMutations.readActionSettings(tuned, 0) as SleepActionSettings).value, 3);
  check('越界写行动设置返回 false', !WorkflowMutations.writeActionSettings(tuned, 3, changed));
  check('越界写触发器设置返回 false', !WorkflowMutations.writeTriggerSettings(tuned, 0, changed));

  // 改规则集
  const conditioned: Workflow = WorkflowMutations.newWorkflow();
  const rs: Ruleset = timeStateRuleset(TimeState.OnClass);
  WorkflowMutations.setRuleset(conditioned, rs);
  checkEqual('换规则集后能读回来',
    (conditioned.rulesetView().groups[0].rules[0].id), RuleIds.LESSONS_TIME_STATE);
  WorkflowMutations.setConditionEnabled(conditioned, true);
  check('条件开关可写', conditioned.isConditionEnabled);
  WorkflowMutations.setActionSetName(conditioned, '下课铃');
  checkEqual('行动组名可改', conditioned.actionSet.name, '下课铃');
  WorkflowMutations.setActionSetEnabled(conditioned, false);
  check('行动组开关可写', !conditioned.actionSet.isEnabled);
}

// ================================================ G. 往返保真

function testRoundTrip(): void {
  const workflow: Workflow = new Workflow();
  workflow.isConditionEnabled = true;
  workflow.ruleset = timeStateRuleset(TimeState.OnClass).toJson();

  const cron: CronTriggerSettings = new CronTriggerSettings();
  cron.cronExpression = '0 30 8 * * 1-5';
  workflow.triggers.push(trigger(TriggerIds.CRON, cron));
  const pre: PreTimePointTriggerSettings = new PreTimePointTriggerSettings();
  pre.targetState = TimeState.Breaking;
  pre.timeSeconds = 300;
  workflow.triggers.push(trigger(TriggerIds.LESSONS_PRE_TIME_POINT, pre));
  // 陌生触发器：设置原样透传，不能被抹成 null
  const stranger: TriggerSettings = new TriggerSettings();
  stranger.id = 'classisland.plugin.thing';
  stranger.settings = JsonReader.parse('{"Nested":{"Keep":1},"Text":"原文"}');
  workflow.triggers.push(stranger);
  // 无设置的触发器：验证 Settings 写出 null
  const noSettingsTrigger: TriggerSettings = new TriggerSettings();
  noSettingsTrigger.id = TriggerIds.LESSONS_ON_CLASS;
  workflow.triggers.push(noSettingsTrigger);

  workflow.actionSet.name = '下课三件事';
  workflow.actionSet.isEnabled = true;
  workflow.actionSet.isRevertEnabled = true;
  workflow.actionSet.status = ActionSetStatus.IsOn;
  workflow.actionSet.guid = Guid.fromCanonical('bbbbbbbb-cccc-dddd-eeee-ffffffffffff');

  const sleep: SleepActionSettings = new SleepActionSettings();
  sleep.value = 2.5;
  workflow.actionSet.actions.push(action(ActionIds.SLEEP, sleep));
  const notify: NotificationActionSettings = new NotificationActionSettings();
  notify.content = '该喝水了';
  notify.mask = '休息一下';
  notify.isSoundEffectEnabled = false;
  notify.contentDurationSeconds = 3;
  workflow.actionSet.actions.push(action(ActionIds.SHOW_NOTIFICATION, notify));
  const settings: ModifyAppSettingsActionSettings = new ModifyAppSettingsActionSettings();
  settings.name = 'IsSilent';
  settings.value = JsonReader.parse('true');
  settings.mode = 2;
  workflow.actionSet.actions.push(action(ActionIds.SETTINGS, settings));
  const run: RunActionSettings = new RunActionSettings();
  run.runType = RunActionRunType.Url;
  run.value = 'https://example.com';
  run.args = '--a 1';
  workflow.actionSet.actions.push(action(ActionIds.OS_RUN, run));
  // 陌生行动：设置原样透传
  const oddAction: ActionItem = new ActionItem();
  oddAction.id = 'classisland.plugin.action';
  oddAction.settings = JsonReader.parse('{"Anything":[1,2,3]}');
  workflow.actionSet.actions.push(oddAction);
  // 无设置的行动：Settings 整个字段被省略（ActionItem 标了 WhenWritingNull）
  workflow.actionSet.actions.push(action(ActionIds.APP_QUIT));
  // Mode 为默认值 0 时不落盘
  const zeroMode: ModifyAppSettingsActionSettings = new ModifyAppSettingsActionSettings();
  zeroMode.name = 'IsAutoRun';
  workflow.actionSet.actions.push(action(ActionIds.SETTINGS, zeroMode));

  const text: string = JsonWriter.writeCompact(workflow.toJson());
  const back: Workflow = Workflow.fromJson(
    JsonValue.asObject(JsonReader.parse(text)) as JsonObject);

  checkEqual('往返后文本一致', JsonWriter.writeCompact(back.toJson()), text);
  checkNum('触发器个数不变', back.triggers.length, 4);
  checkEqual('cron 表达式保住了',
    (WorkflowMutations.readTriggerSettings(back, 0) as CronTriggerSettings).cronExpression,
    '0 30 8 * * 1-5');
  const preBack: PreTimePointTriggerSettings =
    WorkflowMutations.readTriggerSettings(back, 1) as PreTimePointTriggerSettings;
  checkNum('提前量保住了', preBack.timeSeconds, 300);
  checkEqual('目标状态保住了', String(preBack.targetState), String(TimeState.Breaking));
  checkEqual('陌生触发器的设置原样保住了',
    JsonWriter.writeCompact(back.triggers[2].settings as JsonNode),
    '{"Nested":{"Keep":1},"Text":"\\u539F\\u6587"}');
  checkEqual('行动组名保住了', back.actionSet.name, '下课三件事');
  check('等待恢复状态保住了', back.actionSet.status === ActionSetStatus.IsOn);
  checkNum('行动个数不变', back.actionSet.actions.length, 7);
  const notifyBack: NotificationActionSettings =
    WorkflowMutations.readActionSettings(back, 1) as NotificationActionSettings;
  checkEqual('提醒正文保住了', notifyBack.content, '该喝水了');
  checkEqual('提醒遮罩保住了', notifyBack.mask, '休息一下');
  check('提醒音效开关保住了', !notifyBack.isSoundEffectEnabled);
  checkNum('提醒时长保住了', notifyBack.contentDurationSeconds, 3);
  check('提醒的默认开关保住了', notifyBack.isTopmostEnabled);
  const runBack: RunActionSettings =
    WorkflowMutations.readActionSettings(back, 3) as RunActionSettings;
  checkEqual('运行类型的字符串落盘并读回', String(runBack.runType), String(RunActionRunType.Url));
  checkEqual('运行目标保住了', runBack.value, 'https://example.com');
  checkEqual('运行参数保住了', runBack.args, '--a 1');
  check('陌生行动项的设置原样保住了',
    JsonWriter.writeCompact(back.actionSet.actions[4].settings as JsonNode)
      .indexOf('"Anything"') >= 0);
  check('无设置的行动项没有 Settings 字段',
    back.actionSet.actions[5].settings === undefined);

  // 落盘形状：字段名与顺序
  check('字段名是 Actions 不是 ActionItems', text.indexOf('"Actions":') >= 0);
  check('TriggerSettings 的设置为 null 时仍写出 null', text.indexOf('"Settings":null') >= 0);
  check('等待恢复落盘为 2', text.indexOf('"Status":2') >= 0);
  check('运行类型落盘为字符串而非整数', text.indexOf('"RunType":"Url"') >= 0);
  checkEqual('Mode 为 0 的那一项落盘里没有 Mode',
    JsonWriter.writeCompact(back.actionSet.actions[6].settings as JsonNode),
    '{"Name":"IsAutoRun","Value":null,"IsActive":false}');
  check('Mode 非 0 时落盘', text.indexOf('"Mode":2') >= 0);
  // ModifyAppSettingsActionSettings.Value 没有条件序列化，null 也写出来
  check('应用设置的 Value 为 null 时写出 null', text.indexOf('"Value":null') >= 0);

  // 设置类逐个往返
  const cases: Object[] = [
    newCron(), newPre(), newSignal(), newTray(), newUri(),
    newRestart(), newModify(), newNotify(), newRun(), newSleep(), newWeather()
  ];
  for (const one of cases) {
    const node: JsonNode = WorkflowMutations.settingsToNode(one);
    const name: string = one.constructor.name;
    check(`${name} 转得出对象`, node instanceof JsonObject);
  }
}

function newCron(): CronTriggerSettings {
  const out: CronTriggerSettings = new CronTriggerSettings();
  out.cronExpression = '0 0 8 * * *';
  out.isActive = true;
  return out;
}

function newPre(): PreTimePointTriggerSettings {
  const out: PreTimePointTriggerSettings = new PreTimePointTriggerSettings();
  out.targetState = TimeState.AfterSchool;
  out.timeSeconds = -1;
  return out;
}

function newSignal(): SignalTriggerSettings {
  const out: SignalTriggerSettings = new SignalTriggerSettings();
  out.signalName = '下课';
  out.isRevert = true;
  return out;
}

function newTray(): TrayMenuTriggerSettings {
  const out: TrayMenuTriggerSettings = new TrayMenuTriggerSettings();
  out.header = '手动';
  return out;
}

function newUri(): UriTriggerSettings {
  const out: UriTriggerSettings = new UriTriggerSettings();
  out.uriSuffix = 'run';
  return out;
}

function newRestart(): AppRestartActionSettings {
  const out: AppRestartActionSettings = new AppRestartActionSettings();
  out.value = true;
  return out;
}

function newModify(): ModifyAppSettingsActionSettings {
  const out: ModifyAppSettingsActionSettings = new ModifyAppSettingsActionSettings();
  out.name = 'IsSilent';
  out.value = JsonReader.parse('"文本"');
  return out;
}

function newNotify(): NotificationActionSettings {
  const out: NotificationActionSettings = new NotificationActionSettings();
  out.content = '喝水';
  return out;
}

function newRun(): RunActionSettings {
  const out: RunActionSettings = new RunActionSettings();
  out.runType = RunActionRunType.Folder;
  out.value = 'D:/x';
  return out;
}

function newSleep(): SleepActionSettings {
  const out: SleepActionSettings = new SleepActionSettings();
  out.value = 1.25;
  return out;
}

function newWeather(): WeatherNotificationActionSettings {
  const out: WeatherNotificationActionSettings = new WeatherNotificationActionSettings();
  out.notificationKind = 2;
  return out;
}

function testSettingsSerialization(): void {
  // 每种设置类的落盘形状。这些类都是「照抄桌面版字段顺序」，一旦调换顺序
  // 与桌面版写出的字节就不同，同步一次就会让桌面版认为配置变了。
  const pre: PreTimePointTriggerSettings = new PreTimePointTriggerSettings();
  pre.targetState = TimeState.OnClass;
  pre.timeSeconds = 60;
  checkEqual('PreTimePoint 字段顺序',
    JsonWriter.writeCompact(pre.toJson()),
    '{"TargetState":1,"TimeSeconds":60}');

  const cron: CronTriggerSettings = new CronTriggerSettings();
  checkEqual('cron 默认值与桌面版一致', cron.cronExpression, '* * * * *');
  checkEqual('cron 落盘带 IsActive',
    JsonWriter.writeCompact(cron.toJson()), '{"CronExpression":"* * * * *","IsActive":false}');

  // ObservableObject 派生的四个（preTimePoint / trayMenu / uri / weather）
  // 没有 IsActive —— 桌面版的 ObservableObject 就没有这个字段。
  check('PreTimePoint 不带 IsActive',
    JsonWriter.writeCompact(pre.toJson()).indexOf('IsActive') < 0);

  const sleep: SleepActionSettings = new SleepActionSettings();
  checkEqual('等待时长落盘', JsonWriter.writeCompact(sleep.toJson()), '{"Value":5,"IsActive":false}');
  const notify: NotificationActionSettings = new NotificationActionSettings();
  checkEqual('提醒设置的默认值（桌面版初值）',
    JsonWriter.writeCompact(notify.toJson()),
    '{"Content":"","Mask":"","IsContentSpeechEnabled":true,"IsMaskSpeechEnabled":true,' +
    '"IsAdvancedSettingsEnabled":false,"IsSoundEffectEnabled":true,"IsTopmostEnabled":true,' +
    '"CustomSoundEffectPath":"","IsEffectEnabled":true,"MaskDurationSeconds":5,' +
    '"ContentDurationSeconds":10,"IsWaitForCompleteEnabled":false,"IsActive":false}');

  const run: RunActionSettings = new RunActionSettings();
  checkEqual('运行类型落盘为字符串',
    JsonWriter.writeCompact(run.toJson()),
    '{"RunType":"Application","Value":"","Args":"","IsActive":false}');

  // 不认识的 RunType 退回 Application（0），而不是抛。
  // 桌面版 Enum.TryParse 失败会抛，而 ActionBase.GetInstance 那层没有 catch
  // —— 整组行动会卡在这一条上。一条配坏的行动不该让同组其它行动也跑不起来。
  const badRun: JsonObject = new JsonObject();
  badRun.set('RunType', new JsonString('Nonsense'));
  badRun.set('Value', new JsonString('x'));
  checkEqual('不认识的 RunType 退回 Application',
    String(RunActionSettings.parse(badRun).runType), String(RunActionRunType.Application));

  // 越界的枚举值退回默认值，而不是照抄那个数
  const badPre: JsonObject = new JsonObject();
  badPre.set('TargetState', JsonNumber.of(99));
  checkEqual('越界 TargetState 退回 OnClass',
    String(PreTimePointTriggerSettings.parse(badPre).targetState), String(TimeState.OnClass));
  const badWeather: JsonObject = new JsonObject();
  badWeather.set('NotificationKind', JsonNumber.of(7));
  checkNum('越界 NotificationKind 原样读回（求值侧判不成立）',
    WeatherNotificationActionSettings.parse(badWeather).notificationKind, 7);

  // 设置为 null / 非对象时按「空对象」解，不崩
  checkEqual('cron 设置为 null 时用默认值',
    CronTriggerSettings.parse(new JsonObject()).cronExpression, '* * * * *');
  checkNum('提前量缺省是 60',
    PreTimePointTriggerSettings.parse(new JsonObject()).timeSeconds, 60);
  checkNum('等待时长缺省是 5', SleepActionSettings.parse(new JsonObject()).value, 5);

  // 分档与默认设置必须一一对应
  check('cron 的 settingsKind',
    TriggerCatalog.find(TriggerIds.CRON).settingsKind === TriggerSettingsKind.Cron);
  check('preTimePoint 的 settingsKind',
    TriggerCatalog.find(TriggerIds.LESSONS_PRE_TIME_POINT).settingsKind ===
      TriggerSettingsKind.PreTimePoint);
  check('无设置的触发器分档为 None',
    TriggerCatalog.find(TriggerIds.LESSONS_ON_CLASS).settingsKind === TriggerSettingsKind.None);
  check('无设置的行动分档为 None',
    ActionCatalog.find(ActionIds.APP_QUIT).settingsKind === ActionSettingsKind.None);
  check('运行行动的分档',
    ActionCatalog.find(ActionIds.OS_RUN).settingsKind === ActionSettingsKind.Run);
  check('未知 id 造不出默认设置', TriggerCatalog.defaultSettingsOf('nope') === undefined);
  check('无设置的触发器也造不出默认设置',
    TriggerCatalog.defaultSettingsOf(TriggerIds.LESSONS_ON_CLASS) === undefined);
}

// ------------------------------------------------------------ 调用清单

testCatalogs();
testCronParsing();
testTimeStateTriggers();
testLifetimeTriggers();
testCronTrigger();
testPreTimePoint();
testUnsupportedTriggers();
testChainGuards();
testConditionRevert();
testStatusAfterRun();
testMutations();
testRoundTrip();
testSettingsSerialization();

console.log(`自动化链路 通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('');
  for (const failure of failures) {
    console.log(`✗ ${failure}`);
  }
  process.exit(1);
}
