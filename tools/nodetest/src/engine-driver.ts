/*
 * 课表引擎行为测试驱动。
 *
 * 与 driver.ts（字节级往返）互补：那一个抓「输出与桌面版是否逐字节一致」，
 * 这一个抓「算出来的结果对不对」。两者都在 Node 中跑真实源码。
 *
 * 判据来源全部是 ClassIsland 桌面版源码，逐条注明出处；凡是我判定为
 * 「桌面版怪癖但照搬」而非「桌面版 bug 顺手修掉」的，都在注释里点明，
 * 免得后来者以为是移植失误。
 */

import {
  DateTimeValue,
  Guid,
  JsonObject,
  JsonReader,
  JsonValue,
  Profile,
  TimeSpanValue
} from '../../common_shared/src/main/ets/Index';
import { TimeState } from '../../common_shared/src/main/ets/enums/TimeState';
import { TempClassPlanGroupType } from '../../common_shared/src/main/ets/enums/TempClassPlanGroupType';
import { ClassInfo } from '../../common_shared/src/main/ets/models/ClassInfo';
import { ClassPlan } from '../../common_shared/src/main/ets/models/ClassPlan';
import { ClassPlanGroup } from '../../common_shared/src/main/ets/models/ClassPlanGroup';
import { OrderedSchedule } from '../../common_shared/src/main/ets/models/OrderedSchedule';
import { Subject } from '../../common_shared/src/main/ets/models/Subject';
import { TimeLayout } from '../../common_shared/src/main/ets/models/TimeLayout';
import { TimeLayoutItem } from '../../common_shared/src/main/ets/models/TimeLayoutItem';
import { TimeRule } from '../../common_shared/src/main/ets/models/TimeRule';
import { ClassPlanResolver, ResolvedSource } from '../../common_core/src/main/ets/engine/ClassPlanResolver';
import { EngineSettings } from '../../common_core/src/main/ets/engine/EngineSettings';
import { LessonsEngine } from '../../common_core/src/main/ets/engine/LessonsEngine';
import { LessonsSnapshot } from '../../common_core/src/main/ets/engine/LessonsSnapshot';
import { TempPlanManager } from '../../common_core/src/main/ets/engine/TempPlanManager';
import { WeekRotation } from '../../common_core/src/main/ets/engine/WeekRotation';

let passed: number = 0;
const failures: string[] = [];

function check(name: string, condition: boolean, detail: string = ''): void {
  if (condition) {
    passed++;
    return;
  }
  failures.push(detail.length > 0 ? `${name}\n    ${detail}` : name);
}

function checkEqual(name: string, actual: string, expected: string): void {
  if (actual === expected) {
    passed++;
    return;
  }
  failures.push(`${name}\n    期望: ${expected}\n    实际: ${actual}`);
}

function checkNum(name: string, actual: number, expected: number): void {
  checkEqual(name, String(actual), String(expected));
}

// ------------------------------------------------------------------ 夹具

const SUBJECT_YUWEN: string = '11111111-1111-1111-1111-111111111111';
const SUBJECT_SHUXUE: string = '22222222-2222-2222-2222-222222222222';
const SUBJECT_YINGYU: string = '33333333-3333-3333-3333-333333333333';

const LAYOUT_ID: string = 'aaaaaaaa-0000-0000-0000-000000000001';
const GROUP_DEFAULT: string = 'acaf4ef0-e261-4262-b941-34ea93cb4369';
const GROUP_TEMP: string = 'bbbbbbbb-0000-0000-0000-000000000002';

function dt(text: string): DateTimeValue {
  return DateTimeValue.parseOrMin(text);
}

/** 建一个时间点。type: 0=上课 1=课间 2=分割线。 */
function item(type: number, start: string, end: string, breakName: string = ''): TimeLayoutItem {
  const out: TimeLayoutItem = new TimeLayoutItem();
  out.timeType = type;
  out.startTime = TimeSpanValue.parseOrZero(start);
  out.endTime = TimeSpanValue.parseOrZero(end);
  out.breakName = breakName;
  return out;
}

function subjectAt(index: number): ClassInfo {
  const info: ClassInfo = new ClassInfo();
  const ids: string[] = [SUBJECT_YUWEN, SUBJECT_SHUXUE, SUBJECT_YINGYU];
  info.subjectId = Guid.fromCanonical(ids[index % ids.length]);
  return info;
}

/**
 * 标准作息：3 节课 + 2 个课间。
 *   08:00-08:45 上课(slot 0, 布局下标 0)
 *   08:45-09:00 课间(布局下标 1)
 *   09:00-09:45 上课(slot 1, 布局下标 2)
 *   09:45-10:00 课间(布局下标 3)
 *   10:00-10:45 上课(slot 2, 布局下标 4)
 */
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

interface PlanSpec {
  key: string;
  weekDay: number;
  name: string;
  group?: string;
  overlay?: boolean;
  enabled?: boolean;
  weekCountDiv?: number;
  weekCountDivTotal?: number;
}

/**
 * 造一份档案。给 days 传入星期几列表，为每天建一张课表（桌面版一张课表
 * 只对应一个 weekDay，所以一周作息天然是 7 张课表）。
 */
function buildProfile(plans: PlanSpec[]): Profile {
  const profile: Profile = new Profile();
  profile.name = '测试档案';
  profile.timeLayouts.set(LAYOUT_ID, standardLayout());
  profile.selectedClassPlanGroupId = ClassPlanGroup.defaultGroupGuid();

  const subjectIds: string[] = [SUBJECT_YUWEN, SUBJECT_SHUXUE, SUBJECT_YINGYU];
  const names: string[] = ['语文', '数学', '英语'];
  for (let i: number = 0; i < subjectIds.length; i++) {
    const subject: Subject = new Subject();
    subject.name = names[i];
    profile.subjects.set(subjectIds[i], subject);
  }

  for (const spec of plans) {
    const plan: ClassPlan = new ClassPlan();
    plan.name = spec.name;
    plan.timeLayoutId = Guid.fromCanonical(LAYOUT_ID);
    plan.isOverlay = spec.overlay === true;
    plan.isEnabled = spec.enabled !== false;
    if (spec.group !== undefined) {
      plan.associatedGroup = Guid.fromCanonical(spec.group);
    }
    const rule: TimeRule = new TimeRule();
    rule.weekDay = spec.weekDay;
    rule.weekCountDiv = spec.weekCountDiv === undefined ? 0 : spec.weekCountDiv;
    rule.weekCountDivTotal = spec.weekCountDivTotal === undefined ? 2 : spec.weekCountDivTotal;
    plan.timeRule = rule;
    plan.classes = [subjectAt(0), subjectAt(1), subjectAt(2)];
    profile.classPlans.set(spec.key, plan);
  }

  profile.refreshDerivedState();
  return profile;
}

/** 全周 7 张课表，都属默认群。 */
function weeklyProfile(): Profile {
  const names: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
  const specs: PlanSpec[] = [];
  for (let day: number = 0; day < 7; day++) {
    specs.push({ key: PlanKey(day), weekDay: day, name: names[day] });
  }
  return buildProfile(specs);
}

function PlanKey(day: number): string {
  const hex: string = (0x10000000 + day).toString(16);
  return `${hex}-0000-0000-0000-000000000000`;
}

function settings(): EngineSettings {
  // 单周起点固定为 2026-09-20（周日），使轮转计算可预期
  return new EngineSettings(dt('2026-09-20T00:00:00'));
}

function at(text: string): DateTimeValue {
  return dt(text);
}

// ------------------------------------------------------------------ A. 历法基座

/**
 * 历法运算是轮转与临时层到期判断的地基，一旦错一位整周都错。
 * 单独锁住，并做长跨度往返以覆盖闰年与世纪闰年。
 */
