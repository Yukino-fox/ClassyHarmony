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

console.log(`通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('');
  for (const failure of failures) {
    console.log(`✗ ${failure}`);
  }
  process.exit(1);
}
