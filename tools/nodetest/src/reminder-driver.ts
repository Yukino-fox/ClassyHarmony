/*
 * 提醒编排测试台。
 *
 * 平台侧（reminderAgentManager）只有真机能验，所以「该在什么时刻触发、覆盖哪几天、
 * 额度不够时怎么降级」全部挤到 core 的纯函数里，在这里穷举边界。
 *
 * 覆盖分组：
 *   A 基本编排        哪些时段该排、哪些不该排
 *   B 触发时刻        提前量、已过顺延、跨零点
 *   C 额度与降级      截断顺序、两条形态的条数
 *   D 口径转换        档案 0=周日 ↔ 平台 1=周一
 *   E 差异比对        增 / 改 / 删 / 别人的提醒
 *   F 单双周          排了但如实标记偏差
 *   G 纯度与确定性    不改档案、同输入同输出
 */

import { ClassInfo } from '../../common_shared/src/main/ets/models/ClassInfo';
import { ClassPlan } from '../../common_shared/src/main/ets/models/ClassPlan';
import { ClassPlanGroup } from '../../common_shared/src/main/ets/models/ClassPlanGroup';
import { Guid } from '../../common_shared/src/main/ets/json/Guid';
import { Subject } from '../../common_shared/src/main/ets/models/Subject';
import { TimeLayout } from '../../common_shared/src/main/ets/models/TimeLayout';
import { TimeLayoutItem } from '../../common_shared/src/main/ets/models/TimeLayoutItem';
import { TimeRule } from '../../common_shared/src/main/ets/models/TimeRule';
import { DateTimeValue } from '../../common_shared/src/main/ets/json/DateTimeValue';
import { Profile } from '../../common_shared/src/main/ets/models/Profile';
import { TimeSpanValue } from '../../common_shared/src/main/ets/json/TimeSpanValue';
import {
  ReminderAdvance,
  ReminderDiff,
  ReminderMode,
  ReminderPlan,
  ReminderPlanItem,
  ReminderPlanner,
  ReminderSnapshot
} from '../../common_core/src/main/ets/reminder/ReminderPlan';

// ------------------------------------------------------------------ 断言

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
  checkEqual(name, String(actual), String(expected));
}

function checkTrue(name: string, value: boolean): void {
  check(name, value, '期望 true');
}

// ------------------------------------------------------------------ 夹具

const BASE_DAY: string = '2026-09-26';   // 周六。2026-09-27 是周日。
const LAYOUT_ID: string = 'aaaaaaaa-0000-0000-0000-000000000000';
const SUBJECT_YUWEN: string = '11111111-1111-1111-1111-111111111111';
const SUBJECT_SHUXUE: string = '22222222-2222-2222-2222-222222222222';
const SUBJECT_YINGYU: string = '33333333-3333-3333-3333-333333333333';
const MISSING_SUBJECT: string = '99999999-9999-9999-9999-999999999999';

function dt(text: string): DateTimeValue {
  return DateTimeValue.parseOrMin(text);
}

function item(timeType: number, start: string, end: string, name: string = ''): TimeLayoutItem {
  const out: TimeLayoutItem = new TimeLayoutItem();
  out.timeType = timeType;
  out.startSecond = start;
  out.endSecond = end;
  out.startTime = TimeSpanValue.parseOrZero(start);
  out.endTime = TimeSpanValue.parseOrZero(end);
  out.breakName = name;
  return out;
}

/** 0=课 1=课间 2=分割线。三节课夹两个课间，首节课 08:00 开始。 */
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

function advance(indoor: number, outdoor: number = indoor): ReminderAdvance {
  const out: ReminderAdvance = new ReminderAdvance();
  out.indoorSeconds = indoor;
  out.outdoorSeconds = outdoor;
  return out;
}

/** 为 days 列出的星期几各建一张课表（.NET 口径 0=周日 … 6=周六），三节课。 */
function profileForDays(days: number[], layout?: TimeLayout): Profile {
  const profile: Profile = new Profile();
  profile.name = '提醒测试';
  profile.timeLayouts.set(LAYOUT_ID, layout === undefined ? standardLayout() : layout);
  profile.selectedClassPlanGroupId = ClassPlanGroup.defaultGroupGuid();

  // 三节课三个不同科目：后面「改了老师的正文」那条断言依赖三节课互不影响，
  // 第 3 节课误用第一个科目会让它一起变，改断言就变成在测巧合。
  const ids: string[] = [SUBJECT_YUWEN, SUBJECT_SHUXUE, SUBJECT_YINGYU];
  const names: string[] = ['语文', '数学', '英语'];
  for (let i: number = 0; i < ids.length; i++) {
    const subject: Subject = new Subject();
    subject.name = names[i];
    // 老师字段只放姓：正文里的「…老师」由 ReminderPlanner 拼（照搬桌面版
    // ClassNotificationProvider.FormatTeacher 的 GetFirstName() + 「老师」）。
    subject.teacherName = ['王', '李', '陈'][i];
    profile.subjects.set(ids[i], subject);
  }

  for (const day of days) {
    const plan: ClassPlan = new ClassPlan();
    plan.name = `${day} 的课`;
    plan.timeLayoutId = Guid.fromCanonical(LAYOUT_ID);
    const rule: TimeRule = new TimeRule();
    rule.weekDay = day;
    rule.weekCountDiv = 0;
    rule.weekCountDivTotal = 2;
    plan.timeRule = rule;
    // 课次数必须跟着时间表走。硬编码 3 个会让 makeWideLayout(12) 静默失效：
    // 夹具看起来有 12 节课，实际每张课表仍只有 3 节，于是「84 条截到 30」这类额度
    // 断言全在测一个更小的数字，看起来通过而什么也没验证到。
    const used: TimeLayout = layout === undefined ? standardLayout() : layout;
    const classCount: number = used.classTimePoints().length;
    const classes: ClassInfo[] = [];
    for (let i: number = 0; i < classCount; i++) {
      const info: ClassInfo = new ClassInfo();
      info.subjectId = Guid.fromCanonical(ids[i % ids.length]);
      classes.push(info);
    }
    plan.classes = classes;
    profile.classPlans.set(planKey(day), plan);
  }
  profile.refreshDerivedState();
  return profile;
}

