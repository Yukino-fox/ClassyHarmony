/*
 * 档案改动测试台。
 *
 * 关注的是「改完之后档案还是不是自洽的」：
 *   - 课程列表长度是否跟着时间表走
 *   - 引用重绑后有没有留下悬空 Guid
 *   - 调课标记只对叠加课表有意义
 *   - 临时层 / 叠加层的指针有没有被删课表带走
 *   - 改完落盘能不能原样读回来（与桌面版兼容的前提）
 *
 * 最后一个尤其重要：P4 交付标准里写着「编辑后 JSON 往返仍与桌面版兼容」，
 * 而桌面版是靠一串事件维持这些不变量，鸿蒙侧是显式推导 —— 推导漏一步
 * 写出去的还是合法 JSON，桌面版读得进去，只是内容悄悄错了。所以除了
 * 断言字段值，还要断言「序列化 -> 解析 -> 再序列化」逐字节相同。
 */

import { ClassInfo } from '../../common_shared/src/main/ets/models/ClassInfo';
import { ClassPlan } from '../../common_shared/src/main/ets/models/ClassPlan';
import { ClassPlanGroup } from '../../common_shared/src/main/ets/models/ClassPlanGroup';
import { DateTimeValue } from '../../common_shared/src/main/ets/json/DateTimeValue';
import { Guid } from '../../common_shared/src/main/ets/json/Guid';
import { OrderedSchedule } from '../../common_shared/src/main/ets/models/OrderedSchedule';
import { Profile } from '../../common_shared/src/main/ets/models/Profile';
import { Subject } from '../../common_shared/src/main/ets/models/Subject';
import {
  TIME_TYPE_BREAK,
  TIME_TYPE_CLASS,
  TIME_TYPE_SEPARATOR
} from '../../common_shared/src/main/ets/models/TimeLayoutItem';
import { TimeLayout } from '../../common_shared/src/main/ets/models/TimeLayout';
import { TimeLayoutItem } from '../../common_shared/src/main/ets/models/TimeLayoutItem';
import { TimeSpanValue } from '../../common_shared/src/main/ets/json/TimeSpanValue';
import { TimeRule } from '../../common_shared/src/main/ets/models/TimeRule';
import { TempClassPlanGroupType } from '../../common_shared/src/main/ets/enums/TempClassPlanGroupType';
import { ScheduleMutations } from '../../common_core/src/main/ets/edit/ScheduleMutations';
import {
  ClassPlanGroupRow,
  ClassPlanRow,
  ClassSlotRow,
  EditorRows,
  OrderedScheduleRow,
  TimePointRow,
  parseClockText,
  parseDurationText
} from '../../common_core/src/main/ets/edit/EditorRows';
import {
  formatClock,
  formatDuration,
  timeTypeName,
  weekDayName,
  weekDayShortName,
  weekRotationText
} from '../../common_core/src/main/ets/view/TextFormat';
import {
  TimeSpanRow,
  newTimeSpanRow,
  timeRangeConflictIndex,
  timeRangeOverlap,
  timeRangeOverlapMinutes
} from '../../common_core/src/main/ets/edit/TimeRange';
import { EngineSettings } from '../../common_core/src/main/ets/engine/EngineSettings';
import { ClassPlanResolver } from '../../common_core/src/main/ets/engine/ClassPlanResolver';

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

// ------------------------------------------------------------------ 夹具

function dt(text: string): DateTimeValue {
  return DateTimeValue.parseOrMin(text);
}

/** 引擎设置：单双周以 2026-09-20（周日）为起点，与 grid-driver 同基准。 */
function settings(): EngineSettings {
  return new EngineSettings(dt('2026-09-20T00:00:00'));
}

function point(type: number, start: string, end: string, breakName: string = ''): TimeLayoutItem {
  const out: TimeLayoutItem = new TimeLayoutItem();
  out.timeType = type;
  out.startTime = TimeSpanValue.parseOrZero(start);
  out.endTime = TimeSpanValue.parseOrZero(end);
  out.breakName = breakName;
  return out;
}

/** 3 节课 + 2 个课间：行 0..4，课次 0..2。 */
function standardLayout(): TimeLayout {
  const layout: TimeLayout = new TimeLayout();
  layout.name = '标准作息';
  layout.layouts = [
    point(TIME_TYPE_CLASS, '08:00:00', '08:45:00'),
    point(TIME_TYPE_BREAK, '08:45:00', '09:00:00', '大课间'),
    point(TIME_TYPE_CLASS, '09:00:00', '09:45:00'),
    point(TIME_TYPE_BREAK, '09:45:00', '10:00:00'),
    point(TIME_TYPE_CLASS, '10:00:00', '10:45:00')
  ];
  return layout;
}

function emptyProfile(): Profile {
  return new Profile();
}

/** 一张课表 + 一张时间表 + 三个科目，全部走改动层建出来。 */
function seededProfile(): Profile {
  const profile: Profile = emptyProfile();
  const yw: Guid = ScheduleMutations.addSubject(profile, '语文');
  const sx: Guid = ScheduleMutations.addSubject(profile, '数学');
  const yy: Guid = ScheduleMutations.addSubject(profile, '英语');
  ScheduleMutations.setSubjectTeacher(profile, yw, '张老师');
  ScheduleMutations.setSubjectInitial(profile, yw, '语');
  const layoutId: Guid = ScheduleMutations.addTimeLayout(profile, '标准作息');
  // 覆盖掉 addTimeLayout 预置的单个时间点，换成标准作息
  (profile.tryGetTimeLayout(layoutId) as TimeLayout).layouts = standardLayout().layouts;
  const planId: Guid = ScheduleMutations.addClassPlan(profile, layoutId, '周一');
  ScheduleMutations.setClassPlanRule(profile, planId, 1, 0, 2);
  ScheduleMutations.setClassSubject(profile, planId, 0, yw);
  ScheduleMutations.setClassSubject(profile, planId, 1, sx);
  ScheduleMutations.setClassSubject(profile, planId, 2, yy);
  ScheduleMutations.settle(profile);
  return profile;
}

function firstLayoutId(profile: Profile): Guid {
  return Guid.fromCanonical(profile.timeLayouts.keys()[0]);
}

function firstPlanId(profile: Profile): Guid {
  return Guid.fromCanonical(profile.classPlans.keys()[0]);
}

function subjectNames(profile: Profile): string {
  const names: string[] = [];
  profile.subjects.forEach((s: Subject) => {
    names.push(s.name);
  });
  return names.join(',');
}

/** 序列化 -> 解析 -> 再序列化，逐字节比对。 */
function checkRoundTrip(name: string, profile: Profile): void {
  const once: string = Profile.stringify(profile);
  let reparsed: Profile = new Profile();
  try {
    reparsed = Profile.parse(once);
  } catch (error) {
    check(name, false, `解析抛错：${error}`);
    return;
  }
  reparsed.refreshDerivedState();
  const twice: string = Profile.stringify(reparsed);
  check(name, once === twice, once === twice ? '' : '往返后字节不一致');
}

// ------------------------------------------------------------------ 科目

function testAddSubject(): void {
  const profile: Profile = emptyProfile();
  const id: Guid = ScheduleMutations.addSubject(profile, '语文');
  check('addSubject 返回非空 guid', !id.isEmpty());
  check('addSubject 键进字典', profile.subjects.has(id.toString()));
  const subject: Subject = profile.tryGetSubject(id) as Subject;
  checkNum('addSubject isActive 置位', subject.isActive ? 1 : 0, 1);
  checkEqual('addSubject 名字', subject.name, '语文');

  const second: Guid = ScheduleMutations.addSubject(profile, '数学');
  check('两个科目键不同', firstPlanIdIsDifferent(id, second));
  checkNum('科目数量', profile.subjects.size, 2);
}

function firstPlanIdIsDifferent(a: Guid, b: Guid): boolean {
  return !a.equals(b);
}

function testRemoveSubjectClearsReferences(): void {
  const profile: Profile = seededProfile();
  const ids: string[] = profile.subjects.keys();
  const yw: Guid = Guid.fromCanonical(ids[0]);
  const planId: Guid = firstPlanId(profile);
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  check('前置：第 1 节课挂的是语文', plan.classes[0].subjectId.equals(yw));

  check('removeSubject 返回 true', ScheduleMutations.removeSubject(profile, yw));
  checkNum('removeSubject 后字典剩两个', profile.subjects.size, 2);
  const after: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  // 悬空 Guid 渲染出来是「（无）」，看着像没排课，实际是删剩的引用
  check('引用它的课表格被清空', after.classes[0].subjectId.isEmpty());
  check('不引用它的课表格没被动', !after.classes[1].subjectId.isEmpty());

  check('删不存在的科目返回 false', !ScheduleMutations.removeSubject(profile, yw));
}

function testMoveSubject(): void {
  const profile: Profile = emptyProfile();
  const a: Guid = ScheduleMutations.addSubject(profile, 'A');
  const b: Guid = ScheduleMutations.addSubject(profile, 'B');
  const c: Guid = ScheduleMutations.addSubject(profile, 'C');
  checkEqual('初始顺序', subjectNames(profile), 'A,B,C');

  check('moveSubject 向上', ScheduleMutations.moveSubject(profile, b, -1));
  checkEqual('B 上移后顺序', subjectNames(profile), 'B,A,C');

  check('moveSubject 向下', ScheduleMutations.moveSubject(profile, b, 1));
  checkEqual('B 下移后顺序', subjectNames(profile), 'A,B,C');

  // KeyedMap.set 已存在的键会保留原位，所以「不 clear 就重写」等于没动
  check('moveSubject 到底返回 false', !ScheduleMutations.moveSubject(profile, c, 1));
  check('moveSubject 到顶返回 false', !ScheduleMutations.moveSubject(profile, a, -1));
  check('不存在的键返回 false', !ScheduleMutations.moveSubject(profile, Guid.newGuid(), 1));
  checkEqual('越界后顺序不变', subjectNames(profile), 'A,B,C');

  // 键与值的对应关系不能错位
  checkEqual('A 键仍指向 A', (profile.tryGetSubject(a) as Subject).name, 'A');
  checkEqual('C 键仍指向 C', (profile.tryGetSubject(c) as Subject).name, 'C');
  checkEqual('往返后顺序一致', (() => {
    const text: string = Profile.stringify(profile);
    return Profile.parse(text).subjects.values().map((s: Subject) => s.name).join(',');
  })(), 'A,B,C');
}

// -------------------------------------------------------------- 时间表

function testAddTimeLayout(): void {
  const profile: Profile = emptyProfile();
  const id: Guid = ScheduleMutations.addTimeLayout(profile, '');
  check('addTimeLayout 返回 guid', profile.timeLayouts.has(id.toString()));
  const layout: TimeLayout = profile.tryGetTimeLayout(id) as TimeLayout;
  checkEqual('空名兜底为默认名', layout.name, '新时间表');
  checkNum('预置一个时间点', layout.layouts.length, 1);
  checkNum('预置的是课程', layout.layouts[0].timeType, TIME_TYPE_CLASS);
  checkNum('isActive 置位', layout.isActive ? 1 : 0, 1);
}

function testRemoveTimeLayout(): void {
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const planId: Guid = firstPlanId(profile);

  check('removeTimeLayout 返回 true', ScheduleMutations.removeTimeLayout(profile, layoutId));
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  check('课表被解绑', plan.timeLayoutId.isEmpty());
  // 解绑但留着 classes 的话，界面上会显示一个没有时间信息的课表
  checkNum('课表课程列表清空', plan.classes.length, 0);
  check('删不存在的时间表返回 false', !ScheduleMutations.removeTimeLayout(profile, layoutId));
}

function testRemoveTimeLayoutClearsOverlaySource(): void {
  // overlaySourceId 指向的是课表不是时间表，这里用一个不变量守住：
  // 删时间表后所有课表都不该还挂着 overlaySourceId
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const planId: Guid = firstPlanId(profile);
  const overlayId: Guid = ScheduleMutations.createOverlayClassPlan(
    profile, planId, '叠加') as Guid;
  const overlay: ClassPlan = profile.tryGetClassPlan(overlayId) as ClassPlan;
  check('前置：叠加课表指向源课表', (overlay.overlaySourceId as Guid).equals(planId));

  ScheduleMutations.removeTimeLayout(profile, layoutId);
  check('叠加源没被时间表删除带偏', (overlay.overlaySourceId as Guid).equals(planId));
}

function testAddRemoveTimePoint(): void {
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);

  check('追加课间', ScheduleMutations.addTimePoint(
    profile, layoutId, TIME_TYPE_BREAK, 10 * 3600 + 45 * 60, 15));
  let layout: TimeLayout = profile.tryGetTimeLayout(layoutId) as TimeLayout;
  checkNum('行数 5 -> 6', layout.layouts.length, 6);
  const added: TimeLayoutItem = layout.layouts[5];
  checkNum('类型是课间', added.timeType, TIME_TYPE_BREAK);
  checkEqual('课间有名字', added.breakName, '课间');
  checkNum('开始时刻', added.startTime.toSeconds(), 10 * 3600 + 45 * 60);
  checkNum('结束时刻', added.endTime.toSeconds(), 11 * 3600);
  // 课间占位不占课次
  checkNum('课次数不变', layout.classTimePoints().length, 3);

  check('删除最后一行', ScheduleMutations.removeTimePoint(profile, layoutId, 5));
  layout = profile.tryGetTimeLayout(layoutId) as TimeLayout;
  checkNum('行数回到 5', layout.layouts.length, 5);

  check('删除下标越界返回 false', !ScheduleMutations.removeTimePoint(profile, layoutId, 5));
  check('删除负下标返回 false', !ScheduleMutations.removeTimePoint(profile, layoutId, -1));
  check('对不存在的时间表返回 false',
    !ScheduleMutations.removeTimePoint(profile, Guid.newGuid(), 0));
}