function testCalendarMath(): void {
  checkNum('dayOfWeek: 2026-09-26 是周六', dt('2026-09-26T00:00:00').dayOfWeek(), 6);
  checkNum('dayOfWeek: 2026-01-01 是周四', dt('2026-01-01T00:00:00').dayOfWeek(), 4);
  // 2024-02-29 是周四，C# DayOfWeek.Thursday = 4
  checkNum('dayOfWeek: 2024-02-29 是周四', dt('2024-02-29T00:00:00').dayOfWeek(), 4);
  // DateTime.MinValue：0001-01-01 是周一。P1 用 new Date(y,...) 会算成 1901 年而错
  checkNum('dayOfWeek: 0001-01-01 是周一', DateTimeValue.minValue().dayOfWeek(), 1);
  checkNum('dayOfWeek: 1900-01-01 是周一', dt('1900-01-01T00:00:00').dayOfWeek(), 1);
  checkNum('dayOfWeek: 2000-01-01 是周六', dt('2000-01-01T00:00:00').dayOfWeek(), 6);

  checkNum('epochDay: 1970-01-01 为 0', dt('1970-01-01T00:00:00').epochDay(), 0);
  checkNum('epochDay: 1970-01-02 为 1', dt('1970-01-02T00:00:00').epochDay(), 1);
  checkNum('epochDay: 1969-12-31 为 -1', dt('1969-12-31T00:00:00').epochDay(), -1);

  checkEqual('addDays: 平年 2 月底跨月',
    dt('2026-02-28T00:00:00').addDays(1).toDateString(), '2026-03-01');
  checkEqual('addDays: 闰年 2 月底',
    dt('2024-02-28T00:00:00').addDays(1).toDateString(), '2024-02-29');
  checkEqual('addDays: 跨年',
    dt('2026-12-31T00:00:00').addDays(1).toDateString(), '2027-01-01');
  checkEqual('addDays: 公元 1 年跨年（P1 的 Date 路径在此出错）',
    dt('0001-12-31T00:00:00').addDays(1).toDateString(), '0002-01-01');
  checkEqual('addDays: 负偏移回到上一年',
    dt('2026-01-01T00:00:00').addDays(-1).toDateString(), '2025-12-31');

  // 长跨度往返：历日 -> 年月日 -> 历日 必须恒等
  let mismatches: number = 0;
  let firstBad: string = '';
  for (let step: number = -30000; step <= 30000; step++) {
    const base: DateTimeValue = dt('2026-09-26T00:00:00');
    const moved: DateTimeValue = base.addDays(step);
    if (moved.epochDay() !== base.epochDay() + step) {
      mismatches++;
      if (firstBad.length === 0) {
        firstBad = `${moved.toDateString()} 期望 ${base.epochDay() + step}`;
      }
    }
  }
  check('历日往返 6 万天恒等（含闰年与世纪边界）', mismatches === 0, firstBad);

  // epochDay 单调性：逐日推进必须恰好 +1
  let monotonic: boolean = true;
  for (let step: number = 1; step <= 4000; step++) {
    const d: DateTimeValue = dt('1900-01-01T00:00:00').addDays(step);
    if (d.epochDay() !== dt('1900-01-01T00:00:00').epochDay() + step) {
      monotonic = false;
      break;
    }
  }
  check('epochDay 逐日推进严格 +1（1900 起 4000 天）', monotonic);
}

// ------------------------------------------------------------------ B. 有效时间点

/**
 * 「有效时间点」的双遍扫描是整个引擎最易误实现处。
 * 语义：某节课被停用时，紧贴它前后的课间与分割线一并消失。
 * 详见 ClassPlan.validTimeLayoutItems 的注释。
 */
function testValidTimeLayoutItems(): void {
  const profile: Profile = weeklyProfile();
  const plan: ClassPlan = profile.tryGetClassPlan(Guid.fromCanonical(PlanKey(6)))!;
  const layout: TimeLayout = standardLayout();
  plan.bindTimeLayout(layout);
  plan.classes = [subjectAt(0), subjectAt(1), subjectAt(2)];

  checkEqual('全部启用时：5 个时间点都在',
    describe(plan.validTimeLayoutItems()), '0,1,0,1,0');

  // 停用中间那节课（slot 1，布局下标 2）：两侧课间都应消失
  plan.classes[1].isEnabled = false;
  checkEqual('停用中间课后：只剩两节课',
    describe(plan.validTimeLayoutItems()), '0,0');

  // 停用第一节课：其后的课间消失，末尾课间保留
  plan.classes[1].isEnabled = true;
  plan.classes[0].isEnabled = false;
  checkEqual('停用第一节课后：首课与其后课间消失',
    describe(plan.validTimeLayoutItems()), '0,1,0');

  // 停用首尾两节：所有课间都消失
  plan.classes[0].isEnabled = true;
  plan.classes[2].isEnabled = false;
  checkEqual('停用第三节课后：尾课与其前课间消失',
    describe(plan.validTimeLayoutItems()), '0,1,0');

  // 首尾都停：只剩中间那节课
  plan.classes[0].isEnabled = false;
  checkEqual('停用首尾两课后：仅剩中间一节课',
    describe(plan.validTimeLayoutItems()), '0');
}

/** 把 TimeType 序列拼成可读串。 */
function describe(items: TimeLayoutItem[]): string {
  const parts: string[] = [];
  for (const it of items) {
    parts.push(String(it.timeType));
  }
  return parts.join(',');
}

/**
 * 课程时段下标映射：Classes[i] 对应 classTimePoints()[i]，
 * 布局全表下标需再过一次 classIndexOf。二者不同是常态。
 */
function testClassSlotMapping(): void {
  const layout: TimeLayout = standardLayout();
  checkEqual('classTimePoints 只含上课点', describe(layout.classTimePoints()), '0,0,0');
  checkEqual('displayTimePoints 含上课与课间', describe(layout.displayTimePoints()), '0,1,0,1,0');
  checkNum('布局下标 0 -> 课程序号 0', layout.classIndexOf(0), 0);
  checkNum('布局下标 1（课间）-> -1', layout.classIndexOf(1), -1);
  checkNum('布局下标 2 -> 课程序号 1', layout.classIndexOf(2), 1);
  checkNum('布局下标 4 -> 课程序号 2', layout.classIndexOf(4), 2);
  checkNum('越界下标 -> -1', layout.classIndexOf(5), -1);
  checkNum('负下标 -> -1', layout.classIndexOf(-1), -1);
}

// ------------------------------------------------------------------ C. 状态机