/** 周一到周五。 */
function schoolWeek(): Profile {
  return profileForDays([1, 2, 3, 4, 5]);
}

function plan(profile: Profile, now: string, mode: ReminderMode, adv: ReminderAdvance,
  budget: number = -1): ReminderPlan {
  return ReminderPlanner.plan(profile, dt(now), adv, mode, budget);
}

function specificOf(profile: Profile, now: string, adv: ReminderAdvance): ReminderPlan {
  return plan(profile, now, ReminderMode.Specific, adv);
}

function collapsedOf(profile: Profile, now: string, adv: ReminderAdvance): ReminderPlan {
  return plan(profile, now, ReminderMode.Collapsed, adv);
}

function itemAt(items: ReminderPlanItem[], index: number): ReminderPlanItem {
  return items[index];
}

function findByWeekDay(items: ReminderPlanItem[], weekDay: number,
  timePointIndex: number): ReminderPlanItem | undefined {
  for (const item of items) {
    if (item.weekDays.length === 1 && item.weekDays[0] === weekDay &&
      item.timePointIndex === timePointIndex) {
      return item;
    }
  }
  return undefined;
}

function uniqueKeys(items: ReminderPlanItem[]): boolean {
  const seen: Set<string> = new Set<string>();
  for (const item of items) {
    if (seen.has(item.key)) {
      return false;
    }
    seen.add(item.key);
  }
  return true;
}

// ------------------------------------------------------------------ A 基本编排

function testBasicPlanning(): void {
  // 2026-09-26 是周六。提前量取 0，让触发时刻等于上课时刻，便于对齐。
  const p: ReminderPlan = specificOf(schoolWeek(), `${BASE_DAY}T07:00:00`, advance(0));

  checkNum('周一到周五各 3 节 = 15 条', p.items.length, 15);
  checkNum('精确条数', p.specificCount, 15);
  checkNum('未丢任何条', p.droppedCount, 0);
  check('key 唯一', uniqueKeys(p.items));

  // 只有课间被跳过：3 个课间时间点不该各排一条。
  let breaks: number = 0;
  for (const item of p.items) {
    if (item.timePointIndex === 1 || item.timePointIndex === 3) {
      breaks++;
    }
  }
  checkNum('课间不排提醒', breaks, 0);

  // 周一第一节 = 语文，08:00。
  const mondayFirst: ReminderPlanItem | undefined = findByWeekDay(p.items, 1, 0);
  check('周一第一节存在', mondayFirst !== undefined);
  if (mondayFirst !== undefined) {
    checkEqual('周一第一节科目', mondayFirst.subjectName, '语文');
    checkEqual('周一第一节老师', mondayFirst.teacherName, '王');
    checkNum('周一第一节触发时刻（秒）', mondayFirst.trigger.timeOfDaySeconds(), 8 * 3600);
    checkNum('周一第一节星期几', mondayFirst.weekDays[0], 1);
    checkNum('周一第一节课次下标', mondayFirst.classSlot, 0);
  }

  // 提前量 0 时标题不含「分钟后」。
  check('提前量 0 的标题不含分钟后', !p.items[0].title.includes('分钟后'));
}

function testSkippedSlots(): void {
  const profile: Profile = schoolWeek();
  const monday: string = planKey(1);
  const planOfMonday: ClassPlan = profile.classPlans.tryGet(monday) as ClassPlan;

  // 第二节课次禁用。
  planOfMonday.classes[1].isEnabled = false;
  let after: ReminderPlan = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  checkNum('禁用一节课后少一条', after.items.length, 14);
  check('被禁的课次不排', findByWeekDay(after.items, 1, 2) === undefined);

  // 第一节课次没有科目。
  planOfMonday.classes[1].isEnabled = true;
  planOfMonday.classes[0].subjectId = Guid.empty();
  after = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  checkNum('空科目不排', after.items.length, 14);
  check('空科目的课次不排', findByWeekDay(after.items, 1, 0) === undefined);

  // 悬空指针：subjectId 指向档案里没有的科目。
  planOfMonday.classes[0].subjectId = Guid.fromCanonical(SUBJECT_YUWEN);
  planOfMonday.classes[2].subjectId = Guid.fromCanonical(MISSING_SUBJECT);
  after = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  // 只坏了周一的第 3 节课，所以只少一条（不是少三条）。
  checkNum('悬空指针只少一条', after.items.length, 14);
  check('悬空指针的那一格不排', findByWeekDay(after.items, 1, 4) === undefined);
  // 同一时间点的其它天仍要排：悬空只影响一格，不影响整列。
  check('同列其它天照排', findByWeekDay(after.items, 2, 4) !== undefined);
}