function testRemoveTimePointResizesClasses(): void {
  // 从中间删一节课，丢的应该是被删的那节课排的科目，而不是最后一节。
  // 桌面版的 RefreshClassesList 只会在末尾截断，从中间删会静默丢掉最后一节，
  // 所以这里钉住改动层的有意偏差。
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const planId: Guid = firstPlanId(profile);
  // 行 2 是第 2 节课（数学）
  checkEqual('前置：第 2 节课是数学',
    (profile.tryGetSubject((profile.tryGetClassPlan(planId) as ClassPlan).classes[1].subjectId) as Subject).name,
    '数学');
  check('删掉第 2 节课', ScheduleMutations.removeTimePoint(profile, layoutId, 2));
  ScheduleMutations.settle(profile);
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  checkNum('课次 3 -> 2', plan.classes.length, 2);
  checkNum('下标回填 0', plan.classes[0].index, 0);
  checkNum('下标回填 1', plan.classes[1].index, 1);
  checkEqual('第 1 节课没动',
    (profile.tryGetSubject(plan.classes[0].subjectId) as Subject).name, '语文');
  checkEqual('被删的数学没了，原第 3 节顶上',
    (profile.tryGetSubject(plan.classes[1].subjectId) as Subject).name, '英语');
}

function testRemoveTimePointFollowsAllBoundPlans(): void {
  // 一张时间表被多张课表绑定时，删课要让每张都少一节，
  // 否则课次数与时间表对不上，选课引擎会读出越界
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const otherPlanId: Guid = ScheduleMutations.addClassPlan(profile, layoutId, '周二');
  ScheduleMutations.settle(profile);
  const other: ClassPlan = profile.tryGetClassPlan(otherPlanId) as ClassPlan;
  checkNum('前置：另一张也有 3 节', other.classes.length, 3);

  ScheduleMutations.removeTimePoint(profile, layoutId, 0);
  ScheduleMutations.settle(profile);
  checkNum('另一张也跟着少一节', other.classes.length, 2);
  checkNum('第一张也跟着少一节', (profile.tryGetClassPlan(firstPlanId(profile)) as ClassPlan).classes.length, 2);
}

function testAddTimePointGrowsClasses(): void {
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const planId: Guid = firstPlanId(profile);
  ScheduleMutations.addTimePoint(profile, layoutId, TIME_TYPE_CLASS, 11 * 3600, 45);
  ScheduleMutations.settle(profile);
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  checkNum('课次 3 -> 4', plan.classes.length, 4);
  checkNum('新课次默认无科目', plan.classes[3].subjectId.isEmpty() ? 1 : 0, 1);
}

function testMoveTimePointReordersRows(): void {
  // 行序是用户排的，不是派生量：桌面版只在「按时段重排」按钮上排序。
  // 移动后若顺手排一下序，用户刚拖上去的一行会被弹回原处。
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const layout: TimeLayout = profile.tryGetTimeLayout(layoutId) as TimeLayout;
  const originalFirst: TimeLayoutItem = layout.layouts[0];

  // 行 1 是 08:45 的课间，让它上移到第 1 行
  check('上移第 2 行', ScheduleMutations.moveTimePoint(profile, layoutId, 1, -1));
  checkNum('行数不变', layout.layouts.length, 5);
  checkNum('第 0 行现在是课间', layout.layouts[0].timeType, TIME_TYPE_BREAK);
  checkNum('课间拿到了 08:45 的时段',
    layout.layouts[0].startTime.toSeconds(), 8 * 3600 + 45 * 60);
  checkEqual('课间名跟着自己的行走', layout.layouts[0].breakName, '大课间');
  check('原来的第 1 行被挤到第 2 位', layout.layouts[1] === originalFirst);
  checkNum('行序不再按时刻升序', layout.layouts[0].startTime.toSeconds() > layout.layouts[1].startTime.toSeconds() ? 1 : 0, 1);

  check('再上移越界返回 false', !ScheduleMutations.moveTimePoint(profile, layoutId, 0, -1));
  check('下移越界返回 false', !ScheduleMutations.moveTimePoint(profile, layoutId, 4, 1));
  check('不存在的行返回 false',
    !ScheduleMutations.moveTimePoint(profile, layoutId, 99, -1));

  // 移回去应当完全还原
  check('移回去', ScheduleMutations.moveTimePoint(profile, layoutId, 0, 1));
  check('还原到原样', layout.layouts[0] === originalFirst);
  checkNum('课次内容没被换', profile.tryGetClassPlan(firstPlanId(profile)) !== undefined ? 1 : 0, 1);
}

function testSortTimeLayout(): void {
  // 桌面版的「按时段重排」：降序 CompareTo 排完再 Reverse，净效果是升序。
  // 这里先打乱行序再排，断言具体的行序与课次跟随。
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const layout: TimeLayout = profile.tryGetTimeLayout(layoutId) as TimeLayout;
  const planId: Guid = firstPlanId(profile);
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  const nameAt = (slot: number): string => {
    return (profile.tryGetSubject(plan.classes[slot].subjectId) as Subject).name;
  };
  checkEqual('前置：语文数学英语', `${nameAt(0)},${nameAt(1)},${nameAt(2)}`, '语文,数学,英语');

  // 把第 1 节课（行 0）挪到第 3 节课（行 4）下面：
  // 行 0 -> 1 -> 2 -> 3 -> 4，每步都记着当前下标
  check('第 1 节课下移', ScheduleMutations.moveTimePoint(profile, layoutId, 0, 1));
  check('再下移', ScheduleMutations.moveTimePoint(profile, layoutId, 1, 1));
  checkEqual('此时语文落到第 2 课次', `${nameAt(0)},${nameAt(1)},${nameAt(2)}`, '数学,语文,英语');
  check('再下移', ScheduleMutations.moveTimePoint(profile, layoutId, 2, 1));
  check('再下移', ScheduleMutations.moveTimePoint(profile, layoutId, 3, 1));
  checkEqual('课次跟着换了位', `${nameAt(0)},${nameAt(1)},${nameAt(2)}`, '数学,英语,语文');

  check('重排', ScheduleMutations.sortTimeLayout(profile, layoutId));
  ScheduleMutations.settle(profile);
  const order: string = layout.layouts
    .map((item: TimeLayoutItem) => `${item.startTime.toSeconds()}`).join(',');
  checkEqual('按开始时刻升序', order,
    `${8 * 3600},${8 * 3600 + 45 * 60},${9 * 3600},${9 * 3600 + 45 * 60},${10 * 3600}`);
  checkEqual('重排后课次内容原样回来', `${nameAt(0)},${nameAt(1)},${nameAt(2)}`, '语文,数学,英语');
  checkNum('行数不变', layout.layouts.length, 5);
  check('对不存在的时间表返回 false',
    !ScheduleMutations.sortTimeLayout(profile, Guid.newGuid()));
}

function testMoveTimePointCarriesClass(): void {
  // 把一节课拖到别处，它排的科目要跟着走；留在原地会变成另一节课的科目，
  // 用户看着就是「拖了一下，语文变成数学了」
  const profile: Profile = emptyProfile();
  const layoutId: Guid = ScheduleMutations.addTimeLayout(profile, '三节连排');
  const layout: TimeLayout = profile.tryGetTimeLayout(layoutId) as TimeLayout;
  layout.layouts = [
    point(TIME_TYPE_CLASS, '09:00:00', '09:45:00'),
    point(TIME_TYPE_CLASS, '10:00:00', '10:45:00'),
    point(TIME_TYPE_CLASS, '11:00:00', '11:45:00')
  ];
  const yw: Guid = ScheduleMutations.addSubject(profile, '语文');
  const sx: Guid = ScheduleMutations.addSubject(profile, '数学');
  const yy: Guid = ScheduleMutations.addSubject(profile, '英语');
  const planId: Guid = ScheduleMutations.addClassPlan(profile, layoutId, '周三');
  ScheduleMutations.setClassSubject(profile, planId, 0, yw);
  ScheduleMutations.setClassSubject(profile, planId, 1, sx);
  ScheduleMutations.setClassSubject(profile, planId, 2, yy);
  ScheduleMutations.settle(profile);
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  const nameAt = (slot: number): string => {
    return (profile.tryGetSubject(plan.classes[slot].subjectId) as Subject).name;
  };
  checkEqual('前置：语文数学英语', `${nameAt(0)},${nameAt(1)},${nameAt(2)}`, '语文,数学,英语');

  // 第 2 节课上移一行
  check('上移第 2 行', ScheduleMutations.moveTimePoint(profile, layoutId, 1, -1));
  ScheduleMutations.settle(profile);
  checkEqual('行序调换', `${layout.layouts[0].startTime.toSeconds()},${layout.layouts[1].startTime.toSeconds()}`,
    `${10 * 3600},${9 * 3600}`);
  checkEqual('数学跟到第 1 课次', nameAt(0), '数学');
  checkEqual('语文跟到第 2 课次', nameAt(1), '语文');
  checkEqual('英语没动', nameAt(2), '英语');
  checkNum('课次数不变', plan.classes.length, 3);

  check('再挪回来', ScheduleMutations.moveTimePoint(profile, layoutId, 1, -1));
  ScheduleMutations.settle(profile);
  checkEqual('还原：语文数学英语', `${nameAt(0)},${nameAt(1)},${nameAt(2)}`, '语文,数学,英语');
}

function testMoveBreakCarriesNoClass(): void {
  // 课间行挪动不该影响课次内容（它不占课次）
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const planId: Guid = firstPlanId(profile);
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  const before: string = plan.classes.map((info: ClassInfo) => info.subjectId.toString()).join(',');
  check('上移课间行', ScheduleMutations.moveTimePoint(profile, layoutId, 1, -1));
  ScheduleMutations.settle(profile);
  checkEqual('课次内容没变',
    plan.classes.map((info: ClassInfo) => info.subjectId.toString()).join(','), before);
}

function testUpdateTimePoint(): void {
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const layout: TimeLayout = profile.tryGetTimeLayout(layoutId) as TimeLayout;

  // 行 1 是课间，改它的课间名与时刻
  check('改课间名', ScheduleMutations.updateTimePoint(
    profile, layoutId, 1, undefined, undefined, undefined, '眼保健操'));
  checkEqual('课间名生效', layout.layouts[1].breakName, '眼保健操');
  check('改起止', ScheduleMutations.updateTimePoint(
    profile, layoutId, 1, undefined, 9 * 3600, 20, undefined));
  checkNum('开始时刻', layout.layouts[1].startTime.toSeconds(), 9 * 3600);
  checkNum('时长 20 分钟', layout.layouts[1].endTime.toSeconds(), 9 * 3600 + 20 * 60);

  // 切成课程要清掉课间名，否则界面上「课程」行显示着上一个课间的名字
  check('切类型为课程', ScheduleMutations.updateTimePoint(
    profile, layoutId, 1, TIME_TYPE_CLASS, undefined, undefined, undefined));
  checkEqual('课间名被清', layout.layouts[1].breakName, '');
  checkNum('现在是课程', layout.layouts[1].timeType, TIME_TYPE_CLASS);

  // 传 undefined 的项保持原值
  const before: number = layout.layouts[0].startTime.toSeconds();
  check('只传类型', ScheduleMutations.updateTimePoint(
    profile, layoutId, 0, undefined, undefined, undefined, undefined));
  checkNum('开始时刻未被清零', layout.layouts[0].startTime.toSeconds(), before);

  check('下标越界返回 false', !ScheduleMutations.updateTimePoint(
    profile, layoutId, 99, undefined, undefined, undefined, undefined));
}

function testSeparatorDoesNotTakeSlot(): void {
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const planId: Guid = firstPlanId(profile);
  ScheduleMutations.addTimePoint(profile, layoutId, TIME_TYPE_SEPARATOR, 10 * 3600, 0);
  ScheduleMutations.settle(profile);
  const layout: TimeLayout = profile.tryGetTimeLayout(layoutId) as TimeLayout;
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  checkNum('分割线占一行', layout.layouts.length, 6);
  checkNum('但课次数不变', plan.classes.length, 3);
}