function testStateMachine(): void {
  const profile: Profile = weeklyProfile();
  const cfg: EngineSettings = settings();
  // 2026-09-26 是周六 -> 课程序号 6
  const at26 = (time: string): LessonsSnapshot =>
    LessonsEngine.compute(profile, cfg, at(`2026-09-26T${time}`));

  let snap: LessonsSnapshot = at26('07:00:00');
  checkNum('07:00 尚未开课：state = None', snap.state, TimeState.None);
  check('07:00 未确认课次', !snap.isLessonConfirmed);
  check('07:00 已加载课表', snap.isClassPlanLoaded);
  checkEqual('07:00 距下一节课 1 小时', snap.onClassLeftTime.toString(), '01:00:00');
  checkEqual('07:00 距课间不计时（上课中才计）', snap.onBreakingTimeLeftTime.toString(), '00:00:00');
  checkEqual('07:00 下一节课科目为语文', snap.nextClassSubject.name, '语文');
  checkEqual('07:00 当前科目为占位 ???', snap.currentSubject.name, '???');

  snap = at26('08:00:00');
  checkNum('08:00 开课：state = OnClass', snap.state, TimeState.OnClass);
  check('08:00 已确认课次', snap.isLessonConfirmed);
  checkEqual('08:00 当前科目为语文', snap.currentSubject.name, '语文');
  checkEqual('08:00 距下课 45 分钟', snap.onBreakingTimeLeftTime.toString(), '00:45:00');
  checkEqual('08:00 距下一节课不计时', snap.onClassLeftTime.toString(), '00:00:00');
  checkNum('08:00 布局下标为 0', snap.selectedIndex, 0);

  snap = at26('08:50:00');
  checkNum('08:50 课间中：state = Breaking', snap.state, TimeState.Breaking);
  checkEqual('08:50 课间科目名为自定义课间名', snap.currentSubject.name, '大课间');
  checkEqual('08:50 课间简称为「休」（不被 Name 回填覆盖）', snap.currentSubject.initial, '休');
  checkEqual('08:50 距下一节课 10 分钟', snap.onClassLeftTime.toString(), '00:10:00');

  // 09:00:00 恰是课间末尾与第二节课开头的交界秒，两点都命中，靠列表先后定胜负：
  // 课间（布局下标 1）排在前节课（布局下标 2）之前，故仍算课间。
  snap = at26('09:00:00');
  checkNum('09:00:00 交界秒仍算课间（课间在前节课之前）',
    snap.state, TimeState.Breaking);
  checkEqual('09:00:00 当前科目仍是课间', snap.currentSubject.name, '大课间');

  snap = at26('09:00:01');
  checkNum('09:00:01 第二节课：OnClass', snap.state, TimeState.OnClass);
  checkEqual('09:00:01 当前科目为数学', snap.currentSubject.name, '数学');
  checkNum('09:00:01 布局下标为 2', snap.selectedIndex, 2);

  snap = at26('10:00:00');
  checkNum('10:00:00 交界秒仍算课间', snap.state, TimeState.Breaking);
  snap = at26('10:00:01');
  checkNum('10:00:01 第三节课：OnClass', snap.state, TimeState.OnClass);
  checkEqual('10:00:01 当前科目为英语', snap.currentSubject.name, '英语');
  checkNum('10:00:01 布局下标为 4', snap.selectedIndex, 4);

  snap = at26('11:00:00');
  checkNum('11:00 全天结束：AfterSchool', snap.state, TimeState.AfterSchool);
  check('11:00 未确认课次', !snap.isLessonConfirmed);
  checkEqual('11:00 两个倒计时都为 0', snap.onClassLeftTime.toString(), '00:00:00');

  // 课间无自定义名时回退为「课间休息」
  profile.classPlans.forEach((plan: ClassPlan) => {
    const layout: TimeLayout = plan.resolveTimeLayout()!;
    layout.layouts[1].breakName = '';
  });
  snap = at26('08:50:00');
  checkEqual('课间无自定义名时显示「课间休息」', snap.currentSubject.name, '课间休息');
}

/**
 * 端点闭区间带来的桌面版怪癖：
 * 区间判定两端都是 <= / >=，因此第一节课会一直延续到下一节课开始的
 * 那一秒为止——08:45:00 到 09:00:00 之间（含 09:00:00 之前）都算第一节课在上课，
 * 整个课间被前节课吞掉。这不是移植失误，是桌面版行为，照搬并锁住。
 */
/**
 * 端点闭区间带来的两处行为。
 *
 * 判定式是 `StartTime <= now && EndTime >= now`，两端都含。于是每个时间点独占
 * [start, end] 闭区间，相邻两点在交界那一秒**同时**命中，靠列表先后定胜负：
 * 课间排在后节课之前，所以交界那一秒算课间，要到下一秒才进入上课。
 * 这是桌面版 FirstOrDefault 的原样行为，照搬并锁住。
 */
function testBoundaryInclusion(): void {
  const profile: Profile = weeklyProfile();
  const cfg: EngineSettings = settings();
  const state = (time: string): number =>
    LessonsEngine.compute(profile, cfg, at(`2026-09-26T${time}`)).state;

  // 第一节课 08:00:00–08:45:00
  checkNum('08:44:59 在第一节课内', state('08:44:59'), TimeState.OnClass);
  checkNum('08:45:00 交界秒：前节课与课间同时命中，靠先到者胜 -> 仍是第一节课',
    state('08:45:00'), TimeState.OnClass);
  checkNum('08:45:01 进入课间', state('08:45:01'), TimeState.Breaking);
  checkNum('08:59:59 仍在课间', state('08:59:59'), TimeState.Breaking);

  // 课间 08:45:00–09:00:00 / 第二节课 09:00:00–09:45:00
  checkNum('09:00:00 交界秒：课间在后节课之前 -> 仍算课间',
    state('09:00:00'), TimeState.Breaking);
  checkNum('09:00:01 进入第二节课', state('09:00:01'), TimeState.OnClass);
  checkNum('09:44:59 仍在第二节课', state('09:44:59'), TimeState.OnClass);
  checkNum('09:45:00 交界秒 -> 仍是第二节课', state('09:45:00'), TimeState.OnClass);
  checkNum('09:45:01 进入课间', state('09:45:01'), TimeState.Breaking);

  // 第三节课 10:00:00–10:45:00
  checkNum('10:00:00 交界秒 -> 仍算课间', state('10:00:00'), TimeState.Breaking);
  checkNum('10:00:01 进入第三节课', state('10:00:01'), TimeState.OnClass);
  checkNum('10:45:00 末节课最后一秒仍算上课', state('10:45:00'), TimeState.OnClass);
  checkNum('10:45:01 放学', state('10:45:01'), TimeState.AfterSchool);
}

/**
 * 跨零点的时间段。桌面版拿「当天已过秒数」比较，StartTime > EndTime 的
 * 跨夜时段永远匹配不上——23:30-00:30 在 23:45 落选，在 00:15 也落选
 * （因为 EndTime=1800 < 1830）。桌面版同样如此，不做修补。
 */
/**
 * 跨零点时段。判定式是 `StartTime <= now && EndTime >= now`，秒数在同一天内，
 * 因此 `StartTime > EndTime` 的时间点（23:30–00:30）在任何时刻都两头对不上，
 * 永远不命中——桌面版同样如此。要表达跨夜作息必须拆成两段。
 *
 * 另注：当前时间点与「下一节课/课间」都落空时，状态直接落到 AfterSchool，
 * 而不是停在 None。这是桌面版 `if (NextClass == null && NextBreaking == null)`
 * 的无条件判定，None 只在「还没到第一节课且第一节课仍算下一节」时出现。
 */
function testMidnightBoundary(): void {
  const profile: Profile = weeklyProfile();
  const cfg: EngineSettings = settings();
  const layout: TimeLayout = profile.timeLayouts.tryGet(LAYOUT_ID)!;
  layout.layouts = [
    item(0, '23:30:00', '00:30:00'),
    item(0, '00:00:00', '00:30:00')
  ];
  profile.refreshDerivedState();

  const state = (time: string): number =>
    LessonsEngine.compute(profile, cfg, at(`2026-09-26T${time}`)).state;

  checkNum('跨夜时段 23:30-00:30 自身永不命中（StartTime > EndTime）',
    state('23:45:00'), TimeState.AfterSchool);
  checkNum('同一条跨夜时段在 00:15 也不命中',
    state('00:15:00'), TimeState.OnClass);
  checkEqual('00:15 命中的是后面那条 00:00-00:30',
    LessonsEngine.compute(profile, cfg, at('2026-09-26T00:15:00')).currentSubject.name, '数学');

  // 正确表达跨夜作息：拆成 23:30-23:59 与 00:00-00:30 两段
  layout.layouts = [
    item(0, '23:30:00', '23:59:59'),
    item(0, '00:00:00', '00:30:00')
  ];
  profile.refreshDerivedState();
  checkNum('拆段后 23:45 命中前一段', state('23:45:00'), TimeState.OnClass);
  checkNum('拆段后 00:15 命中后一段', state('00:15:00'), TimeState.OnClass);

  // 纯 00:00-00:30 的时段：23:59 当天已无课可等 -> 放学，而不是 None
  layout.layouts = [item(0, '00:00:00', '00:30:00')];
  profile.refreshDerivedState();
  checkNum('00:00-00:30 时段在 00:15 命中', state('00:15:00'), TimeState.OnClass);
  checkNum('同一天 23:59 不命中，且无下一节课 -> 放学', state('23:59:00'), TimeState.AfterSchool);
}