function testPlanFiltering(): void {
  const profile: Profile = schoolWeek();

  // 停用课表。
  (profile.classPlans.tryGet(planKey(1)) as ClassPlan).isEnabled = false;
  let p: ReminderPlan = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  checkNum('停用课表不排', p.items.length, 12);
  (profile.classPlans.tryGet(planKey(1)) as ClassPlan).isEnabled = true;

  // 叠加课表不排。
  (profile.classPlans.tryGet(planKey(1)) as ClassPlan).isOverlay = true;
  p = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  checkNum('叠加课表不排', p.items.length, 12);
  (profile.classPlans.tryGet(planKey(1)) as ClassPlan).isOverlay = false;

  // 不在选中群里的课表不排。
  const other: ClassPlan = profile.classPlans.tryGet(planKey(1)) as ClassPlan;
  other.associatedGroup = Guid.newGuid();
  p = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  checkNum('非选中群的课表不排', p.items.length, 12);
  other.associatedGroup = ClassPlanGroup.defaultGroupGuid();

  // 全局群要排。
  other.associatedGroup = ClassPlanGroup.globalGroupGuid();
  p = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  checkNum('全局群的课表要排', p.items.length, 15);
  other.associatedGroup = ClassPlanGroup.defaultGroupGuid();

  // 越界的 weekDay（手改 JSON 才会有）不排，而不是排成永不触发的提醒。
  other.timeRule.weekDay = 7;
  p = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  checkNum('weekDay=7 越界不排', p.items.length, 12);
  other.timeRule.weekDay = -1;
  p = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  checkNum('weekDay=-1 越界不排', p.items.length, 12);

  // 课表没有绑定时间表时不排。
  other.timeRule.weekDay = 1;
  other.timeLayoutId = Guid.fromCanonical('bbbbbbbb-0000-0000-0000-000000000000');
  // 换 timeLayoutId 之后必须 refreshDerivedState：resolveTimeLayout() 读的是
  // refreshDerivedState 里 bindTimeLayout 绑好的引用，不重算就还是旧时间表。
  profile.refreshDerivedState();
  p = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  checkNum('时间表缺失不排', p.items.length, 12);
}

// ------------------------------------------------------------------ B 触发时刻

function testTriggerTime(): void {
  // 提前 5 分钟（默认 300 秒），基准周六 07:00。周一 08:00 的课 → 07:55 触发。
  const p: ReminderPlan = specificOf(schoolWeek(), `${BASE_DAY}T07:00:00`, advance(300));
  const monday: ReminderPlanItem | undefined = findByWeekDay(p.items, 1, 0);
  check('周一第一节存在', monday !== undefined);
  if (monday !== undefined) {
    checkEqual('周一触发日期', monday.trigger.toDateString(), '2026-09-28');
    checkNum('周一触发时刻', monday.trigger.timeOfDaySeconds(), 7 * 3600 + 55 * 60);
    checkNum('实际提前量', monday.advanceSeconds, 300);
  }

  // 已过时刻顺延一周。基准改成周一 09:00：周一 08:00 那节课的 07:55 已过 → 下周一。
  const after: ReminderPlan = specificOf(schoolWeek(), '2026-09-28T09:00:00', advance(300));
  const mondayAgain: ReminderPlanItem | undefined = findByWeekDay(after.items, 1, 0);
  check('周一第一节仍存在', mondayAgain !== undefined);
  if (mondayAgain !== undefined) {
    checkEqual('已过的时刻顺延一周', mondayAgain.trigger.toDateString(), '2026-10-05');
  }
  // 同一天的 09:45 那节课 09:40 触发，此刻 09:00，还没到 → 不顺延。
  const mondayThird: ReminderPlanItem | undefined = findByWeekDay(after.items, 1, 4);
  if (mondayThird !== undefined) {
    checkEqual('当天稍晚的课不顺延', mondayThird.trigger.toDateString(), '2026-09-28');
  }

  // 恰好等于基准时刻也算过去（平台不接受此刻触发）。
  const edge: ReminderPlan = specificOf(schoolWeek(), '2026-09-28T07:55:00', advance(300));
  const edgeItem: ReminderPlanItem | undefined = findByWeekDay(edge.items, 1, 0);
  if (edgeItem !== undefined) {
    checkEqual('触发时刻等于基准时刻也顺延', edgeItem.trigger.toDateString(), '2026-10-05');
  }
}

