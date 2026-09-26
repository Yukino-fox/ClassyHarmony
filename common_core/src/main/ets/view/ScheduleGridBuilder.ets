/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 周课表网格推导。
 *
 * 纯静态函数，无跨调用状态。调用方拿一份档案，在一周七个日期上各解一次课表，
 * 把结果拼成 7 x N 的格子。
 *
 * 行的日期分配
 * ------------
 * 取「基准日所在的那一个周一」作为整周起点，七行依次是那一周的周一到周日。
 * 关键是不能简单用「基准日 + 0..6 天」再按星期几贴标签 —— 那样只有当基准日
 * 恰好是周一时，日期序列才真的是周一到周日；基准日是周四时，标着「周一」的那行
 * 实际会落在基准日之后的周一，整张表横跨了两个自然周。今天所在的那一行因此
 * 可能出现在表格中间，也可能出现在末尾，靠 weekStart 反推才稳定。
 *
 * 高亮靠**对象身份**定位当前 / 下一节课，不靠时间区间字符串比对：
 * 引擎的 selectedIndex 就是 layout.layouts.indexOf(currentItem)，而同一个时间
 * 区间完全可能出现在两个时间点上（例如分割线与课程点同区间），
 * 比字符串会标错格子。这里沿用引擎的口径，把快照里的时间点反查成 layouts
 * 下标再与列下标对齐。
 *
 * 时间点自身的属性（IsHideDefault 等）挂在**列**上而不是格子上：它们描述的是
 * 这个时间点，不是「某天第几节课」。挂在列上还有个附带好处 —— 逐行去读的话，
 * 遇到某天真换了时间表就会拿模板下标去索引别的表，读到不相干的时间点。
 */

import { ClassInfo, ClassPlan, DateTimeValue, Guid, Profile, Subject, TimeLayout, TimeLayoutItem, TimeSpanValue } from 'common_shared';
import { ClassPlanResolver } from '../engine/ClassPlanResolver';
import { EngineSettings } from '../engine/EngineSettings';
import { LessonsSnapshot } from '../engine/LessonsSnapshot';
import { ScheduleCell, ScheduleColumn, ScheduleGrid, ScheduleRow } from './ScheduleGrid';

/** 网格行序：周一起。元素是 dayOfWeek 取值（0=周日 … 6=周六）。 */
const ROW_ORDER: number[] = [1, 2, 3, 4, 5, 6, 0];

/** 今天相关的推导结果，在 build 内部流转。 */
class Highlight {
  rowIndex: number = -1;
  currentLayoutIndex: number = -1;
  nextLayoutIndex: number = -1;
}

export class ScheduleGridBuilder {
  /**
   * 推导一周课表网格。
   *
   * @param baseDate 基准日期，通常是「今天」。它决定哪一行是今天。
   * @param snapshot 同一时刻的引擎快照，用来标当前课与下一节课。
   *                 必须与 baseDate 出自同一次时钟读取，否则高亮会落到别的行上。
   *                 传 undefined 表示不高亮（预览、编辑态）。
   */
  static build(profile: Profile, settings: EngineSettings, baseDate: DateTimeValue,
    snapshot?: LessonsSnapshot): ScheduleGrid {
    const grid: ScheduleGrid = new ScheduleGrid();

    // 列模板取基准日生效课表的时间表。基准日没课表时不再退而求其次找别的课表 ——
    // 换一张别的课表来定列，会让「今天这天的格子」按另一张表的时间点对齐，
    // 是假数据。宁可交出没有列的网格，让界面显示空态。
    const templatePlan: ClassPlan | undefined =
      ClassPlanResolver.resolve(profile, baseDate, settings).plan;
    const templateLayout: TimeLayout | undefined =
      templatePlan === undefined ? undefined : templatePlan.resolveTimeLayout();

    if (templatePlan !== undefined && templateLayout !== undefined) {
      grid.templateLayoutName = templateLayout.name;
      grid.columns = buildColumns(templatePlan, templateLayout);
    }

    grid.rows = buildRows(profile, settings, weekStartOf(baseDate), grid.columns);

    const highlight: Highlight = new Highlight();
    markToday(grid, baseDate, highlight);
    if (templateLayout !== undefined) {
      markHighlights(grid, templateLayout, snapshot, highlight);
    }
    return grid;
  }
}

