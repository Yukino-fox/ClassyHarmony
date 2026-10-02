/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 单日课表视图 —— 手机形态的主体。
 *
 * 为什么手机不直接用网格
 * ----------------------
 * 一周 5 天 x 8 节在竖屏上必然要横滑，而横滑的表格没法一眼看全「第几节课上什么」。
 * 手机上用户的问题通常是「我今天要上什么」，按时间顺序竖着排才对得上这个问题。
 * 网格留给平板和 2in1，那里宽度够，横向对比才是主要需求。
 *
 * 数据仍然来自同一份 ScheduleGrid：按行取出该天的 cells，与 columns 一一配对。
 * 也就是说周视图里能看到的东西，这里一样不少，只是排布不同。
 */

import { t } from 'common_core';
import { EMPTY_SUBJECT_TEXT, ScheduleCell, ScheduleColumn, ScheduleGrid, ScheduleRow } from 'common_core';

@ComponentV2
export struct ScheduleDayView {
  @Param grid: ScheduleGrid = new ScheduleGrid();
  /** 要显示的那一行（通常是今天或用户选中的某天）。 */
  @Param rowIndex: number = -1;

  private hasContent(): boolean {
    if (this.rowIndex < 0 || this.rowIndex >= this.grid.rows.length) {
      return false;
    }
    return this.grid.rows[this.rowIndex].hasPlan;
  }

  @Builder
  private classEntry(column: ScheduleColumn, cell: ScheduleCell | undefined) {
    Row() {
      // 左侧：节次 + 时间
      Column() {
        Text(column.label)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ch_text_primary'))
          .maxLines(1)
        Text(column.timeRange)
          .fontSize(10)
          .fontColor($r('app.color.ch_text_hint'))
          .maxLines(1)
          .margin({ top: 1 })
      }
      .width(76)
      .alignItems(HorizontalAlign.Start)

      // 右侧：课程
      Row() {
        Column() {
          Text(subjectText(cell))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ch_text_primary'))
            .fontStyle(enabledOf(cell) ? FontStyle.Normal : FontStyle.Italic)
            .decoration({
              type: enabledOf(cell) ? TextDecorationType.None : TextDecorationType.LineThrough,
              color: $r('app.color.ch_text_secondary')
            })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (teacherText(cell).length > 0) {
            Text(teacherText(cell))
              .fontSize(12)
              .fontColor($r('app.color.ch_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (changedOf(cell)) {
          Circle({ width: 7, height: 7 })
            .fill($r('app.color.ch_accent'))
        }
      }
      .layoutWeight(1)
      .padding({ left: 10, right: 10, top: 12, bottom: 12 })
      .borderRadius(12)
      .backgroundColor($r('app.color.ch_surface'))
      .border({
        width: nextOf(cell) ? 1 : 0.5,
        color: nextOf(cell) ? $r('app.color.ch_next') : $r('app.color.ch_outline'),
        style: nextOf(cell) ? BorderStyle.Dashed : BorderStyle.Solid
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 2, right: 2, bottom: 8 })
  }

  @Builder
  private breakEntry(column: ScheduleColumn) {
    Row() {
      Text(column.label)
        .fontSize(11)
        .fontColor($r('app.color.ch_text_secondary'))
        .maxLines(1)
      Blank()
      Text(column.timeRange)
        .fontSize(10)
        .fontColor($r('app.color.ch_text_hint'))
    }
    .width('100%')
    .padding({ left: 2, right: 2, top: 6, bottom: 6 })
  }

  @Builder
  private noPlanHint() {
    Text(t('sdv_no_schedule_day'))
      .fontSize(14)
      .fontColor($r('app.color.ch_text_hint'))
      .margin({ top: 40 })
  }

  build() {
    Column() {
      if (this.hasContent()) {
        ForEach(this.grid.columns, (column: ScheduleColumn, index: number) => {
          if (column.isClass) {
            this.classEntry(column, this.grid.rows[this.rowIndex].cells[index])
          } else if (column.isBreak) {
            this.breakEntry(column)
          }
          // 分割线（TimeType==2）在日视图里不占位置，直接略过。
        }, (column: ScheduleColumn, index: number) => `e${index}`)
      } else {
        this.noPlanHint()
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4 })
  }
}

function subjectText(cell: ScheduleCell | undefined): string {
  if (cell === undefined || !cell.hasSubject) {
    return EMPTY_SUBJECT_TEXT;
  }
  return cell.subjectName;
}

function teacherText(cell: ScheduleCell | undefined): string {
  if (cell === undefined || !cell.hasSubject) {
    return '';
  }
  return cell.teacherName;
}

function enabledOf(cell: ScheduleCell | undefined): boolean {
  return cell !== undefined && cell.isEnabled;
}

function nextOf(cell: ScheduleCell | undefined): boolean {
  return cell !== undefined && cell.isNext;
}

function changedOf(cell: ScheduleCell | undefined): boolean {
  return cell !== undefined && cell.isChangedClass;
}