function testCrossMidnight(): void {
  // 00:05 的课，提前 10 分钟 → 前一天 23:55 触发。
  const layout: TimeLayout = new TimeLayout();
  layout.layouts = [item(0, '00:05:00', '00:50:00')];
  const profile: Profile = profileForDays([1], layout);

  const p: ReminderPlan = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(600));
  const first: ReminderPlanItem = itemAt(p.items, 0);
  checkEqual('跨零点的触发日期是前一天', first.trigger.toDateString(), '2026-09-27');
  checkNum('跨零点的触发时刻是 23:55', first.trigger.timeOfDaySeconds(), 23 * 3600 + 55 * 60);
  checkNum('星期几仍是上课那天（周一）', first.weekDays[0], 1);
  // 09-27 是周日，而触发日是周日的 23:55 —— 提醒必须早于周一 00:05 那节课。
  check('跨零点后触发早于上课', first.trigger.epochDay() * 86400 +
    first.trigger.timeOfDaySeconds() < dt('2026-09-28T00:05:00').epochDay() * 86400 +
    dt('2026-09-28T00:05:00').timeOfDaySeconds());
}

function testOutdoorAdvance(): void {
  const profile: Profile = schoolWeek();
  const outdoor: Subject = profile.subjects.tryGet(SUBJECT_SHUXUE) as Subject;
  outdoor.isOutDoor = true;

  // 室内 5 分钟、室外 10 分钟。周一第二节 09:00（数学，室外）→ 08:50 触发。
  const p: ReminderPlan = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(300, 600));
  const mondaySecond: ReminderPlanItem | undefined = findByWeekDay(p.items, 1, 2);
  check('周一第二节存在', mondaySecond !== undefined);
  if (mondaySecond !== undefined) {
    checkNum('室外课用室外提前量', mondaySecond.advanceSeconds, 600);
    checkNum('室外课触发时刻 08:50', mondaySecond.trigger.timeOfDaySeconds(),
      8 * 3600 + 50 * 60);
  }
  const mondayFirst: ReminderPlanItem | undefined = findByWeekDay(p.items, 1, 0);
  if (mondayFirst !== undefined) {
    checkNum('室内课用室内提前量', mondayFirst.advanceSeconds, 300);
  }
}

function testTextContent(): void {
  const p: ReminderPlan = specificOf(schoolWeek(), `${BASE_DAY}T07:00:00`, advance(300));
  const monday: ReminderPlanItem | undefined = findByWeekDay(p.items, 1, 0);
  if (monday !== undefined) {
    checkEqual('标题含提前分钟数', monday.title, '5 分钟后 语文 上课');
    checkEqual('正文含时刻与老师', monday.content, '08:00 上课：语文，王老师');
    checkEqual('过期正文', monday.expiredContent, '语文 正在上课');
  }
  const mondaySecond: ReminderPlanItem | undefined = findByWeekDay(p.items, 1, 2);
  if (mondaySecond !== undefined) {
    checkEqual('数学那节标题', mondaySecond.title, '5 分钟后 数学 上课');
  }

  // 提前量 0 = 「现在上课」，与桌面版「上课提醒」这一路对齐。
  const zero: ReminderPlan = specificOf(schoolWeek(), `${BASE_DAY}T07:00:00`, advance(0));
  const zeroItem: ReminderPlanItem = itemAt(zero.items, 0);
  checkEqual('提前量 0 的标题', zeroItem.title, '语文 上课');
  checkEqual('提前量 0 的正文', zeroItem.content, '现在上课：语文，王老师');

  // 折叠形态没有科目名，正文退化成纯时刻提示。
  const collapsed: ReminderPlan = collapsedOf(schoolWeek(), `${BASE_DAY}T07:00:00`, advance(300));
  const folded: ReminderPlanItem = itemAt(collapsed.items, 0);
  checkEqual('折叠形态无科目', folded.subjectName, '');
  checkEqual('折叠形态标题', folded.title, '该上课了');
  // 正文说的是「几点上课」，不是「几点提醒」—— 提醒在 07:55 响，正文告诉用户 08:00 上课。
  checkEqual('折叠形态正文', folded.content, '08:00 有课，记得看一下课表');
}

// ------------------------------------------------------------------ C 额度与降级