/**
 * 列 = 基准日课表的有效时间点。
 *
 * 刻意用 validTimeLayoutItems() 而不是 TimeLayout.displayTimePoints()：
 * 前者已经按「课程被停用则连带前后课间一起消失」的规则过滤过，
 * 与引擎算当前时间点时用的集合完全一致，selectedIndex 才对得上。
 *
 * layoutIndex 由 indexOf 反查。validTimeLayoutItems 返回的是同一批对象引用，
 * 所以 indexOf 能唯一命中。
 */
function buildColumns(plan: ClassPlan, layout: TimeLayout): ScheduleColumn[] {
  const columns: ScheduleColumn[] = [];
  const items: TimeLayoutItem[] = plan.validTimeLayoutItems();
  const classCount: number = plan.classes.length;
  for (let i: number = 0; i < items.length; i++) {
    const item: TimeLayoutItem = items[i];
    const layoutIndex: number = layout.layouts.indexOf(item);
    let classSlot: number = layout.classIndexOf(layoutIndex);

    // 越界的 classSlot 意味着这张课表的 classes 还没跟时间表对齐。
    // 不静默改写数据，只把这一格降级成非课程格（见 ScheduleGrid 头注的前提说明）。
    if (classSlot < 0 || classSlot >= classCount) {
      classSlot = -1;
    }

    const column: ScheduleColumn = new ScheduleColumn();
    column.layoutIndex = layoutIndex;
    column.classSlot = classSlot;
    column.isClass = item.isClass();
    column.isBreak = item.isBreak();
    column.isHideDefault = item.isHideDefault;
    if (column.isClass) {
      // 节序号与 classSlot 对齐；越界降级后 classSlot 为 -1，此时不编节次。
      column.label = classSlot >= 0 ? `第 ${classSlot + 1} 节` : '';
    } else if (column.isBreak) {
      column.label = item.breakNameText();
    }
    column.timeRange = `${formatClock(item.startTime)}-${formatClock(item.endTime)}`;
    columns.push(column);
  }
  return columns;
}

/** 建出 7 行：日期、是否有课表、以及每行的格子。weekStart 必须是周一。 */
function buildRows(profile: Profile, settings: EngineSettings, weekStart: DateTimeValue,
  columns: ScheduleColumn[]): ScheduleRow[] {
  const rows: ScheduleRow[] = [];
  for (let i: number = 0; i < ROW_ORDER.length; i++) {
    const date: DateTimeValue = weekStart.addDays(i);
    const plan: ClassPlan | undefined =
      ClassPlanResolver.resolve(profile, date, settings).plan;

    const row: ScheduleRow = new ScheduleRow();
    row.dayOfWeek = ROW_ORDER[i];
    row.date = date;
    row.hasPlan = plan !== undefined;
    if (plan === undefined) {
      // 当天没有课表：整行留白。这里刻意不填「（无）」——
      // 桌面版对这种情况用的是 ClassInfo.IsEmpty 哨兵，格子是完全空的。
      row.cells = blankCells(columns.length);
    } else {
      row.planName = plan.name;
      row.isOverlay = plan.isOverlay;
      row.cells = buildCells(profile, plan, columns);
    }
    rows.push(row);
  }
  return rows;
}

function buildCells(profile: Profile, plan: ClassPlan, columns: ScheduleColumn[]): ScheduleCell[] {
  const cells: ScheduleCell[] = [];
  for (const column of columns) {
    const cell: ScheduleCell = new ScheduleCell();
    cell.isClassSlot = column.classSlot >= 0;
    if (!cell.isClassSlot) {
      // 课间 / 分割线格：不排课，只有底色与文字。
      cells.push(cell);
      continue;
    }
    const info: ClassInfo | undefined = plan.classes[column.classSlot];
    if (info !== undefined) {
      cell.isEnabled = info.isEnabled;
      cell.isChangedClass = info.isChangedClass;
      const subject: Subject | undefined = subjectOf(profile, info);
      if (subject !== undefined) {
        cell.hasSubject = true;
        cell.subjectName = subject.name;
        cell.teacherName = subject.teacherName;
      }
    }
    cells.push(cell);
  }
  return cells;
}

function blankCells(count: number): ScheduleCell[] {
  const cells: ScheduleCell[] = [];
  for (let i: number = 0; i < count; i++) {
    cells.push(new ScheduleCell());
  }
  return cells;
}