/** 状态迁移只在变化的那一次被标记，供提醒链路挂触发。 */
function testTransitionSequence(): void {
  const profile: Profile = weeklyProfile();
  const cfg: EngineSettings = settings();
  const times: string[] = [
    '07:00:00', '07:30:00',
    '08:00:00', '08:30:00', '08:44:00', '08:44:01', '08:50:00',
    '09:00:00', '09:00:01', '09:30:00', '10:00:00', '10:30:00', '11:00:00'
  ];

  let previous: LessonsSnapshot | undefined = undefined;
  const states: string[] = [];
  const transitions: string[] = [];
  for (const time of times) {
    const snap: LessonsSnapshot =
      LessonsEngine.compute(profile, cfg, at(`2026-09-26T${time}`), previous);
    states.push(stateName(snap.state));
    if (snap.transitionTo !== undefined) {
      transitions.push(`${time}->${stateName(snap.transitionTo)}`);
    }
    previous = snap;
  }
  checkEqual('状态序列：None → OnClass → Breaking → OnClass → AfterSchool',
    states.join(' '),
    'None None OnClass OnClass OnClass OnClass Breaking Breaking OnClass OnClass Breaking OnClass AfterSchool');
  checkEqual('迁移仅在跳变处标记，且跳变处必须被标记',
    transitions.join(' '),
    '08:00:00->OnClass 08:50:00->Breaking 09:00:01->OnClass 10:00:00->Breaking 10:30:00->OnClass 11:00:00->AfterSchool');

  // 首次计算（previous 为 undefined）不产生迁移
  const first: LessonsSnapshot =
    LessonsEngine.compute(profile, cfg, at('2026-09-26T08:00:00'));
  check('首次计算不报迁移', first.transitionTo === undefined);
}

function stateName(state: number): string {
  return TimeState[state] as string;
}

// ------------------------------------------------------------------ D. 选课

function testClassPlanSelection(): void {
  const profile: Profile = weeklyProfile();
  const cfg: EngineSettings = settings();
  const saturday: string = PlanKey(6);
  const sunday: string = PlanKey(0);

  let resolved = ClassPlanResolver.resolve(profile, at('2026-09-26T10:00:00'), cfg);
  checkEqual('周六选中周六课表', resolved.guid.toString(), saturday);
  checkNum('来源为常规选课', resolved.source, ResolvedSource.Regular);

  resolved = ClassPlanResolver.resolve(profile, at('2026-09-27T10:00:00'), cfg);
  checkEqual('周日选中周日课表', resolved.guid.toString(), sunday);

  // 空档案
  const empty: Profile = new Profile();
  const none = ClassPlanResolver.resolve(empty, at('2026-09-26T10:00:00'), cfg);
  check('空档案选不出课表', none.plan === undefined);
  check('未命中时 guid 为 Guid.Empty 而非 undefined（桌面版 out 参数语义）',
    none.guid.isEmpty());

  // 被停用的课表不参与
  const disabled: Profile = weeklyProfile();
  disabled.tryGetClassPlan(Guid.fromCanonical(saturday))!.isEnabled = false;
  check('课表 isEnabled=false 时不参与选课',
    ClassPlanResolver.resolve(disabled, at('2026-09-26T10:00:00'), cfg).plan === undefined);

  // 课表群不匹配则不参与
  const foreign: Profile = weeklyProfile();
  foreign.tryGetClassPlan(Guid.fromCanonical(saturday))!.associatedGroup =
    Guid.fromCanonical(GROUP_TEMP);
  check('课表不在所选群内时不参与选课',
    ClassPlanResolver.resolve(foreign, at('2026-09-26T10:00:00'), cfg).plan === undefined);

  // 叠加课表不参与常规选课
  const overlaid: Profile = weeklyProfile();
  overlaid.tryGetClassPlan(Guid.fromCanonical(saturday))!.isOverlay = true;
  check('isOverlay 课表不参与常规选课',
    ClassPlanResolver.resolve(overlaid, at('2026-09-26T10:00:00'), cfg).plan === undefined);

  // 星期几不匹配
  const wrongDay: Profile = weeklyProfile();
  const wrongPlan: ClassPlan = wrongDay.tryGetClassPlan(Guid.fromCanonical(saturday))!;
  wrongPlan.timeRule.weekDay = 3;
  check('星期几不匹配时不参与选课',
    ClassPlanResolver.resolve(wrongDay, at('2026-09-26T10:00:00'), cfg).plan === undefined);
}

/**
 * 群优先级与稳定序。桌面版先按群优先级排序、再按 CheckClassPlan 过滤、
 * 最后取第一个——所以高优先级群里「今天不匹配」的课表会把位置占住而
 * 不让位给低优先级的课表。这是怪癖但必须照搬。
 */
function testGroupPriority(): void {
  const cfg: EngineSettings = settings();
  const saturday: string = PlanKey(6);

  // 全局群优先级低于所选群。所选群那张星期不匹配，被 CheckClassPlan 滤掉后，
  // 仍会继续往下看全局群那张——顺序与筛选是两个独立环节。
  const globalPlan: Profile = buildProfile([
    { key: saturday, weekDay: 3, name: '周三的' },
    { key: 'dddddddd-0000-0000-0000-00000000000a', weekDay: 6, name: '全局周六', group: '00000000-0000-0000-0000-000000000000' }
  ]);
  const picked = ClassPlanResolver.resolve(globalPlan, at('2026-09-26T10:00:00'), cfg);
  checkEqual('高优先级群里不匹配的课表被滤掉后，低优先级的仍能入选',
    picked.plan === undefined ? '<空>' : picked.plan.name, '全局周六');

  // 优先级压过档案顺序：全局群那张排在档案内更靠前，仍输给所选群那张。
  // 这条是「先排序后筛选」最容易被误实现成「先筛选后排序」的地方——
  // 两种写法在只有一张匹配时结果相同，只有两张都匹配时才分得出高下。
  const bothMatch: Profile = buildProfile([
    { key: 'dddddddd-0000-0000-0000-00000000000a', weekDay: 6, name: '全局周六（靠前）', group: '00000000-0000-0000-0000-000000000000' },
    { key: saturday, weekDay: 6, name: '所选周六（靠后）' }
  ]);
  checkEqual('两张都匹配时，群优先级压过档案内先后顺序',
    ClassPlanResolver.resolve(bothMatch, at('2026-09-26T10:00:00'), cfg).plan!.name, '所选周六（靠后）');

  // 同群内顺序仍然由档案顺序决定（稳定排序）
  const sameGroup: Profile = buildProfile([
    { key: saturday, weekDay: 6, name: '先' },
    { key: 'cccccccc-0000-0000-0000-000000000009', weekDay: 6, name: '后' }
  ]);
  checkEqual('同群同优先级时仍按档案顺序取首个',
    ClassPlanResolver.resolve(sameGroup, at('2026-09-26T10:00:00'), cfg).plan!.name, '先');

  // 临时群优先级最高：所选群那张排在更前也应被临时群压过
  const withTemp: Profile = buildProfile([
    { key: saturday, weekDay: 6, name: '所选周六' },
    { key: 'eeeeeeee-0000-0000-0000-00000000000b', weekDay: 6, name: '临时周六', group: GROUP_TEMP }
  ]);
  withTemp.classPlanGroups.set(GROUP_TEMP, new ClassPlanGroup());
  withTemp.isTempClassPlanGroupEnabled = true;
  withTemp.tempClassPlanGroupId = Guid.fromCanonical(GROUP_TEMP);
  withTemp.tempClassPlanGroupExpireTime = dt('2026-10-01T00:00:00');
  checkEqual('临时群优先级最高，压过所选群',
    ClassPlanResolver.resolve(withTemp, at('2026-09-26T10:00:00'), cfg).plan!.name, '临时周六');
}

