/*
 * 面板渲染模型测试台。
 *
 * 这一层是「布局 JSON 对不对」与「面板画出来好不好看」之间的那一段：吃一份
 * ComponentProfile 加一份课表档案，吐出一棵可以交给 ArkUI 画的可渲染树。测它的
 * 理由与 widget-driver 一样 —— 面板每次重算都走这里，而面板重算的触发条件
 * （每秒一次时钟）意味着任何一处算错都会一直错下去，肉眼在真机上分辨不出
 * 「今天的倒计时是 3 天」和「倒计时该是 3 天」。
 *
 * 重点覆盖六类只有读过桌面版源码才知道的事：
 *
 *   1. 倒计时格式串的 12 个占位符。大小写两组含义完全不同（%M 向上取整、
 *      %m 补零），写混了显示出来的数字差一大截而完全合法。%p 与 %P 的百分比
 *      位数也不同（两位 / 整数）。
 *   2. CountdownSource 四档各自的起止时刻。第三档「本周」要用课表首末节课的
 *      时刻，退化路径（找不到课表、NatureTimeUseMode）也要对。
 *   3. 颜色换序。落盘 #RRGGBBAA，模型输出已经是 #AARRGGBB。这里断言输出的是
 *      换过序的字符串 —— 错了一处的话面板是不透明红变半透明红，机器上看不出
 *      是 bug。
 *   4. 课程表组件的时刻边界。正在上的那节课用 [start, end) 判定，08:00 整
 *      那一刻必须已经是「正在上课」而不是「下一节」；跨零点的课不能把进度算成
 *      负数。
 *   5. 空课表的三种情形要三句不同的话：没选课表 / 今天没课 / 今天上完了。写成
 *      同一句的话，用户上完课回家看到「今天没有课程」会以为课表被清了。
 *   6. 样式合成。组件开了 IsResourceOverridingEnabled 才覆盖行的字号与前景色；
 *      背景色没开就不画（给个默认黑底会让「没设背景」看起来像「设了黑底」）。
 *
 * 另外测了容器嵌套与深度上限：布局文件外部可写，手改一份 JSON 就能造出环，
 * 无限递归的表现是页面卡死且不报错。
 */

import { ClassInfo } from '../../common_shared/src/main/ets/models/ClassInfo';
import { ClassPlan } from '../../common_shared/src/main/ets/models/ClassPlan';
import { ClassPlanGroup } from '../../common_shared/src/main/ets/models/ClassPlanGroup';
import { ColorValue } from '../../common_shared/src/main/ets/json/ColorValue';
import { DateTimeValue } from '../../common_shared/src/main/ets/json/DateTimeValue';
import { Guid } from '../../common_shared/src/main/ets/json/Guid';
import {
  JsonArray,
  JsonBoolean,
  JsonNumber,
  JsonObject,
  JsonString
} from '../../common_shared/src/main/ets/json/JsonNode';
import { JsonValue } from '../../common_shared/src/main/ets/json/JsonValue';
import {
  ComponentProfile,
  ComponentSettings,
  MainWindowLineSettings
} from '../../common_shared/src/main/ets/models/ComponentProfile';
import { Profile } from '../../common_shared/src/main/ets/models/Profile';
import { Subject } from '../../common_shared/src/main/ets/models/Subject';
import { TimeLayout } from '../../common_shared/src/main/ets/models/TimeLayout';
import { TimeLayoutItem } from '../../common_shared/src/main/ets/models/TimeLayoutItem';
import { TimeRule } from '../../common_shared/src/main/ets/models/TimeRule';
import { TimeSpanValue } from '../../common_shared/src/main/ets/json/TimeSpanValue';
import { TimeState } from '../../common_shared/src/main/ets/enums/TimeState';
import { EngineSettings } from '../../common_core/src/main/ets/engine/EngineSettings';
import { LessonsEngine } from '../../common_core/src/main/ets/engine/LessonsEngine';
import { RuleContext } from '../../common_core/src/main/ets/rules/RuleEngine';
import {
  COMPONENT_CLOCK,
  COMPONENT_COUNTDOWN,
  COMPONENT_DATE,
  COMPONENT_GROUP,
  COMPONENT_ROLLING,
  COMPONENT_SCHEDULE,
  COMPONENT_SEPARATOR,
  COMPONENT_SLIDE,
  COMPONENT_STACK,
  COMPONENT_TEXT,
  COMPONENT_WEATHER,
  ComponentCatalog
} from '../../common_core/src/main/ets/components/ComponentCatalog';
import {
  PanelBuilder,
  PanelNode,
  PanelNodeKind,
  PanelModel
} from '../../common_core/src/main/ets/panel/PanelModel';
import {
  Rule,
  RuleGroup,
  RuleIds,
  Ruleset,
  RulesetLogicalMode,
  TimeStateRuleSettings
} from '../../common_shared/src/main/ets/models/Ruleset';

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

/**
 * 按桌面版 CountDownComponent.axaml 的四段拼出界面上那一行。
 *
 * 界面上不是拿 primaryText 直接显示的 —— 那四段各有各的字号与颜色。所以测试也
 * 按四段来断言，而不是断言拼好的字符串，否则改一下弱化色的分段就全线飘红。
 */
function countdownRow(node: PanelNode): string {
  const parts: string[] = [];
  if (node.prefixText.length > 0) {
    parts.push(node.prefixText);
  }
  if (node.nameText.length > 0) {
    parts.push(node.nameText);
  }
  if (node.connectorText.length > 0) {
    parts.push(node.connectorText);
  }
  parts.push(node.valueText);
  return parts.join(' ');
}

/** 浮点比较。进度百分比在桌面版是 double，不该为了断言去改实现。 */
function checkNear(name: string, actual: number, expected: number, tolerance: number = 0.01): void {
  check(name, Math.abs(actual - expected) <= tolerance, `实际 ${actual}，期望 ${expected}±${tolerance}`);
}

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

/** 3 节课 + 2 个课间，布局下标 0..4，课程时段下标 0..2。 */
function standardLayout(): TimeLayout {
  const layout: TimeLayout = new TimeLayout();
  layout.name = '标准作息';
  layout.layouts = [
    item(0, '08:00:00', '08:45:00'),
    item(1, '08:45:00', '09:00:00', '大课间'),
    item(0, '09:00:00', '09:45:00'),
    item(1, '09:45:00', '10:00:00'),
    item(0, '10:00:00', '10:45:00')
  ];
  return layout;
}

function planKey(day: number): string {
  const hex: string = (0x10000000 + day).toString(16);
  return `${hex}-0000-0000-0000-000000000000`;
}