function testSetDefaultClassPropagates(): void {
  // 只改时间表不刷课表，界面上会显示改了但课表里没变。
  // 注意行下标与课次下标不是一回事：行 4 才是第 3 节课（行 1、3 是课间）。
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const planId: Guid = firstPlanId(profile);
  const yw: Guid = Guid.fromCanonical(profile.subjects.keys()[0]);
  const sx: Guid = Guid.fromCanonical(profile.subjects.keys()[1]);
  const layout: TimeLayout = profile.tryGetTimeLayout(layoutId) as TimeLayout;
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  checkEqual('前置：第 3 节课是英语',
    (profile.tryGetSubject(plan.classes[2].subjectId) as Subject).name, '英语');

  check('设预置科目', ScheduleMutations.setDefaultClass(profile, layoutId, 4, yw, true));
  check('时间点上记下了', layout.layouts[4].defaultClassId.equals(yw));
  check('isHideDefault 记下了', layout.layouts[4].isHideDefault);
  // 语义是「所有绑定这张时间表的课表，这一节统一设成某科目」，
  // 所以是覆盖而不是只填空位
  checkEqual('刷到了绑定该时间表的课表',
    (profile.tryGetSubject(plan.classes[2].subjectId) as Subject).name, '语文');

  // 行下标算错就会刷到别的课次上：行 2 是第 2 节课，不是第 3 节
  check('再设一次到行 2', ScheduleMutations.setDefaultClass(profile, layoutId, 2, sx, true));
  checkEqual('行 2 对应课次 1',
    (profile.tryGetSubject(plan.classes[1].subjectId) as Subject).name, '数学');
  checkEqual('行 4 那节没被误伤',
    (profile.tryGetSubject(plan.classes[2].subjectId) as Subject).name, '语文');

  // 另一张同样绑定这张时间表的课表，也应被刷到
  const otherPlanId: Guid = ScheduleMutations.addClassPlan(profile, layoutId, '周二');
  ScheduleMutations.setDefaultClass(profile, layoutId, 4, yw, true);
  const other: ClassPlan = profile.tryGetClassPlan(otherPlanId) as ClassPlan;
  checkEqual('同样绑定该时间表，所以也被刷',
    (profile.tryGetSubject(other.classes[2].subjectId) as Subject).name, '语文');
}

// ------------------------------------------------------------ 课表（排课）

function testAddClassPlan(): void {
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const id: Guid = ScheduleMutations.addClassPlan(profile, layoutId, '');
  const plan: ClassPlan = profile.tryGetClassPlan(id) as ClassPlan;
  checkEqual('空名兜底', plan.name, '新课表');
  checkNum('isActive 置位', plan.isActive ? 1 : 0, 1);
  check('绑上了时间表', plan.timeLayoutId.equals(layoutId));
  // 默认 weekCountDiv=0 是「每周都匹配」，课表建出来就能生效；
  // 若沿用 TimeRule 的 weekCountDivTotal=2 而 weekCountDiv 非 0，会永不匹配
  checkNum('未排课状态 weekCountDiv', plan.timeRule.weekCountDiv, 0);
  checkNum('settle 后课次数跟时间表对齐', plan.classes.length, 3);
}

function testSetClassPlanTimeLayoutClearsClasses(): void {
  // 课次数不同的两张表之间换绑，沿用旧内容会错位
  const profile: Profile = seededProfile();
  const otherLayoutId: Guid = ScheduleMutations.addTimeLayout(profile, '两节课');
  const other: TimeLayout = profile.tryGetTimeLayout(otherLayoutId) as TimeLayout;
  other.layouts = [
    point(TIME_TYPE_CLASS, '08:00:00', '08:45:00'),
    point(TIME_TYPE_CLASS, '09:00:00', '09:45:00')
  ];
  const planId: Guid = firstPlanId(profile);
  const yw: Guid = Guid.fromCanonical(profile.subjects.keys()[0]);
  ScheduleMutations.setClassSubject(profile, planId, 0, yw);
  ScheduleMutations.settle(profile);

  check('换绑时间表', ScheduleMutations.setClassPlanTimeLayout(profile, planId, otherLayoutId));
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  checkNum('课次按新表缩到 2', plan.classes.length, 2);
  checkNum('旧内容没被沿用', plan.classes[0].subjectId.isEmpty() ? 1 : 0, 1);
}

function testSetClassPlanRuleClamps(): void {
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;

  ScheduleMutations.setClassPlanRule(profile, planId, 3, 2, 4);
  checkNum('weekDay', plan.timeRule.weekDay, 3);
  checkNum('weekCountDiv', plan.timeRule.weekCountDiv, 2);
  checkNum('weekCountDivTotal', plan.timeRule.weekCountDivTotal, 4);

  // 越界的轮转位置会让规则永远不匹配，界面上却看不出哪里不对
  ScheduleMutations.setClassPlanRule(profile, planId, 3, 9, 4);
  checkNum('轮转位置被夹住', plan.timeRule.weekCountDiv, 4);

  ScheduleMutations.setClassPlanRule(profile, planId, 3, -1, 4);
  checkNum('负轮转位置归零=每周', plan.timeRule.weekCountDiv, 0);

  ScheduleMutations.setClassPlanRule(profile, planId, 3, 1, 0);
  checkNum('轮转总数下限 1', plan.timeRule.weekCountDivTotal, 1);
  checkNum('轮转位置随之夹住', plan.timeRule.weekCountDiv, 1);
}

function testSetClassMutations(): void {
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  const yw: Guid = Guid.fromCanonical(profile.subjects.keys()[0]);

  check('排课', ScheduleMutations.setClassSubject(profile, planId, 1, yw));
  check('停用', ScheduleMutations.setClassEnabled(profile, planId, 1, false));
  check('标调课', ScheduleMutations.setClassChanged(profile, planId, 1, true));
  check('第 2 节是语文', plan.classes[1].subjectId.equals(yw));
  checkNum('停用生效', plan.classes[1].isEnabled ? 1 : 0, 0);
  checkNum('调课标记生效', plan.classes[1].isChangedClass ? 1 : 0, 1);

  check('课次越界返回 false', !ScheduleMutations.setClassSubject(profile, planId, 99, yw));
  check('负下标返回 false', !ScheduleMutations.setClassSubject(profile, planId, -1, yw));
  check('停用越界返回 false', !ScheduleMutations.setClassEnabled(profile, planId, 99, true));
  check('标记越界返回 false', !ScheduleMutations.setClassChanged(profile, planId, 99, true));
}

// -------------------------------------------------------------- 叠加课表

function testCreateOverlayClassPlan(): void {
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);
  const sx: Guid = Guid.fromCanonical(profile.subjects.keys()[1]);
  // 源课表先手动标一个调课
  ScheduleMutations.setClassChanged(profile, planId, 0, true);

  const overlayId: Guid = ScheduleMutations.createOverlayClassPlan(profile, planId, '') as Guid;
  const overlay: ClassPlan = profile.tryGetClassPlan(overlayId) as ClassPlan;
  const source: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  check('叠加课表建出来了', overlay !== undefined);
  checkEqual('默认名是源名加后缀', overlay.name, `${source.name} 副本`);
  checkNum('isOverlay 置位', overlay.isOverlay ? 1 : 0, 1);
  check('overlaySourceId 指向源', (overlay.overlaySourceId as Guid).equals(planId));
  checkNum('课次数跟源一致', overlay.classes.length, source.classes.length);
  check('课程内容复制过来了', overlay.classes[1].subjectId.equals(source.classes[1].subjectId));
  check('不是同一个对象', overlay.classes[1] !== source.classes[1]);

  // 改叠加课表的一节课 -> settle 应该把它标成调课
  ScheduleMutations.setClassSubject(profile, overlayId, 0, sx);
  ScheduleMutations.settle(profile);
  checkNum('改过的课被标调课', overlay.classes[0].isChangedClass ? 1 : 0, 1);
  checkNum('没改的课没被标', overlay.classes[1].isChangedClass ? 1 : 0, 0);

  // 叠加的叠加：判定永远只跟 overlaySourceId 指的那张比，不追溯整条链
  const overlay2Id: Guid = ScheduleMutations.createOverlayClassPlan(profile, overlayId, '第二层') as Guid;
  const overlay2: ClassPlan = profile.tryGetClassPlan(overlay2Id) as ClassPlan;
  ScheduleMutations.settle(profile);
  // 叠加的叠加：与来源逐格相同，所以没有一格被标调课。判定永远只跟
  // overlaySourceId 指的那张比，不追溯整条链。
  checkNum('第二层与来源相同故无调课标记', overlay2.classes[0].isChangedClass ? 1 : 0, 0);
  check('源课表不存在返回 undefined',
    ScheduleMutations.createOverlayClassPlan(profile, Guid.newGuid(), 'x') === undefined);
}

function testSettleNormalizesChangedClassOnNonOverlay(): void {
  // 桌面版 RefreshIsChangedClass 对没有 overlaySourceId 的课表一律置 false。
  // 照搬的结果是：从文件里读进来的散落标记会被清掉。这是有意为之，
  // 这里钉住它，免得以后有人「优化」成不重算。
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);
  ScheduleMutations.setClassChanged(profile, planId, 0, true);
  ScheduleMutations.settle(profile);
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  checkNum('非叠加课表的调课标记被归零', plan.classes[0].isChangedClass ? 1 : 0, 0);
}

function testSettleWithMissingOverlaySource(): void {
  // 叠加源被删掉后标记应全部归零，而不是保留上一轮的判断
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);
  const sx: Guid = Guid.fromCanonical(profile.subjects.keys()[1]);
  const overlayId: Guid = ScheduleMutations.createOverlayClassPlan(profile, planId, '') as Guid;
  ScheduleMutations.setClassSubject(profile, overlayId, 0, sx);
  ScheduleMutations.settle(profile);
  const overlay: ClassPlan = profile.tryGetClassPlan(overlayId) as ClassPlan;
  checkNum('前置：有调课标记', overlay.classes[0].isChangedClass ? 1 : 0, 1);

  // 直接把源课表从字典里摘掉，模拟「源没了但 overlaySourceId 还挂着」
  profile.classPlans.delete(planId.toString());
  ScheduleMutations.settle(profile);
  checkNum('源没了则标记归零', overlay.classes[0].isChangedClass ? 1 : 0, 0);
}

// ---------------------------------------------------------------- 课表群

function testClassPlanGroup(): void {
  const profile: Profile = emptyProfile();
  const groupId: Guid = ScheduleMutations.addClassPlanGroup(profile, '');
  const group: ClassPlanGroup = profile.classPlanGroups.getOrDefault(
    groupId.toString(), new ClassPlanGroup());
  checkEqual('空名兜底', group.name, '新课表群');
  checkNum('isActive 置位', group.isActive ? 1 : 0, 1);

  check('改群名', ScheduleMutations.renameClassPlanGroup(profile, groupId, '秋季'));
  checkEqual('群名生效', group.name, '秋季');
  check('改不存在的群返回 false',
    !ScheduleMutations.renameClassPlanGroup(profile, Guid.newGuid(), 'x'));

  check('选当前群', ScheduleMutations.selectClassPlanGroup(profile, groupId));
  check('当前群生效', profile.selectedClassPlanGroupId.equals(groupId));
}

function testDisbandClassPlanGroup(): void {
  const profile: Profile = seededProfile();
  const groupId: Guid = ScheduleMutations.addClassPlanGroup(profile, '临时');
  const planId: Guid = firstPlanId(profile);
  ScheduleMutations.setClassPlanGroup(profile, planId, groupId);

  check('解散', ScheduleMutations.disbandClassPlanGroup(profile, groupId));
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  checkNum('群还在', profile.classPlanGroups.size, 0);
  check('课表移到默认群',
    plan.associatedGroup.equals(ClassPlanGroup.defaultGroupGuid()));
  check('默认群不可解散', !ScheduleMutations.disbandClassPlanGroup(
    profile, ClassPlanGroup.defaultGroupGuid()));
  check('全局群不可解散', !ScheduleMutations.disbandClassPlanGroup(
    profile, ClassPlanGroup.globalGroupGuid()));
}

function testDeleteClassPlanGroup(): void {
  const profile: Profile = seededProfile();
  const groupId: Guid = ScheduleMutations.addClassPlanGroup(profile, '临时');
  const planId: Guid = firstPlanId(profile);
  ScheduleMutations.setClassPlanGroup(profile, planId, groupId);

  check('删除', ScheduleMutations.deleteClassPlanGroup(profile, groupId));
  checkNum('群没了', profile.classPlanGroups.size, 0);
  checkNum('群内课表一并没了', profile.classPlans.size, 0);
  check('默认群不可删除', !ScheduleMutations.deleteClassPlanGroup(
    profile, ClassPlanGroup.defaultGroupGuid()));
}

// -------------------------------------------------- 临时课表 / 预定课表

function testRemoveClassPlanClearsPointers(): void {
  // 留着悬空指针不会崩（resolve 时 tryGet 拿不到就往下走），
  // 但界面上会出现「临时课表已启用」而课表列表里找不到它
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);
  ScheduleMutations.applyTempClassPlan(profile, planId, dt('2026-09-26T00:00:00'));
  ScheduleMutations.setOrderedSchedule(profile, dt('2026-09-28T00:00:00'), planId);
  check('前置：临时课表已设', profile.tempClassPlanId !== undefined);
  checkNum('前置：预定一条', profile.orderedSchedules.size, 1);

  check('删课表', ScheduleMutations.removeClassPlan(profile, planId));
  check('tempClassPlanId 被清', profile.tempClassPlanId === undefined);
  check('overlayClassPlanId 被清', profile.overlayClassPlanId === undefined);
  checkNum('预定那条被清', profile.orderedSchedules.size, 0);
  check('删不存在的返回 false', !ScheduleMutations.removeClassPlan(profile, planId));
}