/**
 * 临时群的三种类型。判据来自 GetClassPlanByDate 里那段 switch。
 */
function testTempGroupTypes(): void {
  const cfg: EngineSettings = settings();
  const saturday: string = PlanKey(6);

  // 周六周日各备一套，才能同时在 2026-09-26（周六）与 2026-09-27（周日）上取数。
  // 排在前面的周六那几张不匹配当天星期，不会干扰当天的结论。
  const make = (type: number): Profile => {
    const profile: Profile = buildProfile([
      { key: saturday, weekDay: 6, name: '常规周六' },
      { key: PlanKey(0), weekDay: 0, name: '常规周日' },
      { key: 'eeeeeeee-0000-0000-0000-00000000000b', weekDay: 6, name: '临时周六', group: GROUP_TEMP },
      { key: 'ffffffff-0000-0000-0000-00000000000c', weekDay: 0, name: '临时周日', group: GROUP_TEMP }
    ]);
    profile.classPlanGroups.set(GROUP_TEMP, new ClassPlanGroup());
    profile.isTempClassPlanGroupEnabled = true;
    profile.tempClassPlanGroupId = Guid.fromCanonical(GROUP_TEMP);
    profile.tempClassPlanGroupExpireTime = dt('2026-10-01T00:00:00');
    profile.tempClassPlanGroupType = type;
    return profile;
  };

  // 枚举值以整数写进 JSON，必须与桌面版一致：Override=0, Inherit=1
  checkEqual('Inherit：临时群优先级高于所选群，临时课表胜出',
    ClassPlanResolver.resolve(make(TempClassPlanGroupType.Inherit),
      at('2026-09-26T10:00:00'), cfg).plan!.name, '临时周六');
  checkEqual('Override：同样取临时课表',
    ClassPlanResolver.resolve(make(TempClassPlanGroupType.Override),
      at('2026-09-26T10:00:00'), cfg).plan!.name, '临时周六');
  checkEqual('未知类型：退化为只看所选群与全局群',
    ClassPlanResolver.resolve(make(99), at('2026-09-26T10:00:00'), cfg).plan!.name, '常规周六');

  // 临时群过期后不再参与
  const expired: Profile = make(TempClassPlanGroupType.Inherit);
  expired.tempClassPlanGroupExpireTime = dt('2026-09-01T00:00:00');
  checkEqual('临时群过期：退回只认所选群与全局群',
    ClassPlanResolver.resolve(expired, at('2026-09-26T10:00:00'), cfg).plan!.name, '常规周六');

  // 未启用时不参与
  const off: Profile = make(TempClassPlanGroupType.Inherit);
  off.isTempClassPlanGroupEnabled = false;
  checkEqual('临时群未启用：退回只认所选群与全局群',
    ClassPlanResolver.resolve(off, at('2026-09-26T10:00:00'), cfg).plan!.name, '常规周六');

  // 到期当天仍然生效（选课判据是 !(到期 < 目标日)）
  const todayExpire: Profile = make(TempClassPlanGroupType.Inherit);
  todayExpire.tempClassPlanGroupExpireTime = dt('2026-09-26T00:00:00');
  checkEqual('临时群到期当天：仍然生效',
    ClassPlanResolver.resolve(todayExpire, at('2026-09-26T10:00:00'), cfg).plan!.name, '临时周六');
  checkEqual('临时群到期当天：次日失效，退回常规周日',
    ClassPlanResolver.resolve(todayExpire, at('2026-09-27T10:00:00'), cfg).plan!.name, '常规周日');
}

/**
 * 预定课表（OrderedSchedules）。这是「今天特殊安排」的主入口。
 */
function testOrderedSchedules(): void {
  const cfg: EngineSettings = settings();
  const saturday: string = PlanKey(6);
  const special: string = 'ffffffff-0000-0000-0000-00000000000c';

  // 建一张只属于周一的课表，预定到周六
  const profile: Profile = weeklyProfile();
  profile.tryGetClassPlan(Guid.fromCanonical(PlanKey(1)))!.name = '周一的（今天特殊）';
  const schedule: OrderedSchedule = new OrderedSchedule();
  schedule.classPlanId = Guid.fromCanonical(PlanKey(1));
  profile.orderedSchedules.set('2026-09-26T00:00:00', schedule);

  let resolved = ClassPlanResolver.resolve(profile, at('2026-09-26T10:00:00'), cfg);
  checkEqual('当天有预定：预定课表优先于按星期选出的课表',
    resolved.plan!.name, '周一的（今天特殊）');
  checkNum('来源标记为预定', resolved.source, ResolvedSource.OrderedSchedule);

  // 预定指向不存在的课表 -> 落回常规选课
  schedule.classPlanId = Guid.fromCanonical(special);
  resolved = ClassPlanResolver.resolve(profile, at('2026-09-26T10:00:00'), cfg);
  checkNum('预定指向不存在的课表时落回常规选课', resolved.source, ResolvedSource.Regular);

  // 预定叠加课表但未开叠加班表开关 -> 落回常规选课
  const overlayPlanKey: string = '99999999-0000-0000-0000-00000000000d';
  const overlaid: ClassPlan = new ClassPlan();
  overlaid.name = '临时层';
  overlaid.timeLayoutId = Guid.fromCanonical(LAYOUT_ID);
  overlaid.isOverlay = true;
  overlaid.timeRule.weekDay = 6;
  overlaid.classes = [subjectAt(0), subjectAt(1), subjectAt(2)];
  profile.classPlans.set(overlayPlanKey, overlaid);
  schedule.classPlanId = Guid.fromCanonical(overlayPlanKey);
  profile.refreshDerivedState();
  profile.isOverlayClassPlanEnabled = false;
  checkNum('预定为叠加课表但开关关闭 -> 落回常规选课',
    ClassPlanResolver.resolve(profile, at('2026-09-26T10:00:00'), cfg).source,
    ResolvedSource.Regular);
  profile.isOverlayClassPlanEnabled = true;
  checkNum('预定为叠加课表且开关打开 -> 采用叠加课表',
    ClassPlanResolver.resolve(profile, at('2026-09-26T10:00:00'), cfg).source,
    ResolvedSource.OrderedSchedule);

  // 键归一化：非规范键在「JSON 读入层」被归一。必须走 JSON —— 键归一化只发生在
  // 字典键转换时（桌面版 System.Text.Json 同理）；直接 set 塞裸字符串是绕过转换层的，
  // 桌面版那样做同样不归一，所以这里不能直接 set。
  const loose: Profile = weeklyProfile();
  loose.orderedSchedules.set('2026-09-08T00:00:00', schedule);
  const looseText: string = Profile.stringify(loose).replace('"2026-09-08T00:00:00"', '"2026-9-8"');
  check('夹具确实写入了非规范键', looseText.indexOf('"2026-9-8"') > 0, looseText);
  const looseParsed: Profile = Profile.parse(looseText);
  check('手写非规范日期键（2026-9-8）在读入时被归一',
    looseParsed.orderedScheduleFor(at('2026-09-08T15:00:00')) !== undefined);
  checkEqual('归一后的键是规范 ISO 形式（补零）',
    looseParsed.orderedSchedules.keys()[0], '2026-09-08T00:00:00');
  // 归一是「按值相等」，不是字符串前缀匹配：只给日期不给时刻也该命中同一天
  check('非规范键归一后与时刻无关地命中',
    looseParsed.orderedScheduleFor(at('2026-09-08T03:00:00')) !== undefined);
  check('相邻日不误命中',
    looseParsed.orderedScheduleFor(at('2026-09-09T15:00:00')) === undefined);
}

