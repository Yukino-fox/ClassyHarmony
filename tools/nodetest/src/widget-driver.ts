/*
 * 小组件视图数据测试台。
 *
 * 小组件这条路上唯一能在装机之前测的就是 WidgetBuilder —— FormExtensionAbility
 * 10 秒就被回收，看一眼真机也看不出「5 分钟后叫醒它算得对不对」。所以这里的断言
 * 全是纯函数的输出，重点覆盖四类最容易错的地方：
 *
 *   1. 时刻边界。正在上的课必须出现在列表第一条（用 end >= now 过滤，不是 start）。
 *      课程状态机那边是两端闭区间，卡片这边若用开区间，08:00 整那一刻会短暂
 *      显示「下一节 08:00」而没有「正在上课」。
 *   2. 跨天。今天上完之后必须滚到下一个有课的日子，且日期标签同步换掉。
 *      不滚的话卡片在放学后到第二天早上这段时间是空白装饰。
 *   3. 容量。2*4 排 3 节、4*4 排 6 节，截断之后 currentIndex / nextIndex 仍要
 *      指向被截断后的下标 —— 这两个下标是界面高亮用的，越界会高亮到别的行。
 *   4. 刷新时点。nextRefreshMinutes 夹在 [5, 720]，且不会因为「下一节就在 2 分钟后」
 *      而给出一个小于平台下限的值（那一次 setFormNextRefreshTime 会直接报 401）。
 *
 * 另有一组断言把 encode/decode 走一遍：卡片与扩展之间只隔一个 FormBindingData，
 * 那一层过的是 JSON，所以编解码必须是无损的往返，否则装机后表现为卡片空白，
 * 而且日志里什么都看不到。
 */

import { ClassInfo } from '../../common_shared/src/main/ets/models/ClassInfo';
import { ClassPlan } from '../../common_shared/src/main/ets/models/ClassPlan';
import { ClassPlanGroup } from '../../common_shared/src/main/ets/models/ClassPlanGroup';
import { DateTimeValue } from '../../common_shared/src/main/ets/json/DateTimeValue';
import { Guid } from '../../common_shared/src/main/ets/json/Guid';
import { Profile } from '../../common_shared/src/main/ets/models/Profile';
import { Subject } from '../../common_shared/src/main/ets/models/Subject';
import { TimeLayout } from '../../common_shared/src/main/ets/models/TimeLayout';
import { TimeLayoutItem } from '../../common_shared/src/main/ets/models/TimeLayoutItem';
import { TimeRule } from '../../common_shared/src/main/ets/models/TimeRule';
import { TimeSpanValue } from '../../common_shared/src/main/ets/json/TimeSpanValue';
import { EngineSettings } from '../../common_core/src/main/ets/engine/EngineSettings';
import { ScheduleMutations } from '../../common_core/src/main/ets/edit/ScheduleMutations';
import {
  WIDGET_REFRESH_MAX_MINUTES,
  WIDGET_REFRESH_MIN_MINUTES,
  WidgetBuilder,
  WidgetCodec,
  WidgetDimension,
  WidgetModel
} from '../../common_core/src/main/ets/view/WidgetModel';

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

const SUBJECT_YUWEN: string = '11111111-1111-1111-1111-111111111111';
const SUBJECT_SHUXUE: string = '22222222-2222-2222-2222-222222222222';
const SUBJECT_YINGYU: string = '33333333-3333-3333-3333-333333333333';
const LAYOUT_ID: string = 'aaaaaaaa-0000-0000-0000-000000000001';

/** 2026-09-26 是周六（dayOfWeek=6），与其它驱动同基准。 */
const BASE_DAY: string = '2026-09-26';

