/*
 * 网格推导测试台。
 *
 * 关注的是「下标对齐」这一类最容易静默出错的逻辑：
 *   - 列的 layoutIndex / classSlot 是否与引擎的 selectedIndex 同一坐标系
 *   - 行的日期分配（周一起排、今天落在第几行、跨月跨年）
 *   - 当前课 / 下一节课的高亮在四种时刻下各自落在哪一格
 *   - 停用课程时 validTimeLayoutItems 的连带删除是否体现在列上
 *   - 当天无课表时是留白而不是「（无）」
 *
 * 与 engine-driver 各自独立跑，互不共享计数。
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
import { EngineSettings } from '../../common_core/src/main/ets/engine/EngineSettings';
import { LessonsEngine } from '../../common_core/src/main/ets/engine/LessonsEngine';
import { LessonsSnapshot } from '../../common_core/src/main/ets/engine/LessonsSnapshot';
import { ScheduleGridBuilder } from '../../common_core/src/main/ets/view/ScheduleGridBuilder';
import { ScheduleCell, ScheduleColumn, ScheduleGrid, ScheduleRow } from '../../common_core/src/main/ets/view/ScheduleGrid';
import { WeekRotation } from '../../common_core/src/main/ets/engine/WeekRotation';
import { LayoutForm, layoutFormOf, SINGLE_COLUMN_MAX_WIDTH, GRID_FILL_MIN_WIDTH } from '../../common_core/src/main/ets/view/LayoutForm';
import { weekDayName, weekDayShortName } from '../../common_core/src/main/ets/view/TextFormat';

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

const SUBJECT_YUWEN: string = '11111111-1111-1111-1111-111111111111';
const SUBJECT_SHUXUE: string = '22222222-2222-2222-2222-222222222222';
const SUBJECT_YINGYU: string = '33333333-3333-3333-3333-333333333333';
const LAYOUT_ID: string = 'aaaaaaaa-0000-0000-0000-000000000001';

/** 2026-09-26 是周六（dayOfWeek=6），与 engine-driver 用同一基准。 */
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
  return new EngineSettings(dt('2026-09-20T00:00:00'));
}