function profileForDays(days: number[], layout?: TimeLayout): Profile {
  const profile: Profile = new Profile();
  profile.name = '面板测试';
  profile.timeLayouts.set(LAYOUT_ID, layout === undefined ? standardLayout() : layout);
  profile.selectedClassPlanGroupId = ClassPlanGroup.defaultGroupGuid();

  const ids: string[] = [SUBJECT_YUWEN, SUBJECT_SHUXUE, SUBJECT_YINGYU];
  const names: string[] = ['语文', '数学', '英语'];
  for (let i: number = 0; i < ids.length; i++) {
    const subject: Subject = new Subject();
    subject.name = names[i];
    subject.teacherName = `${names[i]}老师`;
    profile.subjects.set(ids[i], subject);
  }

  for (const day of days) {
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

function fullWeekProfile(): Profile {
  return profileForDays([0, 1, 2, 3, 4, 5, 6]);
}

// ------------------------------------------------------------- 布局构造工具

function component(guid: string): ComponentSettings {
  const out: ComponentSettings = new ComponentSettings();
  out.id = guid;
  return out;
}

/** 带设置对象的组件。 */
function withSettings(guid: string, fields: Record<string, Object>): ComponentSettings {
  const out: ComponentSettings = component(guid);
  const node: JsonObject = new JsonObject();
  for (const key of Object.keys(fields)) {
    const value: Object = fields[key];
    if (typeof value === 'boolean') {
      node.set(key, new JsonBoolean(value));
    } else if (typeof value === 'number') {
      node.set(key, JsonNumber.of(value));
    } else {
      node.set(key, new JsonString(`${value}`));
    }
  }
  out.settings = node;
  return out;
}

function line(children: ComponentSettings[]): MainWindowLineSettings {
  const out: MainWindowLineSettings = new MainWindowLineSettings();
  out.children = children;
  return out;
}

function layoutOf(lines: MainWindowLineSettings[]): ComponentProfile {
  const out: ComponentProfile = new ComponentProfile();
  out.lines = lines;
  return out;
}

/** 只有一行一个组件的布局，测试里最常用的形状。 */
function oneOf(guid: string, fields?: Record<string, Object>): ComponentProfile {
  const node: ComponentSettings = fields === undefined
    ? component(guid) : withSettings(guid, fields);
  return layoutOf([line([node])]);
}

function build(layout: ComponentProfile, at: string, profile?: Profile): PanelModel {
  return PanelBuilder.build(layout,
    profile === undefined ? fullWeekProfile() : profile, engineSettings(), dt(at));
}

/** 第 0 行第 0 个节点。 */
function node0(model: PanelModel): PanelNode {
  return model.lines[0].nodes[0];
}

// ------------------------------------------------------------- 隐藏规则夹具

/**
 * 造一个「时间状态」隐藏规则集。
 *
 * 这是唯一一条在当前平台既Implemented 又不依赖任何外部数据的规则（课表快照
 * 里就有），所以面板侧的隐藏判定全部用它。
 */
function timeStateRuleset(state: TimeState, mode?: RulesetLogicalMode): JsonObject {
  const settings: TimeStateRuleSettings = new TimeStateRuleSettings();
  settings.state = state;
  const ruleset: Ruleset = new Ruleset();
  ruleset.mode = mode === undefined ? RulesetLogicalMode.Or : mode;
  const group: RuleGroup = new RuleGroup();
  group.mode = RulesetLogicalMode.Or;
  const rule: Rule = new Rule();
  rule.id = RuleIds.LESSONS_TIME_STATE;
  rule.settings = settings.toJson();
  group.rules.push(rule);
  ruleset.groups.push(group);
  return ruleset.toJson();
}

/**
 * 造一个容器。
 *
 * 容器的子组件存在 settings.Children 里（裸 JSON），走 withSettings 那条通用
 * 通道会把它当成未知字段，所以这里直接拼 JsonNode。
 */
function groupOf(children: ComponentSettings[]): ComponentSettings {
  const settings: JsonObject = new JsonObject();
  const arr: JsonArray = new JsonArray();
  for (const child of children) {
    arr.push(child.toJson());
  }
  settings.set('Children', arr);
  const out: ComponentSettings = component(COMPONENT_GROUP);
  out.settings = settings;
  return out;
}

/** 给组件挂上隐藏规则。 */
function withRule(node: ComponentSettings, hideOnRule: boolean, rules?: JsonObject): ComponentSettings {
  node.hideOnRule = hideOnRule;
  if (rules !== undefined) {
    node.hidingRules = rules;
  }
  return node;
}

/** 给行挂上隐藏规则。 */
function lineWithRule(children: ComponentSettings[], hideOnRule: boolean,
  rules?: JsonObject): MainWindowLineSettings {
  const out: MainWindowLineSettings = line(children);
  out.hideOnRule = hideOnRule;
  if (rules !== undefined) {
    out.hidingRules = rules;
  }
  return out;
}

/** 08:30 正在上第一节课（语文），BASE_DAY 是周六，档案里排满课。 */
const ON_CLASS_AT: string = `${BASE_DAY}T08:30:00`;

/** 12:00 今天没课了（末节课 10:45 结束），状态是已放学。 */
const AFTER_SCHOOL_AT: string = `${BASE_DAY}T12:00:00`;

// ------------------------------------------------------------ 隐藏规则判定

function testRuleNeedsBothSwitchAndRules(): void {
  // 桌面版是 `HideOnRule && HidingRules != null && IsRulesetSatisfied(HidingRules)`，
  // 三个条件缺一不可。这里分别去掉前两个。
  const rules: JsonObject = timeStateRuleset(TimeState.OnClass);

  const noSwitch: PanelModel = build(
    layoutOf([line([withRule(component(COMPONENT_DATE), false, rules)])]), ON_CLASS_AT);
  check('配了规则但没开开关 → 不藏', !node0(noSwitch).isRuleHidden);

  const noRules: PanelModel = build(
    layoutOf([line([withRule(component(COMPONENT_DATE), true)])]), ON_CLASS_AT);
  check('开了开关但没配规则 → 不藏', !node0(noRules).isRuleHidden);

  const both: PanelModel = build(
    layoutOf([line([withRule(component(COMPONENT_DATE), true, rules)])]), ON_CLASS_AT);
  check('开关与规则都在且成立 → 藏', node0(both).isRuleHidden);
}

function testRuleHiddenStillRendersContent(): void {
  // 桌面版只是把 IsVisibleInternal 置 false，presenter 里该算的照算（换算时刻、
  // 筛课表都要跑），所以内容必须还在树上 —— 界面上编辑页要靠这些内容画那份
  // 淡化的「被藏起来」的样子。
  const rules: JsonObject = timeStateRuleset(TimeState.OnClass);
  const model: PanelModel = build(layoutOf([line([withSettings(COMPONENT_TEXT, {
    TextContent: '期中'
  })])]), ON_CLASS_AT);
  const node: PanelNode = node0(model);
  checkEqual('未命中时文本照常算', node.primaryText, '期中');

  const hidden: PanelModel = build(layoutOf([line([withRule(withSettings(COMPONENT_TEXT, {
    TextContent: '期中'
  }), true, rules)])]), ON_CLASS_AT);
  check('命中时节点仍在树上', hidden.lines[0].nodes.length === 1);
  checkEqual('命中时内容照样算出来', hidden.lines[0].nodes[0].primaryText, '期中');
  check('命中标志打上了', hidden.lines[0].nodes[0].isRuleHidden);
}

function testRuleNotMatchedAtOtherTime(): void {
  // 同一份规则在放学后不成立。这条最容易写错成「只要有规则就藏」。
  const rules: JsonObject = timeStateRuleset(TimeState.OnClass);
  const model: PanelModel = build(
    layoutOf([line([withRule(component(COMPONENT_DATE), true, rules)])]), AFTER_SCHOOL_AT);
  check('规则不成立 → 不藏', !node0(model).isRuleHidden);
}

function testLineRuleHidden(): void {
  const rules: JsonObject = timeStateRuleset(TimeState.OnClass);
  const hidden: PanelModel = build(
    layoutOf([lineWithRule([component(COMPONENT_DATE)], true, rules)]), ON_CLASS_AT);
  checkNum('被规则藏的行数', hidden.ruleHiddenLineCount, 1);
  checkNum('被规则藏的行不算「用户关掉的」', hidden.hiddenLineCount, 0);
  // 关键：行仍然在模型里。桌面版编辑模式下这一行照常占位（只淡化），
  // 真面板由 PanelNodeView 按 inEditMode 决定画不画 —— core 不替界面决定。
  checkNum('被规则藏的行仍在模型里', hidden.lines.length, 1);
  check('行的命中标志打上了', hidden.lines[0].isRuleHidden);

  const miss: PanelModel = build(
    layoutOf([lineWithRule([component(COMPONENT_DATE)], true, rules)]), AFTER_SCHOOL_AT);
  checkNum('规则不成立时不算被藏的行', miss.ruleHiddenLineCount, 0);
  check('规则不成立时行不标记', !miss.lines[0].isRuleHidden);
}

function testLineRuleIndependentOfChildren(): void {
  // 桌面版 MainWindowLine.UpdateHiddenState 里
  // `Settings.IsVisible = IsVisibleInternal` —— 只看自己的规则，不与子节点做
  // 与运算。所以一行里所有组件都被藏了之后，这一行仍然不是「被规则藏的行」。
  const rules: JsonObject = timeStateRuleset(TimeState.OnClass);
  const model: PanelModel = build(layoutOf([
    line([withRule(component(COMPONENT_DATE), true, rules),
      withRule(component(COMPONENT_CLOCK), true, rules)])
  ]), ON_CLASS_AT);
  checkNum('两个子组件都被藏', model.lines[0].nodes.filter(
    (n: PanelNode) => n.isRuleHidden).length, 2);
  check('行本身不算被规则藏', !model.lines[0].isRuleHidden);
  checkNum('被藏的行数仍是 0', model.ruleHiddenLineCount, 0);
}

function testExplicitlyHiddenLineSkipsRuleCheck(): void {
  // IsVisible=false 的行在算规则之前就被跳过了（PanelBuilder.build 里 continue），
  // 所以它只进 hiddenLineCount，不会同时进 ruleHiddenLineCount —— 一个行被算
  // 两次会让「另有 N 行已隐藏」这句话里的 N 大于用户实际关掉的行数。
  const rules: JsonObject = timeStateRuleset(TimeState.OnClass);
  const hidden: MainWindowLineSettings = lineWithRule([component(COMPONENT_DATE)], true, rules);
  hidden.isVisible = false;
  const model: PanelModel = build(layoutOf([hidden]), ON_CLASS_AT);
  checkNum('显式隐藏的行进 hiddenLineCount', model.hiddenLineCount, 1);
  checkNum('显式隐藏的行不进 ruleHiddenLineCount', model.ruleHiddenLineCount, 0);
  checkNum('模型里没有这一行', model.lines.length, 0);
  check('空模型', model.isEmpty);
}

function testAllChildrenHiddenPropagates(): void {
  // 递归口径：子节点的「有效可见」= 自身没被藏 **且** 子节点不全空。
  // 对应桌面版 _isAllComponentsHid + `IsVisible = IsVisibleInternal && !_isAllComponentsHid`。
  const rules: JsonObject = timeStateRuleset(TimeState.OnClass);
  const hiddenChild: ComponentSettings = withRule(component(COMPONENT_DATE), true, rules);

  // 1. 组里只有一个被藏的子组件 → 组的 allChildrenHidden 为真，但组自己不算被藏。
  const onlyHidden: PanelModel = build(layoutOf([line([groupOf([hiddenChild])])]), ON_CLASS_AT);
  const groupNode: PanelNode = onlyHidden.lines[0].nodes[0];
  check('单个被藏子组件 → 组的 allChildrenHidden', groupNode.allChildrenHidden);
  check('组自己不算被规则藏', !groupNode.isRuleHidden);

  // 2. 组里有一个可见子组件 → 不算全藏。
  const mixed: PanelModel = build(layoutOf([line([
    groupOf([hiddenChild, component(COMPONENT_CLOCK)])])]), ON_CLASS_AT);
  check('有可见子组件 → 不算全藏', !mixed.lines[0].nodes[0].allChildrenHidden);

  // 3. 空容器：桌面版 `Children.FirstOrDefault(x => x.IsVisible) == null` 对空列表
  //    同样成立，所以空容器算「全藏」—— 它还显示着靠的是自己的 IsVisibleInternal。
  const empty: PanelModel = build(layoutOf([line([groupOf([])])]), ON_CLASS_AT);
  check('空容器算全藏', empty.lines[0].nodes[0].allChildrenHidden);
  check('空容器不算被规则藏', !empty.lines[0].nodes[0].isRuleHidden);
}

function testAllChildrenHiddenRecurses(): void {
  // 两层嵌套：内层的子组件全被藏 → 内层 allChildrenHidden；外层只有一个内层，
  // 照同一口径也全藏。一层就停的话，外层会以为自己还有可见内容。
  const rules: JsonObject = timeStateRuleset(TimeState.OnClass);
  const inner: ComponentSettings = groupOf([withRule(component(COMPONENT_DATE), true, rules)]);
  const outer: ComponentSettings = groupOf([inner]);
  const model: PanelModel = build(layoutOf([line([outer])]), ON_CLASS_AT);
  const outerNode: PanelNode = model.lines[0].nodes[0];
  check('外层 allChildrenHidden', outerNode.allChildrenHidden);
  check('内层 allChildrenHidden', outerNode.children[0].allChildrenHidden);
  check('内层的子组件被藏', outerNode.children[0].children[0].isRuleHidden);
  check('外层与内层都不算自身被藏', !outerNode.isRuleHidden && !outerNode.children[0].isRuleHidden);
}

function testAllChildrenHiddenStopsAtOwnHit(): void {
  // 节点自身被藏了，allChildrenHidden 就无所谓了：桌面版是
  // `IsVisibleInternal && !_isAllComponentsHid`，自身已经假了与运算的结果不会翻过来。
  // 这里让被藏的组里放一个可见子组件：allChildrenHidden 应为假。
  const rules: JsonObject = timeStateRuleset(TimeState.OnClass);
  const group: ComponentSettings = groupOf([component(COMPONENT_CLOCK)]);
  withRule(group, true, rules);
  const model: PanelModel = build(layoutOf([line([group])]), ON_CLASS_AT);
  const node: PanelNode = model.lines[0].nodes[0];
  check('自身被藏的组 isRuleHidden', node.isRuleHidden);
  check('自身被藏但子节点可见 → allChildrenHidden 为假', !node.allChildrenHidden);
}

function testRuleHiddenSharesOneContext(): void {
  // 整块面板只算一次 RuleContext。同一时刻两个组件用同一份课表状态，一个该藏
  // 一个不该藏 —— 如果按节点各算一次，这两份状态可能因为跨过某一刻而不一致。
  const onClass: JsonObject = timeStateRuleset(TimeState.OnClass);
  const afterSchool: JsonObject = timeStateRuleset(TimeState.AfterSchool);
  const model: PanelModel = build(layoutOf([line([
    withRule(component(COMPONENT_DATE), true, onClass),
    withRule(component(COMPONENT_CLOCK), true, afterSchool)
  ])]), ON_CLASS_AT);
  check('上课中：命中「上课中」的那个', model.lines[0].nodes[0].isRuleHidden);
  check('上课中：不命中「已放学」的那个', !model.lines[0].nodes[1].isRuleHidden);

  const later: PanelModel = build(layoutOf([line([
    withRule(component(COMPONENT_DATE), true, onClass),
    withRule(component(COMPONENT_CLOCK), true, afterSchool)
  ])]), AFTER_SCHOOL_AT);
  check('放学后：反过来', !later.lines[0].nodes[0].isRuleHidden
    && later.lines[0].nodes[1].isRuleHidden);
}

function testRuleHiddenInSignature(): void {
  // 隐藏状态必须进指纹。文本组件的内容一个字都不会变，课表状态一变被藏的
  // 组件就换人 —— 不进指纹的话面板不重绘，藏起来的那个要等下一次别处变化才消失。
  const onClass: JsonObject = timeStateRuleset(TimeState.OnClass);
  const afterSchool: JsonObject = timeStateRuleset(TimeState.AfterSchool);
  // 两个一模一样的文本组件各挂一条不同的规则，内容不变，只有隐藏状态会变。
  const layout: ComponentProfile = layoutOf([line([
    withRule(withSettings(COMPONENT_TEXT, { TextContent: '期中' }), true, onClass),
    withRule(withSettings(COMPONENT_TEXT, { TextContent: '期末' }), true, afterSchool)
  ])]);
  const a: PanelModel = build(layout, ON_CLASS_AT);
  const b: PanelModel = build(layout, AFTER_SCHOOL_AT);
  check('隐藏状态翻转时签名要变', a.buildSignature() !== b.buildSignature());
  check('节点自身翻转也要变',
    PanelBuilder.signatureOf(a.lines[0].nodes)
    !== PanelBuilder.signatureOf(b.lines[0].nodes));

  // 只有 allChildrenHidden 变（节点自身都没被藏）时也要变。
  const inner: ComponentSettings = groupOf([withRule(component(COMPONENT_DATE), true, onClass)]);
  const outer: ComponentSettings = groupOf([inner, component(COMPONENT_CLOCK)]);
  const layout2: ComponentProfile = layoutOf([line([outer])]);
  const a2: PanelModel = build(layout2, ON_CLASS_AT);
  const b2: PanelModel = build(layout2, AFTER_SCHOOL_AT);
  check('allChildrenHidden 变时节点签名要变',
    PanelBuilder.signatureOf(a2.lines[0].nodes)
    !== PanelBuilder.signatureOf(b2.lines[0].nodes));
  check('allChildrenHidden 变时整模签名要变',
    a2.buildSignature() !== b2.buildSignature());
}

function testRuleReversedIsHonored(): void {
  // 组件上把整条规则集取反：上课时不藏、放学时藏。这条与求值器无关，
  // 但它确认 PanelBuilder 走的是 RuleEngine 而不是自己判。
  const rules: JsonObject = timeStateRuleset(TimeState.OnClass);
  const reversed: Ruleset = Ruleset.parse(rules);
  reversed.isReversed = true;
  const layout: ComponentProfile = layoutOf([
    line([withRule(component(COMPONENT_DATE), true, reversed.toJson())])]);
  check('取反后上课时不藏', !node0(build(layout, ON_CLASS_AT)).isRuleHidden);
  check('取反后放学时藏', node0(build(layout, AFTER_SCHOOL_AT)).isRuleHidden);
}

function testRuleCountingWithMixedLines(): void {
  // 三个行：可见、显式关掉、被规则藏。三个计数各自独立。
  const rules: JsonObject = timeStateRuleset(TimeState.OnClass);
  const manual: MainWindowLineSettings = line([component(COMPONENT_DATE)]);
  manual.isVisible = false;
  const model: PanelModel = build(layoutOf([
    line([component(COMPONENT_DATE)]),
    manual,
    lineWithRule([component(COMPONENT_CLOCK)], true, rules)
  ]), ON_CLASS_AT);
  checkNum('可见行进了模型', model.lines.length, 2);
  checkNum('显式关掉的行数', model.hiddenLineCount, 1);
  checkNum('被规则藏的行数', model.ruleHiddenLineCount, 1);
  check('不空', !model.isEmpty);
}

function testRuleWithoutProfile(): void {
  // 编辑预览时可能还没选课表（profile 是 undefined）。没有课表状态时课表类规则
  // 判不成立，别的规则照常求值 —— 不能因为没有档案就把整棵树的规则判定
  // 变成「全部不藏」，那会让预览里看不到任何一条被藏起来的组件。
  const rules: JsonObject = timeStateRuleset(TimeState.OnClass);
  const model: PanelModel = PanelBuilder.build(
    layoutOf([line([withRule(component(COMPONENT_DATE), true, rules)])]),
    undefined, engineSettings(), dt(ON_CLASS_AT));
  check('没有课表时课表类规则不成立', !node0(model).isRuleHidden);
  check('没有课表时仍能算隐藏状态（不崩）', model.lines.length === 1);

  // 恒假的那几条（窗口类）没档案也一样不成立，不该反过来成立。
  const window: JsonObject = timeStateRuleset(TimeState.OnClass);
  const model2: PanelModel = PanelBuilder.build(
    layoutOf([line([withRule(component(COMPONENT_DATE), true, window)])]),
    undefined, engineSettings(), dt(ON_CLASS_AT));
  check('没档案也不会误判成立', !node0(model2).isRuleHidden);
}

function testIsRuleHiddenDirectly(): void {
  // PanelBuilder.isRuleHidden 是行与组件共用的那个函数，公开出来就是为了界面上
  // 的编辑器与测试能问同一个问题。这里直接测它的三个早退。
  const context: RuleContext = new RuleContext();
  context.now = dt(ON_CLASS_AT);
  context.profile = fullWeekProfile();
  context.snapshot = LessonsEngine.compute(context.profile, engineSettings(), context.now);
  const rules: JsonObject = timeStateRuleset(TimeState.OnClass);
  check('开关关 → 假', !PanelBuilder.isRuleHidden(false, rules, context));
  check('没规则 → 假', !PanelBuilder.isRuleHidden(true, undefined, context));
  check('开关与规则都在且成立 → 真', PanelBuilder.isRuleHidden(true, rules, context));

  // 换一份时刻不同的上下文，同一份规则的结论要跟着变。函数里如果藏了个静态
  // 缓存的快照，这里会返回上一次那个时刻的结论。
  const later: RuleContext = new RuleContext();
  later.now = dt(AFTER_SCHOOL_AT);
  later.profile = fullWeekProfile();
  later.snapshot = LessonsEngine.compute(later.profile, engineSettings(), later.now);
  check('换时刻后同一份规则不成立', !PanelBuilder.isRuleHidden(true, rules, later));
  check('早退不依赖上下文', !PanelBuilder.isRuleHidden(false, rules, later)
    && !PanelBuilder.isRuleHidden(true, undefined, later));
}

// --------------------------------------------------------- A. 倒计时格式串

function testCountDownFormatTokens(): void {
  // %D 向上取整的天数。delta = 1.5 天 → 2（Math.Ceiling(1.5)）。
  checkEqual('%D 向上取整',
    PanelBuilder.formatCountDown('%D', 1.5 * 86400, 10 * 86400), '2');
  // %d 截断。
  checkEqual('%d 截断',
    PanelBuilder.formatCountDown('%d', 1.5 * 86400, 10 * 86400), '1');
  // %H 向上取整。
  checkEqual('%H 向上取整',
    PanelBuilder.formatCountDown('%H', 3601, 10 * 3600), '2');
  // %h 截断且只到 0..23。
  checkEqual('%h 截断取模 24',
    PanelBuilder.formatCountDown('%h', 3601, 10 * 3600), '1');
  checkEqual('%h 超过一天取模',
    PanelBuilder.formatCountDown('%h', 25 * 3600, 30 * 3600), '1');
  // %M 向上取整 vs %m 补零截断：这是最容易写混的一对。
  checkEqual('%M 向上取整',
    PanelBuilder.formatCountDown('%M', 125, 3600), '3');
  checkEqual('%m 补零截断',
    PanelBuilder.formatCountDown('%m', 125, 3600), '02');
  // %S 向上取整 vs %s 补零。
  checkEqual('%S 向上取整',
    PanelBuilder.formatCountDown('%S', 10.2, 3600), '11');
  checkEqual('%s 补零',
    PanelBuilder.formatCountDown('%s', 10.2, 3600), '10');
  // %X 毫秒向上取整 vs %x 毫秒分量补零三位。1.5 秒 = 1500 毫秒，分量是 500。
  checkEqual('%X 毫秒向上取整',
    PanelBuilder.formatCountDown('%X', 1.5, 3600), '1500');
  checkEqual('%x 毫秒分量补零',
    PanelBuilder.formatCountDown('%x', 1.5, 3600), '500');
  checkEqual('%x 毫秒分量补零到三位',
    PanelBuilder.formatCountDown('%x', 1.05, 3600), '050');
  // %P 已过百分比整数，%p 两位小数，%L 剩余百分比整数。
  checkEqual('%P 已过取整',
    PanelBuilder.formatCountDown('%P', 4567, 10000), '54%');
  checkEqual('%p 已过两位',
    PanelBuilder.formatCountDown('%p', 4567, 10000), '54.33%');
  checkEqual('%L 剩余取整',
    PanelBuilder.formatCountDown('%L', 4567, 10000), '46%');
  // 大小写混排一次，验证替换顺序不影响结果。
  // 1.5 天 + 1 小时零 1 秒 = 133201 秒。%D 是向上取整的**总**天数（2），
  // %H 是向上取整的**总**小时数（37.0003 → 38），两者各自独立，不做「天时进位」。
  checkEqual('混排', PanelBuilder.formatCountDown('%D天%H时', 1.5 * 86400 + 3601, 10 * 86400),
    '2天38时');
  // 空格式串不该吐出「null」或 undefined。
  checkEqual('空格式串', PanelBuilder.formatCountDown('', 100, 100), '');
  // totalSeconds 为 0 时百分比不能是 NaN。
  checkEqual('totalSeconds=0 时 %L',
    PanelBuilder.formatCountDown('%L', 0, 0), '0%');
  checkEqual('totalSeconds=0 时 %P',
    PanelBuilder.formatCountDown('%P', 0, 0), '100%');
  // delta 为负（目标日已过）时夹到 0。
  checkEqual('负 delta 夹到 0',
    PanelBuilder.formatCountDown('%S', -500, 3600), '0');
}

// ----------------------------------------------------- B. 倒计时四档起止

function testCountDownStaticRange(): void {
  // 第 0 档：start → over。2026-10-01 00:00 减 2026-09-26 00:00 = 5 天。
  const model: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountDownName': '期末',
    'CountDownConnector': '还有',
    'CustomStringFormat': '%D天',
    'StartTime': `${BASE_DAY}T00:00:00`,
    'OverTime': '2026-10-01T00:00:00'
  }), `${BASE_DAY}T00:00:00`);
  const node: PanelNode = node0(model);
  // 非紧凑模式的四段：距离（弱化）/ 期末 / 还有（弱化）/ 数值。
  checkEqual('静态区间前缀', node.prefixText, '距离');
  checkEqual('静态区间名称', node.nameText, '期末');
  checkEqual('静态区间连接词', node.connectorText, '还有');
  checkEqual('静态区间数值', node.valueText, '5天');
  checkEqual('静态区间主文本', countdownRow(node), '距离 期末 还有 5天');
  checkNum('静态区间进度不显示', node.progressPercent, -1);
}