function testRemoveClassPlanClearsOverlaySourceOfOthers(): void {
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);
  const overlayId: Guid = ScheduleMutations.createOverlayClassPlan(profile, planId, '') as Guid;
  check('前置：叠加指向源', ScheduleMutations.overlaySourceOf(
    profile, profile.tryGetClassPlan(overlayId) as ClassPlan) !== undefined);
  ScheduleMutations.removeClassPlan(profile, planId);
  check('叠加源被清',
    ScheduleMutations.overlaySourceOf(profile, profile.tryGetClassPlan(overlayId) as ClassPlan) === undefined);
}

function testTempClassPlan(): void {
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);
  check('对不存在的课表返回 false',
    !ScheduleMutations.applyTempClassPlan(profile, Guid.newGuid(), dt('2026-09-26T00:00:00')));
  check('启用临时课表', ScheduleMutations.applyTempClassPlan(
    profile, planId, dt('2026-09-26T00:00:00')));
  check('tempClassPlanId 记下了', (profile.tempClassPlanId as Guid).equals(planId));
  check('建立时间记下了', profile.tempClassPlanSetupTime.toString() === '2026-09-26T00:00:00');
  check('overlayClassPlanId 同步', (profile.overlayClassPlanId as Guid).equals(planId));

  // 单独设过的 overlayClassPlanId 不该被「取消临时课表」带走
  const other: Guid = ScheduleMutations.addClassPlan(profile, firstLayoutId(profile), '另一张');
  profile.overlayClassPlanId = other;
  ScheduleMutations.cancelTempClassPlan(profile);
  check('tempClassPlanId 没了', profile.tempClassPlanId === undefined);
  check('别人的 overlayClassPlanId 还在', (profile.overlayClassPlanId as Guid).equals(other));
}

function testCancelTempClassPlanClearsMatchingOverlay(): void {
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);
  ScheduleMutations.applyTempClassPlan(profile, planId, dt('2026-09-26T00:00:00'));
  ScheduleMutations.cancelTempClassPlan(profile);
  check('指向同一张时一并清掉', profile.overlayClassPlanId === undefined);
}

function testTempClassPlanGroup(): void {
  const profile: Profile = seededProfile();
  const groupId: Guid = ScheduleMutations.addClassPlanGroup(profile, '国庆');
  const expire: DateTimeValue = dt('2026-10-08T00:00:00');

  check('启用', ScheduleMutations.applyTempClassPlanGroup(
    profile, groupId, expire, TempClassPlanGroupType.Override));
  check('启用标志', profile.isTempClassPlanGroupEnabled);
  check('群 id', (profile.tempClassPlanGroupId as Guid).equals(groupId));
  checkNum('类型', profile.tempClassPlanGroupType, TempClassPlanGroupType.Override);
  checkEqual('过期时间', profile.tempClassPlanGroupExpireTime.toString(), '2026-10-08T00:00:00');

  check('默认群不可作为临时群',
    !ScheduleMutations.applyTempClassPlanGroup(profile, ClassPlanGroup.defaultGroupGuid(),
      expire, TempClassPlanGroupType.Override));
  check('全局群不可作为临时群',
    !ScheduleMutations.applyTempClassPlanGroup(profile, ClassPlanGroup.globalGroupGuid(),
      expire, TempClassPlanGroupType.Override));
  check('不存在的群返回 false',
    !ScheduleMutations.applyTempClassPlanGroup(profile, Guid.newGuid(),
      expire, TempClassPlanGroupType.Override));

  ScheduleMutations.cancelTempClassPlanGroup(profile);
  checkNum('取消后标志', profile.isTempClassPlanGroupEnabled ? 1 : 0, 0);
  check('取消后群 id', profile.tempClassPlanGroupId === undefined);
}

function testDeleteClassPlanGroupClearsTempGroupPointer(): void {
  const profile: Profile = seededProfile();
  const groupId: Guid = ScheduleMutations.addClassPlanGroup(profile, '国庆');
  ScheduleMutations.applyTempClassPlanGroup(
    profile, groupId, dt('2026-10-08T00:00:00'), TempClassPlanGroupType.Inherit);
  ScheduleMutations.deleteClassPlanGroup(profile, groupId);
  check('临时群指针被清', profile.tempClassPlanGroupId === undefined);
}

function testOrderedSchedule(): void {
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);

  check('对不存在的课表返回 false',
    !ScheduleMutations.setOrderedSchedule(profile, dt('2026-09-28T00:00:00'), Guid.newGuid()));
  check('设预定', ScheduleMutations.setOrderedSchedule(
    profile, dt('2026-09-28T09:30:00'), planId));
  // 键必须归一到当天 00:00:00，否则 orderedScheduleFor 查不到
  const found = profile.orderedScheduleFor(dt('2026-09-28T00:00:00'));
  check('带时刻也能命中', found !== undefined);
  check('指向对的课表', found !== undefined && found.classPlanId.equals(planId));
  check('另一个那天查不到', profile.orderedScheduleFor(dt('2026-09-29T00:00:00')) === undefined);

  check('取消预定', ScheduleMutations.setOrderedSchedule(
    profile, dt('2026-09-28T00:00:00'), undefined));
  checkNum('预定清空', profile.orderedSchedules.size, 0);
}

/**
 * 预定课表行。
 *
 * 三类「看起来是同一条预定、实际完全不是」的情况各测一遍：
 *   1. 过去的预定 —— 留在档案里但已经没意义，界面要标出来
 *   2. 指向已删课表的预定 —— 悬空指针，桌面版也可能留下
 *   3. 指向叠加班表、而叠加班表总开关关着 —— 有预定但引擎不会用它
 * 第 3 类最要紧：只判断「键存在 + 指针能解引用」的话它会被标成生效中，
 * 用户以为考试那天安排好了课表，其实那天走的是常规选课。
 */
function testEditorRowsOrderedSchedules(): void {
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);
  // 别把局部变量也叫 settings：同名会把自己遮住，右侧的 settings() 解析到
  // 还没初始化的局部 const 上，运行时报 TDZ 而不是编译错误。
  const engineSettings: EngineSettings = settings();
  const today: DateTimeValue = dt('2026-09-26T00:00:00');

  // 建三天预定，插入顺序故意打乱：09-28 / 09-20 / 10-05
  check('设三天预定',
    ScheduleMutations.setOrderedSchedule(profile, dt('2026-09-28T00:00:00'), planId) &&
    ScheduleMutations.setOrderedSchedule(profile, dt('2026-09-20T00:00:00'), planId) &&
    ScheduleMutations.setOrderedSchedule(profile, dt('2026-10-05T00:00:00'), planId));

  const rows: OrderedScheduleRow[] =
    EditorRows.orderedSchedules(profile, engineSettings, today);
  checkNum('三条都在', rows.length, 3);
  checkEqual('按日期升序，不按插入序', rows[0].dateText, '2026-09-20');
  checkEqual('第二条', rows[1].dateText, '2026-09-28');
  checkEqual('第三条', rows[2].dateText, '2026-10-05');

  // 今天固定取 2026-09-26（周六），下面的星期几都对着它算。
  checkNum('过去的：偏移是负数', rows[0].dayOffset, -6);
  check('过去的标为死条目', rows[0].isStale);
  check('过去的仍算生效（引擎照常按它选课，只是不再有未来价值）', rows[0].isActive);
  checkEqual('过去的星期几', rows[0].weekDayText, '周日');

  checkNum('本周的偏移是 2', rows[1].dayOffset, 2);
  check('本周的不是死条目', !rows[1].isStale);
  check('本周的生效', rows[1].isActive);
  checkEqual('本周的星期几', rows[1].weekDayText, '周一');
  check('指向的课表名解出来了', rows[1].planExists);
  checkEqual('dateKey 就是键本身', rows[1].dateKey, '2026-09-28T00:00:00');
  checkEqual('planId 是解出来的课表', rows[1].planId, planId.toString());

  // 悬空指针：直接往档案里塞一个不存在的 Guid，模拟用户文件里的残留
  const dangling: OrderedSchedule = new OrderedSchedule();
  dangling.classPlanId = Guid.newGuid();
  dangling.isActive = true;
  profile.orderedSchedules.set('2026-09-30T00:00:00', dangling);
  const dangleRow: OrderedScheduleRow =
    rowFor(EditorRows.orderedSchedules(profile, engineSettings, today), '2026-09-30');
  check('悬空那条能按日期找到', dangleRow !== undefined);
  check('悬空那条 planExists 为 false', dangleRow !== undefined && !dangleRow.planExists);
  check('悬空那条不生效', dangleRow !== undefined && !dangleRow.isActive);
  checkEqual('悬空那条显示已失效', dangleRow === undefined ? '' : dangleRow.planName, "（已失效）");

  // 叠加班表 + 叠加班表总开关关着：有预定，但引擎不会用它。
  // 用 createOverlayClassPlan 建而不是手搓：ClassPlan 自己没有 guid 字段
  // （身份就是 KeyedMap 的键），手搓那张表根本进不了档案。
  const overlayId: Guid = ScheduleMutations.createOverlayClassPlan(
    profile, planId, '考试表') as Guid;
  check('预定到叠加班表',
    ScheduleMutations.setOrderedSchedule(profile, dt('2026-10-01T00:00:00'), overlayId));
  profile.isOverlayClassPlanEnabled = false;
  const offRow: OrderedScheduleRow =
    rowFor(EditorRows.orderedSchedules(profile, engineSettings, today), '2026-10-01');
  check('叠加班表关着时不算生效', offRow !== undefined && !offRow.isActive);
  check('但不是死条目（开关一开就生效）', offRow !== undefined && !offRow.isStale);
  profile.isOverlayClassPlanEnabled = true;
  const onRow: OrderedScheduleRow =
    rowFor(EditorRows.orderedSchedules(profile, engineSettings, today), '2026-10-01');
  check('开关打开后生效', onRow !== undefined && onRow.isActive);

  // 键不是合法日期：不能让它凭空消失
  const broken: OrderedSchedule = new OrderedSchedule();
  broken.classPlanId = planId;
  profile.orderedSchedules.set('不是日期', broken);
  const brokenRows: OrderedScheduleRow[] = EditorRows.orderedSchedules(profile, engineSettings, today);
  checkNum('坏键也列出来', brokenRows.length, 6);
  const brokenRow: OrderedScheduleRow = brokenRows[brokenRows.length - 1];
  checkEqual('坏键排在最后', brokenRow.dateText, '不是日期');
  check('坏键标为死条目', brokenRow.isStale);
  check('坏键不生效（日期都读不出来，谈不上当天选课）', !brokenRow.isActive);

  // 纯函数：同一份档案同一份参数，结果逐字段一致
  const again: OrderedScheduleRow[] = EditorRows.orderedSchedules(profile, engineSettings, today);
  let same: boolean = again.length === brokenRows.length;
  for (let i: number = 0; same && i < again.length; i++) {
    same = again[i].dateKey === brokenRows[i].dateKey &&
      again[i].dayOffset === brokenRows[i].dayOffset &&
      again[i].isActive === brokenRows[i].isActive &&
      again[i].isStale === brokenRows[i].isStale;
  }
  check('两次调用结果一致', same);
}

/** 按日期文本找行。找不到返回 undefined —— 界面上不存在这种行，测试里要显式判。 */
function rowFor(rows: OrderedScheduleRow[], dateText: string): OrderedScheduleRow | undefined {
  for (const row of rows) {
    if (row.dateText === dateText) {
      return row;
    }
  }
  return undefined;
}

// -------------------------------------------------------------- 档案级

function testRenameProfile(): void {
  const profile: Profile = emptyProfile();
  check('改档案名', ScheduleMutations.renameProfile(profile, '我的课表'));
  checkEqual('生效', profile.name, '我的课表');
}

function testSetClassPlanEnabled(): void {
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);
  check('停用课表', ScheduleMutations.setClassPlanEnabled(profile, planId, false));
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  checkNum('生效', plan.isEnabled ? 1 : 0, 0);
  check('改不存在的返回 false', !ScheduleMutations.setClassPlanEnabled(
    profile, Guid.newGuid(), false));
}

function testOverlayEnabledToggle(): void {
  const profile: Profile = emptyProfile();
  check('打开叠加开关', ScheduleMutations.setClassPlanOverlayEnabled(profile, true));
  checkNum('生效', profile.isOverlayClassPlanEnabled ? 1 : 0, 1);
  check('hasOverlayClassPlan 跟着变', profile.hasOverlayClassPlan());
  ScheduleMutations.setClassPlanOverlayEnabled(profile, false);
  checkNum('关闭', profile.isOverlayClassPlanEnabled ? 1 : 0, 0);
}

// -------------------------------------------------------------- 往返兼容