function dt(text: string): DateTimeValue {
  return DateTimeValue.parseOrMin(text);
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

function settings(): EngineSettings {
  // 单周起始日取周日，与 AppSettings.defaultEngineSettings 同口径。
  return new EngineSettings(dt('2026-09-20T00:00:00'));
}

/** 为 days 列出的星期几各建一张课表，科目依次 语文/数学/英语。 */
function profileForDays(days: number[], layout?: TimeLayout): Profile {
  const profile: Profile = new Profile();
  profile.name = '小组件测试';
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

function schoolWeekProfile(): Profile {
  return profileForDays([1, 2, 3, 4, 5]);
}

function build(profile: Profile, at: string, dimension?: string): WidgetModel {
  if (dimension === undefined) {
    return WidgetBuilder.build(profile, settings(), dt(at));
  }
  return WidgetBuilder.build(profile, settings(), dt(at), dimension);
}

function subjectNames(model: WidgetModel): string {
  const parts: string[] = [];
  for (const lesson of model.lessons) {
    parts.push(lesson.subjectName);
  }
  return parts.join(',');
}

// ------------------------------------------------------------------ A. 时刻边界

function testCurrentLessonAlwaysFirst(): void {
  const profile: Profile = fullWeekProfile();

  // 课中：正在上的那节必须在第一条，且 isCurrent。
  const during: WidgetModel = build(profile, `${BASE_DAY}T08:20:00`);
  checkNum('课中 currentIndex 指向第一条', during.currentIndex, 0);
  checkEqual('课中 headline 是当前科目', during.headline, '语文');
  checkEqual('课中 headlineHint', during.headlineHint, '正在上课');
  checkEqual('课中 dayLabel', during.dayLabel, '今天');
  checkEqual('课中不标下一节', `${during.lessons[0].isNext}`, 'false');
  check('课中 currentIndex 有效', during.lessons[0].isCurrent);
  // 正在上第一节时，「下一节」是第二节而不是第一节 —— 第一节已经是「现在」了。
  checkNum('课中 nextIndex 指向第二节', during.nextIndex, 1);
  checkEqual('课中下一节是数学', during.lessons[during.nextIndex].subjectName, '数学');

  // 精确落在开始时刻：两端闭，与引擎口径一致。
  const atStart: WidgetModel = build(profile, `${BASE_DAY}T08:00:00`);
  check('开始时刻整点算正在上', atStart.lessons[0].isCurrent);
  checkEqual('开始时刻整点 headlineHint', atStart.headlineHint, '正在上课');

  // 精确落在结束时刻：引擎是闭区间，08:45:00 仍算在上课。
  const atEnd: WidgetModel = build(profile, `${BASE_DAY}T08:45:00`);
  check('结束时刻整点仍算正在上', atEnd.lessons[0].isCurrent);

  // 结束时刻 + 1 秒：第一节被滤掉，首位变成第二节。
  const justAfter: WidgetModel = build(profile, `${BASE_DAY}T08:45:01`);
  checkNum('过了结束时刻 currentIndex 归位', justAfter.currentIndex, -1);
  checkEqual('过了结束时刻首位是第二节', justAfter.lessons[0].subjectName, '数学');
  checkEqual('过了结束时刻 headlineHint', justAfter.headlineHint, '09:00 上课');
  check('过了结束时刻第一节被筛掉', subjectNames(justAfter) === '数学,英语',
    `实际 ${subjectNames(justAfter)}`);
}

function testBeforeFirstLesson(): void {
  const profile: Profile = fullWeekProfile();
  const before: WidgetModel = build(profile, `${BASE_DAY}T07:30:00`);
  checkNum('还没上课 currentIndex 为 -1', before.currentIndex, -1);
  checkNum('还没上课 nextIndex 为 0', before.nextIndex, 0);
  checkEqual('还没上课 headline 是第一节', before.headline, '语文');
  checkEqual('还没上课 headlineHint 带时刻', before.headlineHint, '08:00 上课');
  checkEqual('还没上课列出全部三节', subjectNames(before), '语文,数学,英语');
}

function testDuringBreak(): void {
  const profile: Profile = fullWeekProfile();
  // 大课间 08:45-09:00：第一节已结束、第二节未开始，首位是第二节且不是「正在上」。
  const inBreak: WidgetModel = build(profile, `${BASE_DAY}T08:50:00`);
  checkNum('课间 currentIndex 为 -1', inBreak.currentIndex, -1);
  checkEqual('课间首位是第二节', inBreak.lessons[0].subjectName, '数学');
  check('课间不把课间算成一节课', inBreak.lessons.length === 2,
    `实际 ${inBreak.lessons.length} 节`);
}

function testDisabledClassExcluded(): void {
  const profile: Profile = fullWeekProfile();
  const planKeyOfSaturday: string = planKey(6);
  const plan: ClassPlan | undefined = profile.tryGetClassPlan(Guid.fromCanonical(planKeyOfSaturday));
  check('取到基准日的课表', plan !== undefined);
  if (plan === undefined) {
    return;
  }
  ScheduleMutations.setClassEnabled(profile, Guid.fromCanonical(planKeyOfSaturday), 0, false);
  ScheduleMutations.settle(profile);

  const model: WidgetModel = build(profile, `${BASE_DAY}T07:30:00`);
  // 停用第一节后 validTimeLayoutItems 会连带去掉它后面的课间，剩下两节。
  checkEqual('停用的课不出现', subjectNames(model), '数学,英语');
  checkEqual('停用后 headline 跟着换', model.headline, '数学');
}

function testChangedClassFlag(): void {
  // 调课标记只对叠加课表有意义：ClassPlan.refreshIsChangedClass 每次 settle 都会
  // 按「与叠加来源的科目差异」重算它，普通课表上直接写 true 会被刷回 false。
  // 所以这条断言必须走叠加表，否则测的是一个不存在的语义。
  const profile: Profile = fullWeekProfile();
  const sourceKey: string = planKey(6);
  const overlayId: Guid | undefined =
    ScheduleMutations.createOverlayClassPlan(profile, Guid.fromCanonical(sourceKey), '周六叠加');
  check('建出叠加课表', overlayId !== undefined);
  if (overlayId === undefined) {
    return;
  }
  ScheduleMutations.setClassSubject(profile, overlayId, 1, Guid.fromCanonical(SUBJECT_YINGYU));
  ScheduleMutations.settle(profile);

  // 叠加表不参与常规选课，要靠 TempClassPlanId 拉起来才能被选到。
  ScheduleMutations.applyTempClassPlan(profile, overlayId, dt('2026-09-26T07:00:00'));
  const model: WidgetModel = build(profile, `${BASE_DAY}T07:30:00`);
  checkEqual('临时课表生效后 planTag 标出来', model.planTag, '临时');
  checkEqual('走的是叠加表的课', subjectNames(model), '语文,英语,英语');
  check('换过科目的那节标为调课', model.lessons[1].isChangedClass);
  check('没换的那节不标', !model.lessons[0].isChangedClass);
}

// ------------------------------------------------------------------ B. 跨天

function testRollsToNextSchoolDay(): void {
  // 只有周一到周五有课。基准日是周六。
  const profile: Profile = schoolWeekProfile();

  const weekend: WidgetModel = build(profile, `${BASE_DAY}T09:00:00`);
  checkEqual('周六显示下周一', weekend.dayLabel, '周一');
  // 周六往后：周日没有课，周一才是第一个有课的日子，所以是 2 而不是 1。
  checkNum('下周一在 offset 2', weekend.dayOffset, 2);
  checkEqual('下周一 dateText', weekend.dateText, '9月28日 周一');
  checkEqual('下周一 headline', weekend.headline, '语文');
  // 非今天不写「上课」二字：那天还没到，说「08:00 上课」会让人以为快上课了。
  checkEqual('未来那天只给时刻', weekend.headlineHint, '08:00');
  check('未来那天没有 isCurrent', weekend.lessons[0].isCurrent === false);
  check('未来那天标了 isNext', weekend.lessons[0].isNext);
}

function testAfterLastLessonRollsForward(): void {
  const profile: Profile = fullWeekProfile();
  // 周六最后一节 10:45 结束。11:00 之后今天没课了，应滚到周日。
  const after: WidgetModel = build(profile, `${BASE_DAY}T11:00:00`);
  checkEqual('上完课滚到明天', after.dayLabel, '明天');
  checkNum('明天 dayOffset 为 1', after.dayOffset, 1);
  checkEqual('明天 dateText', after.dateText, '9月27日 周日');
  checkEqual('明天 headline', after.headline, '语文');
}

function testLabelAtLongerOffset(): void {
  // 只有周三有课。周六(9/26)往后找，第一个有课的日子是 9/30，offset 4。
  const profile: Profile = profileForDays([3]);
  const model: WidgetModel = build(profile, `${BASE_DAY}T09:00:00`);
  checkNum('往后 4 天', model.dayOffset, 4);
  checkEqual('offset 4 显示星期名', model.dayLabel, '周三');
  checkEqual('offset 4 的日期', model.dateText, '9月30日 周三');
  // 找不到星期名兜底时不留空白。
  check('标签不为空', model.dayLabel.length > 0);
}

function testEmptyProfile(): void {
  const empty: Profile = new Profile();
  empty.refreshDerivedState();
  const model: WidgetModel = build(empty, `${BASE_DAY}T09:00:00`);
  check('空档案走 isEmpty', model.isEmpty);
  checkEqual('空档案提示是「还没有课表」', model.emptyHint, '还没有课表');
  checkEqual('空档案仍给日期', model.dateText, '9月26日 周六');
  checkEqual('空档案 dayLabel', model.dayLabel, '今天');
  checkNum('空档案没有课程', model.lessons.length, 0);
}

function testPlansButNoClasses(): void {
  // 课表存在但三节课全部停用 -> 7 天内每天都选得出课表，却没有一节课可上。
  // 这时该说「这一周没有课」而不是「还没有课表」：两者的下一步完全不同。
  const profile: Profile = fullWeekProfile();
  profile.classPlans.forEach((plan: ClassPlan, key: string) => {
    for (let slot: number = 0; slot < plan.classes.length; slot++) {
      ScheduleMutations.setClassEnabled(profile, Guid.fromCanonical(key), slot, false);
    }
  });
  ScheduleMutations.settle(profile);

  const model: WidgetModel = build(profile, `${BASE_DAY}T07:00:00`);
  check('全停用走 isEmpty', model.isEmpty);
  checkEqual('全停用的提示', model.emptyHint, '这一周没有课');
}

// ------------------------------------------------------------------ C. 容量

function testCapacity(): void {
  const profile: Profile = fullWeekProfile();

  const compact: WidgetModel = build(profile, `${BASE_DAY}T07:30:00`, WidgetDimension.COMPACT);
  checkNum('2*4 排 3 节', compact.lessons.length, 3);

  const roomy: WidgetModel = build(profile, `${BASE_DAY}T07:30:00`, WidgetDimension.ROOMY);
  // 标准作息只有 3 节，4*4 排不满是正常的：容量是上限不是配额。
  checkNum('4*4 至少装得下 3 节', roomy.lessons.length, 3);
  checkEqual('4*4 与 2*4 内容一致', subjectNames(roomy), subjectNames(compact));

  const small: WidgetModel = build(profile, `${BASE_DAY}T07:30:00`, WidgetDimension.SMALL);
  checkNum('2*2 排 2 节', small.lessons.length, 2);
  checkNum('2*2 的 nextIndex 仍在 0', small.nextIndex, 0);

  const tiny: WidgetModel = build(profile, `${BASE_DAY}T07:30:00`, WidgetDimension.TINY);
  checkNum('1*1 排 1 节', tiny.lessons.length, 1);
  checkEqual('1*1 只有第一节', tiny.headline, '语文');
}

function testTruncationKeepsIndices(): void {
  // 造一张 8 节课的时间表，好把 4*4 截断到 6 节。
  const profile: Profile = profileForDays([6], eightClassLayout());
  const model: WidgetModel = build(profile, `${BASE_DAY}T08:20:00`, WidgetDimension.ROOMY);
  checkNum('4*4 截到 6 节', model.lessons.length, 6);
  checkNum('截断后 currentIndex 仍指向第一条', model.currentIndex, 0);
  checkNum('截断后 nextIndex 指向第二节', model.nextIndex, 1);
  checkEqual('截断后 headline', model.headline, '语文');

  const roomier: WidgetModel = build(profile, `${BASE_DAY}T08:20:00`, WidgetDimension.COMPACT);
  checkNum('2*4 截到 3 节', roomier.lessons.length, 3);
  checkNum('2*4 截断后 currentIndex', roomier.currentIndex, 0);
}

/** 8 节课连排，08:00 到 12:20，课程时段下标 0..7。 */
function eightClassLayout(): TimeLayout {
  const layout: TimeLayout = new TimeLayout();
  layout.name = '长作息';
  const items: TimeLayoutItem[] = [];
  let minutes: number = 8 * 60;
  for (let i: number = 0; i < 8; i++) {
    const start: number = minutes;
    const end: number = minutes + 40;
    items.push(item(0, hms(start), hms(end)));
    minutes = end + 5;
  }
  layout.layouts = items;
  return layout;
}

function hms(totalMinutes: number): string {
  const h: number = Math.floor(totalMinutes / 60);
  const m: number = totalMinutes % 60;
  return `${h < 10 ? '0' : ''}${h}:${m < 10 ? '0' : ''}${m}:00`;
}

// ------------------------------------------------------------------ D. 刷新时点

function testRefreshMinutesBounds(): void {
  const profile: Profile = fullWeekProfile();

  // 08:20 正在上第一节，08:45 结束 -> 25 分钟。
  const during: WidgetModel = build(profile, `${BASE_DAY}T08:20:00`);
  checkNum('课中按下课时刻算', during.nextRefreshMinutes, 25);

  // 07:30 距第一节开始 30 分钟。
  const before: WidgetModel = build(profile, `${BASE_DAY}T07:30:00`);
  checkNum('未上课按上课时刻算', before.nextRefreshMinutes, 30);

  // 08:44 距下课 1 分钟 —— 小于平台下限 5，必须夹上去，否则 setFormNextRefreshTime 报 401。
  const imminent: WidgetModel = build(profile, `${BASE_DAY}T08:44:00`);
  checkNum('临近边界夹到平台下限', imminent.nextRefreshMinutes, WIDGET_REFRESH_MIN_MINUTES);

  for (const model of [during, before, imminent]) {
    check('刷新时点落在平台区间内',
      model.nextRefreshMinutes >= WIDGET_REFRESH_MIN_MINUTES &&
      model.nextRefreshMinutes <= WIDGET_REFRESH_MAX_MINUTES,
      `实际 ${model.nextRefreshMinutes}`);
  }
}

function testRefreshForFutureDay(): void {
  const profile: Profile = fullWeekProfile();
  // 周六 23:00 -> 明天(周日)第一节 08:00。日期标签会在 1 小时后从「明天」变成
  // 「周日」，那也是一次内容变化，比等 9 小时后上课更早该醒。
  const lateNight: WidgetModel = build(profile, `${BASE_DAY}T23:00:00`);
  checkEqual('深夜滚到明天', lateNight.dayLabel, '明天');
  checkNum('深夜先等标签变化', lateNight.nextRefreshMinutes, 60);

  // 周六 00:30 还在「今天」（第一节 08:00 才开始），所以走的是今天的分支：
  // 距第一节 7.5 小时。把它写成 450 是想钉住「凌晨也要显示今天」——
  // 若按「现在已经过了 00:00 就该看明天」的思路实现，这里会变成 1410。
  const earlyMorning: WidgetModel = build(profile, `${BASE_DAY}T00:30:00`);
  checkEqual('凌晨仍显示今天', earlyMorning.dayLabel, '今天');
  checkNum('凌晨等今天第一节', earlyMorning.nextRefreshMinutes, 450);

  // 这条是「现在必须当作真实当前时刻」的回归：早上的卡片不能按当天零点算，
  // 否则「还有多久到明天第一节」会算成 32 小时，卡片一整天不更新。
  const noonish: WidgetModel = build(profile, `${BASE_DAY}T12:00:00`);
  checkEqual('中午滚到明天', noonish.dayLabel, '明天');
  checkNum('中午到明天零点是 12 小时', noonish.nextRefreshMinutes, 720);
}

function testEmptyRefreshIsMax(): void {
  const empty: Profile = new Profile();
  empty.refreshDerivedState();
  const model: WidgetModel = build(empty, `${BASE_DAY}T09:00:00`);
  checkNum('空档案不频繁自唤醒', model.nextRefreshMinutes, WIDGET_REFRESH_MAX_MINUTES);
}

// ------------------------------------------------------------------ E. 编解码

function testCodecRoundTrip(): void {
  const profile: Profile = fullWeekProfile();
  const model: WidgetModel = build(profile, `${BASE_DAY}T08:20:00`, WidgetDimension.ROOMY);
  const text: string = WidgetCodec.encode(model);
  const back: WidgetModel = WidgetCodec.decode(text);

  checkEqual('往返后 headline', back.headline, model.headline);
  checkEqual('往返后 headlineHint', back.headlineHint, model.headlineHint);
  checkEqual('往返后 dayLabel', back.dayLabel, model.dayLabel);
  checkEqual('往返后 dateText', back.dateText, model.dateText);
  checkEqual('往返后 planName', back.planName, model.planName);
  checkEqual('往返后 planTag', back.planTag, model.planTag);
  checkEqual('往返后 dimension', back.dimension, model.dimension);
  checkNum('往返后 currentIndex', back.currentIndex, model.currentIndex);
  checkNum('往返后 nextIndex', back.nextIndex, model.nextIndex);
  checkNum('往返后 nextRefreshMinutes', back.nextRefreshMinutes, model.nextRefreshMinutes);
  checkNum('往返后课程数', back.lessons.length, model.lessons.length);
  checkEqual('往返后指纹一致', back.displaySignature(), model.displaySignature());
  checkEqual('编解码是幂等的', WidgetCodec.encode(back), text);
}

function testCodecEscapesText(): void {
  // 课表名带引号与反斜杠、中文、引号。JSON 转义错了卡片就整个读不出来，
  // 而这里最容易漏的是 & < > ` 这几个 HTML 敏感字符。
  const profile: Profile = fullWeekProfile();
  profile.classPlans.forEach((plan: ClassPlan) => {
    plan.name = 'A"B\\C<D>E&F`G语文';
  });
  profile.refreshDerivedState();

  const model: WidgetModel = build(profile, `${BASE_DAY}T07:30:00`);
  const back: WidgetModel = WidgetCodec.decode(WidgetCodec.encode(model));
  checkEqual('特殊字符往返无损', back.planName, 'A"B\\C<D>E&F`G语文');
  checkEqual('特殊字符下指纹一致', back.displaySignature(), model.displaySignature());
}

function testCodecToleratesGarbage(): void {
  // 解析不出来、或根本不是对象：给「正在载入」占位，绝不抛异常 ——
  // 卡片是在渲染路径上调 decode 的，抛异常的表现是卡片一片空白而不是一句提示。
  for (const text of ['', '   ', 'not json', '{', '[]', 'null', '"x"', '42']) {
    const model: WidgetModel = WidgetCodec.decode(text);
    check(`坏输入退化为占位：${text.length === 0 ? '(空)' : text}`,
      model.isEmpty && model.emptyHint === '正在载入…',
      `实际 isEmpty=${model.isEmpty} hint=${model.emptyHint}`);
    checkNum(`坏输入不留课程：${text}`, model.lessons.length, 0);
  }

  // 合法对象但字段缺失：用默认值补齐，不崩也不臆造。
  const partial: WidgetModel = WidgetCodec.decode('{"headline":"数学"}');
  checkEqual('缺字段时 headline 取到', partial.headline, '数学');
  checkNum('缺字段时课程为空', partial.lessons.length, 0);
  check('缺字段时不崩', partial.displaySignature().length > 0);
  // 字段类型对不上（dimension 是数字）也不能抛，按字符串读。
  const mistyped: WidgetModel = WidgetCodec.decode('{"dimension":42,"isEmpty":true}');
  check('类型不符时不崩', mistyped.isEmpty && mistyped.displaySignature().length > 0);
}

function testCodecEmptyLessonList(): void {
  const empty: Profile = new Profile();
  empty.refreshDerivedState();
  const model: WidgetModel = build(empty, `${BASE_DAY}T09:00:00`);
  const back: WidgetModel = WidgetCodec.decode(WidgetCodec.encode(model));
  check('空模型往返后仍 isEmpty', back.isEmpty);
  checkEqual('空模型往返后提示一致', back.emptyHint, model.emptyHint);
  checkEqual('空模型往返后指纹一致', back.displaySignature(), model.displaySignature());
}

// ------------------------------------------------------------------ F. 纯度

function testProfileNotMutated(): void {
  const profile: Profile = fullWeekProfile();
  const before: string = Profile.stringify(profile);
  build(profile, `${BASE_DAY}T08:20:00`);
  build(profile, `${BASE_DAY}T07:30:00`);
  checkEqual('构建不改档案', Profile.stringify(profile), before);
}

function testDeterminism(): void {
  const profile: Profile = fullWeekProfile();
  const a: string = build(profile, `${BASE_DAY}T08:20:00`).displaySignature();
  const b: string = build(profile, `${BASE_DAY}T08:20:00`).displaySignature();
  checkEqual('同输入同输出', a, b);
}

function testSignatureTracksContent(): void {
  const profile: Profile = fullWeekProfile();
  const during: string = build(profile, `${BASE_DAY}T08:20:00`).displaySignature();
  const after: string = build(profile, `${BASE_DAY}T08:45:01`).displaySignature();
  check('时刻推进后指纹改变（可据此决定要不要重绘）', during !== after);
}

// ------------------------------------------------------------------ 入口

function main(): void {
  testCurrentLessonAlwaysFirst();
  testBeforeFirstLesson();
  testDuringBreak();
  testDisabledClassExcluded();
  testChangedClassFlag();
  testRollsToNextSchoolDay();
  testAfterLastLessonRollsForward();
  testLabelAtLongerOffset();
  testEmptyProfile();
  testPlansButNoClasses();
  testCapacity();
  testTruncationKeepsIndices();
  testRefreshMinutesBounds();
  testRefreshForFutureDay();
  testEmptyRefreshIsMax();
  testCodecRoundTrip();
  testCodecEscapesText();
  testCodecToleratesGarbage();
  testCodecEmptyLessonList();
  testProfileNotMutated();
  testDeterminism();
  testSignatureTracksContent();

  if (failures.length > 0) {
    console.log(`小组件  失败 ${failures.length} 项：`);
    for (const failure of failures) {
      console.log(`  ✗ ${failure}`);
    }
    process.exit(1);
  }
  console.log(`小组件  通过 ${passed} 项，失败 0 项`);
}

main();