function testCountDownCompactMode(): void {
  // 紧凑模式省掉名称，也不再给连接词分色。
  const model: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountDownName': '期末',
    'CountDownConnector': '还有',
    'IsCompactModeEnabled': true,
    'CustomStringFormat': '%D天',
    'StartTime': `${BASE_DAY}T00:00:00`,
    'OverTime': '2026-10-01T00:00:00'
  }), `${BASE_DAY}T00:00:00`);
  const node: PanelNode = node0(model);
  // 紧凑模式只剩「连接词 + 数值」，前缀与名称都不摆出来。
  // 名称那段在桌面版模板里没绑 IsVisible，紧凑模式下仍然摆出来。
  checkEqual('紧凑模式无前缀', node.prefixText, '');
  checkEqual('紧凑模式保留名称', node.nameText, '期末');
  checkEqual('紧凑模式无连接词', node.connectorText, '');
  checkEqual('紧凑模式数值', node.valueText, '5天');
  checkEqual('紧凑模式主文本', node.primaryText, '期末 5天');
  checkEqual('紧凑模式无连接词', node.connectorText, '');
}

function testCountDownProgress(): void {
  // 正向进度 = 剩余比例。目标日 10 天后、已过 4 天 → 剩 6 天 = 60%。
  // 桌面版 `value = Inverted ? end - now : now - start`：正向填「已过」，
  // 反向填「剩余」。10 天里已过 4 天 → 正向 40%、反向 60%。
  // 名字里的「反向」指的是进度条倒着填，不是「反过来算」，所以别在这上面调换。
  const model: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CustomStringFormat': '%D天',
    'ShowProgress': true,
    'StartTime': '2026-09-22T00:00:00',
    'OverTime': '2026-10-02T00:00:00'
  }), '2026-09-26T00:00:00');
  const node: PanelNode = node0(model);
  checkNum('正向进度是已过比例', node.progressPercent, 40);
  check('正向进度未反向', !node.progressInverted);

  const inverted: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CustomStringFormat': '%D天',
    'ShowProgress': true,
    'IsProgressInverted': true,
    'StartTime': '2026-09-22T00:00:00',
    'OverTime': '2026-10-02T00:00:00'
  }), '2026-09-26T00:00:00');
  checkNum('反向进度是剩余比例', node0(inverted).progressPercent, 60);
  check('反向进度标记生效', node0(inverted).progressInverted);

  // 关掉 ShowProgress 就不画进度条。
  const off: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'ShowProgress': false, 'StartTime': '2026-09-22T00:00:00',
    'OverTime': '2026-10-02T00:00:00'
  }), '2026-09-26T00:00:00');
  checkNum('关掉进度则无进度', node0(off).progressPercent, -1);

  // 进度条形态：0 圆环 / 1 横条，抄桌面版 ProgressBarMode。
  checkNum('默认圆环', node.progressMode, 0);
  const bar: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'ShowProgress': true, 'ProgressBarMode': 1,
    'StartTime': '2026-09-22T00:00:00', 'OverTime': '2026-10-02T00:00:00'
  }), '2026-09-26T00:00:00');
  checkNum('横条形态', node0(bar).progressMode, 1);
  checkNum('横条形态也有进度', node0(bar).progressPercent, 40);
}