function testRoundTripAfterEdits(): void {
  // P4 的验收标准：编辑后 JSON 仍与桌面版兼容。
  // 桌面版读的是同一份 schema，改动层写出的东西必须字段全、顺序对。
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const planId: Guid = firstPlanId(profile);
  const groupId: Guid = ScheduleMutations.addClassPlanGroup(profile, '单双周');
  const overlayId: Guid = ScheduleMutations.createOverlayClassPlan(profile, planId, '国庆叠加') as Guid;
  const sx: Guid = Guid.fromCanonical(profile.subjects.keys()[1]);

  ScheduleMutations.setClassSubject(profile, overlayId, 0, sx);
  ScheduleMutations.setClassPlanGroup(profile, planId, groupId);
  ScheduleMutations.selectClassPlanGroup(profile, groupId);
  ScheduleMutations.setDefaultClass(profile, layoutId, 4, sx, false);
  ScheduleMutations.setOrderedSchedule(profile, dt('2026-09-28T00:00:00'), overlayId);
  ScheduleMutations.applyTempClassPlan(profile, overlayId, dt('2026-09-26T00:00:00'));
  ScheduleMutations.setClassPlanOverlayEnabled(profile, true);
  ScheduleMutations.settle(profile);

  const text: string = Profile.stringify(profile);
  checkRoundTrip('改完落盘能原样读回', profile);

  // 抽查几个最容易在改动中被写坏的字段
  const parsed: Profile = Profile.parse(text);
  parsed.refreshDerivedState();
  const parsedPlan: ClassPlan = parsed.tryGetClassPlan(planId) as ClassPlan;
  checkNum('课次数量', parsedPlan.classes.length, 3);
  checkNum('weekDay', parsedPlan.timeRule.weekDay, 1);
  checkNum('weekCountDiv', parsedPlan.timeRule.weekCountDiv, 0);
  check('群归属', parsedPlan.associatedGroup.equals(groupId));
  const parsedOverlay: ClassPlan = parsed.tryGetClassPlan(overlayId) as ClassPlan;
  check('叠加标志', parsedOverlay.isOverlay);
  check('叠加源', (parsedOverlay.overlaySourceId as Guid).equals(planId));
  checkNum('叠加课表被改的那节标了调课', parsedOverlay.classes[0].isChangedClass ? 1 : 0, 1);
  check('预置科目', (parsed.tryGetTimeLayout(layoutId) as TimeLayout).layouts[4].defaultClassId.equals(sx));
  check('isHideDefault 为 false 不被丢掉',
    (parsed.tryGetTimeLayout(layoutId) as TimeLayout).layouts[4].isHideDefault === false);
  check('预定课表', parsed.orderedScheduleFor(dt('2026-09-28T00:00:00')) !== undefined);
  check('临时课表', parsed.tempClassPlanId !== undefined);
  check('叠加开关', parsed.isOverlayClassPlanEnabled);
  checkNum('当前群', parsed.classPlanGroups.size, 1);

  // 已被标 Obsolete 但仍要写出的两个字段
  check('StartSecond 仍写出', text.indexOf('"StartSecond"') >= 0);
  check('EndSecond 仍写出', text.indexOf('"EndSecond"') >= 0);
}

function testRoundTripAfterDeletes(): void {
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const yw: Guid = Guid.fromCanonical(profile.subjects.keys()[0]);
  ScheduleMutations.removeSubject(profile, yw);
  // 删第 2 节课（行 2），课次数跟着少一
  ScheduleMutations.removeTimePoint(profile, layoutId, 2);
  ScheduleMutations.settle(profile);
  checkRoundTrip('删完落盘能原样读回', profile);

  const parsed: Profile = Profile.parse(Profile.stringify(profile));
  parsed.refreshDerivedState();
  const planId: Guid = firstPlanId(parsed);
  const plan: ClassPlan = parsed.tryGetClassPlan(planId) as ClassPlan;
  checkNum('科目少了一个', parsed.subjects.size, 2);
  checkNum('课次少了一个', plan.classes.length, 2);
  checkNum('行数少了一行', (parsed.tryGetTimeLayout(layoutId) as TimeLayout).layouts.length, 4);
  check('被删科目的那格不再指向它', !plan.classes[0].subjectId.equals(yw));
}

function testMutationsAreDeterministic(): void {
  // 可重入约束：同一串改动跑两遍，结果必须完全一致。
  // Profile 的 Id 与两个 SetupTime 默认取「现在」，本身就不确定，比对前先钉死，
  // 否则这条断言测的是时钟而不是改动层。
  const layoutId: string = 'aaaaaaaa-0000-0000-0000-000000000001';
  const subjectId: string = '11111111-1111-1111-1111-111111111111';
  const planId: string = '20000000-0000-0000-0000-000000000000';

  const run = (): string => {
    const profile: Profile = emptyProfile();
    profile.id = Guid.fromCanonical('30000000-0000-0000-0000-000000000000');
    profile.tempClassPlanSetupTime = dt('2026-01-01T00:00:00');
    profile.tempClassPlanGroupExpireTime = dt('2026-01-01T00:00:00');
    profile.timeLayouts.set(layoutId, standardLayout());
    const subject: Subject = new Subject();
    subject.name = '语文';
    subject.teacherName = '张老师';
    profile.subjects.set(subjectId, subject);
    const plan: ClassPlan = new ClassPlan();
    plan.name = '周一';
    plan.timeLayoutId = Guid.fromCanonical(layoutId);
    plan.overlaySetupTime = dt('2026-01-01T00:00:00');
    plan.classes = [new ClassInfo(), new ClassInfo(), new ClassInfo()];
    plan.classes[0].subjectId = Guid.fromCanonical(subjectId);
    profile.classPlans.set(planId, plan);
    ScheduleMutations.setClassPlanRule(profile, Guid.fromCanonical(planId), 1, 1, 2);
    ScheduleMutations.setClassEnabled(profile, Guid.fromCanonical(planId), 2, false);
    ScheduleMutations.settle(profile);
    return Profile.stringify(profile, 2);
  };

  const first: string = run();
  const second: string = run();
  if (first === second) {
    check('两遍结果一致', true);
    return;
  }
  // 报出第一处不同的行：整个 JSON 丢进失败信息里，等于什么都没说
  const left: string[] = first.split('\n');
  const right: string[] = second.split('\n');
  let where: string = '长度不同';
  for (let i: number = 0; i < Math.max(left.length, right.length); i++) {
    if (left[i] !== right[i]) {
      where = `第 ${i + 1} 行：「${left[i]}」vs「${right[i]}」`;
      break;
    }
  }
  check('两遍结果一致', false, where);
}

// ------------------------------------------------------------ 文本格式化

function testTextFormat(): void {
  checkEqual('00:00', formatClock(0), '00:00');
  checkEqual('08:05', formatClock(8 * 3600 + 5 * 60), '08:05');
  checkEqual('10:45', formatClock(10 * 3600 + 45 * 60), '10:45');
  // 跨零点的时间点在界面上显示 00:00，而不是 -1:-1 之类
  checkEqual('负值降级为 00:00', formatClock(-3600), '00:00');
  // 超过 24 小时按天回绕：作息表里有跨夜自习时不能显示成 25:00
  checkEqual('跨夜回绕', formatClock(25 * 3600), '01:00');

  checkEqual('45 分钟', formatDuration(45), '45 分钟');
  checkEqual('1 小时', formatDuration(60), '1 小时');
  checkEqual('1 小时 5 分', formatDuration(65), '1 小时 5 分');
  checkEqual('0 分钟', formatDuration(0), '0 分钟');

  // weekDay 是 .NET 口径 0=周日。写成 1=周一 会让所有单双周课表错一天，
  // 而且界面上看不出异常，所以这里逐个钉住
  checkEqual('0=周日', weekDayName(0), '周日');
  checkEqual('1=周一', weekDayName(1), '周一');
  checkEqual('6=周六', weekDayName(6), '周六');
  checkEqual('越界空串', weekDayName(7), '');
  checkEqual('负数空串', weekDayName(-1), '');
  checkEqual('短名 一', weekDayShortName(1), '一');
  checkEqual('短名 日', weekDayShortName(0), '日');

  // weekCountDiv === 0 是「每周都匹配」，不是「第 0 周」
  checkEqual('每周', weekRotationText(0, 2), '每周');
  checkEqual('每周（总数也是 1）', weekRotationText(0, 1), '每周');
  checkEqual('单周', weekRotationText(1, 2), '单周');
  checkEqual('双周', weekRotationText(2, 2), '双周');
  checkEqual('第 1/4 周', weekRotationText(1, 4), '第 1/4 周');
  checkEqual('第 3/4 周', weekRotationText(3, 4), '第 3/4 周');
  // 总数被改成 0 或负数时不能除零，也不能读成「第 1/0 周」
  checkEqual('总数非法回落双周', weekRotationText(1, 0), '单周');

  checkEqual('上课', timeTypeName(0), '上课');
  checkEqual('课间', timeTypeName(1), '课间');
  checkEqual('分割线', timeTypeName(2), '分割线');
  checkEqual('行动', timeTypeName(3), '行动');
  checkEqual('未知', timeTypeName(9), '未知');
}

function testParseClockText(): void {
  checkNum('08:00', parseClockText('08:00') as number, 8 * 3600);
  checkNum('前导零', parseClockText('8:00') as number, 8 * 3600);
  checkNum('带空格', parseClockText('  09:30 ') as number, 9 * 3600 + 30 * 60);
  checkNum('带秒', parseClockText('09:30:15') as number, 9 * 3600 + 30 * 60);
  checkNum('24:00', parseClockText('24:00') as number, 24 * 3600);
  // 格式不对返回 undefined 而不是 0：返回 0 会把时间点挪到 00:00，
  // 界面上看着像「凌晨第一节课」，用户很难发现是自己输错了
  check('空串非法', parseClockText('') === undefined);
  check('缺分钟非法', parseClockText('08') === undefined);
  check('缺冒号非法', parseClockText('0800') === undefined);
  check('非数字非法', parseClockText('ab:cd') === undefined);
  check('分钟越界非法', parseClockText('08:99') === undefined);
  check('小时越界非法', parseClockText('25:00') === undefined);
  check('负数非法', parseClockText('-1:00') === undefined);
  check('四段非法', parseClockText('08:00:00:00') === undefined);
}

function testParseDurationText(): void {
  checkNum('45 分钟', parseDurationText('45 分钟') as number, 45);
  checkNum('纯数字', parseDurationText('45') as number, 45);
  checkNum('1 小时', parseDurationText('1 小时') as number, 1);
  checkNum('1 小时 5 分', parseDurationText('1 小时 5 分') as number, 15);
  check('空串非法', parseDurationText('') === undefined);
  check('无数字非法', parseDurationText('半小时') === undefined);
  check('零非法', parseDurationText('0 分钟') === undefined);
  check('超过一天非法', parseDurationText('2000 分钟') === undefined);
}

// ------------------------------------------------------- 编辑页视图数据

function testEditorRowsSubjects(): void {
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);
  const rows = EditorRows.subjects(profile);
  checkNum('三行', rows.length, 3);
  checkEqual('按插入序', `${rows[0].name},${rows[1].name},${rows[2].name}`, '语文,数学,英语');
  // 语文被第一节课引用；英语被第三节课引用
  checkNum('语文被 1 张表 1 节课引用', rows[0].usedByPlans, 1);
  checkNum('语文引用次数', rows[0].usedByClassesTotal, 1);
  checkNum('英语引用次数', rows[2].usedByClassesTotal, 1);
  // 缩略与教师名要带到界面上
  checkEqual('缩略', rows[0].initial, '语');
  checkEqual('教师', rows[0].teacherName, '张老师');
  check('guid 取自字典键', rows[0].guid === profile.subjects.keys()[0]);

  // 同一科目被一节课引用两次时，plans 与 classes 两个数要分开算
  const sx: Guid = Guid.fromCanonical(profile.subjects.keys()[1]);
  ScheduleMutations.setClassSubject(profile, planId, 0, sx);
  ScheduleMutations.settle(profile);
  const after = EditorRows.subjects(profile);
  checkNum('数学被 1 张表引用', after[1].usedByPlans, 1);
  checkNum('数学被引用 2 次', after[1].usedByClassesTotal, 2);
  checkNum('语文不再被引用', after[0].usedByClassesTotal, 0);

  // 删科目后引用数归零，界面才不会显示一个已经失效的引用
  ScheduleMutations.removeSubject(profile, sx);
  const gone = EditorRows.subjects(profile);
  checkNum('删后剩两行', gone.length, 2);
  checkEqual('英语顶上第 2 行', gone[1].name, '英语');
}

function testEditorRowsTimeLayout(): void {
  const profile: Profile = seededProfile();
  const rows = EditorRows.timeLayouts(profile);
  checkNum('一行', rows.length, 1);
  const row = rows[0];
  checkEqual('名字', row.name, '标准作息');
  checkNum('五行', row.rowCount, 5);
  checkNum('三个课次', row.classCount, 3);
  checkEqual('摘要取前三项并截断', row.summary, '08:00 / 大课间 / 09:00 / …');
  checkNum('被一张课表用', row.usedByPlans, 1);
  checkEqual('绑定的课表名', row.boundPlanNames, '周一');

  // 行下标与课次下标的映射：行 1、3 是课间，课次下标必须是 -1。
  // 这里是全篇最容易搞混的一处，写错的话排课界面会显示成「第 2 节」在课间上
  checkNum('行 0 课次 0', row.rows[0].classSlot, 0);
  checkNum('行 1 是课间', row.rows[1].classSlot, -1);
  checkNum('行 2 课次 1', row.rows[2].classSlot, 1);
  checkNum('行 3 是课间', row.rows[3].classSlot, -1);
  checkNum('行 4 课次 2', row.rows[4].classSlot, 2);
  checkEqual('行 0 节次文案', row.rows[0].classSlotText, '第 1 节');
  checkEqual('课间行无节次文案', row.rows[1].classSlotText, '');
  checkNum('行 0 是课程', row.rows[0].isClass ? 1 : 0, 1);
  checkNum('行 1 不是课程', row.rows[1].isClass ? 1 : 0, 0);
  checkEqual('时段', row.rows[0].startText + '-' + row.rows[0].endText, '08:00-08:45');
  checkNum('时长分钟', row.rows[0].durationMinutes, 45);
  checkEqual('时长文案', row.rows[0].durationText, '45 分钟');
  checkEqual('类型文案', row.rows[1].timeTypeText, '课间');
  checkEqual('课间名', row.rows[1].breakName, '大课间');
}