function subjectOf(profile: Profile, info: ClassInfo): Subject | undefined {
  if (info.subjectId.equals(Guid.empty())) {
    return undefined;
  }
  return profile.tryGetSubject(info.subjectId);
}

/**
 * 基准日所在那一周的周一。
 *
 * dayOfWeek 是 0=周日 的 .NET 口径，周一恒为 1，所以回退天数是 (dow - 1 + 7) % 7。
 */
function weekStartOf(date: DateTimeValue): DateTimeValue {
  return date.addDays(-((date.dayOfWeek() - 1 + 7) % 7));
}

/**
 * 标今天。
 *
 * 判定用日期相等而不是行序 —— 「周一」既可能是本周的也可能是下周的，
 * 只有日期能唯一确定。这一步让 baseDate 与高亮来源解耦：即使快照没传，
 * 网格也知道哪一行是今天（行头要加粗）。
 */
function markToday(grid: ScheduleGrid, baseDate: DateTimeValue, highlight: Highlight): void {
  const target: DateTimeValue = baseDate.dateOnly();
  for (let i: number = 0; i < grid.rows.length; i++) {
    if (grid.rows[i].date.dateOnly().equals(target)) {
      grid.rows[i].isToday = true;
      grid.todayRowIndex = i;
      highlight.rowIndex = i;
      return;
    }
  }
}

/**
 * 标当前列、当前课、下一节课。
 *
 * 「下一节课」不能直接用快照的 nextClassTimeLayoutItem：引擎取它的判据是
 * 「第一个 TimeType==0 且 EndTime >= now」，上课中这个条件把**当前这节课**自己也
 * 算进去了（正在上的课 EndTime 当然 >= now）。直接用会把当前课同时标成下一节。
 * 所以分两种情形自己推：
 *   - 此刻正落在某个时间点里 -> 取它之后的第一节课（课间时就是下一节课，上课时是再下一节）；
 *   - 此刻不在任何时间点内（还没到校 / 已放学）-> 用引擎的值，它此时确实是「下一节」，
 *     放学后是 TimeLayoutItem.empty() 哨兵，indexOf 为 -1，自然不标。
 */
function markHighlights(grid: ScheduleGrid, layout: TimeLayout,
  snapshot: LessonsSnapshot | undefined, highlight: Highlight): void {
  if (snapshot === undefined || highlight.rowIndex < 0) {
    return;
  }
  if (snapshot.selectedIndex >= 0) {
    highlight.currentLayoutIndex = snapshot.selectedIndex;
  }
  highlight.nextLayoutIndex = resolveNextLayoutIndex(grid, layout, snapshot, highlight);

  const row: ScheduleRow = grid.rows[highlight.rowIndex];
  for (let i: number = 0; i < grid.columns.length; i++) {
    const column: ScheduleColumn = grid.columns[i];
    const cell: ScheduleCell | undefined = row.cells[i];
    if (cell === undefined) {
      continue;
    }
    if (column.layoutIndex === highlight.currentLayoutIndex) {
      column.isCurrentColumn = true;
      if (cell.isClassSlot) {
        cell.isCurrent = true;
      }
    }
    if (cell.isClassSlot && column.layoutIndex === highlight.nextLayoutIndex) {
      cell.isNext = true;
    }
  }
}

/** 见 markHighlights 的注释：上课中要跳过当前这节，往后找。 */
function resolveNextLayoutIndex(grid: ScheduleGrid, layout: TimeLayout,
  snapshot: LessonsSnapshot, highlight: Highlight): number {
  if (highlight.currentLayoutIndex < 0) {
    return layout.layouts.indexOf(snapshot.nextClassTimeLayoutItem);
  }
  for (const column of grid.columns) {
    if (column.isClass && column.layoutIndex > highlight.currentLayoutIndex) {
      return column.layoutIndex;
    }
  }
  return -1;
}

/** TimeSpanValue -> 「HH:mm」。负值（跨零点的时间点）显示为 00:00。 */
function formatClock(span: TimeSpanValue): string {
  let seconds: number = span.toSeconds();
  if (seconds < 0) {
    seconds = 0;
  }
  const hours: number = Math.floor(seconds / 3600) % 24;
  const minutes: number = Math.floor(seconds / 60) % 60;
  return `${pad2(hours)}:${pad2(minutes)}`;
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}