function testQuotaDegradation(): void {
  // 精确形态 15 条，超过配额 10 → 截断到 10。
  const capped: ReminderPlan = plan(schoolWeek(), `${BASE_DAY}T07:00:00`,
    ReminderMode.Specific, advance(0), 10);
  checkNum('超额度被截断', capped.items.length, 10);
  checkNum('丢了 5 条', capped.droppedCount, 5);
  checkNum('精确总条数仍如实报 15', capped.specificCount, 15);

  // 截断丢的是靠后的时间点，且对每一天一致 —— 不能出现「周一到周三有、周四五没有」。
  const timePoints: number[] = [];
  for (const item of capped.items) {
    if (timePoints.indexOf(item.timePointIndex) < 0) {
      timePoints.push(item.timePointIndex);
    }
  }
  timePoints.sort((a: number, b: number): number => a - b);
  // 15 条 = 5 天 × 3 个时间点，预算 10 正好保住前两个时间点（每天第一节、第二节）。
  checkEqual('保留的是靠前的时间点', timePoints.join(','), '0,2');
  const daysOfTimePoint0: Set<number> = new Set<number>();
  for (const item of capped.items) {
    if (item.timePointIndex === 0) {
      daysOfTimePoint0.add(item.weekDays[0]);
    }
  }
  checkNum('靠前的时间点覆盖全部 5 天', daysOfTimePoint0.size, 5);

  // 折叠形态：3 条（3 个时间点），不超配额。
  const collapsed: ReminderPlan = collapsedOf(schoolWeek(), `${BASE_DAY}T07:00:00`, advance(0));
  checkNum('折叠形态 3 条', collapsed.items.length, 3);
  checkNum('折叠总条数', collapsed.collapsedCount, 3);
  checkNum('折叠后不丢条', collapsed.droppedCount, 0);
  checkNum('折叠形态星期一第一节覆盖 5 天', itemAt(collapsed.items, 0).weekDays.length, 5);

  // 预算为 0 时全丢，但计数仍如实报出。
  const zero: ReminderPlan = plan(schoolWeek(), `${BASE_DAY}T07:00:00`,
    ReminderMode.Specific, advance(0), 0);
  checkNum('预算 0 时没有条目', zero.items.length, 0);
  checkNum('预算 0 时丢 15 条', zero.droppedCount, 15);

  // 预算恰好等于条数时一条不丢。
  const exact: ReminderPlan = plan(schoolWeek(), `${BASE_DAY}T07:00:00`,
    ReminderMode.Specific, advance(0), 15);
  checkNum('预算等于条数时不丢', exact.droppedCount, 0);
  checkNum('预算等于条数时全排', exact.items.length, 15);

  // 真实场景：七天 × 12 节 = 84 条精确 > 30 条配额 → 折叠形态 12 条装得下。
  const wide: Profile = profileForDays([1, 2, 3, 4, 5, 6, 0], makeWideLayout(12));
  const wideSpecific: ReminderPlan = plan(wide, `${BASE_DAY}T07:00:00`,
    ReminderMode.Specific, advance(0), ReminderPlanner.QUOTA);
  checkNum('84 条精确提醒被截到配额', wideSpecific.items.length, ReminderPlanner.QUOTA);
  checkNum('84 条超出配额 54', wideSpecific.droppedCount, 84 - ReminderPlanner.QUOTA);
  checkNum('84 条精确计数如实报出', wideSpecific.specificCount, 84);
  const wideCollapsed: ReminderPlan = plan(wide, `${BASE_DAY}T07:00:00`,
    ReminderMode.Collapsed, advance(0), ReminderPlanner.QUOTA);
  checkNum('折叠后 12 条装得下', wideCollapsed.items.length, 12);
  checkNum('折叠形态不丢条', wideCollapsed.droppedCount, 0);
  checkNum('配额常量是 30', ReminderPlanner.QUOTA, 30);
}

/**
 * 造一张「一天 classCount 节课」的时间表：08:00 起，每节 40 分钟、课间 5 分钟。
 *
 * 时刻一律走 clock() 拼出规规矩矩的 HH:mm:ss。这里原来自己拼了 4 位小时
 * （'0815:00'），而 TimeSpanValue 的小时位是变长的，于是 '0815:00' 被读成
 * 815 小时 0 分 —— 一天的第 12 节课落在 815 小时后，触发时刻算出来是
 * 几十天后，整组断言在测一个不存在的课表却看着像通过了。
 */
function makeWideLayout(classCount: number): TimeLayout {
  const layout: TimeLayout = new TimeLayout();
  const out: TimeLayoutItem[] = [];
  const base: number = 8 * 3600;
  for (let i: number = 0; i < classCount; i++) {
    const start: number = base + i * 45 * 60;
    out.push(item(0, clock(start), clock(start + 40 * 60)));
    if (i < classCount - 1) {
      out.push(item(1, clock(start + 40 * 60), clock(start + 45 * 60)));
    }
  }
  layout.layouts = out;
  return layout;
}

function clock(seconds: number): string {
  const hours: number = Math.floor(seconds / 3600);
  const minutes: number = Math.floor((seconds % 3600) / 60);
  const hh: string = hours < 10 ? `0${hours}` : `${hours}`;
  const mm: string = minutes < 10 ? `0${minutes}` : `${minutes}`;
  return `${hh}:${mm}:00`;
}