function testCountDownTodaySource(): void {
  // 第 2 档「今天」：用课表首末节课的时刻。标准作息是 08:00-10:45。
  // 06:00 起到 10:45 是 4h45m = 17100 秒。%h 是小时分量（4）、%m 是分钟分量（45）。
  const model: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 2,
    'CountDownName': '今天',
    'CountDownConnector': '',
    'CustomStringFormat': '%h:%m',
    'OverTime': '2026-10-01T00:00:00',
    'StartTime': '2026-09-01T00:00:00'
  }), `${BASE_DAY}T06:00:00`);
  checkEqual('今天档用课表末节时刻', countdownRow(node0(model)), '距离 今天 4:45');

  // 同一段的 %H 与 %M 是**总量**（ceil(delta.TotalHours) / ceil(delta.TotalMinutes)），
  // 不是分量。写成 %H:%M 会得到 5:285 —— 这是桌面版的行为，不是 bug。
  // 记在这里是因为它最容易被后来的人当成 bug「修」掉。
  const totals: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 2,
    'CountDownName': '今天',
    'CountDownConnector': '',
    'CustomStringFormat': '%H:%M',
    'OverTime': '2026-10-01T00:00:00',
    'StartTime': '2026-09-01T00:00:00'
  }), `${BASE_DAY}T06:00:00`);
  checkEqual('大写占位符是总量', countdownRow(node0(totals)), '距离 今天 5:285');

  // 自然日口径只在「今天没课」时才读得到 —— dayRange 有课时它压根不被看。
  // 所以下面几个退化用例都要用一份今天没课的档案（今天 2026-09-26 是周六）。
  const weekday: Profile = profileForDays([1, 2, 3, 4, 5]);

  // 口径 1：整天。06:00 到次日 00:00 = 18 小时。
  const whole: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 2,
    'NatureTimeUseMode': 1,
    'CustomStringFormat': '%H',
    'OverTime': '2026-10-01T00:00:00',
    'StartTime': '2026-09-01T00:00:00'
  }), `${BASE_DAY}T06:00:00`, weekday);
  checkEqual('自然日口径 1 用整天', countdownRow(node0(whole)), '距离 倒计时 还有 18');

  // 口径 0 + 今天没课：退回整天（同为 18 小时，走的是 dayRange 的 fallback）。
  const fallback: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 2,
    'NatureTimeUseMode': 0,
    'CustomStringFormat': '%H',
    'OverTime': '2026-10-01T00:00:00',
    'StartTime': '2026-09-01T00:00:00'
  }), `${BASE_DAY}T06:00:00`, weekday);
  checkEqual('自然日口径 0 无课时退回整天',
    countdownRow(node0(fallback)), '距离 倒计时 还有 18');

  // 口径 2：起止都是此刻，delta 夹到 0。
  const none: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 2,
    'NatureTimeUseMode': 2,
    'CustomStringFormat': '%H',
    'OverTime': '2026-10-01T00:00:00',
    'StartTime': '2026-09-01T00:00:00'
  }), `${BASE_DAY}T06:00:00`, weekday);
  checkEqual('自然日口径 2 落到空区间', countdownRow(node0(none)), '距离 倒计时 还有 0');

  // 没档案（编辑预览）时按整天算，而不是崩。
  const bare: PanelModel = PanelBuilder.build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 2, 'CustomStringFormat': '%H',
    'OverTime': '2026-10-01T00:00:00', 'StartTime': '2026-09-01T00:00:00'
  }), undefined, engineSettings(), dt(`${BASE_DAY}T06:00:00`));
  checkEqual('没档案时今天档按整天算', countdownRow(node0(bare)), '距离 倒计时 还有 18');
}

function testCountDownWeekSource(): void {
  // 第 3 档「本周」：区间是本周首节课开始 → 周末那天的末节课结束，而**显示的是从
  // 此刻到结束还剩多久**，不是整段跨度。引擎的单周起始日是 2026-09-20（周日），
  // 区间是 09-20 08:00 → 09-26 10:45。BASE_DAY 是周六，此刻 00:00，
  // 距末节课还剩 10h45m = 38700 秒。
  //   %D = ceil(38700 / 86400) = 1，%H = ceil(38700 / 3600) = 11
  // 所以「1 天 11 时」是对的 —— 「7 天」那种整段跨度不是倒计时该显示的东西。
  const model: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 3,
    'CountDownName': '本周',
    'CountDownConnector': '',
    'CustomStringFormat': '%D天%H时',
    'OverTime': '2026-10-01T00:00:00',
    'StartTime': '2026-09-01T00:00:00'
  }), `${BASE_DAY}T00:00:00`);
  checkEqual('本周档跨天跨节', countdownRow(node0(model)), '距离 本周 1天11时');

  // 同一份设置换个时刻：到 09-26 08:00 时末节课还剩 2h45m。这里用小写的分量占位符
  // %h:%m（2:45）；写成大写 %H 会得到 3:45 —— 见 testCountDownFormat。
  const midDay: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 3,
    'CountDownName': '本周',
    'CountDownConnector': '',
    'CustomStringFormat': '%h:%m',
    'OverTime': '2026-10-01T00:00:00',
    'StartTime': '2026-09-01T00:00:00'
  }), `${BASE_DAY}T08:00:00`);
  checkEqual('本周档课中剩余', countdownRow(node0(midDay)), '距离 本周 2:45');

  // 上完末节课之后不再倒计时（区间结束，delta 夹到 0），不能出负数。
  const past: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 3,
    'CountDownName': '本周',
    'CountDownConnector': '',
    'CustomStringFormat': '%D',
    'OverTime': '2026-10-01T00:00:00',
    'StartTime': '2026-09-01T00:00:00'
  }), `${BASE_DAY}T23:00:00`);
  checkEqual('本周档上完后归零', countdownRow(node0(past)), '距离 本周 0');

  // 自定义起始星期几：设成周一（1），本周从 09-21 起算，末节课是 09-27（周日）
  // 的 10:45。09-26 00:00 到 09-27 10:45 = 124200 秒 → %D = 2。
  const monday: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 3,
    'IsCustomWeekCountdownStartDayEnabled': true,
    'WeekCountdownStartDay': 1,
    'CountDownName': '本周',
    'CountDownConnector': '',
    'CustomStringFormat': '%D天',
    'OverTime': '2026-10-01T00:00:00',
    'StartTime': '2026-09-01T00:00:00'
  }), `${BASE_DAY}T00:00:00`);
  checkEqual('本周档自定义起始日', countdownRow(node0(monday)), '距离 本周 2天');

  // 自然日口径 1：整周。09-20 00:00 → 09-27 00:00，此刻 09-26 00:00 还剩 1 天。
  const whole: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 3,
    'NatureTimeUseMode': 1,
    'CountDownName': '本周',
    'CountDownConnector': '',
    'CustomStringFormat': '%H',
    'OverTime': '2026-10-01T00:00:00',
    'StartTime': '2026-09-01T00:00:00'
  }), `${BASE_DAY}T00:00:00`);
  checkEqual('本周档自然日口径 1', countdownRow(node0(whole)), '距离 本周 24');

  // 没档案时也按整周算，不能崩也不能给 0。
  const bare: PanelModel = PanelBuilder.build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 3, 'CustomStringFormat': '%H',
    'OverTime': '2026-10-01T00:00:00', 'StartTime': '2026-09-01T00:00:00'
  }), undefined, engineSettings(), dt(`${BASE_DAY}T00:00:00`));
  checkEqual('没档案时本周档按整周算', countdownRow(node0(bare)), '距离 倒计时 还有 24');
}

