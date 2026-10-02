/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 一周日期条 —— 手机形态下切换「看哪一天」的选择器。
 *
 * 选中态与今天态用两种视觉区分：选中是实心填充，今天是描边 + 强调色文字。
 * 两者可能重合（默认就是看今天），所以今天态不能靠「比选中更深」来表达，
 * 必须是另一条通道。
 */

import { t } from 'common_core';
import { ScheduleGrid, ScheduleRow } from 'common_core';

const WEEKDAY_SHORT: string[] = [t('week_sun'), t('week_mon'), t('week_tue'), t('week_wed'), t('week_thu'), t('week_fri'), t('week_sat')];

@ComponentV2
export struct WeekStripView {
  @Param grid: ScheduleGrid = new ScheduleGrid();
  /** 当前选中的行下标。 */
  @Param selectedIndex: number = -1;
  /** 点击某一天。参数是行下标。 */
  @Event onPick: (index: number) => void = (index: number): void => {};

  @Builder
  private chip(row: ScheduleRow, index: number) {
    Column() {
      Text(WEEKDAY_SHORT[row.dayOfWeek])
        .fontSize(11)
        .fontColor(this.isSelected(index) ? '#FFFFFF' : $r('app.color.ch_text_secondary'))
        .maxLines(1)
      Text(`${row.date.day}`)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isSelected(index)
          ? '#FFFFFF'
          : (row.isToday ? $r('app.color.ch_accent') : $r('app.color.ch_text_primary')))
        .maxLines(1)
        .margin({ top: 1 })
    }
    .width(40)
    .height(48)
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .backgroundColor(this.isSelected(index) ? $r('app.color.ch_accent') : Color.Transparent)
    .border({
      width: row.isToday && !this.isSelected(index) ? 1 : 0,
      color: $r('app.color.ch_accent'),
      style: BorderStyle.Solid
    })
    .onClick(() => {
      this.onPick(index);
    })
  }

  private isSelected(index: number): boolean {
    return this.selectedIndex === index;
  }

  build() {
    Row() {
      ForEach(this.grid.rows, (row: ScheduleRow, index: number) => {
        this.chip(row, index)
      }, (row: ScheduleRow) => `w${row.date.toDateString()}`)
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
  }
}