function testCollapsedGrouping(): void {
  // 只有周一和周三有课：折叠后第一节应当覆盖两天。
  const profile: Profile = profileForDays([1, 3]);
  const collapsed: ReminderPlan = collapsedOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  checkNum('两天的 3 节课折叠成 3 条', collapsed.items.length, 3);
  checkEqual('第一节覆盖周一与周三', itemAt(collapsed.items, 0).weekDays.join(','), '1,3');
  check('折叠后 key 唯一', uniqueKeys(collapsed.items));

  // 折叠的 key 与星期几集合绑定：覆盖的天变了 key 就变，于是差异比对应重发。
  const profile2: Profile = profileForDays([1, 2]);
  const collapsed2: ReminderPlan = collapsedOf(profile2, `${BASE_DAY}T07:00:00`, advance(0));
  checkTrue('覆盖天不同则 key 不同',
    itemAt(collapsed.items, 0).key !== itemAt(collapsed2.items, 0).key);

  // 上课时刻变了 key 也要变，否则平台上的旧提醒会一直用旧时刻。
  const layout: TimeLayout = new TimeLayout();
  layout.layouts = [item(0, '08:30:00', '09:15:00')];
  const shifted: ReminderPlan = collapsedOf(profileForDays([1, 3], layout),
    `${BASE_DAY}T07:00:00`, advance(0));
  checkTrue('时刻不同则 key 不同',
    itemAt(collapsed.items, 0).key !== itemAt(shifted.items, 0).key);
}

// ------------------------------------------------------------------ D 口径转换

function testWeekDayConvention(): void {
  // 档案 .NET 口径 0=周日 … 6=周六。
  checkNum('周日 dayOfWeek 是 0', dt('2026-09-27').dayOfWeek(), 0);
  checkNum('周一 dayOfWeek 是 1', dt('2026-09-28').dayOfWeek(), 1);
  checkNum('周六 dayOfWeek 是 6', dt('2026-10-03').dayOfWeek(), 6);

  // 平台 1=周一 … 7=周日。全周日课表的一条提醒，平台侧必须是 7 而不是 0。
  const sundayOnly: ReminderPlan = specificOf(profileForDays([0]),
    `${BASE_DAY}T07:00:00`, advance(0));
  checkNum('周日课表 3 条', sundayOnly.items.length, 3);
  checkNum('档案侧记 0', itemAt(sundayOnly.items, 0).weekDays[0], 0);
  checkEqual('平台侧转成 7',
    ReminderPlanner.platformDaysOfWeek(itemAt(sundayOnly.items, 0).weekDays).join(','), '7');

  // 周一..周六在两套口径下同值，漏转换时看不出问题 —— 这正是要钉住的原因。
  const week: ReminderPlan = specificOf(schoolWeek(), `${BASE_DAY}T07:00:00`, advance(0));
  for (const item of week.items) {
    const platform: number[] = ReminderPlanner.platformDaysOfWeek(item.weekDays);
    checkEqual(`weekDay ${item.weekDays[0]} 转换后不变`,
      platform.join(','), `${item.weekDays[0]}`);
  }

  // 全覆盖七天 -> 平台 1..7。
  const all: ReminderPlan = collapsedOf(profileForDays([1, 2, 3, 4, 5, 6, 0], makeWideLayout(2)),
    `${BASE_DAY}T07:00:00`, advance(0));
  checkEqual('七天折叠后平台侧是 1..7',
    ReminderPlanner.platformDaysOfWeek(itemAt(all.items, 0).weekDays).join(','), '1,2,3,4,5,6,7');

  // 去重且升序；越界值被丢掉。
  checkEqual('去重', ReminderPlanner.platformDaysOfWeek([1, 1, 3]).join(','), '1,3');
  checkEqual('周日去重后只有一个 7',
    ReminderPlanner.platformDaysOfWeek([0, 0]).join(','), '7');
  checkEqual('升序', ReminderPlanner.platformDaysOfWeek([6, 1, 0]).join(','), '1,6,7');
  checkEqual('越界丢弃', ReminderPlanner.platformDaysOfWeek([7, 8, -1]).join(','), '');
  checkEqual('空输入', ReminderPlanner.platformDaysOfWeek([]).join(','), '');
}

// ------------------------------------------------------------------ E 差异比对

function snapshotOf(id: number, item: ReminderPlanItem): ReminderSnapshot {
  const out: ReminderSnapshot = new ReminderSnapshot();
  out.reminderId = id;
  out.key = item.key;
  out.triggerYear = item.trigger.year;
  out.triggerMonth = item.trigger.month;
  out.triggerDay = item.trigger.day;
  out.title = item.title;
  out.content = item.content;
  return out;
}