function testCountDownCycleSource(): void {
  // 第 1 档「周期」：CycleStartTime 09-25 00:00，周期 3 天。现在 09-26 12:00
  // → 过了 1.5 天，floor(1.5/3) = 0，所以区间就是第一轮。
  const model: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 1,
    'CountDownName': '轮',
    'CountDownConnector': '',
    'CustomStringFormat': '%D天',
    'CycleStartTime': '2026-09-25T00:00:00',
    'CycleDuration': '3.00:00:00'
  }), '2026-09-26T12:00:00');
  // 第一轮 09-25 00:00 → 09-28 00:00，从 09-26 12:00 起还剩 1.5 天 → %D 向上 = 2。
  checkEqual('周期第一轮', countdownRow(node0(model)), '距离 轮 2天');

  // 到第二轮：09-28 12:00 → floor(3.5/3) = 1，区间 09-28 00:00 → 09-31
  // （不存在的日期，addSeconds 落到 10-01 00:00），剩 2.5 天 → 3。
  const second: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 1,
    'CountDownName': '轮',
    'CountDownConnector': '',
    'CustomStringFormat': '%D天',
    'CycleStartTime': '2026-09-25T00:00:00',
    'CycleDuration': '3.00:00:00'
  }), '2026-09-28T12:00:00');
  checkEqual('周期第二轮', countdownRow(node0(second)), '距离 轮 3天');

  // 限次：数到第 1 轮之后就停在第 1 轮。
  const limited: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 1,
    'IsCycleCountLimited': true,
    'CycleCountLimit': 1,
    'CountDownName': '轮',
    'CountDownConnector': '',
    'CustomStringFormat': '%D天',
    'CycleStartTime': '2026-09-25T00:00:00',
    'CycleDuration': '3.00:00:00'
  }), '2026-10-10T12:00:00');
  // 停在第一轮 09-25 → 09-28，早已过去 → 夹到 0。
  checkEqual('周期限次封顶', countdownRow(node0(limited)), '距离 轮 0天');

  // 周期时长为 0 不能除出 NaN。
  const zero: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountdownSource': 1,
    'CountDownName': '轮',
    'CountDownConnector': '',
    'CustomStringFormat': '%D天',
    'CycleStartTime': '2026-09-25T00:00:00',
    'CycleDuration': '0.00:00:00'
  }), '2026-09-26T12:00:00');
  checkEqual('周期时长 0', countdownRow(node0(zero)), '距离 轮 0天');
}

function testCountDownOverTimePassed(): void {
  // 目标日已过 → 夹到 0，不显示负数。
  const model: PanelModel = build(oneOf(COMPONENT_COUNTDOWN, {
    'CountDownName': '期末',
    'CountDownConnector': '',
    'CustomStringFormat': '%D天',
    'StartTime': '2026-09-01T00:00:00',
    'OverTime': '2026-09-20T00:00:00'
  }), `${BASE_DAY}T00:00:00`);
  checkEqual('目标日已过夹 0', countdownRow(node0(model)), '距离 期末 0天');
}

// ------------------------------------------------------------- C. 简单组件

function testClock(): void {
  // 不显示秒、冒号闪烁：秒数为奇数时显示冒号。
  const odd: PanelModel = build(oneOf(COMPONENT_CLOCK, {
    'ShowSeconds': false, 'FlashTimeSeparator': true
  }), `${BASE_DAY}T08:00:21`);
  checkEqual('时钟奇数秒显示冒号', node0(odd).primaryText, '08:00');
  check('模型标记冒号这一拍显示', odd.clockShowsSeparator);

  const even: PanelModel = build(oneOf(COMPONENT_CLOCK, {
    'ShowSeconds': false, 'FlashTimeSeparator': true
  }), `${BASE_DAY}T08:00:20`);
  checkEqual('时钟偶数秒隐藏冒号', node0(even).primaryText, '08 00');
  check('模型标记冒号这一拍隐藏', !even.clockShowsSeparator);

  // 显示秒时冒号常亮（桌面版 `!Flash || ShowSeconds || odd`）。
  const seconds: PanelModel = build(oneOf(COMPONENT_CLOCK, {
    'ShowSeconds': true, 'FlashTimeSeparator': true
  }), `${BASE_DAY}T08:00:20`);
  checkEqual('显示秒时冒号常亮', node0(seconds).primaryText, '08:00:20');

  // 关掉闪烁则冒号常亮。
  const steady: PanelModel = build(oneOf(COMPONENT_CLOCK, {
    'ShowSeconds': false, 'FlashTimeSeparator': false
  }), `${BASE_DAY}T08:00:20`);
  checkEqual('关掉闪烁冒号常亮', node0(steady).primaryText, '08:00');
}

function testDate(): void {
  // 桌面版是 `ddd MM/dd`。
  const model: PanelModel = build(oneOf(COMPONENT_DATE), `${BASE_DAY}T12:00:00`);
  checkEqual('日期文本', node0(model).primaryText, '周六 09/26');
}

function testText(): void {
  // 落盘是 #RRGGBBAA：#00FF00FF = r 00 / g FF / b 00 / a FF，换成 ArkUI 序
  // 应当是 #FF00FF00（a 提到最前）。换错了得到 #00FF00FF，界面上是全透明。
  const withColor: PanelModel = build(oneOf(COMPONENT_TEXT, {
    'TextContent': '午休倒计时', 'FontSize': 22, 'FontColor': '#00FF00FF', 'UseCustomFontColor': true
  }), `${BASE_DAY}T12:00:00`);
  const node: PanelNode = node0(withColor);
  checkEqual('文本内容', node.primaryText, '午休倒计时');
  checkNum('文本字号', node.fontSize, 22);
  checkEqual('文本自定义颜色换序', node.foregroundColor, '#FF00FF00');

  // 不透明红也要正确换序：#FF0000FF（r FF g 00 b 00 a FF）→ #FFFF0000。
  const red: PanelModel = build(oneOf(COMPONENT_TEXT, {
    'TextContent': 'x', 'FontColor': '#FF0000FF', 'UseCustomFontColor': true
  }), `${BASE_DAY}T12:00:00`);
  checkEqual('文本不透明红换序', node0(red).foregroundColor, '#FFFF0000');

  // 关掉自定义颜色则跟随面板前景色。
  const inherited: PanelModel = build(oneOf(COMPONENT_TEXT, {
    'TextContent': 'x', 'FontColor': '#00FF00FF', 'UseCustomFontColor': false
  }), `${BASE_DAY}T12:00:00`);
  checkEqual('关掉自定义颜色跟随前景', node0(inherited).foregroundColor, '#FFFFFFFF');

  // 文本组件的 FontSize 压过行样式（桌面版是局部值绑在 TextBlock 上，
  // 优先级高于 ComponentPresenter 用 DynamicResource 设的继承值）。
  // 这条单独立一个用例，免得后来的人以为 IsResourceOverridingEnabled 也管字号。
  const text: ComponentSettings = component(COMPONENT_TEXT);
  text.isResourceOverridingEnabled = true;
  text.mainWindowBodyFontSize = 30;
  const parent: MainWindowLineSettings = line([text]);
  parent.mainWindowBodyFontSize = 16;
  const overridden: PanelModel = build(layoutOf([parent]), `${BASE_DAY}T12:00:00`);
  checkNum('文本组件字号不被行样式覆盖', node0(overridden).fontSize, 16);
}

function testSeparator(): void {
  const model: PanelModel = build(oneOf(COMPONENT_SEPARATOR), `${BASE_DAY}T12:00:00`);
  checkEqual('分割线种类', node0(model).kind, PanelNodeKind.SEPARATOR);
  checkEqual('分割线无文本', node0(model).primaryText, '');
}

function testWeather(): void {
  const model: PanelModel = build(oneOf(COMPONENT_WEATHER), `${BASE_DAY}T12:00:00`);
  checkEqual('天气种类', node0(model).kind, PanelNodeKind.WEATHER);
  check('天气给出未接入提示', node0(model).hintText.length > 0);
}

function testUnknownComponent(): void {
  const model: PanelModel = build(oneOf('99999999-9999-9999-9999-999999999999'),
    `${BASE_DAY}T12:00:00`);
  const node: PanelNode = node0(model);
  check('未知组件标记', node.isUnknown);
  checkEqual('未知组件种类', node.kind, PanelNodeKind.UNKNOWN);
  check('未知组件有提示', node.hintText.length > 0);
  checkEqual('未知组件显示名退化成 GUID 前 8 位', node.displayName, '99999999');
}

// --------------------------------------------------------------- D. 课程表

function testScheduleCurrentLesson(): void {
  const model: PanelModel = build(oneOf(COMPONENT_SCHEDULE, { 'ExtraInfoType': 0 }),
    `${BASE_DAY}T08:20:00`);
  const node: PanelNode = node0(model);
  checkNum('课中三节课都摆出来', node.lessons.length, 3);
  check('第一节是当前', node.lessons[0].isCurrent);
  checkEqual('第一节科目', node.lessons[0].subjectName, '语文');
  check('第一节不是下一节', !node.lessons[0].isNext);
  check('第一节没上完', !node.lessons[0].isFinished);
  // 08:00-08:45 过了 20 分钟 → 20/45 = 44.44…%。桌面版是 double，
  // 进度条按原值用，不该为了好看取整。
  checkNear('第一节进度', node.lessons[0].progressPercent, 20 / 45 * 100);
  check('第二节是下一节', node.lessons[1].isNext);
  check('第二节不是当前', !node.lessons[1].isCurrent);
  check('第三节不是下一节', !node.lessons[2].isNext);
  checkEqual('额外信息是区间', node.lessons[0].extraText, '08:00-08:45');
  checkEqual('教师名', node.lessons[0].teacherName, '语文老师');
}