// ------------------------------------------------------------------ E. 临时层生命周期

function testTempPlanLifecycle(): void {
  const saturday: string = PlanKey(6);
  const now: DateTimeValue = at('2026-09-26T10:00:00');

  // 创建临时层
  const profile: Profile = weeklyProfile();
  const created: Guid | undefined = TempPlanManager.createTempClassPlan(
    profile, Guid.fromCanonical(saturday), now.dateOnly(), false);
  check('创建临时层返回新 ID', created !== undefined);
  check('创建后叠加班表开关被打开', profile.isOverlayClassPlanEnabled);
  checkEqual('创建后当天有了预定',
    profile.orderedScheduleFor(now.dateOnly())!.classPlanId.toString(), created!.toString());
  check('创建后 OverlayClassPlanId 指向新课表',
    profile.overlayClassPlanId !== undefined &&
    profile.overlayClassPlanId.equals(created!));

  const createdPlan: ClassPlan = profile.tryGetClassPlan(created!)!;
  check('临时层 isOverlay 为真', createdPlan.isOverlay);
  checkEqual('临时层课表名带后缀', createdPlan.name, '周六（临时层）');
  check('临时层记录了叠加来源', createdPlan.overlaySourceId !== undefined &&
    createdPlan.overlaySourceId.equals(Guid.fromCanonical(saturday)));
  // 当天有预定时，临时层不会被清理掉
  TempPlanManager.cleanExpired(profile, now);
  check('当天有预定时，临时层不会被清理掉',
    profile.classPlans.has(created!.toString()));

  // 同一天再创建一次 -> 拒绝
  const again: Guid | undefined = TempPlanManager.createTempClassPlan(
    profile, Guid.fromCanonical(saturday), now.dateOnly(), false);
  check('当天已有临时层时再建被拒绝', again === undefined);

  // 取消临时层
  check('取消临时层成功', TempPlanManager.clearTempClassPlan(profile, now));
  check('取消后当天预定被删', profile.orderedScheduleFor(now.dateOnly()) === undefined);
  check('取消后临时层课表被清理', !profile.classPlans.has(created!.toString()));
  check('取消后 OverlayClassPlanId 被解绑', profile.overlayClassPlanId === undefined);

  // 临时层课表的过期清理
  const aging: Profile = weeklyProfile();
  const tempId: Guid = TempPlanManager.createTempClassPlan(
    aging, Guid.fromCanonical(saturday), now.dateOnly(), false)!;
  TempPlanManager.cleanExpired(aging, at('2026-09-27T10:00:00'));
  check('过期后预定消失', aging.orderedScheduleFor(dt('2026-09-26T00:00:00')) === undefined);
  check('过期后临时层课表被回收', !aging.classPlans.has(tempId.toString()));

  // 临时 TempClassPlanId 过期解绑
  const binding: Profile = weeklyProfile();
  binding.tempClassPlanId = Guid.fromCanonical(saturday);
  binding.tempClassPlanSetupTime = dt('2026-09-26T00:00:00');
  check('今天建立的临时课表当天仍有效',
    !TempPlanManager.clearExpiredTempClassPlan(binding, now));
  check('昨天建立的临时课表在今天被解绑',
    TempPlanManager.clearExpiredTempClassPlan(binding, at('2026-09-27T10:00:00')));
  check('解绑后 TempClassPlanId 为 undefined', binding.tempClassPlanId === undefined);

  // 转正。桌面版 ConvertToStdClassPlan 只把「时间表」名去后缀，课表名保留
  // （newCp.Name += "（临时层）" 是在 CreateTempClassPlan 里加的，转正不回滚）。
  const promote: Profile = weeklyProfile();
  const promoteId: Guid = TempPlanManager.createTempClassPlan(
    promote, Guid.fromCanonical(saturday), now.dateOnly(), false)!;
  const promotePlan: ClassPlan = promote.tryGetClassPlan(promoteId)!;
  const sharedLayoutId: string = promotePlan.timeLayoutId.toString();
  check('转正成功', TempPlanManager.convertToStdClassPlan(promote, promoteId));
  check('转正后课表 isOverlay 为假', !promotePlan.isOverlay);
  checkEqual('转正后课表名仍保留「（临时层）」后缀', promotePlan.name, '周六（临时层）');
  check('非临时层时间表不受影响（isOverlay 仍为假）',
    !promote.tryGetTimeLayout(Guid.fromCanonical(sharedLayoutId))!.isOverlay);
  check('非临时层时间表名未被改动',
    promote.tryGetTimeLayout(Guid.fromCanonical(sharedLayoutId))!.name === '标准作息');

  // 建了临时时间表的情况：转正应把时间表名后缀去掉
  const withLayout: Profile = weeklyProfile();
  const withLayoutId: Guid = TempPlanManager.createTempClassPlan(
    withLayout, Guid.fromCanonical(saturday), now.dateOnly(), true)!;
  const tempLayoutPlan: ClassPlan = withLayout.tryGetClassPlan(withLayoutId)!;
  const tempLayoutId: string = tempLayoutPlan.timeLayoutId.toString();
  check('建临时层时另建了临时时间表',
    tempLayoutId !== sharedLayoutId);
  checkEqual('临时时间表名带后缀',
    withLayout.tryGetTimeLayout(Guid.fromCanonical(tempLayoutId))!.name, '标准作息（临时层）');
  check('临时时间表 isOverlay 为真',
    withLayout.tryGetTimeLayout(Guid.fromCanonical(tempLayoutId))!.isOverlay);
  check('转正成功', TempPlanManager.convertToStdClassPlan(withLayout, withLayoutId));
  check('转正后临时时间表 isOverlay 为假',
    !withLayout.tryGetTimeLayout(Guid.fromCanonical(tempLayoutId))!.isOverlay);
  checkEqual('转正后临时时间表名去掉后缀',
    withLayout.tryGetTimeLayout(Guid.fromCanonical(tempLayoutId))!.name, '标准作息');
  check('原时间表始终没被动过',
    !withLayout.tryGetTimeLayout(Guid.fromCanonical(LAYOUT_ID))!.isOverlay &&
    withLayout.tryGetTimeLayout(Guid.fromCanonical(LAYOUT_ID))!.name === '标准作息');
}