function testDiff(): void {
  const profile: Profile = schoolWeek();
  const p: ReminderPlan = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));

  // 平台上一条都没有 -> 全新建。
  let diff: ReminderDiff = ReminderPlanner.diff(p, [], dt(`${BASE_DAY}T07:00:00`));
  checkNum('首次全新建', diff.toAdd.length, 15);
  checkNum('首次无更新', diff.toRefresh.length, 0);
  checkNum('首次无取消', diff.toCancel.length, 0);

  // 平台已完全一致 -> 什么都不做（额度不能白白消耗）。
  const same: ReminderSnapshot[] = [];
  for (let i: number = 0; i < p.items.length; i++) {
    same.push(snapshotOf(i + 1, itemAt(p.items, i)));
  }
  diff = ReminderPlanner.diff(p, same, dt(`${BASE_DAY}T07:00:00`));
  checkNum('一致时不新建', diff.toAdd.length, 0);
  checkNum('一致时不更新', diff.toRefresh.length, 0);
  checkNum('一致时不取消', diff.toCancel.length, 0);

  // 平台上有、计划里没有的 -> 取消。
  const extra: ReminderSnapshot[] = same.concat([snapshotOf(999, itemAt(p.items, 0))]);
  const stale: ReminderSnapshot = new ReminderSnapshot();
  stale.reminderId = 888;
  stale.key = 'stale-key';
  extra.push(stale);
  diff = ReminderPlanner.diff(p, extra, dt(`${BASE_DAY}T07:00:00`));
  checkNum('多余的一条被取消', diff.toCancel.length, 1);
  checkNum('取消的是那条多余的', diff.toCancel[0], 888);

  // groupId 为空（不是我们排的）-> 也取消，否则它永远没人更新。
  const foreign: ReminderSnapshot = new ReminderSnapshot();
  foreign.reminderId = 777;
  foreign.key = '';
  diff = ReminderPlanner.diff(p, [foreign], dt(`${BASE_DAY}T07:00:00`));
  checkNum('无主提醒被取消', diff.toCancel.length, 1);
  checkNum('无主提醒的 id', diff.toCancel[0], 777);

  // key 对上但内容变了 -> 更新（同一时刻改了科目）。
  const edited: ReminderPlan = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  (profile.subjects.tryGet(SUBJECT_YUWEN) as Subject).teacherName = '吴';
  profile.refreshDerivedState();
  const editedPlan: ReminderPlan = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  checkTrue('内容变了 key 不变（key 只含身份与时刻）',
    itemAt(p.items, 0).key === itemAt(editedPlan.items, 0).key);
  const beforeContent: string = itemAt(edited.items, 0).content;
  const afterContent: string = itemAt(editedPlan.items, 0).content;
  checkTrue('正文确实变了', beforeContent !== afterContent);
  const editedSnapshots: ReminderSnapshot[] = [];
  for (let i: number = 0; i < edited.items.length; i++) {
    editedSnapshots.push(snapshotOf(i + 1, itemAt(edited.items, i)));
  }
  diff = ReminderPlanner.diff(editedPlan, editedSnapshots, dt(`${BASE_DAY}T07:00:00`));
  // 只有用这个科目的那节课受影响 = 每天第 1 节 = 5 条，另外 10 条不该被动。
  checkNum('内容变了只更新受影响的', diff.toRefresh.length, 5);
  checkNum('内容变了不新建', diff.toAdd.length, 0);
  checkNum('内容变了不取消', diff.toCancel.length, 0);
  // 这条用例的提前量是 0，所以正文是「现在上课」而不是「几点上课」。
  checkEqual('更新后的正文是新老师', afterContent, '现在上课：语文，吴老师');
  (profile.subjects.tryGet(SUBJECT_YUWEN) as Subject).teacherName = '王';
  profile.refreshDerivedState();

  // 起始日已过 -> 更新，把首次触发日往后续。
  const staleDate: ReminderSnapshot[] = [];
  for (let i: number = 0; i < p.items.length; i++) {
    const snap: ReminderSnapshot = snapshotOf(i + 1, itemAt(p.items, i));
    snap.triggerYear = 2020;
    staleDate.push(snap);
  }
  diff = ReminderPlanner.diff(p, staleDate, dt('2026-09-28T09:00:00'));
  checkNum('起始日过期的要更新', diff.toRefresh.length, 15);
  checkNum('起始日过期的不新建', diff.toAdd.length, 0);

  // 起始日只在同一天内变化 -> 不更新。平台可能把秒归零，逐字段比对会永远判定
  // 不一样，于是每次同步都重发一遍，额度白耗。
  const sameDay: ReminderSnapshot[] = [];
  for (let i: number = 0; i < p.items.length; i++) {
    const snap: ReminderSnapshot = snapshotOf(i + 1, itemAt(p.items, i));
    snap.triggerYear = 2026;
    sameDay.push(snap);
  }
  diff = ReminderPlanner.diff(p, sameDay, dt('2026-09-26T12:00:00'));
  checkNum('同年不因日期更新', diff.toRefresh.length, 0);

  // 计划里少一条 -> 那条被取消。
  // 形态从精确切到折叠：key 必然全变（key 前缀 s / c 不同），于是 15 条全取消、
  // 3 条全新建。这不是浪费而是必须的：折叠形态的 daysOfWeek 与正文都不同，沿用旧的
  // 精确提醒只会得到「周一声称语文、周二到周五也声称语文」。
  const fewer: ReminderPlan = collapsedOf(profile, `${BASE_DAY}T07:00:00`, advance(0));
  diff = ReminderPlanner.diff(fewer, same, dt(`${BASE_DAY}T07:00:00`));
  checkNum('形态切换后旧的 15 条全取消', diff.toCancel.length, 15);
  checkNum('形态切换后新建 3 条', diff.toAdd.length, 3);
  checkNum('形态切换不更新', diff.toRefresh.length, 0);
}

// ------------------------------------------------------------------ F 单双周