function testScheduleAtBoundary(): void {
  // 08:00 整那一刻必须已经是「正在上课」，不能是「下一节」。
  const exact: PanelModel = build(oneOf(COMPONENT_SCHEDULE), `${BASE_DAY}T08:00:00`);
  check('08:00 整算正在上课', node0(exact).lessons[0].isCurrent);
  check('08:00 整不算下一节', !node0(exact).lessons[0].isNext);

  // 08:45 整（第一节结束、进课间）不算当前，且已上完。
  const end: PanelModel = build(oneOf(COMPONENT_SCHEDULE), `${BASE_DAY}T08:45:00`);
  check('08:45 整第一节不算当前', !node0(end).lessons[0].isCurrent);
  check('08:45 整第一节算上完', node0(end).lessons[0].isFinished);
  // 课间里没有「正在上的课」，第一节还没开始的课就是「接下来第一节」。
  check('08:45 整第二节是下一节', node0(end).lessons[1].isNext);
  check('08:45 整第二节不算当前', !node0(end).lessons[1].isCurrent);

  // 09:00 整（第二节开始）：第二节成为当前，第三节成为下一节。
  const second: PanelModel = build(oneOf(COMPONENT_SCHEDULE), `${BASE_DAY}T09:00:00`);
  check('09:00 整第二节算当前', node0(second).lessons[1].isCurrent);
  check('09:00 整第二节不是下一节', !node0(second).lessons[1].isNext);
  check('09:00 整第三节是下一节', node0(second).lessons[2].isNext);
}

function testScheduleExtraInfoKinds(): void {
  const cases: Array<[number, string]> = [
    [0, '08:00-08:45'],
    [1, '00:20'],
    [2, '-00:25'],
    [3, '44%'],
    [4, '-00:25'],
    [5, '-00:25']
  ];
  for (const pair of cases) {
    const model: PanelModel = build(oneOf(COMPONENT_SCHEDULE, { 'ExtraInfoType': pair[0] }),
      `${BASE_DAY}T08:20:00`);
    checkEqual(`额外信息第 ${pair[0]} 档`, node0(model).lessons[0].extraText, pair[1]);
  }
  // 未知档位给空串而不是把 %1 显示出来。
  const unknown: PanelModel = build(oneOf(COMPONENT_SCHEDULE, { 'ExtraInfoType': 99 }),
    `${BASE_DAY}T08:20:00`);
  checkEqual('额外信息未知档位', node0(unknown).lessons[0].extraText, '');
  // 关掉开关就不给。
  const off: PanelModel = build(oneOf(COMPONENT_SCHEDULE, {
    'ExtraInfoType': 0, 'ShowExtraInfoOnTimePoint': false
  }), `${BASE_DAY}T08:20:00`);
  checkEqual('关掉额外信息', node0(off).lessons[0].extraText, '');
}

function testScheduleCountdown(): void {
  // 07:59:30 → 距第一节 30 秒，窗口 60 秒 → 给倒计时。
  const near: PanelModel = build(oneOf(COMPONENT_SCHEDULE, { 'CountdownSeconds': 60 }),
    `${BASE_DAY}T07:59:30`);
  checkEqual('临上课倒计时', node0(near).lessons[0].countdownText, '30 秒后上课');

  // 07:59:30 但关掉倒计时 → 空串。
  const off: PanelModel = build(oneOf(COMPONENT_SCHEDULE, {
    'CountdownSeconds': 60, 'IsCountdownEnabled': false
  }), `${BASE_DAY}T07:59:30`);
  checkEqual('关掉临上课倒计时', node0(off).lessons[0].countdownText, '');

  // 07:00 → 距第一节 3600 秒，窗口 60 秒 → 不显示。
  const far: PanelModel = build(oneOf(COMPONENT_SCHEDULE, { 'CountdownSeconds': 60 }),
    `${BASE_DAY}T07:00:00`);
  checkEqual('不在窗口内无倒计时', node0(far).lessons[0].countdownText, '');

  // 正在上课的那节课不算「临上课」。
  const during: PanelModel = build(oneOf(COMPONENT_SCHEDULE, { 'CountdownSeconds': 60 }),
    `${BASE_DAY}T08:20:00`);
  checkEqual('课中无临上课倒计时', node0(during).lessons[0].countdownText, '');
}

function testScheduleHideAndOnly(): void {
  const before: PanelModel = build(oneOf(COMPONENT_SCHEDULE, {
    'HideFinishedClass': true
  }), `${BASE_DAY}T09:00:00`);
  checkNum('隐藏已上完的课', node0(before).lessons.length, 2);
  check('第一节被隐藏', node0(before).lessons[0].subjectName === '数学');

  const only: PanelModel = build(oneOf(COMPONENT_SCHEDULE, {
    'ShowCurrentLessonOnlyOnClass': true
  }), `${BASE_DAY}T08:20:00`);
  checkNum('只显示当前这节', node0(only).lessons.length, 1);
  checkEqual('只显示的是当前这节', node0(only).lessons[0].subjectName, '语文');

  // 课间（不在上课）时「只显示当前」什么都不剩 → 走占位文案而不是空白。
  const gap: PanelModel = build(oneOf(COMPONENT_SCHEDULE, {
    'ShowCurrentLessonOnlyOnClass': true, 'ShowPlaceholderOnEmptyClassPlan': true
  }), `${BASE_DAY}T08:50:00`);
  checkNum('课间只显示当前时列表为空', node0(gap).lessons.length, 0);
  check('课间只显示当前时给占位文案', node0(gap).hintText.length > 0);
}

function testScheduleFadeVersusHide(): void {
  // 淡化保留这节课（用户要能回顾），隐藏才是不摆出来。
  const faded: PanelModel = build(oneOf(COMPONENT_SCHEDULE, { 'FadeCompletedClasses': true }),
    `${BASE_DAY}T09:00:00`);
  checkNum('淡化保留已上完的课', node0(faded).lessons.length, 3);
  check('淡化第一节标上完', node0(faded).lessons[0].isFinished);

  const notFaded: PanelModel = build(oneOf(COMPONENT_SCHEDULE, { 'FadeCompletedClasses': false }),
    `${BASE_DAY}T09:00:00`);
  check('不淡化则不标上完', !node0(notFaded).lessons[0].isFinished);
  checkNum('不淡化仍保留这节课', node0(notFaded).lessons.length, 3);
}

function testScheduleEmptyKinds(): void {
  // 一、没档案（编辑预览，profile 传 undefined）。
  const noProfile: PanelModel = PanelBuilder.build(oneOf(COMPONENT_SCHEDULE),
    undefined, engineSettings(), dt(`${BASE_DAY}T08:20:00`));
  checkEqual('没档案的提示', node0(noProfile).hintText,
    '还没有课表档案，先去编辑页导入或新建一份。');

  // 二、课表分组是空的。与桌面版一致：CurrentClassPlan 为 null 时
  // TodayScheduleEmpty 伪类成立，用的是同一句占位文案。
  const noGroup: Profile = fullWeekProfile();
  noGroup.selectedClassPlanGroupId = Guid.empty();
  noGroup.refreshDerivedState();
  const emptyGroup: PanelModel = build(oneOf(COMPONENT_SCHEDULE), `${BASE_DAY}T08:20:00`, noGroup);
  checkEqual('空课表分组的占位', node0(emptyGroup).hintText, '今天没有课程。');

  // 三、今天没课（只有工作日的课表，今天是周六）。与第二种是同一句话 ——
  // 桌面版也分不出来，不在这里硬分。
  const weekday: Profile = profileForDays([1, 2, 3, 4, 5]);
  const noClass: PanelModel = build(oneOf(COMPONENT_SCHEDULE), `${BASE_DAY}T08:20:00`, weekday);
  checkEqual('今天没课的占位', node0(noClass).hintText, '今天没有课程。');

  // 四、今天上完了 —— 必须是另一句，不能也说「没有课程」。
  // 桌面版这一句只在 AfterSchool 伪类与 HideFinishedClass 同时成立时才出现
  // （ScheduleComponent.axaml:37 的样式选择器），所以这里要显式关掉已上完的课。
  const ended: PanelModel = build(oneOf(COMPONENT_SCHEDULE, {
    'HideFinishedClass': true
  }), `${BASE_DAY}T23:00:00`, fullWeekProfile());
  checkNum('隐藏后列表空', node0(ended).lessons.length, 0);
  checkEqual('今天上完的占位', node0(ended).hintText, '今日课程已全部结束。');

  // 五、默认不隐藏已上完的课（桌面版默认也是 false）时列表不空，占位不出现。
  const kept: PanelModel = build(oneOf(COMPONENT_SCHEDULE), `${BASE_DAY}T23:00:00`);
  checkNum('不隐藏时列表非空', node0(kept).lessons.length, 3);
  checkEqual('不隐藏时无占位文案', node0(kept).hintText, '');

  // 六、自定义占位文案。
  const custom: PanelModel = build(oneOf(COMPONENT_SCHEDULE, {
    'ShowPlaceholderOnEmptyClassPlan': true,
    'PlaceholderTextNoClass': '休息日'
  }), `${BASE_DAY}T08:20:00`, weekday);
  checkEqual('自定义空课表文案', node0(custom).hintText, '休息日');

  // 七、自定义「上完」文案。
  const customEnded: PanelModel = build(oneOf(COMPONENT_SCHEDULE, {
    'HideFinishedClass': true, 'PlaceholderTextAllClassEnded': '放学了'
  }), `${BASE_DAY}T23:00:00`);
  checkEqual('自定义上完文案', node0(customEnded).hintText, '放学了');

  // 八、关掉占位 → 什么都不显示，而不是显示默认文案。
  const silent: PanelModel = build(oneOf(COMPONENT_SCHEDULE, {
    'ShowPlaceholderOnEmptyClassPlan': false
  }), `${BASE_DAY}T08:20:00`, weekday);
  checkEqual('关掉占位后无文案', node0(silent).hintText, '');
}

function testScheduleEmptyStringPlaceholder(): void {
  // 占位文案被清成空串时退回引擎兜底，而不是显示一个空白行。
  const blanked: PanelModel = build(oneOf(COMPONENT_SCHEDULE, {
    'PlaceholderTextNoClass': ''
  }), `${BASE_DAY}T08:20:00`, profileForDays([1, 2, 3, 4, 5]));
  checkEqual('空占位文案退回兜底', node0(blanked).hintText, '今天没有课程。');
}

function testScheduleDisabledClass(): void {
  // 停用 = 这节课不上。摆在列表里等于骗用户。
  const profile: Profile = fullWeekProfile();
  const plans: ClassPlan[] = profile.classPlans.values();
  for (const plan of plans) {
    plan.classes[0].isEnabled = false;
  }
  profile.refreshDerivedState();
  const model: PanelModel = build(oneOf(COMPONENT_SCHEDULE), `${BASE_DAY}T08:20:00`, profile);
  checkNum('停用第一节后剩两节', node0(model).lessons.length, 2);
  check('第一节确实不在列表里', node0(model).lessons[0].subjectName === '数学');
}

// ------------------------------------------------------------------ E. 样式