/** 临时层课表的到期时间：等群内最后一门课跑完。 */
function testTempGroupSetup(): void {
  const cfg: EngineSettings = settings();
  // 2026-09-26 是周六(6)。单周起点 2026-09-20(周日)，
  // 于是 elapsedWeeks = floor(6/7)+1 = 1
  const profile: Profile = buildProfile([
    { key: PlanKey(6), weekDay: 6, name: '周六', group: GROUP_TEMP },
    { key: 'abababab-0000-0000-0000-00000000000e', weekDay: 0, name: '周日', group: GROUP_TEMP },
    { key: 'cdcdcdcd-0000-0000-0000-00000000000f', weekDay: 1, name: '周一', group: GROUP_TEMP }
  ]);
  profile.classPlanGroups.set(GROUP_TEMP, new ClassPlanGroup());
  const expire: DateTimeValue = TempPlanManager.setupTempGroup(
    profile, Guid.fromCanonical(GROUP_TEMP), cfg, at('2026-09-26T10:00:00'));
  // today=2026-09-26 周六(6)，SingleWeekStartTime=2026-09-20 周日
  //   dd = 6 天，dw = floor(6/7) + 1 = 1
  // 每张课表：w = 1 % 2 = 1，divOffset = (0 + 2 - 1) % 2 = 1，故 finalOffset = 周几差 + 7
  //   周六 周几差 0 -> 0 + 7 = 7
  //   周日 周几差 -6 -> -6 + 7 = 1
  //   周一 周几差 -5 -> -5 + 7 = 2
  // 取最大 7 -> 2026-09-26 + 7 天 = 2026-10-03
  // 那个 divOffset*7 的含义是「单双周轮转还没轮到本周，所以最早也要等一整周」。
  checkEqual('临时群到期日 = 今天 + 群内最大生效日偏移（含单双周轮转等待）',
    expire.toDateString(), '2026-10-03');
  check('到期时间已写回档案',
    profile.tempClassPlanGroupExpireTime.toDateString() === '2026-10-03');
  check('临时群 ID 已写回', profile.tempClassPlanGroupId !== undefined);
  check('临时群已启用', profile.isTempClassPlanGroupEnabled);

  // 全是单周课表（WeekCountDivTotal=1）时 divOffset 恒为 0，当天就到期
  const everyWeek: Profile = buildProfile([
    { key: PlanKey(6), weekDay: 6, name: '周六', group: GROUP_TEMP, weekCountDivTotal: 1 }
  ]);
  everyWeek.classPlanGroups.set(GROUP_TEMP, new ClassPlanGroup());
  checkEqual('单周课表群当天即到期',
    TempPlanManager.setupTempGroup(everyWeek, Guid.fromCanonical(GROUP_TEMP), cfg,
      at('2026-09-26T10:00:00')).toDateString(), '2026-09-26');

  // WeekCountDivTotal=0 是脏数据，桌面版在此 % 0 抛 DivideByZeroException；
  // 本实现让该课表不参与偏移计算，其余照常
  const dirty: Profile = buildProfile([
    { key: PlanKey(6), weekDay: 6, name: '周六', group: GROUP_TEMP, weekCountDivTotal: 0 },
    { key: 'abababab-0000-0000-0000-00000000000e', weekDay: 0, name: '周日', group: GROUP_TEMP, weekCountDivTotal: 1 }
  ]);
  dirty.classPlanGroups.set(GROUP_TEMP, new ClassPlanGroup());
  checkEqual('脏数据课表被跳过，其余照常算出到期日',
    TempPlanManager.setupTempGroup(dirty, Guid.fromCanonical(GROUP_TEMP), cfg,
      at('2026-09-26T10:00:00')).toDateString(), '2026-09-27');

  // 显式指定过期时间时覆盖计算结果
  const forced: DateTimeValue = TempPlanManager.setupTempGroup(
    profile, Guid.fromCanonical(GROUP_TEMP), cfg, at('2026-09-26T10:00:00'),
    dt('2026-12-31T00:00:00'));
  checkEqual('显式过期时间覆盖计算结果', forced.toDateString(), '2026-12-31');

  // 清除
  TempPlanManager.clearTempGroup(profile);
  check('清除后 TempClassPlanGroupId 为 undefined', profile.tempClassPlanGroupId === undefined);
  check('清除后开关为假', !profile.isTempClassPlanGroupEnabled);

  // 过期清理
  profile.isTempClassPlanGroupEnabled = true;
  profile.tempClassPlanGroupId = Guid.fromCanonical(GROUP_TEMP);
  profile.tempClassPlanGroupExpireTime = dt('2026-09-01T00:00:00');
  check('过期临时群被清除', TempPlanManager.clearExpiredTempGroup(profile, at('2026-09-26T10:00:00')));
  check('清除后开关为假', !profile.isTempClassPlanGroupEnabled);
}

// ------------------------------------------------------------------ F. 单双周轮转

function testWeekRotation(): void {
  const cfg: EngineSettings = settings();
  // 单周起点 2026-09-20（周日）
  // 2026-09-26 距起点 6 天 -> elapsedWeeks = 0
  checkNum('elapsedWeeks: 起点当周为 0',
    WeekRotation.elapsedWeeks(at('2026-09-26T10:00:00'), cfg), 0);
  checkNum('elapsedWeeks: 下一周为 1',
    WeekRotation.elapsedWeeks(at('2026-10-03T10:00:00'), cfg), 1);
  checkNum('elapsedWeeks: 起点之前为负',
    WeekRotation.elapsedWeeks(at('2026-09-13T10:00:00'), cfg), -1);
  checkNum('elapsedWeeks: 时刻部分被忽略',
    WeekRotation.elapsedWeeks(at('2026-09-26T23:59:59'), cfg), 0);

  // 位置数组：下标 0/1 为占位 -1，其后按周期长度 2..maxCycle 给出 1 起位置。
  // 长度 = 2 个占位 + (maxCycle - 1) 个周期 = maxCycle + 1
  const positions: number[] = WeekRotation.cyclePositions(at('2026-09-26T10:00:00'), cfg);
  checkNum('位置数组长度 = maxCycle + 1', positions.length, cfg.multiWeekRotationMaxCycle + 1);
  checkNum('下标 0 为占位 -1', positions[0], -1);
  checkNum('下标 1 为占位 -1', positions[1], -1);
  checkNum('周期 2 的位置为 1（第 0 周即第 1 位）', positions[2], 1);
  checkNum('周期 3 的位置为 1', positions[3], 1);
  checkNum('周期 4 的位置为 1', positions[4], 1);

  // 偏移生效：给周期 2 加 1 偏移后，第 0 周落到第 2 位
  const offset: EngineSettings = settings();
  offset.multiWeekRotationOffset = [-1, -1, 1, 0, 0];
  checkNum('偏移把位置从 1 推到 2',
    WeekRotation.positionOf(at('2026-09-26T10:00:00'), offset, 2), 2);

  // 越界周期长度返回 0（桌面版会抛异常）
  checkNum('周期长度越界返回 0', WeekRotation.positionOf(at('2026-09-26T10:00:00'), cfg, 9), 0);
  checkNum('周期长度为 0 返回 0', WeekRotation.positionOf(at('2026-09-26T10:00:00'), cfg, 0), 0);

  // 单双周课表：weekCountDiv=1 / total=2 只在奇数周生效
  const alternating: Profile = buildProfile([
    { key: PlanKey(6), weekDay: 6, name: '单周', weekCountDiv: 1, weekCountDivTotal: 2 }
  ]);
  const even = settings();
  check('第 0 周（位置 1）命中单周课表',
    ClassPlanResolver.resolve(alternating, at('2026-09-26T10:00:00'), even).plan !== undefined);
  check('第 1 周（位置 2）不命中单周课表',
    ClassPlanResolver.resolve(alternating, at('2026-10-03T10:00:00'), even).plan === undefined);

  const odd: Profile = buildProfile([
    { key: PlanKey(6), weekDay: 6, name: '双周', weekCountDiv: 2, weekCountDivTotal: 2 }
  ]);
  check('第 0 周不命中双周课表',
    ClassPlanResolver.resolve(odd, at('2026-09-26T10:00:00'), even).plan === undefined);
  check('第 1 周命中双周课表',
    ClassPlanResolver.resolve(odd, at('2026-10-03T10:00:00'), even).plan !== undefined);

  // 周期总数超过上限 -> 永不匹配
  const tooLong: Profile = buildProfile([
    { key: PlanKey(6), weekDay: 6, name: '六周制', weekCountDiv: 1, weekCountDivTotal: 6 }
  ]);
  check('周期总数超过上限时不匹配',
    ClassPlanResolver.resolve(tooLong, at('2026-09-26T10:00:00'), even).plan === undefined);

  // weekCountDiv=0 -> 每天都命中
  const daily: Profile = buildProfile([
    { key: PlanKey(6), weekDay: 6, name: '每周', weekCountDiv: 0, weekCountDivTotal: 2 }
  ]);
  check('weekCountDiv=0 时不参与轮转判定',
    ClassPlanResolver.resolve(daily, at('2026-10-03T10:00:00'), even).plan !== undefined);
}