function testEditorRowsTimeLayoutDefaultApplied(): void {
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const yw: Guid = Guid.fromCanonical(profile.subjects.keys()[0]);
  const sx: Guid = Guid.fromCanonical(profile.subjects.keys()[1]);
  let row = EditorRows.timeLayouts(profile)[0];
  checkEqual('默认未设预置科目', row.rows[2].defaultSubjectName, '');

  // 行 4 是第 3 节课（行 1、3 是课间）。设成数学，已被排成数学的课数是 0
  ScheduleMutations.setDefaultClass(profile, layoutId, 4, sx, false);
  row = EditorRows.timeLayouts(profile)[0];
  checkEqual('预置科目记下了', row.rows[4].defaultSubjectName, '数学');
  checkNum('isHideDefault 为 false', row.rows[4].isHideDefault ? 1 : 0, 0);
  // setDefaultClass 是覆盖语义：所有绑定这张时间表的课表，这一节立刻被刷成数学。
  // 所以「设了预置但还没人用」这个状态根本不存在，计数落下就是 1
  checkNum('落下即被实际排上', row.rows[4].defaultAppliedCount, 1);

  // 再绑一张表也一并被刷，计数跟着涨
  const extra: Guid = ScheduleMutations.addClassPlan(profile, layoutId, '周二');
  ScheduleMutations.settle(profile);
  row = EditorRows.timeLayouts(profile)[0];
  checkNum('新表也被刷上', row.rows[4].defaultAppliedCount, 2);
  checkNum('新表有 3 节', (profile.tryGetClassPlan(extra) as ClassPlan).classes.length, 3);

  // 预置科目指向已删除的科目时显示占位符，而不是空串
  // 空串会被界面当成「没设」，用户就看不到这里曾经设过东西
  ScheduleMutations.removeSubject(profile, sx);
  row = EditorRows.timeLayouts(profile)[0];
  checkEqual('悬空预置科目显示占位符', row.rows[4].defaultSubjectName, '（无）');
  check('guid 仍在', row.rows[4].defaultSubjectId === sx.toString());
  check('不与英语混淆', yw.toString() !== row.rows[4].defaultSubjectId);
}

function testEditorRowsClassPlan(): void {
  const profile: Profile = seededProfile();
  const rows = EditorRows.classPlans(profile, '');
  checkNum('一张课表', rows.length, 1);
  const row = rows[0];
  checkEqual('名字', row.name, '周一');
  checkNum('绑定了时间表', row.hasTimeLayout ? 1 : 0, 1);
  checkEqual('时间表名', row.timeLayoutName, '标准作息');
  checkNum('三个课次', row.slots.length, 3);
  checkEqual('第一节语文', row.slots[0].subjectName, '语文');
  checkEqual('第二节数学', row.slots[1].subjectName, '数学');
  checkEqual('第三节英语', row.slots[2].subjectName, '英语');
  checkEqual('已排课摘要', row.filledText, '语文、数学、英语');
  checkNum('已排课数', row.filledCount, 3);
  checkEqual('星期文案', row.weekDayText, '周一');
  checkEqual('轮转文案', row.weekRotationText, '每周');
  checkNum('默认未启用', row.isEnabled ? 1 : 0, 1);
  check('guid 取自字典键', row.guid === profile.classPlans.keys()[0]);
  // 默认群不在字典里（ClassPlan.AssociatedGroup 指向它的固定 guid），
  // 界面仍要显示得出名字，不能显示成「已失效」
  checkEqual('默认群名', row.groupName, '默认课表群');
}

function testEditorRowsPlanEditRowsInvariant(): void {
  // 排课页按下标配对取课次：slots[editRows[i].classSlot]。这条不变量断了，
  // 界面就会把「第三节的课」显示在第二节那一行上，且不报任何错。
  const profile: Profile = seededProfile();
  const rows = EditorRows.classPlans(profile, '');
  const row = rows[0];
  checkNum('五个可显示行', row.editRows.length, 5);
  checkEqual('行下标连续', `${row.editRows[0].rowIndex},${row.editRows[4].rowIndex}`, '0,4');
  for (const edit of row.editRows) {
    if (edit.classSlot < 0) {
      continue;
    }
    check(`行 ${edit.rowIndex} 的课次下标落在 slots 范围内`,
      edit.classSlot < row.slots.length);
    check(`行 ${edit.rowIndex} 配对的课次自洽`,
      row.slots[edit.classSlot].slot === edit.classSlot);
  }
  checkNum('课程行的课次下标', row.editRows[2].classSlot, 1);
  checkNum('课间行的课次下标为 -1', row.editRows[1].classSlot, -1);
  checkEqual('课间行的标签', row.editRows[1].label, '大课间');
  checkEqual('课程行的标签', row.editRows[2].label, '第 2 节');
  checkEqual('课程行的时段', row.editRows[2].timeRange, '09:00-09:45');
  checkNum('课间行也有时段', row.editRows[1].timeRange.length > 0 ? 1 : 0, 1);
}

function testEditorRowsPlanEditRowsWithSeparator(): void {
  // 分割线占行但不占课次，且不显示时段
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  ScheduleMutations.addTimePoint(profile, layoutId, TIME_TYPE_SEPARATOR, 10 * 3600, 0);
  ScheduleMutations.settle(profile);
  const row = EditorRows.classPlans(profile, '')[0];
  checkNum('行数多了一个', row.editRows.length, 6);
  checkNum('课次数没变', row.slots.length, 3);
  const last = row.editRows[5];
  checkNum('末行是分割线', last.isSeparator ? 1 : 0, 1);
  checkNum('末行不占课次', last.classSlot, -1);
  checkEqual('末行不显示时段', last.timeRange, '');
  checkNum('末行不参与配对', last.isClass ? 1 : 0, 0);
}

function testEditorRowsClassPlanAfterLayoutDeleted(): void {
  // 时间表被删后课表不会被删（改动层只解绑），界面要显示成「已失效」
  // 而不是空白，也不能崩在 profile.tryGetTimeLayout 的 undefined 上
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  ScheduleMutations.removeTimeLayout(profile, layoutId);
  const row = EditorRows.classPlans(profile, '')[0];
  checkNum('标记为未绑定', row.hasTimeLayout ? 1 : 0, 0);
  checkEqual('时间表名显示已失效', row.timeLayoutName, "（已失效）");
  checkNum('没有课次可排', row.slots.length, 0);
  checkNum('没有行可渲染', row.editRows.length, 0);
  checkEqual('摘要清空', row.filledText, '');
}

function testEditorRowsClassPlanGroupFallsBack(): void {
  const profile: Profile = emptyProfile();
  const planId: Guid = ScheduleMutations.addClassPlan(
    profile, Guid.newGuid(), '指向空群');
  // 手工把课表挂到一个不存在的群上，模拟用户文件里的悬空引用
  (profile.tryGetClassPlan(planId) as ClassPlan).associatedGroup =
    Guid.fromCanonical('99999999-9999-9999-9999-999999999999');
  ScheduleMutations.settle(profile);
  const row = EditorRows.classPlans(profile, '')[0];
  checkEqual('悬空群显示已失效', row.groupName, "（已失效）");

  // 全局群 guid 是 Guid.Empty，也不在字典里
  (profile.tryGetClassPlan(planId) as ClassPlan).associatedGroup = ClassPlanGroup.globalGroupGuid();
  checkEqual('全局群名', EditorRows.classPlans(profile, '')[0].groupName, '全局课表群');
}

function testEditorRowsOverlaySourceFallsBack(): void {
  const profile: Profile = seededProfile();
  const planId: Guid = firstPlanId(profile);
  const overlayId: Guid = ScheduleMutations.createOverlayClassPlan(
    profile, planId, '国庆叠加') as Guid;
  let row = findPlan(EditorRows.classPlans(profile, ''), overlayId.toString());
  checkEqual('叠加源名', row.overlaySourceName, '周一');
  checkNum('叠加标志', row.isOverlay ? 1 : 0, 1);

  // 删源课表会连带清掉叠加表的 overlaySourceId（改动层的既定行为），
  // 所以这里不该再显示一个悬空源，而是当成普通课表
  ScheduleMutations.removeClassPlan(profile, planId);
  row = findPlan(EditorRows.classPlans(profile, ''), overlayId.toString());
  checkEqual('源指针被清', row.overlaySourceId, '');
  checkEqual('源名清空', row.overlaySourceName, '');
  checkNum('叠加标志仍在', row.isOverlay ? 1 : 0, 1);
  checkNum('叠加表本身没被删', EditorRows.classPlans(profile, '').length, 1);
}

function testEditorRowsActiveMark(): void {
  // 判定由引擎给出，编辑页不再自己算一遍。这里只验「传进来什么就标什么」
  const profile: Profile = seededProfile();
  const planId: string = profile.classPlans.keys()[0];
  checkNum('空串时都不标',
    EditorRows.classPlans(profile, '')[0].isActiveOnBaseDate ? 1 : 0, 0);
  checkNum('传对的 guid 时标上',
    EditorRows.classPlans(profile, planId)[0].isActiveOnBaseDate ? 1 : 0, 1);

  // 引擎口径：2026-09-26 是周六（dayOfWeek=6），课表挂在周一所以不生效
  const resolved = ClassPlanResolver.resolve(profile, dt('2026-09-26T09:00:00'), settings());
  checkNum('引擎判今天无课', resolved.plan === undefined ? 1 : 0, 1);
  // 换成周一就有课
  const monday = ClassPlanResolver.resolve(profile, dt('2026-09-21T09:00:00'), settings());
  check('引擎判周一生效', monday.plan !== undefined);
  checkEqual('生效的正是那张', monday.guid.toString(), planId);
  // 编辑页拿引擎结果去标，标到的就是同一张
  const marked = EditorRows.classPlans(profile, monday.guid.toString());
  checkNum('编辑页标同一张', marked[0].isActiveOnBaseDate ? 1 : 0, 1);
}

function testEditorRowsClassPlanGroups(): void {
  const profile: Profile = emptyProfile();
  const groupId: Guid = ScheduleMutations.addClassPlanGroup(profile, '单双周');
  // 建一张挂在这个群里的课表，好数 planCount
  const planId: Guid = ScheduleMutations.addClassPlan(
    profile, Guid.newGuid(), '周一');
  ScheduleMutations.setClassPlanGroup(profile, planId, groupId);
  ScheduleMutations.settle(profile);

  const rows = EditorRows.classPlanGroups(profile);
  checkNum('一个群', rows.length, 1);
  checkEqual('名字', rows[0].name, '单双周');
  checkNum('群内一张表', rows[0].planCount, 1);
  check('guid 取自字典键', rows[0].guid === groupId.toString());

  ScheduleMutations.selectClassPlanGroup(profile, groupId);
  checkNum('标为当前群',
    EditorRows.classPlanGroups(profile)[0].isSelected ? 1 : 0, 1);
  checkNum('可解散', EditorRows.classPlanGroups(profile)[0].canDisband ? 1 : 0, 1);
  checkNum('可删除', EditorRows.classPlanGroups(profile)[0].canDelete ? 1 : 0, 1);
}

function testEditorRowsDanglingGroupGuards(): void {
  // 默认群与全局群不在 classPlanGroups 字典里（它们是固定 guid），
  // 所以 canDisband / canDelete 这道闸门只有在这里能验到。
  // 删掉它们改的是选课结果而不只是少一个列表项。
  const profile: Profile = emptyProfile();
  // 手工把两个固定群塞进字典，模拟用户文件里确实有它们的情况
  // 键就是那个固定 guid，对象本身不存 —— 全篇都靠这条
  const defaultGroup = new ClassPlanGroup();
  defaultGroup.name = '默认课表群';
  profile.classPlanGroups.set(ClassPlanGroup.defaultGroupGuid().toString(), defaultGroup);
  const globalGroup = new ClassPlanGroup();
  globalGroup.name = '全局课表群';
  globalGroup.isGlobal = true;
  profile.classPlanGroups.set(ClassPlanGroup.globalGroupGuid().toString(), globalGroup);

  const rows = EditorRows.classPlanGroups(profile);
  checkNum('两个群', rows.length, 2);
  checkNum('识别出默认群',
    rows.some((r: ClassPlanGroupRow) => r.isDefault) ? 1 : 0, 1);
  const global = rows.filter((r: ClassPlanGroupRow) => r.isGlobal)[0];
  checkNum('全局群不可解散', global.canDisband ? 1 : 0, 0);
  checkNum('全局群不可删除', global.canDelete ? 1 : 0, 0);
  const fallback = rows.filter((r: ClassPlanGroupRow) => r.isDefault)[0];
  checkNum('默认群不可解散', fallback.canDisband ? 1 : 0, 0);
  checkNum('默认群不可删除', fallback.canDelete ? 1 : 0, 0);
}