function testStyleInheritance(): void {
  // 用日期组件试样式：它没有自己的 FontSize / FontColor 设置，是唯一能看出
  // 「行样式继承下来」的干净用例。拿文本组件试只会看到它自己的设置（见 testText）。
  const parent: MainWindowLineSettings = line([component(COMPONENT_DATE)]);
  parent.mainWindowBodyFontSize = 21;
  parent.mainWindowSecondaryFontSize = 13;
  parent.mainWindowEmphasizedFontSize = 25;
  parent.isCustomForegroundColorEnabled = true;
  // 落盘序是 #RRGGBBAA：不透明红是 #FF0000FF（alpha 在末位），ArkUI 序 #FFFF0000。
  // 写成 #FFFF0000 会被读成 r=FF g=FF b=00 a=00，即全透明黄绿，界面上直接看不见。
  parent.foregroundColor = ColorValue.tryParse('#FF0000FF') ?? ColorValue.red();
  const model: PanelModel = build(layoutOf([parent]), `${BASE_DAY}T12:00:00`);
  checkNum('组件继承行字号', node0(model).fontSize, 21);
  checkNum('组件继承行次要字号', node0(model).secondaryFontSize, 13);
  checkNum('组件继承行强调字号', node0(model).emphasisFontSize, 25);
  checkEqual('组件继承行前景色', node0(model).foregroundColor, '#FFFF0000');
}

function testStyleOverride(): void {
  // 组件开了覆盖 → 用组件自己的字号与前景色。
  const node: ComponentSettings = component(COMPONENT_DATE);
  node.isResourceOverridingEnabled = true;
  node.mainWindowBodyFontSize = 30;
  node.isCustomForegroundColorEnabled = true;
  // 半透明蓝：落盘 #0000FF80（a=80），ArkUI 序 #800000FF。
  node.foregroundColor = ColorValue.tryParse('#0000FF80') ?? ColorValue.dodgerBlue();
  const parent: MainWindowLineSettings = line([node]);
  parent.mainWindowBodyFontSize = 16;
  const model: PanelModel = build(layoutOf([parent]), `${BASE_DAY}T12:00:00`);
  checkNum('组件覆盖行字号', node0(model).fontSize, 30);
  checkEqual('组件覆盖行前景色', node0(model).foregroundColor, '#800000FF');

  // 没开覆盖时组件自己那三个字号全都不作数。
  const plain: ComponentSettings = component(COMPONENT_DATE);
  plain.mainWindowBodyFontSize = 30;
  const plainLine: MainWindowLineSettings = line([plain]);
  plainLine.mainWindowBodyFontSize = 16;
  const plainModel: PanelModel = build(layoutOf([plainLine]), `${BASE_DAY}T12:00:00`);
  checkNum('未开覆盖则用行字号', node0(plainModel).fontSize, 16);
}

function testStyleNoOverrideKeepsLineForeground(): void {
  // 组件没开覆盖但自己开了前景色 → 用自己的。这一项不受 IsResourceOverriding
  // 管：桌面版 ComponentPresenter 绑的是组件自己的 IsCustomForegroundColorEnabled。
  const node: ComponentSettings = component(COMPONENT_DATE);
  node.isCustomForegroundColorEnabled = true;
  node.foregroundColor = ColorValue.tryParse('#112233FF') ?? ColorValue.black();
  const parent: MainWindowLineSettings = line([node]);
  parent.isCustomForegroundColorEnabled = true;
  parent.foregroundColor = ColorValue.white();
  const model: PanelModel = build(layoutOf([parent]), `${BASE_DAY}T12:00:00`);
  checkEqual('组件前景色优先于行', node0(model).foregroundColor, '#FF112233');
}

function testStyleBackground(): void {
  // 没开自定义背景色 → 不画背景。给个默认黑底会让「没设背景」看起来像「设了黑底」。
  const plain: PanelModel = build(oneOf(COMPONENT_DATE), `${BASE_DAY}T12:00:00`);
  checkEqual('没开背景色不画', node0(plain).backgroundColor, '');

  // 开了背景色但没开不透明度开关 → 那个 0.5 不作数，按 1（不透明）算。
  const ignored: PanelModel = buildOneWithBackground(false, 0.5);
  checkEqual('不透明度未启用时按不透明', node0(ignored).backgroundColor, '#FF000000');

  // 开了开关才用那个 0.5。
  const honored: PanelModel = buildOneWithBackground(true, 0.5);
  checkEqual('开背景色且不透明度 0.5', node0(honored).backgroundColor, '#80000000');
}

function buildOneWithBackground(enableOpacity: boolean, alpha: number): PanelModel {
  const node: ComponentSettings = component(COMPONENT_DATE);
  node.isCustomBackgroundColorEnabled = true;
  node.isCustomBackgroundOpacityEnabled = enableOpacity;
  node.backgroundOpacity = alpha;
  node.backgroundColor = ColorValue.black();
  return build(layoutOf([line([node])]), `${BASE_DAY}T12:00:00`);
}

function testStyleLineBackground(): void {
  // 行开了背景色 → 节点继承（桌面版是先看组件再看行）。
  const node: ComponentSettings = component(COMPONENT_DATE);
  const parent: MainWindowLineSettings = line([node]);
  parent.isCustomBackgroundColorEnabled = true;
  parent.isCustomBackgroundOpacityEnabled = true;
  parent.backgroundOpacity = 0.25;
  parent.backgroundColor = ColorValue.white();
  const model: PanelModel = build(layoutOf([parent]), `${BASE_DAY}T12:00:00`);
  checkEqual('节点继承行背景色', node0(model).backgroundColor, '#40FFFFFF');
  checkEqual('行背景色', model.lines[0].backgroundColor, '#40FFFFFF');
}

function testStyleDoesNotMutateLayout(): void {
  // 算样式时不能改布局草稿里的颜色。表现是「看一眼面板就把背景色改了」，
  // 而且不保存也丢不掉 —— 颜色对象是共享的。
  const node: ComponentSettings = component(COMPONENT_DATE);
  node.isCustomBackgroundColorEnabled = true;
  node.isCustomBackgroundOpacityEnabled = true;
  node.backgroundOpacity = 0.5;
  node.backgroundColor = ColorValue.black();
  const layout: ComponentProfile = layoutOf([line([node])]);
  const model: PanelModel = PanelBuilder.build(layout, fullWeekProfile(), engineSettings(),
    dt(`${BASE_DAY}T12:00:00`));
  checkEqual('节点背景色带透明度', node0(model).backgroundColor, '#80000000');
  checkNum('草稿里的不透明度没被改', node.backgroundOpacity, 0.5);
  checkNum('草稿里的颜色 alpha 没被改', node.backgroundColor.a, 255);
}

function testStyleWidthAndMargin(): void {
  const node: ComponentSettings = component(COMPONENT_DATE);
  node.isFixedWidthEnabled = true;
  node.fixedWidth = 220;
  node.isCustomMarginEnabled = true;
  node.marginLeft = 4;
  node.marginTop = 2;
  node.marginRight = 8;
  node.marginBottom = 0;
  const model: PanelModel = build(layoutOf([line([node])]), `${BASE_DAY}T12:00:00`);
  const out: PanelNode = node0(model);
  checkNum('固定宽度', out.widthValue, 220);
  checkEqual('固定宽度语义', `${out.widthKind}`, '1');
  checkNum('左边距', out.marginLeft, 4);
  checkNum('上边距', out.marginTop, 2);
  checkNum('右边距', out.marginRight, 8);
  checkNum('下边距', out.marginBottom, 0);

  // 负边距夹到 0：负边距在桌面版会让组件跑到行外面，看着是「组件不见了」。
  const negative: ComponentSettings = component(COMPONENT_DATE);
  negative.isCustomMarginEnabled = true;
  negative.marginLeft = -5;
  const negModel: PanelModel = build(layoutOf([line([negative])]), `${BASE_DAY}T12:00:00`);
  checkNum('负边距夹到 0', node0(negModel).marginLeft, 0);
}

function testStyleOpacityClamp(): void {
  const node: ComponentSettings = component(COMPONENT_DATE);
  node.opacity = 3;
  const model: PanelModel = build(layoutOf([line([node])]), `${BASE_DAY}T12:00:00`);
  checkNum('不透明度夹到 1', node0(model).opacity, 1);

  const low: ComponentSettings = component(COMPONENT_DATE);
  low.opacity = -1;
  const lowModel: PanelModel = build(layoutOf([line([low])]), `${BASE_DAY}T12:00:00`);
  checkNum('负不透明度夹到 0', node0(lowModel).opacity, 0);
}

function testLineVisibility(): void {
  const first: MainWindowLineSettings = line([component(COMPONENT_DATE)]);
  const second: MainWindowLineSettings = line([component(COMPONENT_SCHEDULE)]);
  second.isVisible = false;
  const model: PanelModel = build(layoutOf([first, second]), `${BASE_DAY}T08:20:00`);
  checkNum('隐藏的行不进模型', model.lines.length, 1);
  checkNum('隐藏的行计数', model.hiddenLineCount, 1);
  check('可见性只剩第一行', !model.isEmpty);

  const allHidden: PanelModel = build(layoutOf([second]), `${BASE_DAY}T08:20:00`);
  check('全隐藏时模型为空', allHidden.isEmpty);
}

// ----------------------------------------------------------------- F. 容器

function testGroupContainer(): void {
  const group: ComponentSettings = component(COMPONENT_GROUP);
  const childrenNode: JsonObject = new JsonObject();
  const dateNode: ComponentSettings = component(COMPONENT_DATE);
  childrenNode.set('Children', arrayOf([dateNode.toJson()]));
  group.settings = childrenNode;

  const model: PanelModel = build(layoutOf([line([group])]), `${BASE_DAY}T12:00:00`);
  const node: PanelNode = node0(model);
  checkEqual('分组种类', node.kind, PanelNodeKind.GROUP);
  checkNum('分组有一个子节点', node.children.length, 1);
  checkEqual('子节点是日期', node.children[0].kind, PanelNodeKind.DATE);
  check('分组本身无主文本', node.primaryText.length === 0);
}

function testNestedContainers(): void {
  // 分组 → 分组 → 文本，两层嵌套。
  const inner: ComponentSettings = component(COMPONENT_TEXT);
  const innerNode: JsonObject = new JsonObject();
  innerNode.set('TextContent', new JsonString('内'));
  inner.settings = innerNode;

  const innerGroup: ComponentSettings = component(COMPONENT_GROUP);
  const innerChildren: JsonObject = new JsonObject();
  innerChildren.set('Children', arrayOf([inner.toJson()]));
  innerGroup.settings = innerChildren;

  const outerGroup: ComponentSettings = component(COMPONENT_GROUP);
  const outerChildren: JsonObject = new JsonObject();
  outerChildren.set('Children', arrayOf([innerGroup.toJson()]));
  outerGroup.settings = outerChildren;

  const model: PanelModel = build(layoutOf([line([outerGroup])]), `${BASE_DAY}T12:00:00`);
  const outer: PanelNode = node0(model);
  checkNum('外层分组一个子节点', outer.children.length, 1);
  checkNum('内层分组一个子节点', outer.children[0].children.length, 1);
  checkEqual('最里层是文本', outer.children[0].children[0].primaryText, '内');
  checkEqual('最里层种类', outer.children[0].children[0].kind, PanelNodeKind.TEXT);
}