/** 为 days 里列出的星期几各建一张课表。 */
function profileForDays(days: number[]): Profile {
  const profile: Profile = new Profile();
  profile.name = '网格测试';
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

  for (const day of days) {
    const plan: ClassPlan = new ClassPlan();
    plan.name = `${day} 的课`;
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

function buildGrid(profile: Profile, base: string, snapshot?: LessonsSnapshot): ScheduleGrid {
  return ScheduleGridBuilder.build(profile, settings(), dt(base), snapshot);
}

function snapshotAt(profile: Profile, base: string): LessonsSnapshot {
  return LessonsEngine.compute(profile, settings(), dt(base));
}

function rowOf(grid: ScheduleGrid, index: number): ScheduleRow {
  return grid.rows[index];
}

function cellOf(grid: ScheduleGrid, row: number, column: number): ScheduleCell {
  return grid.rows[row].cells[column];
}

function columnSignature(grid: ScheduleGrid): string {
  const parts: string[] = [];
  for (const column of grid.columns) {
    parts.push(`${column.layoutIndex}/${column.classSlot}/${column.label}/${column.timeRange}`);
  }
  return parts.join(' | ');
}

/**
 * 指纹直接用 core 里的实现，不在这里另写一份 ——
 * 界面轮询就是靠它判断「要不要重绘」，测试若用另一份算法就测不到真实那条路径。
 */
function gridSignature(grid: ScheduleGrid): string {
  return grid.displaySignature();
}

/** 只取行部分（不含列与高亮），用于「时间推进不应改变课程内容」这类断言。 */
function rowsSignature(grid: ScheduleGrid): string {
  const parts: string[] = [];
  for (const row of grid.rows) {
    const cells: string[] = [];
    for (const cell of row.cells) {
      cells.push(`${cell.subjectName}/${cell.teacherName}/${cell.isEnabled}/${cell.isChangedClass}`);
    }
    parts.push(`${row.date.toDateString()}/${row.hasPlan}/${cells.join(',')}`);
  }
  return parts.join('\n');
}

// ------------------------------------------------------------------ A. 列推导

function testColumns(): void {
  const grid: ScheduleGrid = buildGrid(fullWeekProfile(), `${BASE_DAY}T08:20:00`);

  checkNum('列数 = 3 节课 + 2 个课间', grid.columns.length, 5);
  checkEqual('列模板时间表名', grid.templateLayoutName, '标准作息');

  const expectedSlots: number[] = [0, -1, 1, -1, 2];
  const expectedLabels: string[] = ['第 1 节', '大课间', '第 2 节', '课间休息', '第 3 节'];
  const expectedRanges: string[] = [
    '08:00-08:45', '08:45-09:00', '09:00-09:45', '09:45-10:00', '10:00-10:45'
  ];
  for (let i: number = 0; i < grid.columns.length; i++) {
    const column: ScheduleColumn = grid.columns[i];
    checkNum(`列 ${i} 的 layoutIndex`, column.layoutIndex, i);
    checkNum(`列 ${i} 的 classSlot`, column.classSlot, expectedSlots[i]);
    checkEqual(`列 ${i} 的标签`, column.label, expectedLabels[i]);
    checkEqual(`列 ${i} 的时间区间`, column.timeRange, expectedRanges[i]);
  }
  check('课间列缺省名回退为「课间休息」',
    grid.columns[3].label === '课间休息' && grid.columns[1].label === '大课间',
    grid.columns[3].label);
}

// ------------------------------------------------------------------ B. 停用课程的连带删除

function testDisabledCascade(): void {
  // 停用「模板日」中间那节课：validTimeLayoutItems 会把这节课连同它前后
  // 两个课间一起移除，只剩首尾两节课。引擎的当前时间点也用这个集合，
  // 所以列数变少是预期行为，不是网格的 bug。
  const profile: Profile = fullWeekProfile();
  const plan: ClassPlan = profile.tryGetClassPlan(Guid.fromCanonical(planKey(6)))!;
  plan.classes[1].isEnabled = false;
  const grid: ScheduleGrid = buildGrid(profile, `${BASE_DAY}T08:20:00`);

  checkNum('停用中间一节课后列数 5 -> 2', grid.columns.length, 2);
  checkEqual('停用后保留的列下标', columnSignature(grid),
    '0/0/第 1 节/08:00-08:45 | 4/2/第 3 节/10:00-10:45');
  check('被移除的第二节课在重排后 classSlot 前移',
    grid.columns[1].classSlot === 2 && grid.columns[1].label === '第 3 节');

  // 停用「非模板日」的课：那天的列仍由模板决定，于是格子能出现 isEnabled=false。
  // 这条路径是 isEnabled 字段在网格里唯一能生效的地方，值得钉住。
  const other: Profile = fullWeekProfile();
  const monday: ClassPlan = other.tryGetClassPlan(Guid.fromCanonical(planKey(1)))!;
  monday.classes[0].isEnabled = false;
  const otherGrid: ScheduleGrid = buildGrid(other, `${BASE_DAY}T08:20:00`);
  checkNum('停用非模板日的课不影响列数', otherGrid.columns.length, 5);
  const mondayCell: ScheduleCell = cellOf(otherGrid, 0, 0);
  check('非模板日的停用课程标为 isEnabled=false', !mondayCell.isEnabled);
  check('非模板日的停用课程仍显示科目', mondayCell.subjectName === '语文');
  check('模板日那格不受影响', cellOf(otherGrid, otherGrid.todayRowIndex, 0).isEnabled);
}

// ------------------------------------------------------------------ C. 行序与日期分配

function testRowOrder(): void {
  const grid: ScheduleGrid = buildGrid(fullWeekProfile(), `${BASE_DAY}T08:20:00`);

  checkNum('固定 7 行', grid.rows.length, 7);
  const expectedDow: number[] = [1, 2, 3, 4, 5, 6, 0];
  for (let i: number = 0; i < 7; i++) {
    checkNum(`行 ${i} 的 dayOfWeek`, rowOf(grid, i).dayOfWeek, expectedDow[i]);
  }

  // 基准 2026-09-26（周六）。它所在的那一周是 09-21（周一）到 09-27（周日），
  // 所以周六在第 6 行而不是第 1 行。
  const expectedDates: string[] = [
    '2026-09-21', '2026-09-22', '2026-09-23', '2026-09-24',
    '2026-09-25', '2026-09-26', '2026-09-27'
  ];
  for (let i: number = 0; i < 7; i++) {
    checkEqual(`行 ${i} 的日期`, rowOf(grid, i).date.toDateString(), expectedDates[i]);
  }

  checkNum('今天（周六）落在第 6 行', grid.todayRowIndex, 5);
  check('只有今天那行 isToday', grid.rows.filter((r: ScheduleRow) => r.isToday).length === 1);
}

// ------------------------------------------------------------------ D. 跨月与跨年

function testRowOrderBoundaries(): void {
  // 2026-12-31 是周四（dayOfWeek=4）
  const endOfYear: ScheduleGrid = buildGrid(fullWeekProfile(), '2026-12-31T08:20:00');
  checkNum('12-31 落在周四行', endOfYear.todayRowIndex, 3);
  checkEqual('跨年前后的周一', rowOf(endOfYear, 0).date.toDateString(), '2026-12-28');
  checkEqual('跨年前后的周日', rowOf(endOfYear, 6).date.toDateString(), '2027-01-03');

  // 2027-01-01 是周五（dayOfWeek=5）
  const newYear: ScheduleGrid = buildGrid(fullWeekProfile(), '2027-01-01T08:20:00');
  checkNum('元旦落在周五行', newYear.todayRowIndex, 4);
  checkEqual('元旦那周的周一', rowOf(newYear, 0).date.toDateString(), '2026-12-28');
  checkEqual('元旦那周的周日', rowOf(newYear, 6).date.toDateString(), '2027-01-03');

  // 2024-02-29 是周四（dayOfWeek=4），闰日
  const leap: ScheduleGrid = buildGrid(fullWeekProfile(), '2024-02-29T08:20:00');
  checkNum('闰日落在周四行', leap.todayRowIndex, 3);
  checkEqual('闰日那周的周日跨到 3 月', rowOf(leap, 6).date.toDateString(), '2024-03-03');
}

// ------------------------------------------------------------------ E. 当前课高亮

function testCurrentHighlight(): void {
  const profile: Profile = fullWeekProfile();
  const at: string = '08:20:00';

  // 上课中
  let grid: ScheduleGrid = buildGrid(profile, `${BASE_DAY}T${at}`, snapshotAt(profile, `${BASE_DAY}T${at}`));
  check('08:20 上课中：当前列是第 1 列', grid.columns[0].isCurrentColumn);
  check('08:20 上课中：第 1 格 isCurrent', cellOf(grid, grid.todayRowIndex, 0).isCurrent);
  check('08:20 上课中：其它列不是当前列',
    grid.columns.slice(1).every((c: ScheduleColumn) => !c.isCurrentColumn));
  check('08:20 上课中：只有一格 isCurrent',
    grid.rows[grid.todayRowIndex].cells.filter((c: ScheduleCell) => c.isCurrent).length === 1);
  check('高亮不溢出到别的行',
    grid.rows.every((r: ScheduleRow, i: number) => i === grid.todayRowIndex ||
      r.cells.every((c: ScheduleCell) => !c.isCurrent)));

  // 时间比较是双侧闭区间，FirstOrDefault 取列表里首个命中者。
  // 于是两个相邻时间点在交界那一秒同时命中，靠列表先后定胜负：
  //   08:45:00 —— 第一节课(08:00-08:45) 与 大课间(08:45-09:00) 同时命中，课在前 -> 仍是课
  //   09:00:00 —— 大课间(08:45-09:00) 与 第二节课(09:00-09:45) 同时命中，课间在前 -> 课间
  grid = buildGrid(profile, `${BASE_DAY}T08:45:00`, snapshotAt(profile, `${BASE_DAY}T08:45:00`));
  check('08:45:00 交界秒：第一节课在前，判为上课', grid.columns[0].isCurrentColumn);
  check('08:45:00 课间列不是当前列', !grid.columns[1].isCurrentColumn);

  grid = buildGrid(profile, `${BASE_DAY}T09:00:00`, snapshotAt(profile, `${BASE_DAY}T09:00:00`));
  check('09:00:00 交界秒：课间在前，判为课间', grid.columns[1].isCurrentColumn);
  check('09:00:00 第二节课不是当前列', !grid.columns[2].isCurrentColumn);
  check('09:00:00 课间格不是课程格，不标 isCurrent',
    !cellOf(grid, grid.todayRowIndex, 1).isCurrent);

  // 边界之后一秒钟就该翻页了
  grid = buildGrid(profile, `${BASE_DAY}T09:00:01`, snapshotAt(profile, `${BASE_DAY}T09:00:01`));
  check('09:00:01 越界后翻到第二节课', grid.columns[2].isCurrentColumn);

  // 还没到校
  grid = buildGrid(profile, `${BASE_DAY}T07:00:00`, snapshotAt(profile, `${BASE_DAY}T07:00:00`));
  check('07:00 未到校：没有当前列', grid.columns.every((c: ScheduleColumn) => !c.isCurrentColumn));
  check('07:00 未到校：没有格子标 isCurrent',
    grid.rows[grid.todayRowIndex].cells.every((c: ScheduleCell) => !c.isCurrent));

  // 已放学
  grid = buildGrid(profile, `${BASE_DAY}T18:00:00`, snapshotAt(profile, `${BASE_DAY}T18:00:00`));
  check('18:00 已放学：没有当前列', grid.columns.every((c: ScheduleColumn) => !c.isCurrentColumn));
}

// ------------------------------------------------------------------ F. 下一节课

function testNextHighlight(): void {
  // 上课中：引擎的 nextClassTimeLayoutItem 指向的是当前这节课，
  // 网格必须跳过它，标真正再往后的一节。
  const profile: Profile = fullWeekProfile();
  const snapshot: LessonsSnapshot = snapshotAt(profile, `${BASE_DAY}T08:20:00`);
  checkNum('引擎的 nextClass 就是当前这节课（桌面版怪癖，需在网格层修正）',
    profile.timeLayouts.getOrDefault(LAYOUT_ID, new TimeLayout()).layouts
      .indexOf(snapshot.nextClassTimeLayoutItem), 0);

  let grid: ScheduleGrid = buildGrid(profile, `${BASE_DAY}T08:20:00`, snapshot);
  check('08:20 上课中：下一节是第 2 节课', cellOf(grid, grid.todayRowIndex, 2).isNext);
  check('08:20 上课中：当前课不同时被标成下一节',
    !cellOf(grid, grid.todayRowIndex, 0).isNext);
  check('08:20 上课中：只有一格 isNext',
    grid.rows[grid.todayRowIndex].cells.filter((c: ScheduleCell) => c.isNext).length === 1);

  // 课间中：下一节就是 09:00 那节
  grid = buildGrid(profile, `${BASE_DAY}T08:50:00`, snapshotAt(profile, `${BASE_DAY}T08:50:00`));
  check('08:50 课间中：下一节是第 2 节课', cellOf(grid, grid.todayRowIndex, 2).isNext);

  // 还没到校：用引擎的值，第 1 节就是下一节
  grid = buildGrid(profile, `${BASE_DAY}T07:00:00`, snapshotAt(profile, `${BASE_DAY}T07:00:00`));
  check('07:00 未到校：下一节是第 1 节课',
    cellOf(grid, grid.todayRowIndex, 0).isNext && !cellOf(grid, grid.todayRowIndex, 2).isNext);

  // 最后一节课上：没有下一节
  grid = buildGrid(profile, `${BASE_DAY}T10:20:00`, snapshotAt(profile, `${BASE_DAY}T10:20:00`));
  check('10:20 最后一节课：没有下一节',
    grid.rows[grid.todayRowIndex].cells.every((c: ScheduleCell) => !c.isNext));

  // 已放学：没有下一节
  grid = buildGrid(profile, `${BASE_DAY}T18:00:00`, snapshotAt(profile, `${BASE_DAY}T18:00:00`));
  check('18:00 已放学：没有下一节',
    grid.rows[grid.todayRowIndex].cells.every((c: ScheduleCell) => !c.isNext));
}

// ------------------------------------------------------------------ G. 单元格内容

function testCellContent(): void {
  const profile: Profile = fullWeekProfile();
  const grid: ScheduleGrid = buildGrid(profile, `${BASE_DAY}T08:20:00`);
  const today: number = grid.todayRowIndex;

  checkEqual('第 1 格科目名', cellOf(grid, today, 0).subjectName, '语文');
  checkEqual('第 1 格老师', cellOf(grid, today, 0).teacherName, '语文老师');
  check('第 1 格有科目', cellOf(grid, today, 0).hasSubject);
  checkEqual('第 3 格科目名', cellOf(grid, today, 4).subjectName, '英语');

  check('课间格不是课程格', !cellOf(grid, today, 1).isClassSlot);
  check('课间格没有科目', !cellOf(grid, today, 1).hasSubject);

  checkEqual('当天课表名', rowOf(grid, today).planName, '6 的课');
  check('当天不是叠加班表', !rowOf(grid, today).isOverlay);
}

// ------------------------------------------------------------------ H. 空格子与无课表日

function testEmptyStates(): void {
  // 排了课但没定科目 -> 显示「（无）」，格子仍是有效课程格
  const profile: Profile = fullWeekProfile();
  const plan: ClassPlan = profile.tryGetClassPlan(Guid.fromCanonical(planKey(6)))!;
  plan.classes[0].subjectId = Guid.empty();
  const grid: ScheduleGrid = buildGrid(profile, `${BASE_DAY}T08:20:00`);
  const cell: ScheduleCell = cellOf(grid, grid.todayRowIndex, 0);
  check('未定科目：仍是课程格', cell.isClassSlot);
  check('未定科目：hasSubject 为 false（界面据此显示「（无）」）', !cell.hasSubject);
  check('未定科目：subjectName 为空串', cell.subjectName === '');

  // 某天根本没有课表 -> 整行留白，不填「（无）」
  const school: ScheduleGrid = buildGrid(schoolWeekProfile(), `${BASE_DAY}T08:20:00`);
  const saturday: ScheduleRow = rowOf(school, 5);
  const sunday: ScheduleRow = rowOf(school, 6);
  check('周六无课表：hasPlan 为 false', !saturday.hasPlan);
  check('周六无课表：课表名为空', saturday.planName === '');
  check('周六无课表：格子数量仍与列对齐', saturday.cells.length === school.columns.length);
  check('周六无课表：格子全部留白（hasSubject 均为 false）',
    saturday.cells.every((c: ScheduleCell) => !c.hasSubject));
  check('周六无课表：没有格子被当成课程格',
    saturday.cells.every((c: ScheduleCell) => !c.isClassSlot));
  check('周日无课表：hasPlan 为 false', !sunday.hasPlan);
  check('周一有课表：hasPlan 为 true', rowOf(school, 0).hasPlan);
  check('周六是今天且无课表：todayRowIndex 仍能定位', school.todayRowIndex === 5);

  // 整份档案没有任何课表 -> 空网格
  const blank: ScheduleGrid = buildGrid(new Profile(), `${BASE_DAY}T08:20:00`);
  check('空档案：网格标记为空态', blank.isEmpty());
  checkNum('空档案：列数为 0', blank.columns.length, 0);
  checkNum('空档案：仍给出 7 行骨架', blank.rows.length, 7);
  check('空档案：每行都没有课表', blank.rows.every((r: ScheduleRow) => !r.hasPlan));

  // 课表存在但时间表缺失 -> 降级为空网格，不崩。
  // 真实的降级路径要先 refreshDerivedState：plan 上绑的是旧的时间表对象，
  // 清空 map 本身不会解绑（引擎每帧都刷，网格层由调用方负责刷）。
  const orphan: Profile = fullWeekProfile();
  orphan.timeLayouts.clear();
  orphan.refreshDerivedState();
  const orphanGrid: ScheduleGrid = buildGrid(orphan, `${BASE_DAY}T08:20:00`);
  check('时间表缺失：降级为空网格', orphanGrid.isEmpty());
  check('时间表缺失：仍给出 7 行骨架', orphanGrid.rows.length === 7);
}

// ------------------------------------------------------------------ I. 调课与停用标记

function testFlags(): void {
  const profile: Profile = fullWeekProfile();
  const plan: ClassPlan = profile.tryGetClassPlan(Guid.fromCanonical(planKey(6)))!;
  plan.classes[2].isChangedClass = true;
  const grid: ScheduleGrid = buildGrid(profile, `${BASE_DAY}T08:20:00`);
  const today: number = grid.todayRowIndex;

  check('调课标记透传到格子', cellOf(grid, today, 4).isChangedClass);
  check('未调课的不受影响', !cellOf(grid, today, 0).isChangedClass);
  check('默认全部启用', grid.rows[today].cells.every((c: ScheduleCell) => c.isEnabled));
}

// ------------------------------------------------------------------ J. 单双周

function testWeekRotation(): void {
  // 周一设为双周（weekCountDiv=2 / total=2）。基准 2026-09-26 所在的那一周
  // 起点是 09-21，以 09-20（周日）为轮转参照算出来是第 1 周，奇数周不匹配双周，
  // 于是周一那行应当没有课表。断言同时与 WeekRotation 对齐，防止两边漂移。
  const profile: Profile = schoolWeekProfile();
  const monday: ClassPlan = profile.tryGetClassPlan(Guid.fromCanonical(planKey(1)))!;
  monday.timeRule.weekCountDiv = 2;
  monday.timeRule.weekCountDivTotal = 2;

  const grid: ScheduleGrid = buildGrid(profile, `${BASE_DAY}T08:20:00`);
  const mondayDate: DateTimeValue = rowOf(grid, 0).date;
  const position: number = WeekRotation.positionOf(mondayDate, settings(), 2);

  checkEqual('周一那行是 2026-09-21', mondayDate.toDateString(), '2026-09-21');
  checkNum('该周在双周轮转里是第 1 周', position, 1);
  check('网格的单双周判定与引擎一致',
    rowOf(grid, 0).hasPlan === (position === monday.timeRule.weekCountDiv),
    `position=${position}, hasPlan=${rowOf(grid, 0).hasPlan}`);
  check('第 1 周不匹配双周：周一那行没有课表', !rowOf(grid, 0).hasPlan);
  // 行 1..4 是周二到周五，都没被限定，应当照常有课表
  check('单双周只影响被限定的那个星期',
    rowOf(grid, 1).hasPlan && rowOf(grid, 2).hasPlan &&
    rowOf(grid, 3).hasPlan && rowOf(grid, 4).hasPlan);

  // 换成单周（weekCountDiv=1）后同一行应当有课表
  const single: Profile = schoolWeekProfile();
  const singleMonday: ClassPlan = single.tryGetClassPlan(Guid.fromCanonical(planKey(1)))!;
  singleMonday.timeRule.weekCountDiv = 1;
  const singleGrid: ScheduleGrid = buildGrid(single, `${BASE_DAY}T08:20:00`);
  check('改成单周后周一那行有课表', rowOf(singleGrid, 0).hasPlan);
}

// ------------------------------------------------------------------ K. 无快照与幂等

function testNoSnapshotAndDeterminism(): void {
  const profile: Profile = fullWeekProfile();
  const grid: ScheduleGrid = buildGrid(profile, `${BASE_DAY}T08:20:00`);

  check('不传快照：不标当前列', grid.columns.every((c: ScheduleColumn) => !c.isCurrentColumn));
  check('不传快照：不标 isCurrent / isNext',
    grid.rows.every((r: ScheduleRow) => r.cells.every((c: ScheduleCell) => !c.isCurrent && !c.isNext)));
  check('不传快照：今天仍然标出（行头要加粗）', grid.todayRowIndex === 5);
  check('不传快照：课程内容与带快照时一致',
    rowsSignature(grid) === rowsSignature(buildGrid(profile, `${BASE_DAY}T08:20:00`,
      snapshotAt(profile, `${BASE_DAY}T08:20:00`))));
  check('不传快照：指纹与带快照时不同（正因为少了高亮位）',
    gridSignature(grid) !== gridSignature(buildGrid(profile, `${BASE_DAY}T08:20:00`,
      snapshotAt(profile, `${BASE_DAY}T08:20:00`))));

  // 重复推导结果必须一致：网格是纯函数，页面每 30 秒重算一次不能有累积漂移
  const a: ScheduleGrid = buildGrid(profile, `${BASE_DAY}T08:20:00`, snapshotAt(profile, `${BASE_DAY}T08:20:00`));
  const b: ScheduleGrid = buildGrid(profile, `${BASE_DAY}T08:20:00`, snapshotAt(profile, `${BASE_DAY}T08:20:00`));
  check('重复推导结果一致', gridSignature(a) === gridSignature(b));

  // 时间推进一分钟后高亮应跟着走，但课程内容不该变
  const later: ScheduleGrid = buildGrid(profile, `${BASE_DAY}T08:21:00`, snapshotAt(profile, `${BASE_DAY}T08:21:00`));
  check('推进一分钟后当前列不变（仍在第 1 节课内）', later.columns[0].isCurrentColumn);
  check('推进一分钟后课程内容不变', rowsSignature(a) === rowsSignature(later));
  check('推进一分钟后指纹不变（界面因此不重绘）', gridSignature(a) === gridSignature(later));

  // 跨过时间点边界后指纹必须变，否则高亮永远不更新
  const after: ScheduleGrid = buildGrid(profile, `${BASE_DAY}T09:00:01`, snapshotAt(profile, `${BASE_DAY}T09:00:01`));
  check('跨过时间点边界后指纹变化（界面会重绘）', gridSignature(a) !== gridSignature(after));
  check('跨过边界后课程内容仍不变', rowsSignature(a) === rowsSignature(after));
}

// ------------------------------------------------------------------ L. 只读档案

function testProfileNotMutated(): void {
  // 网格推导本身不改档案。LessonsEngine.compute 会做幂等刷新（桌面版行为），
  // 但 build() 不该顺手改任何东西 —— 否则「读一下课表」会有副作用。
  const profile: Profile = fullWeekProfile();
  const before: string = gridSignature(buildGrid(profile, `${BASE_DAY}T08:20:00`));
  const classPlansBefore: number = profile.classPlans.size;
  const subjectsBefore: number = profile.subjects.size;

  buildGrid(profile, `${BASE_DAY}T08:20:00`);
  buildGrid(profile, `${BASE_DAY}T08:20:00`);

  check('重复推导不新增课表', profile.classPlans.size === classPlansBefore);
  check('重复推导不新增科目', profile.subjects.size === subjectsBefore);
  check('重复推导不改变推导结果',
    before === gridSignature(buildGrid(profile, `${BASE_DAY}T08:20:00`)));
}

// ------------------------------------------------------------ 布局分档

/**
 * layoutFormOf 的边界。
 *
 * 之所以要测：它决定「单栏还是双栏」「网格均分还是横滑」，一旦归错，
 * 界面会横向溢出或留出大片空白，而这两种都不会报错，只在特定屏幕上出现。
 */
function testLayoutForm() {
  checkNum('分档阈值：单栏上界', SINGLE_COLUMN_MAX_WIDTH, 600);
  checkNum('分档阈值：宽档下界', GRID_FILL_MIN_WIDTH, 1100);

  // 阈值两侧各取几个点，中间整段也要连成一片，不能有空洞
  for (const width of [1, 320, 360, 411, 599]) {
    check(`分档 ${width} 判为单栏`, layoutFormOf(width) === LayoutForm.Single);
  }
  for (const width of [600, 601, 720, 839, 840, 1000, 1099]) {
    check(`分档 ${width} 判为双栏横滑`, layoutFormOf(width) === LayoutForm.Dual);
  }
  for (const width of [1100, 1101, 1280, 1600, 2560]) {
    check(`分档 ${width} 判为双栏均分`, layoutFormOf(width) === LayoutForm.DualWide);
  }

  // 未知宽度一律按最窄处理：按宽排会摆出横向溢出的界面，按窄排至多朴素
  for (const width of [0, -1, -1000]) {
    check(`分档 ${width} 兜底为单栏`, layoutFormOf(width) === LayoutForm.Single);
  }
  check('分档 NaN 兜底为单栏', layoutFormOf(NaN) === LayoutForm.Single);
  check('分档 Infinity 判为双栏均分', layoutFormOf(Infinity) === LayoutForm.DualWide);

  // 枚举值被序列化或跨模块传递时不能漂移
  checkNum('LayoutForm.Single 值', LayoutForm.Single, 0);
  checkNum('LayoutForm.Dual 值', LayoutForm.Dual, 1);
  checkNum('LayoutForm.DualWide 值', LayoutForm.DualWide, 2);
}

// ------------------------------------------------- 星期日端到端（口径回归）

/**
 * 星期日必须真的能出课。
 *
 * 这条守的是一个具体错误：星期几在本工程是 .NET 口径 0=周日 … 6=周六。0 与 1..6
 * 在「周一到周六」这一段看起来完全正常，只有周日是另一头，所以任何一处把 0 当
 * 「周一」或把 7 当「周日」的处理都只会在周日暴露。
 *
 * 现有断言里 testRowOrder 已经钉住了行序数组末日是 0，但那只说明「标签对得上」，
 * 不说明「那张课表在周日真的生效」。这两件事会一起坏：编辑页的星期按钮若按下标
 * 写 weekDay，就会出现「界面自洽、引擎永不匹配」——周日有课表但全天无课，无报错。
 * 所以必须从「档案里 weekDay=0 的课表，在周日那天真的出课」这一端验证。
 */
function testSundayPlanTakesEffect(): void {
  const sunday: string = '2026-09-27';   // 基准日 09-26 是周六，故次日是周日
  checkNum('周日 dayOfWeek 是 0（不是 7）', dt(sunday).dayOfWeek(), 0);

  const grid: ScheduleGrid = buildGrid(profileForDays([0]), `${sunday}T08:20:00`);

  checkNum('周日是第 7 行（行序末日）', grid.todayRowIndex, 6);
  checkNum('周日行 dayOfWeek = 0', rowOf(grid, 6).dayOfWeek, 0);
  check('周日那天确实有课表', rowOf(grid, 6).hasPlan);
  checkEqual('周日第一节有科目', cellOf(grid, 6, 0).subjectName, '语文');

  // 引擎侧同一件事：状态机在周日应认出语文。
  const snapshot: LessonsSnapshot = snapshotAt(profileForDays([0]), `${sunday}T08:20:00`);
  check('引擎在周日认出当前科目',
    snapshot.currentSubject !== undefined && snapshot.currentSubject.name === '语文',
    snapshot.currentSubject === undefined ? '(空)' : snapshot.currentSubject.name);

  // 名字在周日不能是空串，也不能串到「周一」。
  checkEqual('周日名字', weekDayName(rowOf(grid, 6).dayOfWeek), '周日');
  checkEqual('周日短名', weekDayShortName(rowOf(grid, 6).dayOfWeek), '日');

  // 反向：只有周一课表时，周日必须没有课。这一条挡的是「把周日当周一」的错法。
  const mondayOnly: ScheduleGrid = buildGrid(profileForDays([1]), `${sunday}T08:20:00`);
  check('只有周一课表时周日无课', !rowOf(mondayOnly, 6).hasPlan);
}

// ------------------------------------------------------------------ 入口

testSundayPlanTakesEffect();
testColumns();
testDisabledCascade();
testRowOrder();
testRowOrderBoundaries();
testCurrentHighlight();
testNextHighlight();
testCellContent();
testEmptyStates();
testFlags();
testWeekRotation();
testNoSnapshotAndDeterminism();
testProfileNotMutated();
testLayoutForm();

console.log(`通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('');
  for (const failure of failures) {
    console.log(`✗ ${failure}`);
  }
  process.exit(1);
}