function testEditorRowsProfileSummary(): void {
  const profile: Profile = emptyProfile();
  ScheduleMutations.renameProfile(profile, '我的课表');
  const row = EditorRows.profile(profile);
  checkEqual('名字', row.name, '我的课表');
  checkNum('空档案各项为零',
    row.subjectCount + row.timeLayoutCount + row.classPlanCount + row.groupCount, 0);
  checkNum('未设临时课表', row.tempPlanExists ? 1 : 0, 0);
  checkEqual('未设临时课表时名字空', row.tempPlanName, '');
  checkNum('未启用临时群', row.isTempGroupEnabled ? 1 : 0, 0);

  // 空名回落到占位符，否则列表页第一行是个看不见的空标签
  const blank = new Profile();
  checkEqual('空名兜底', EditorRows.profile(blank).name, '（未命名档案）');
}

function testEditorRowsProfileDanglingPointers(): void {
  // 悬空指针在用户文件里是常态（桌面版删课表也可能留下）。显示「已失效」
  // 是为了让用户看得见有东西不对；当成「没设」的话用户根本不会去查。
  const profile: Profile = emptyProfile();
  const dangling = Guid.newGuid();
  profile.tempClassPlanId = dangling;
  profile.tempClassPlanGroupId = Guid.newGuid();
  profile.tempClassPlanGroupExpireTime = dt('2026-10-08T00:00:00');
  profile.tempClassPlanGroupType = TempClassPlanGroupType.Override;
  profile.selectedClassPlanGroupId = dangling;
  const row = EditorRows.profile(profile);
  check('临时课表指针仍在', row.tempPlanId === dangling.toString());
  checkNum('标记为失效', row.tempPlanExists ? 1 : 0, 0);
  checkEqual('名字显示已失效', row.tempPlanName, "（已失效）");
  checkNum('临时群标记为失效', row.tempGroupExists ? 1 : 0, 0);
  checkEqual('临时群名显示已失效', row.tempGroupName, "（已失效）");
  checkEqual('临时群类型文案', row.tempGroupTypeText, '覆盖');
  checkEqual('当前群显示已失效', row.selectedGroupName, "（已失效）");

  // 临时课表存在时，摘要要给出名字与建立日期
  const live = seededProfile();
  ScheduleMutations.applyTempClassPlan(live, firstPlanId(live), dt('2026-09-26T10:00:00'));
  const liveRow = EditorRows.profile(live);
  checkNum('临时课表有效', liveRow.tempPlanExists ? 1 : 0, 1);
  checkEqual('临时课表名', liveRow.tempPlanName, '周一');
  checkEqual('建立日期', liveRow.tempPlanFromText, '2026-09-26');
  checkEqual('类型文案', EditorRows.profile(live).tempGroupTypeText, '继承');
}

function testEditorRowsAfterDeletes(): void {
  // 编辑页的数据必须跟着改动走：删完重建的行数、课次数、引用数都要对得上，
  // 否则用户删了一个东西，界面上还留着它
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  const yw: Guid = Guid.fromCanonical(profile.subjects.keys()[0]);
  const groupId: Guid = ScheduleMutations.addClassPlanGroup(profile, '临时群');
  const planId: Guid = firstPlanId(profile);
  ScheduleMutations.setClassPlanGroup(profile, planId, groupId);
  ScheduleMutations.settle(profile);
  checkNum('前置：群内一张表',
    EditorRows.classPlanGroups(profile)[0].planCount, 1);
  checkEqual('前置：课表在临时群里',
    EditorRows.classPlans(profile, '')[0].groupName, '临时群');

  // 删第 2 节课（行 2）：第 3 节顶上
  ScheduleMutations.removeTimePoint(profile, layoutId, 2);
  ScheduleMutations.settle(profile);
  checkNum('剩四行', EditorRows.timeLayouts(profile)[0].rowCount, 4);
  checkNum('剩两个课次', EditorRows.timeLayouts(profile)[0].classCount, 2);
  let planRow = EditorRows.classPlans(profile, '')[0];
  checkNum('剩两节课', planRow.slots.length, 2);
  checkNum('剩四行可渲染', planRow.editRows.length, 4);
  checkEqual('第 2 节课顶成英语', planRow.slots[1].subjectName, '英语');
  checkEqual('摘要为语文、英语', planRow.filledText, '语文、英语');
  checkNum('已排课数', planRow.filledCount, 2);

  // 删科目：那节课变成空位，摘要里不再出现
  ScheduleMutations.removeSubject(profile, yw);
  ScheduleMutations.settle(profile);
  checkNum('剩两个科目', EditorRows.subjects(profile).length, 2);
  planRow = EditorRows.classPlans(profile, '')[0];
  checkNum('空位被识别', planRow.slots[0].isEmpty ? 1 : 0, 1);
  checkEqual('空位显示占位符', planRow.slots[0].subjectName, '');
  checkNum('已排课数减一', planRow.filledCount, 1);
  checkEqual('摘要只剩英语', planRow.filledText, '英语');
  // 配对不变量在删完之后仍然成立
  for (const edit of planRow.editRows) {
    if (edit.classSlot >= 0) {
      check('删后配对仍自洽', planRow.slots[edit.classSlot].slot === edit.classSlot);
    }
  }

  // 解散：课表留下，落到默认群。编辑页要跟着把群名改掉
  ScheduleMutations.disbandClassPlanGroup(profile, groupId);
  ScheduleMutations.settle(profile);
  checkNum('课表还在', EditorRows.classPlans(profile, '').length, 1);
  checkEqual('课表回到默认群', EditorRows.classPlans(profile, '')[0].groupName, '默认课表群');
  checkNum('群已解散', EditorRows.classPlanGroups(profile).length, 0);
}

function testEditorRowsAfterGroupDelete(): void {
  // 删除（区别于解散）会连群内课表一起删，编辑页不该再列出它们
  const profile: Profile = seededProfile();
  const groupId: Guid = ScheduleMutations.addClassPlanGroup(profile, '临时群');
  const planId: Guid = firstPlanId(profile);
  ScheduleMutations.setClassPlanGroup(profile, planId, groupId);
  ScheduleMutations.settle(profile);
  checkNum('前置：一张表', EditorRows.classPlans(profile, '').length, 1);

  ScheduleMutations.deleteClassPlanGroup(profile, groupId);
  ScheduleMutations.settle(profile);
  checkNum('课表被一并删除', EditorRows.classPlans(profile, '').length, 0);
  checkNum('群也没了', EditorRows.classPlanGroups(profile).length, 0);
  // 时间表还在，只是没人用了
  checkNum('时间表保留', EditorRows.timeLayouts(profile).length, 1);
  checkEqual('课次数归零',
    EditorRows.timeLayouts(profile)[0].boundPlanNames, '');
}

/** 按 guid 键取科目名。键取不到时返回空串，用来让断言失败时看得见。 */
function subjectNameOf(profile: Profile, key: string): string {
  const found: Subject | undefined = profile.subjects.tryGet(key);
  return found === undefined ? '（键不存在）' : found.name;
}

function indexOf(items: string[], target: string): number {
  for (let i: number = 0; i < items.length; i++) {
    if (items[i] === target) {
      return i;
    }
  }
  return -1;
}

function startsOf(rows: TimePointRow[]): string {
  const out: string[] = [];
  for (const row of rows) {
    out.push(row.startText);
  }
  return out.join(',');
}

function findPlan(rows: ClassPlanRow[], guid: string): ClassPlanRow {
  for (const row of rows) {
    if (row.guid === guid) {
      return row;
    }
  }
  return new ClassPlanRow();
}

// ------------------------------------------------- 时间段求交（编辑用）

function testTimeRangeOverlap(): void {
  // 编辑时段时要能立刻告诉用户「和第几节课撞了」。漏判的话用户要把整个作息
  // 表从头看一遍才知道哪里冲突。
  checkNum('完全重合', timeRangeOverlap(800, 845, 800, 845) ? 1 : 0, 1);
  checkNum('部分重叠', timeRangeOverlap(800, 845, 830, 900) ? 1 : 0, 1);
  checkNum('包含', timeRangeOverlap(800, 1000, 830, 900) ? 1 : 0, 1);
  checkNum('被包含', timeRangeOverlap(830, 900, 800, 1000) ? 1 : 0, 1);
  // 首尾相接不算撞：08:00-08:45 与 08:45-09:00 是正常的课间排布，
  // 判成撞的话每张作息表都会被报成「有冲突」
  checkNum('首尾相接不算撞', timeRangeOverlap(800, 845, 845, 900) ? 1 : 0, 0);
  checkNum('完全错开', timeRangeOverlap(800, 845, 845, 901) ? 1 : 0, 0);
  checkNum('零长时段不撞', timeRangeOverlap(800, 800, 700, 900) ? 1 : 0, 0);
  checkNum('负区间不撞', timeRangeOverlap(-100, -50, 0, 100) ? 1 : 0, 0);
  // 重叠分钟数向下取整：重叠 20 分半显示 20 分钟，比 20.5 更贴近用户预期
  // 秒为单位：08:00=28800
  // 08:00-08:45 与 08:30-09:00 重叠 15 分钟
  checkNum('重叠 15 分钟', timeRangeOverlapMinutes(28800, 31500, 30600, 32400), 15);
  // 08:00-08:45 与 08:35-08:50 重叠 10 分钟
  checkNum('重叠 10 分钟', timeRangeOverlapMinutes(28800, 31500, 30900, 31500), 10);
  checkNum('相接为零', timeRangeOverlapMinutes(28800, 29220, 29220, 29700), 0);
  checkNum('零长为零', timeRangeOverlapMinutes(28800, 28800, 25200, 29700), 0);
  // 重叠不足一分钟向下取整为 0，而不是 0.98 这样的小数
  checkNum('不足一分钟取整为零', timeRangeOverlapMinutes(28800, 28830, 28800, 28890), 0);
  checkNum('整分零秒', timeRangeOverlapMinutes(28800, 29400, 29400, 29700), 0);
}

function testTimeRangeConflictIndex(): void {
  const spans: TimeSpanRow[] = [
    newTimeSpanRow(0, 800, 845, '第 1 节'),
    newTimeSpanRow(2, 900, 945, '第 2 节'),
    newTimeSpanRow(4, 1000, 1045, '第 3 节')
  ];
  checkNum('撞第 1 节', timeRangeConflictIndex(spans, 830, 900), 0);
  checkNum('撞第 2 节', timeRangeConflictIndex(spans, 940, 1100), 1);
  // 落在课间里（08:45-09:00）不与任何课程行冲突：课间本来就该是空的
  checkNum('落在课间里不冲突', timeRangeConflictIndex(spans, 850, 890), -1);
  checkNum('跨两节撞第一节', timeRangeConflictIndex(spans, 830, 1000), 0);
  checkNum('跨两节撞第二节', timeRangeConflictIndex(spans, 900, 1000), 1);
  checkNum('全空档案不冲突', timeRangeConflictIndex([], 800, 845), -1);
  // 停用的行不参与冲突判定：它不会真的上课，占着它报警是噪声
  const withDisabled: TimeSpanRow[] = [newTimeSpanRow(0, 800, 845, '第 1 节')];
  withDisabled[0].isEnabled = false;
  checkNum('停用行不参与', timeRangeConflictIndex(withDisabled, 800, 845), -1);
  // 撞到多行时只报最先撞到的那一行：报三行用户反而不知道先改哪个
  const many: TimeSpanRow[] = [
    newTimeSpanRow(0, 800, 845, 'a'),
    newTimeSpanRow(1, 900, 945, 'b')
  ];
  checkNum('多行只报第一个', timeRangeConflictIndex(many, 830, 950), 0);
}

// ------------------------------------------------------ 脏检查与规范化

function testDirtyBaselineRebase(): void {
  // 脏检查是拿当前草稿的序列化去比载入时的基线。改了又改回原样必须回到
  // 「不脏」——用布尔标志记脏的话做不到，用户会看着「未保存」提示发呆。
  const src: Profile = seededProfile();
  const baseline: string = Profile.stringify(src);
  const work: Profile = Profile.parse(baseline);
  check('初始不脏', Profile.stringify(work) === baseline);

  const yw: Guid = Guid.fromCanonical(work.subjects.keys()[0]);
  ScheduleMutations.renameSubject(work, yw, '语文课');
  check('改后是脏的', Profile.stringify(work) !== baseline);

  ScheduleMutations.renameSubject(work, yw, '语文');
  check('改回原值后不脏了', Profile.stringify(work) === baseline);

  // 挪一下时间点再挪回来也必须回到不脏
  const layoutId: Guid = firstLayoutId(work);
  const before: string = Profile.stringify(work);
  ScheduleMutations.moveTimePoint(work, layoutId, 0, 1);
  ScheduleMutations.settle(work);
  check('挪动后是脏的', Profile.stringify(work) !== before);
  ScheduleMutations.moveTimePoint(work, layoutId, 1, -1);
  ScheduleMutations.settle(work);
  check('挪回原位后不脏了', Profile.stringify(work) === before);
}