function testDepthCap(): void {
  // 造一个 20 层的环，渲染必须在第 12 层停住。
  // 手改 JSON 造环是真实路径：布局文件外部可写，而无限递归的表现是页面卡死
  // 且不报错 —— 用户连「文件坏了」都猜不到。
  let current: ComponentSettings = component(COMPONENT_TEXT);
  const leafNode: JsonObject = new JsonObject();
  leafNode.set('TextContent', new JsonString('底'));
  current.settings = leafNode;

  for (let i: number = 0; i < 20; i++) {
    const wrap: ComponentSettings = component(COMPONENT_GROUP);
    const children: JsonObject = new JsonObject();
    children.set('Children', arrayOf([current.toJson()]));
    wrap.settings = children;
    current = wrap;
  }

  const model: PanelModel = build(layoutOf([line([current])]), `${BASE_DAY}T12:00:00`);
  const out: PanelNode = node0(model);
  let depth: number = 0;
  let truncated: boolean = false;
  let node: PanelNode = out;
  while (node.children.length > 0) {
    depth++;
    node = node.children[0];
    if (node.isTruncated) {
      truncated = true;
      break;
    }
  }
  check('深嵌套有节点被标记截断', truncated);
  check('深嵌套在上限处停下', depth < 20);
  check('截断节点没有子节点', node.children.length === 0);
}

function testRollingAndSlide(): void {
  const rolling: PanelModel = build(oneOf(COMPONENT_ROLLING, {
    'SpeedPixelPerSecond': 60
  }), `${BASE_DAY}T12:00:00`);
  checkEqual('滚动容器种类', node0(rolling).kind, PanelNodeKind.ROLLING);
  checkNum('滚动速度', node0(rolling).scrollSpeed, 60);

  // 速度 0 会让内容不动，而界面上没有任何提示 → 退回 40。
  const stalled: PanelModel = build(oneOf(COMPONENT_ROLLING, {
    'SpeedPixelPerSecond': 0
  }), `${BASE_DAY}T12:00:00`);
  checkNum('速度 0 退回默认', node0(stalled).scrollSpeed, 40);

  const slide: PanelModel = build(oneOf(COMPONENT_SLIDE, { 'SlideSeconds': 8 }),
    `${BASE_DAY}T12:00:00`);
  checkEqual('轮播容器种类', node0(slide).kind, PanelNodeKind.SLIDE);
  checkNum('轮播停留秒数', node0(slide).slideSeconds, 8);

  // 停留 0 秒会让内容一闪而过，界面上什么都留不住 → 退回 15。
  const instant: PanelModel = build(oneOf(COMPONENT_SLIDE, { 'SlideSeconds': 0 }),
    `${BASE_DAY}T12:00:00`);
  checkNum('停留 0 退回默认', node0(instant).slideSeconds, 15);
}

// ------------------------------------------------------------------ G. 其它

function testSignatureChangesWithContent(): void {
  const layout: ComponentProfile = layoutOf([line([component(COMPONENT_DATE)])]);
  const a: PanelModel = build(layout, `${BASE_DAY}T12:00:00`);
  const b: PanelModel = build(layout, `${BASE_DAY}T12:00:00`);
  checkEqual('同内容同签名', a.buildSignature(), b.buildSignature());

  // 同一天内不同时刻签名不变（日期组件只显示到日）—— 这正是签名的用处：
  // 界面据此只刷新时钟那一格，不必重建整棵树。
  checkEqual('同一天不同时刻同签名',
    build(layout, `${BASE_DAY}T13:00:00`).buildSignature(), a.buildSignature());

  // 跨天必须变。
  const nextDay: PanelModel = build(layout, '2026-09-27T12:00:00');
  check('跨天签名就变', nextDay.buildSignature() !== a.buildSignature());

  // 隐藏一行也要改签名，否则用户关掉一行后面板不会重画。
  const hidden: ComponentProfile = layoutOf([line([component(COMPONENT_DATE)])]);
  hidden.lines[0].isVisible = false;
  const hiddenModel: PanelModel = build(hidden, `${BASE_DAY}T12:00:00`);
  check('隐藏行改签名', hiddenModel.buildSignature() !== a.buildSignature());

  // 只有秒在走时，日期组件那一格没变，签名不该变 —— 界面据此只更新时钟。
  const dateLayout: ComponentProfile = layoutOf([line([component(COMPONENT_CLOCK)])]);
  const clockA: PanelModel = build(dateLayout, `${BASE_DAY}T12:00:20`);
  const clockB: PanelModel = build(dateLayout, `${BASE_DAY}T12:00:21`);
  check('时钟秒变化时签名变化', clockA.buildSignature() !== clockB.buildSignature());
}

function testSettingsPreservedInPayload(): void {
  // 未建模的字段必须原样留着。重建对象会把插件私有数据悄悄丢掉，而丢的时候
  // 没有任何症状 —— 只是下次桌面版打开时设置回到默认。
  const node: JsonObject = new JsonObject();
  node.set('CountDownName', new JsonString('期末'));
  node.set('SomePluginField', new JsonString('插件私有'));
  const settings: ComponentSettings = component(COMPONENT_COUNTDOWN);
  settings.settings = node;

  const model: PanelModel = build(layoutOf([line([settings])]), `${BASE_DAY}T12:00:00`);
  const kept: JsonObject | undefined = JsonValue.asObject(settings.settings);
  check('渲染不丢未建模字段', kept !== undefined && kept.has('SomePluginField'));
  check('渲染不动已建模字段', node0(model).primaryText.indexOf('期末') >= 0);
}

function testDefaultProfileRenders(): void {
  // 默认布局（单行：日期 + 课程表）必须能渲染出来。用户第一次打开应用看到的就是
  // 它，渲染不出来等于应用开屏就是空的。
  const model: PanelModel = PanelBuilder.build(ComponentProfile.defaultProfile(),
    fullWeekProfile(), engineSettings(), dt(`${BASE_DAY}T08:20:00`));
  checkNum('默认布局一行', model.lines.length, 1);
  checkNum('默认布局两个组件', model.lines[0].nodes.length, 2);
  checkEqual('默认布局第一个是日期', model.lines[0].nodes[0].kind, PanelNodeKind.DATE);
  checkEqual('默认布局第二个是课程表', model.lines[0].nodes[1].kind, PanelNodeKind.SCHEDULE);
  checkNum('默认布局的课程表有课', model.lines[0].nodes[1].lessons.length, 3);
}

function testDisplayNameFallback(): void {
  // 逐级退化，从不为空串。
  const known: ComponentSettings = component(COMPONENT_TEXT);
  checkEqual('内置名', PanelBuilder.displayNameOf(known), '文本');

  const cached: ComponentSettings = component('99999999-9999-9999-9999-999999999999');
  cached.nameCache = '我的组件';
  checkEqual('退到 NameCache', PanelBuilder.displayNameOf(cached), '我的组件');

  const bare: ComponentSettings = component('99999999-9999-9999-9999-999999999999');
  checkEqual('退到 GUID 前 8 位', PanelBuilder.displayNameOf(bare), '99999999');

  const shortId: ComponentSettings = component('abc');
  checkEqual('短 GUID 原样', PanelBuilder.displayNameOf(shortId), 'abc');
  check('显示名从不为空串', PanelBuilder.displayNameOf(shortId).length > 0);
}

function testCatalogStillRegistersAll(): void {
  // 面板模型按 GUID 找组件，注册表少一个就有一种组件渲染不出来。这里顺手盯一眼，
  // 免得以后加组件忘了在 Catalog 里注册。
  const guids: string[] = [
    COMPONENT_CLOCK, COMPONENT_COUNTDOWN, COMPONENT_DATE, COMPONENT_GROUP,
    COMPONENT_ROLLING, COMPONENT_SCHEDULE, COMPONENT_SEPARATOR, COMPONENT_SLIDE,
    COMPONENT_STACK, COMPONENT_TEXT, COMPONENT_WEATHER
  ];
  for (const guid of guids) {
    check(`已注册 ${ComponentCatalog.find(guid)?.name ?? guid}`,
      ComponentCatalog.find(guid) !== undefined);
  }
}

/** 只有一个元素的数组。给容器塞子组件用 —— 容器子列表在落盘上就是这个形状。 */
function arrayOf(items: JsonObject[]): JsonArray {
  const out: JsonArray = new JsonArray();
  for (const item of items) {
    out.push(item);
  }
  return out;
}

testCountDownFormatTokens();
testCountDownStaticRange();
testCountDownCompactMode();
testCountDownProgress();
testCountDownTodaySource();
testCountDownWeekSource();
testCountDownCycleSource();
testCountDownOverTimePassed();
testClock();
testDate();
testText();
testSeparator();
testWeather();
testUnknownComponent();
testScheduleCurrentLesson();
testScheduleAtBoundary();
testScheduleExtraInfoKinds();
testScheduleCountdown();
testScheduleHideAndOnly();
testScheduleFadeVersusHide();
testScheduleEmptyKinds();
testScheduleEmptyStringPlaceholder();
testScheduleDisabledClass();
testStyleInheritance();
testStyleOverride();
testStyleNoOverrideKeepsLineForeground();
testStyleBackground();
testStyleLineBackground();
testStyleDoesNotMutateLayout();
testStyleWidthAndMargin();
testStyleOpacityClamp();
testLineVisibility();
testGroupContainer();
testNestedContainers();
testDepthCap();
testRollingAndSlide();
testSignatureChangesWithContent();
testSettingsPreservedInPayload();
testDefaultProfileRenders();
testDisplayNameFallback();
testCatalogStillRegistersAll();
testRuleNeedsBothSwitchAndRules();
testRuleHiddenStillRendersContent();
testRuleNotMatchedAtOtherTime();
testLineRuleHidden();
testLineRuleIndependentOfChildren();
testExplicitlyHiddenLineSkipsRuleCheck();
testAllChildrenHiddenPropagates();
testAllChildrenHiddenRecurses();
testAllChildrenHiddenStopsAtOwnHit();
testRuleHiddenSharesOneContext();
testRuleHiddenInSignature();
testRuleReversedIsHonored();
testRuleCountingWithMixedLines();
testRuleWithoutProfile();
testIsRuleHiddenDirectly();

console.log(`面板渲染 通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('');
  for (const failure of failures) {
    console.log(`✗ ${failure}`);
  }
  process.exit(1);
}
