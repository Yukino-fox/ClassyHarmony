/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 一周课表网格。
 *
 * 布局
 * ----
 * 外层一个纵向 Scroll 包住一整行；左边是「星期 + 日期」的固定列，右边是横向
 * Scroll 的时间点区。这么做而不是「整块一起横滑」的原因是：星期列必须始终可
 * 见，横向滑到第 8 节课时用户还得知道自己看的是周几。两侧处在同一个纵向
 * Scroll 里，行高天然对齐，不需要手动同步滚动位置。
 *
 * 列宽两种模式
 * ------------
 * fillWidth 为真时列用 layoutWeight 均分，把可用宽度吃满（2in1 / 平板宽屏）；
 * 为假时列用固定宽度并允许横向滚动（窄一点的平板）。判断放在页面那一层，
 * 网格只负责按指令渲染 —— 断点判定散在两个地方的话，改断点要改两处。
 *
 * 这个组件只在 md 及以上档位出现（手机用 ScheduleDayView），所以格子一律按
 * 宽屏排：老师名照常显示，行高也不压缩。
 */

import { ScheduleCell, ScheduleColumn, ScheduleGrid, ScheduleRow } from 'common_core';
import { ScheduleCellView } from './ScheduleCellView';

/** 列最小宽度。窄于此就横向滚动。 */
const MIN_CELL_WIDTH: number = 68;

/** 星期列宽度。放得下「周一」加日期（如 9/28）。 */
const DAY_HEADER_WIDTH: number = 62;

/** 行高。课程格要放科目名 + 老师名，课间格用不满但保持对齐。 */
const ROW_HEIGHT: number = 52;

const WEEKDAY_LABELS: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

@ComponentV2
export struct ScheduleGridView {
  @Param grid: ScheduleGrid = new ScheduleGrid();
  /** 宽屏下让列均分吃满宽度。 */
  @Param fillWidth: boolean = false;

  /**
   * 是否走「均分吃满宽度」这条路。
   *
   * 方法名不能与 @Param fillWidth 同名：ArkUI 里属性名与方法名同空间，
   * this.fillWidth 会解析到 boolean 参数，当函数调用就报「无调用签名」。
   */
  private fillsWidth(): boolean {
    return this.fillWidth;
  }

  @Builder
  private columnHeader(column: ScheduleColumn) {
    Column() {
      if (column.label.length > 0) {
        Text(column.label)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(column.isCurrentColumn
            ? $r('app.color.ch_accent')
            : $r('app.color.ch_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Text(column.timeRange)
        .fontSize(9)
        .fontColor($r('app.color.ch_text_hint'))
        .maxLines(1)
        .margin({ top: 1 })
    }
    .width(this.fillsWidth() ? undefined : MIN_CELL_WIDTH)
    .layoutWeight(this.fillsWidth() ? 1 : undefined)
    .height(ROW_HEIGHT)
    .padding({ left: 3, right: 3 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.ch_surface_weak'))
    .border({ width: { bottom: 0.5 }, color: $r('app.color.ch_outline') })
  }

  @Builder
  private dayHeader(row: ScheduleRow) {
    Column() {
      Text(WEEKDAY_LABELS[row.dayOfWeek])
        .fontSize(12)
        .fontWeight(row.isToday ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(row.isToday ? $r('app.color.ch_accent') : $r('app.color.ch_text_primary'))
        .maxLines(1)
      Text(shortDate(row))
        .fontSize(9)
        .fontColor(row.isToday ? $r('app.color.ch_accent') : $r('app.color.ch_text_hint'))
        .maxLines(1)
        .margin({ top: 1 })
    }
    .width(DAY_HEADER_WIDTH)
    .height(ROW_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(row.isToday ? $r('app.color.ch_accent_soft') : $r('app.color.ch_surface_weak'))
    .border({ width: { right: 0.5, bottom: 0.5 }, color: $r('app.color.ch_outline') })
  }

  @Builder
  private cornerHeader() {
    Column() {
      Text(this.grid.templateLayoutName)
        .fontSize(9)
        .fontColor($r('app.color.ch_text_hint'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width(DAY_HEADER_WIDTH)
    .height(ROW_HEIGHT)
    .padding({ left: 2, right: 2 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.ch_surface_weak'))
    .border({
      width: { right: 0.5, bottom: 0.5 },
      color: $r('app.color.ch_outline')
    })
  }

  @Builder
  private cellRow(row: ScheduleRow) {
    Row() {
      ForEach(row.cells, (cell: ScheduleCell, index: number) => {
        ScheduleCellView({
          subjectName: cell.hasSubject ? cell.subjectName : '',
          teacherName: cell.teacherName,
          isBreakCell: !cell.isClassSlot,
          isSeparatorCell: !cell.isClassSlot,
          breakLabel: this.breakLabelOf(index),
          disabled: !cell.isEnabled,
          hideDefault: this.grid.columns[index] !== undefined &&
            this.grid.columns[index].isHideDefault,
          changed: cell.isChangedClass,
          current: cell.isCurrent,
          next: cell.isNext
        })
          .width(this.fillsWidth() ? undefined : MIN_CELL_WIDTH)
          .layoutWeight(this.fillsWidth() ? 1 : undefined)
          .height(ROW_HEIGHT)
      }, (cell: ScheduleCell, index: number) => `c${index}`)
    }
    .width('100%')
    .height(ROW_HEIGHT)
  }

  /** 课间格的文字。课程格不显示，所以这里只在非课程格上取列。 */
  private breakLabelOf(index: number): string {
    const column: ScheduleColumn | undefined = this.grid.columns[index];
    if (column === undefined || column.isClass) {
      return '';
    }
    return column.label;
  }

  /** 整块网格的横向可滚动区域。 */
  @Builder
  private scrollingBody() {
    Scroll() {
      Column() {
        Row() {
          ForEach(this.grid.columns, (column: ScheduleColumn) => {
            this.columnHeader(column)
          }, (column: ScheduleColumn, index: number) => `h${index}`)
        }
        .width('100%')

        ForEach(this.grid.rows, (row: ScheduleRow) => {
          this.cellRow(row)
        }, (row: ScheduleRow) => `r${row.date.toDateString()}`)
      }
      .width(this.fillsWidth() ? '100%' : undefined)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Auto)
    .layoutWeight(1)
    .align(Alignment.Top)
  }

  build() {
    Row() {
      // 固定列：表头占位 + 七个星期
      Column() {
        this.cornerHeader()
        ForEach(this.grid.rows, (row: ScheduleRow) => {
          this.dayHeader(row)
        }, (row: ScheduleRow) => `d${row.date.toDateString()}`)
      }

      this.scrollingBody()
    }
    .width('100%')
    .align(Alignment.Top)
  }
}

/** 「9/28」这样的短日期。 */
function shortDate(row: ScheduleRow): string {
  return `${row.date.month}/${row.date.day}`;
}