// ------------------------------------------------------------------ G. 科目怪癖

function testSubjectQuirks(): void {
  // Name 的 setter 会在 Initial 为空时回填首字
  const auto: Subject = new Subject();
  auto.name = '语文';
  checkEqual('未填简称时由科目名首字回填', auto.initial, '语');

  const explicit: Subject = new Subject();
  explicit.initial = 'Y';
  explicit.name = '语文';
  checkEqual('已填简称时不被回填覆盖', explicit.initial, 'Y');

  const blank: Subject = new Subject();
  blank.name = '   ';
  checkEqual('空白名不回填简称', blank.initial, '');

  // 读入时：先按 Name 回填，再用 JSON 里的 Initial 覆盖
  const fromMissing: Subject = Subject.fromJson(
    jsonObject('{"Name":"数学","TeacherName":"","IsOutDoor":false}'));
  checkEqual('JSON 缺少 Initial 时用回填值', fromMissing.initial, '数');

  const fromPresent: Subject = Subject.fromJson(
    jsonObject('{"Name":"数学","Initial":"S","TeacherName":"","IsOutDoor":false}'));
  checkEqual('JSON 带 Initial 时以 JSON 为准', fromPresent.initial, 'S');

  // 落盘：缺 Initial 的输入会被补上回填值（桌面版 STJ 同样如此）。
  // 注意不能拿字面量去搜落盘文本 —— 写入器严格复刻 STJ 默认 JavaScriptEncoder，
  // 非 Basic Latin 一律转成 \uXXXX，所以「数」在文本里是「数」。
  // 这里改为「落盘后再读回来」比对值，转义行为由 driver.ts 的字节级往返用例覆盖。
  const dumped: Subject = Profile.parse(Profile.stringify(
    singleSubjectProfile(new Subject(), '数学')))
    .subjects.values()[0];
  checkEqual('落盘补上了回填出来的简称', dumped.initial, '数');
  check('落盘确实把 Initial 写进了 JSON（非缺字段）',
    Profile.stringify(singleSubjectProfile(new Subject(), '数学'))
      .indexOf('"Initial":') > 0);

  // 占位科目
  checkEqual('fallback 名称', Subject.fallback().name, '???');
  checkEqual('fallback 简称', Subject.fallback().initial, '?');
  checkEqual('breaking 简称恒为「休」', Subject.breaking('大课间').initial, '休');
  checkEqual('breaking 名称取自定义名', Subject.breaking('大课间').name, '大课间');
  checkEqual('breaking 每次新建，无残留', Subject.breaking('小课间').name, '小课间');

  // 拆分姓氏
  const compound: Subject = new Subject();
  compound.teacherName = '司马相如';
  checkEqual('复姓整体作为姓', compound.firstTeacherSurname(), '司马');
  const single: Subject = new Subject();
  single.teacherName = '李四';
  checkEqual('单姓取首字', single.firstTeacherSurname(), '李');
  const none: Subject = new Subject();
  checkEqual('未填教师名时返回空串', none.firstTeacherSurname(), '');
}

/** 解析一段 JSON 文本为对象节点。测试里手写小片段用。 */
function jsonObject(text: string): JsonObject {
  const asObject: JsonObject | undefined = JsonValue.asObject(JsonReader.parse(text));
  return asObject === undefined ? new JsonObject() : asObject;
}

// ------------------------------------------------------------------ H. 可重入性

/**
 * 可重入性是本阶段的硬约束：小组件 Extension 10 秒不活动即被回收，
 * 每次都是「重新加载档案 -> 算一次 -> 销毁」。若引擎里有跨实例的可变单例，
 * 两次独立计算的结果就会不同，提醒就会重复发或漏发。
 */
function testReentrancy(): void {
  const cfg: EngineSettings = settings();
  const now: DateTimeValue = at('2026-09-26T08:20:00');

  const project = (snap: LessonsSnapshot): string => {
    return [
      String(snap.state),
      snap.currentSubject.name,
      snap.nextClassSubject.name,
      String(snap.selectedIndex),
      snap.onBreakingTimeLeftTime.toString(),
      snap.onClassLeftTime.toString(),
      snap.isLessonConfirmed ? '1' : '0',
      snap.isClassPlanLoaded ? '1' : '0',
      snap.currentClassPlanGuid.toString()
    ].join('|');
  };

  const first: string = project(LessonsEngine.compute(weeklyProfile(), cfg, now));
  const second: string = project(LessonsEngine.compute(weeklyProfile(), cfg, now));
  const third: string = project(LessonsEngine.compute(weeklyProfile(), cfg, now));
  check('同一时刻连续三次独立实例化结果完全一致',
    first === second && second === third, `1=${first}\n    2=${second}\n    3=${third}`);

  // 交叉验证：先算 A 再算 B，B 不应受 A 影响
  const a: string = project(LessonsEngine.compute(weeklyProfile(), cfg, at('2026-09-26T08:20:00')));
  LessonsEngine.compute(weeklyProfile(), cfg, at('2026-09-26T10:20:00'));
  LessonsEngine.compute(weeklyProfile(), cfg, at('2026-09-26T07:00:00'));
  const b: string = project(LessonsEngine.compute(weeklyProfile(), cfg, at('2026-09-26T08:20:00')));
  check('夹杂其他时刻的计算后，目标时刻结果不变', a === b, `${a}\n    ${b}`);

  // compute 会改写档案（清理临时层），但重复调用必须幂等
  const profile: Profile = weeklyProfile();
  const before: string = Profile.stringify(profile);
  LessonsEngine.compute(profile, cfg, now);
  const afterFirst: string = Profile.stringify(profile);
  LessonsEngine.compute(profile, cfg, now);
  const afterSecond: string = Profile.stringify(profile);
  check('compute 的档案副作用是幂等的', afterFirst === afterSecond,
    `\n    第一次后: ${afterFirst.substring(0, 160)}\n    第二次后: ${afterSecond.substring(0, 160)}`);
  check('compute 不改变档案的落盘内容（无临时层时）', before === afterFirst);

  // 班级停用状态不应在两次计算间累积
  const mutating: Profile = weeklyProfile();
  const plan: ClassPlan = mutating.tryGetClassPlan(Guid.fromCanonical(PlanKey(6)))!;
  plan.classes[0].isEnabled = false;
  const runOnce: string = project(LessonsEngine.compute(mutating, cfg, at('2026-09-26T08:20:00')));
  const runTwice: string = project(LessonsEngine.compute(mutating, cfg, at('2026-09-26T08:20:00')));
  check('停用课程后重复计算结果稳定', runOnce === runTwice, `${runOnce}\n    ${runTwice}`);
}

// ------------------------------------------------------------------ 入口

function singleSubjectProfile(subject: Subject, name: string): Profile {
  const profile: Profile = new Profile();
  profile.name = '单科';
  const guid: string = '12345678-1234-1234-1234-123456789012';
  subject.name = name;
  profile.subjects.set(guid, subject);
  return profile;
}

testCalendarMath();
testValidTimeLayoutItems();
testClassSlotMapping();
testStateMachine();
testBoundaryInclusion();
testMidnightBoundary();
testTransitionSequence();
testClassPlanSelection();
testGroupPriority();
testTempGroupTypes();
testOrderedSchedules();
testTempPlanLifecycle();
testTempGroupSetup();
testWeekRotation();
testSubjectQuirks();
testReentrancy();

console.log(`通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('');
  for (const failure of failures) {
    console.log(`✗ ${failure}`);
  }
  process.exit(1);
}