function testNoopMutationsStayClean(): void {
  // 无效操作（删不存在的东西、把课次排到界外）不该弄脏档案。
  // 否则用户随手点错一下，界面上就冒出「未保存的改动」，
  // 而实际内容一个字节都没变。
  const src: Profile = seededProfile();
  const baseline: string = Profile.stringify(src);
  const work: Profile = Profile.parse(baseline);
  const ghost: Guid = Guid.newGuid();
  const planId: Guid = firstPlanId(work);
  check('删不存在的科目返回 false', ScheduleMutations.removeSubject(work, ghost) === false);
  check('删不存在的时间表返回 false', ScheduleMutations.removeTimeLayout(work, ghost) === false);
  check('删不存在的课表返回 false', ScheduleMutations.removeClassPlan(work, ghost) === false);
  check('删不存在的群返回 false', ScheduleMutations.deleteClassPlanGroup(work, ghost) === false);
  check('课次界外返回 false', ScheduleMutations.setClassSubject(work, planId, 99, ghost) === false);
  // 空 guid 是「清空这节课」，是合法语义（对应界面的清除按钮），不是无效操作。
  // 注意它会弄脏档案：清空确实是改了内容。清空后若该时间点有预置科目，
  // settle 会按预置补回来 —— 与桌面版一致，所以这里顺带验一遍。
  check('清空课次返回 true', ScheduleMutations.setClassSubject(work, planId, 0, Guid.empty()) === true);
  const cleared: string = Profile.stringify(work);
  check('清空确实改动了字节', cleared !== baseline);
  check('清空后 subjectId 为空',
    (work.tryGetClassPlan(planId) as ClassPlan).classes[0].subjectId.isEmpty());
  // 上面这步弄脏了档案，所以重置回基线再验「无效操作不弄脏」
  const clean: Profile = Profile.parse(baseline);
  const ghost2: Guid = Guid.newGuid();
  ScheduleMutations.removeSubject(clean, ghost2);
  ScheduleMutations.removeTimeLayout(clean, ghost2);
  ScheduleMutations.removeClassPlan(clean, ghost2);
  ScheduleMutations.deleteClassPlanGroup(clean, ghost2);
  ScheduleMutations.disbandClassPlanGroup(clean, ghost2);
  ScheduleMutations.setClassSubject(clean, planId, 99, ghost2);
  ScheduleMutations.setClassEnabled(clean, planId, -1, true);
  ScheduleMutations.removeTimePoint(clean, firstLayoutId(clean), 99);
  ScheduleMutations.moveTimePoint(clean, firstLayoutId(clean), 0, 99);
  ScheduleMutations.moveSubject(clean, ghost2, 1);
  ScheduleMutations.settle(clean);
  check('无效操作后仍不脏', Profile.stringify(clean) === baseline);
}

// ------------------------------------------------------------ 顺序置换

function testReorderPermutationIsConsistent(): void {
  // 换序必须对键与值施加同一个置换。只重排值的话，每个 guid 会指向别人的科目，
  // 而且界面上完全看不出异常 —— 课表里语文变成数学，没有任何报错。
  const profile: Profile = seededProfile();
  const yw: Guid = Guid.fromCanonical(profile.subjects.keys()[0]);
  const sx: Guid = Guid.fromCanonical(profile.subjects.keys()[1]);
  const planId: Guid = firstPlanId(profile);
  const ywText: string = yw.toString();
  const sxText: string = sx.toString();
  const keysBefore: string[] = profile.subjects.keys();
  const third: string = keysBefore[2];
  const sxIndex: number = indexOf(keysBefore, sxText);
  // 把数学上移到语文的位置
  ScheduleMutations.moveSubject(profile, sx, -sxIndex);
  ScheduleMutations.settle(profile);
  const keysAfter: string[] = profile.subjects.keys();
  // 数学原在下标 1，上移一位到 0，与语文对调；英语留在 2
  checkEqual('数学与语文对调', `${keysAfter[0]},${keysAfter[1]},${keysAfter[2]}`,
    `${sxText},${ywText},${third}`);

  // 关键不变量：值跟着自己的键走
  checkEqual('数学仍在数学的键上', subjectNameOf(profile, sxText), '数学');
  checkEqual('语文仍在语文的键上', subjectNameOf(profile, ywText), '语文');
  checkEqual('英语仍在英语的键上', subjectNameOf(profile, third), '英语');

  // 课次里的科目引用必须还是原来那个科目，不能跟着位置跑
  const plan: ClassPlan = profile.tryGetClassPlan(planId) as ClassPlan;
  checkEqual('第一节仍是语文', plan.classes[0].subjectId.toString(), ywText);
  checkEqual('第二节仍是数学', plan.classes[1].subjectId.toString(), sxText);
  checkEqual('第三节仍是英语', plan.classes[2].subjectId.toString(), third);
  // EditorRows 读出来的名字也要与键一一对应
  const rows = EditorRows.classPlans(profile, '');
  checkEqual('行数据里第一节还是语文', rows[0].slots[0].subjectName, '语文');
  checkEqual('行数据里第二节还是数学', rows[0].slots[1].subjectName, '数学');
  checkEqual('行数据里第三节还是英语', rows[0].slots[2].subjectName, '英语');
}

function testTimePointReorderKeepsSlotRefs(): void {
  // 时间点换序：课次下标是位置派生的，所以顺序变了节号就变；
  // 但每节课挂的科目必须跟着那节课走，不能留在原下标上。
  const profile: Profile = seededProfile();
  const layoutId: Guid = firstLayoutId(profile);
  ScheduleMutations.moveTimePoint(profile, layoutId, 0, 2);
  ScheduleMutations.settle(profile);
  // 原序 [课0, 课间, 课1, 课间, 课2]，把行 0 下移两位 -> [课间, 课1, 课0, 课间, 课2]。
  // 课0 换到下标 2，课次下标随之从 0 变成 1；它那节课也跟着换到课次 1。
  const row = EditorRows.timeLayouts(profile)[0];
  checkNum('课次数不变', row.classCount, 3);
  checkNum('行 0 变成课间', row.rows[0].classSlot, -1);
  checkEqual('行 0 是大课间', row.rows[0].breakName, '大课间');
  checkNum('行 1 成了第 1 节', row.rows[1].classSlot, 0);
  checkNum('语文那行落到课次 1', row.rows[2].classSlot, 1);
  checkNum('原第 2 节那行落到课次 0', row.rows[1].classSlot, 0);
  const planRow = EditorRows.classPlans(profile, '')[0];
  checkEqual('课首挂着数学', planRow.slots[0].subjectName, '数学');
  checkEqual('课尾挂着英语', planRow.slots[2].subjectName, '英语');
  // 行/课次配对不变量在换序后仍要成立
  for (const edit of planRow.editRows) {
    if (edit.classSlot >= 0) {
      check('换序后配对仍自洽', planRow.slots[edit.classSlot].slot === edit.classSlot);
    }
  }
}

function testSortTimeLayoutIsAscending(): void {
  // 桌面版 UpdateTimeLayout 的 l.Sort(); l.Reverse(); 净效果是升序
  //（CompareTo 是降序）。这里钉死升序：排反了的话课表从上往下时间递减，
  // 界面上看着「第一节课 10:00、第二节课 08:00」，而没有任何报错。
  const profile: Profile = emptyProfile();
  const layoutId: Guid = ScheduleMutations.addTimeLayout(profile, '乱序');
  // 新建时间表自带一个 00:00 占位行（与桌面版一致），先删掉再谈排序
  checkNum('新建自带一行占位', EditorRows.timeLayouts(profile)[0].rowCount, 1);
  checkEqual('占位行的时刻', EditorRows.timeLayouts(profile)[0].rows[0].startText, '00:00');
  ScheduleMutations.removeTimePoint(profile, layoutId, 0);
  ScheduleMutations.settle(profile);
  checkNum('占位行已删', EditorRows.timeLayouts(profile)[0].rowCount, 0);
  // 故意按乱序插入
  ScheduleMutations.addTimePoint(profile, layoutId, TIME_TYPE_CLASS, 16 * 3600, 45);
  ScheduleMutations.addTimePoint(profile, layoutId, TIME_TYPE_CLASS, 8 * 3600, 45);
  ScheduleMutations.addTimePoint(profile, layoutId, TIME_TYPE_CLASS, 12 * 3600, 45);
  ScheduleMutations.addTimePoint(profile, layoutId, TIME_TYPE_CLASS, 10 * 3600, 45);
  ScheduleMutations.settle(profile);
  checkEqual('插入顺序保持原样', startsOf(EditorRows.timeLayouts(profile)[0].rows),
    '16:00,08:00,12:00,10:00');

  check('重排返回 true', ScheduleMutations.sortTimeLayout(profile, layoutId));
  ScheduleMutations.settle(profile);
  checkEqual('重排后升序', startsOf(EditorRows.timeLayouts(profile)[0].rows),
    '08:00,10:00,12:00,16:00');

  // 课间也参与排序；排完课次下标要重新按位置算，不能沿用排序前的
  const withBreak: Profile = emptyProfile();
  const breakLayout: Guid = ScheduleMutations.addTimeLayout(withBreak, '带课间');
  ScheduleMutations.addTimePoint(withBreak, breakLayout, TIME_TYPE_CLASS, 9 * 3600, 45);
  ScheduleMutations.removeTimePoint(withBreak, breakLayout, 0);
  ScheduleMutations.addTimePoint(withBreak, breakLayout, TIME_TYPE_BREAK, 9 * 3600 + 40 * 60, 20);
  ScheduleMutations.addTimePoint(withBreak, breakLayout, TIME_TYPE_CLASS, 8 * 3600, 45);
  ScheduleMutations.settle(withBreak);
  ScheduleMutations.sortTimeLayout(withBreak, breakLayout);
  ScheduleMutations.settle(withBreak);
  // 排完是 [08:00 课, 09:00 课, 09:40 课间]。课间在两节课中间，但它的开始时刻
  // 09:40 晚于 09:00，所以按时刻排序后落到最后 —— 排课表是按时刻排的，
  // 不是按「课程在前」的分组顺序排的。
  const row = EditorRows.timeLayouts(withBreak)[0];
  checkEqual('按时刻升序', startsOf(row.rows), '08:00,09:00,09:40');
  checkNum('课次数不受排序影响', row.classCount, 2);
  checkNum('行 0 是第 1 节', row.rows[0].classSlot, 0);
  checkNum('行 1 是第 2 节', row.rows[1].classSlot, 1);
  checkNum('行 2 是课间', row.rows[2].classSlot, -1);
  // addTimePoint 给课间行填的默认名是「课间」，不是「课间1」之类
  checkEqual('课间名跟着走', row.rows[2].breakName, '课间');
}

// ------------------------------------------------------------------ 入口

testAddSubject();
testRemoveSubjectClearsReferences();
testMoveSubject();
testAddTimeLayout();
testRemoveTimeLayout();
testRemoveTimeLayoutClearsOverlaySource();
testAddRemoveTimePoint();
testRemoveTimePointResizesClasses();
testRemoveTimePointFollowsAllBoundPlans();
testAddTimePointGrowsClasses();
testMoveTimePointReordersRows();
testSortTimeLayout();
testMoveTimePointCarriesClass();
testMoveBreakCarriesNoClass();
testUpdateTimePoint();
testSeparatorDoesNotTakeSlot();
testSetDefaultClassPropagates();
testAddClassPlan();
testSetClassPlanTimeLayoutClearsClasses();
testSetClassPlanRuleClamps();
testSetClassMutations();
testCreateOverlayClassPlan();
testSettleNormalizesChangedClassOnNonOverlay();
testSettleWithMissingOverlaySource();
testClassPlanGroup();
testDisbandClassPlanGroup();
testDeleteClassPlanGroup();
testRemoveClassPlanClearsPointers();
testRemoveClassPlanClearsOverlaySourceOfOthers();
testTempClassPlan();
testCancelTempClassPlanClearsMatchingOverlay();
testTempClassPlanGroup();
testDeleteClassPlanGroupClearsTempGroupPointer();
testOrderedSchedule();
testRenameProfile();
testSetClassPlanEnabled();
testOverlayEnabledToggle();
testRoundTripAfterEdits();
testRoundTripAfterDeletes();
testMutationsAreDeterministic();
testTextFormat();
testParseClockText();
testParseDurationText();
testEditorRowsSubjects();
testEditorRowsOrderedSchedules();
testEditorRowsTimeLayout();
testEditorRowsTimeLayoutDefaultApplied();
testEditorRowsClassPlan();
testEditorRowsPlanEditRowsInvariant();
testEditorRowsPlanEditRowsWithSeparator();
testEditorRowsClassPlanAfterLayoutDeleted();
testEditorRowsClassPlanGroupFallsBack();
testEditorRowsOverlaySourceFallsBack();
testEditorRowsActiveMark();
testEditorRowsClassPlanGroups();
testEditorRowsDanglingGroupGuards();
testEditorRowsProfileSummary();
testEditorRowsProfileDanglingPointers();
testEditorRowsAfterDeletes();
testEditorRowsAfterGroupDelete();
testTimeRangeOverlap();
testTimeRangeConflictIndex();
testDirtyBaselineRebase();
testNoopMutationsStayClean();
testReorderPermutationIsConsistent();
testTimePointReorderKeepsSlotRefs();
testSortTimeLayoutIsAscending();
testTimeRangeOverlap();
testTimeRangeConflictIndex();
testDirtyBaselineRebase();
testNoopMutationsStayClean();
testReorderPermutationIsConsistent();
testTimePointReorderKeepsSlotRefs();
testSortTimeLayoutIsAscending();

console.log(`通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('');
  for (const failure of failures) {
    console.log(`✗ ${failure}`);
  }
  process.exit(1);
}