function testRotation(): void {
  const profile: Profile = schoolWeek();
  (profile.classPlans.tryGet(planKey(1)) as ClassPlan).timeRule.weekCountDiv = 1;
  const p: ReminderPlan = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(0));

  checkTrue('单双周要标记出来', p.hasRotation);
  checkNum('单双周仍然排提醒', p.items.length, 15);
  // 平台 daysOfWeek 表达不了隔周，所以周一那条会在每个周一都提醒。
  // 界面上据实告知，不静默丢弃，也不假装只隔周。
  check('单双周的周一那条照排', findByWeekDay(p.items, 1, 0) !== undefined);

  // 全每周时不该标记。
  const plain: ReminderPlan = specificOf(schoolWeek(), `${BASE_DAY}T07:00:00`, advance(0));
  check('无轮转时不标记', !plain.hasRotation);
}

// ------------------------------------------------------------------ G 纯度与确定性

function stringifyPlan(p: ReminderPlan): string {
  const parts: string[] = [];
  for (const item of p.items) {
    parts.push(`${item.key}|${item.trigger.toString()}|${item.weekDays.join(',')}|` +
      `${item.title}|${item.content}`);
  }
  return parts.join('##');
}

function testPurityAndDeterminism(): void {
  const profile: Profile = schoolWeek();
  const first: ReminderPlan = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(300));
  const second: ReminderPlan = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(300));
  checkEqual('同输入同输出', stringifyPlan(first), stringifyPlan(second));

  // 纯度：编排不改档案。
  const before: string = Profile.stringify(profile);
  specificOf(profile, `${BASE_DAY}T07:00:00`, advance(300));
  collapsedOf(profile, `${BASE_DAY}T07:00:00`, advance(300));
  plan(profile, `${BASE_DAY}T07:00:00`, ReminderMode.Specific, advance(300), 3);
  checkEqual('编排不改档案', Profile.stringify(profile), before);

  // 档案载入顺序不同 -> key 集合相同（排序稳定，不因顺序抖动而重发）。
  const reordered: Profile = new Profile();
  reordered.name = profile.name;
  reordered.timeLayouts.set(LAYOUT_ID, standardLayout());
  reordered.selectedClassPlanGroupId = profile.selectedClassPlanGroupId;
  // 按真 key 搬，不能拿科目名当键：tryGetSubject 是拿档案里的 subjectId 去查的，
  // 键对不上就全成悬空指针，结果是「重建后一条提醒都没有」。
  profile.subjects.forEach((subject: Subject, key: string) => {
    reordered.subjects.set(key, subject);
  });
  const keys: string[] = [];
  profile.classPlans.forEach((planValue: ClassPlan, key: string) => {
    const classes: ClassInfo[] = planValue.classes.map((info: ClassInfo): ClassInfo => {
      const copy: ClassInfo = new ClassInfo();
      copy.subjectId = info.subjectId;
      copy.isEnabled = info.isEnabled;
      return copy;
    });
    const next: ClassPlan = new ClassPlan();
    next.name = planValue.name;
    next.timeLayoutId = Guid.fromCanonical(LAYOUT_ID);
    const rule: TimeRule = new TimeRule();
    rule.weekDay = planValue.timeRule.weekDay;
    rule.weekCountDiv = 0;
    rule.weekCountDivTotal = 2;
    next.timeRule = rule;
    next.classes = classes;
    keys.push(key);
    reordered.classPlans.set(key, next);
  });
  reordered.refreshDerivedState();
  const original: ReminderPlan = specificOf(profile, `${BASE_DAY}T07:00:00`, advance(300));
  const rebuilt: ReminderPlan = specificOf(reordered, `${BASE_DAY}T07:00:00`, advance(300));
  checkEqual('重建档案后条目数一致', String(rebuilt.items.length),
    String(original.items.length));
  const originalKeys: string[] = original.keys();
  const rebuiltKeys: string[] = rebuilt.keys();
  originalKeys.sort();
  rebuiltKeys.sort();
  checkEqual('重建档案后 key 集合一致', rebuiltKeys.join(','), originalKeys.join(','));

  // 空档案不炸，且不排任何提醒。
  const empty: Profile = new Profile();
  const none: ReminderPlan = specificOf(empty, `${BASE_DAY}T07:00:00`, advance(0));
  checkNum('空档案不排', none.items.length, 0);
  checkNum('空档案也不丢', none.droppedCount, 0);

  // 时间表里一个课都没有 -> 不排。
  const bare: Profile = profileForDays([1], new TimeLayout());
  checkNum('空时间表不排',
    specificOf(bare, `${BASE_DAY}T07:00:00`, advance(0)).items.length, 0);
}

// ------------------------------------------------------------------ 入口

testBasicPlanning();
testSkippedSlots();
testPlanFiltering();
testTriggerTime();
testCrossMidnight();
testOutdoorAdvance();
testTextContent();
testQuotaDegradation();
testCollapsedGrouping();
testWeekDayConvention();
testDiff();
testRotation();
testPurityAndDeterminism();

console.log(`提醒 通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('');
  for (const failure of failures) {
    console.log(`✗ ${failure}`);
  }
  process.exit(1);
}
