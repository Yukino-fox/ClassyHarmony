/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 周课表网格的视图数据。
 *
 * 这一层是纯推导：给它档案和基准日期，它算出 7 行 N 列的单元格内容。
 * 不持有档案引用、不读时钟、不发通知 —— 同样的输入永远得到同样的输出。
 * 页面靠替换整个 ScheduleGrid 实例来触发重绘（ArkUI V2 状态管理的约定），
 * 所以这里没有一处就地修改。
 *
 * 列模板的选择
 * ------------
 * 网格的列来自「基准日生效课表」的时间表，而不是逐行各取各的。原因是
 * validTimeLayoutItems() 会按该课表自身的 classes[i].isEnabled 过滤时间点，
 * 不同天的课表若过滤结果不同，列就会错位。所以：
 *   - 列（时间点、节次标签、时间区间）只由基准日课表决定，全表统一；
 *   - 每行的课程内容按**课程时段下标**去取，与列的具体类型无关。
 * 代价是：若某天的课表真换了时间表且课程数不同，按下标对齐会失真。
 * 现实中一周作息共用一张时间表，这个前提成立；真不成立时下面的下标越界
 * 会被夹住（退化为空单元格），不会错位到别的天上。
 *
 * 显示规则照搬桌面版 ScheduleDataGridCellControl：
 *   - 真实 ClassInfo 但没排科目 -> 显示「（无）」，半透明斜体
 *   - 当天根本没有课表（ClassInfo.IsEmpty 哨兵）-> 整格留白，不显示「（无）」
 *   - 课程被停用 -> 删除线；时间点 IsHideDefault -> 斜体
 *   - 调课 -> 一个强调色圆点
 *
 * 命名一律带 Schedule 前缀：ArkUI 有 GridRow / GridCol / Grid / Column / Row
 * 同名组件，类型名撞名会被 ArkTS 判为违规。
 */

import { DateTimeValue } from 'common_shared';

/** 空课程格的占位文案，与桌面版一致。 */
export const EMPTY_SUBJECT_TEXT: string = '（无）';

/** 网格的一列，对应时间表里的一个「需要显示的时间点」。 */
export class ScheduleColumn {
  /** 在 TimeLayout.layouts 中的下标。引擎的 selectedIndex 也是这个坐标系。 */
  layoutIndex: number = -1;

  /** 课程时段下标；非课程时间点（课间 / 分割线）为 -1。 */
  classSlot: number = -1;

  isClass: boolean = false;
  isBreak: boolean = false;

  /** 列头主标签：课程「第 N 节」，课间为课间名，分割线为空。 */
  label: string = '';

  /** 列头副标签：「08:00-08:45」。 */
  timeRange: string = '';

  /**
   * 时间为点的 IsHideDefault -> 全列斜体弱化。
   *
   * 挂在列上而非格子上：它描述的是这个时间点本身，不是「某天第几节课」。
   */
  isHideDefault: boolean = false;

  /** 该列是否就是此刻所在的列（课间也会命中，与引擎 selectedIndex 口径一致）。 */
  isCurrentColumn: boolean = false;
}

/** 网格的一个单元格。 */
export class ScheduleCell {
  /** 该格是否对应一个课程时段（false 即课间 / 分割线 / 空）。 */
  isClassSlot: boolean = false;

  hasSubject: boolean = false;
  subjectName: string = '';
  teacherName: string = '';

  /** 课程被停用 -> 删除线。 */
  isEnabled: boolean = true;

  /** 调课 / 换课 -> 强调色圆点。 */
  isChangedClass: boolean = false;

  /** 是否就是此刻正在上的那节课。只有今天那行可能为 true。 */
  isCurrent: boolean = false;

  /** 是否是下一节课。只有今天那行可能为 true。 */
  isNext: boolean = false;
}

/** 网格的一行，对应一周中的某一天。 */
export class ScheduleRow {
  /** 0=周日 … 6=周六，与 DateTimeValue.dayOfWeek() 及 TimeRule.weekDay 同一坐标系。 */
  dayOfWeek: number = 0;

  date: DateTimeValue = DateTimeValue.minValue();
  isToday: boolean = false;

  /** 该天是否真的有课表。false 时整行留白，不显示「（无）」。 */
  hasPlan: boolean = false;

  /** 该天生效的课表名。 */
  planName: string = '';

  /** 该天用的是不是叠加班表 —— 界面上给个标记，免得看混了。 */
  isOverlay: boolean = false;

  cells: ScheduleCell[] = [];
}

/** 一周课表网格。 */
export class ScheduleGrid {
  columns: ScheduleColumn[] = [];
  rows: ScheduleRow[] = [];

  /** 今天的行下标；不在本表范围内时为 -1。 */
  todayRowIndex: number = -1;

  /** 列模板来自哪张时间表；为空表示当天没有任何可用课表，界面应显示空态。 */
  templateLayoutName: string = '';

  isEmpty(): boolean {
    return this.columns.length === 0;
  }

  /**
   * 展示指纹：把界面上会显示出来的每一项拼成一个字符串。
   *
   * 存在的理由是轮询。课表页为了推进「当前课 / 下一节课」的高亮会定时重算，
   * 而重算本身并不改变绝大多数格子。若每次都把新网格塞给状态管理，就会每 tick
   * 触发一次全量重绘。调用方拿两次的指纹比一下，相同就不动状态，界面自然不重绘。
   *
   * 覆盖范围是「所有被界面绑定读取的字段」，含高亮位 —— 高亮变了必须重绘。
   * 引擎快照本身不进网格，所以不在范围内。
   */
  displaySignature(): string {
    const parts: string[] = [this.templateLayoutName];
    for (const column of this.columns) {
      parts.push(`${column.layoutIndex},${column.classSlot},${column.isClass},${column.isBreak},` +
        `${column.label},${column.timeRange},${column.isHideDefault},${column.isCurrentColumn}`);
    }
    for (const row of this.rows) {
      const cells: string[] = [];
      for (const cell of row.cells) {
        cells.push(`${cell.isClassSlot},${cell.hasSubject},${cell.subjectName},${cell.teacherName},` +
          `${cell.isEnabled},${cell.isChangedClass},${cell.isCurrent},${cell.isNext}`);
      }
      parts.push(`${row.date.toDateString()},${row.isToday},${row.hasPlan},${row.planName},` +
        `${row.isOverlay},${cells.join(';')}`);
    }
    return parts.join('|');
  }
}
