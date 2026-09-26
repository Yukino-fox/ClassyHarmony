/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 课表网格的一个格子。
 *
 * 显示规则照搬桌面版 ScheduleDataGridCellControl：
 *   - 有科目 -> 科目名（大）+ 老师名（小、弱化）
 *   - 真实课程格但没排科目 -> 「（无）」，低透明度斜体
 *   - 课间 / 分割线格 -> 只有居中的弱化文字
 *   - 课程被停用 -> 删除线 + 斜体 + 半透明
 *   - 时间为点 IsHideDefault -> 斜体
 *   - 调课 -> 右上角强调色圆点
 *   - 正在上的课 -> 强调色左边条 + 淡蓝底
 *   - 下一节课 -> 次强调色虚线描边
 *
 * 入参全是标量而不是 ScheduleCell 对象
 * ------------------------------------
 * V2 的 @Param 传普通对象时，父组件每次重建都会把整个对象重新传一遍，
 * 于是一个格子变了会导致同行所有格子跟着重绘。这里把要显示的字段拆成
 * 标量参数，V2 才能只重绘真正变了的那几格。7 x 8 的网格在手机上
 * 每秒重绘一次的场景下，这个差别是能看出来的。
 */

import { EMPTY_SUBJECT_TEXT } from 'common_core';

@ComponentV2
export struct ScheduleCellView {
  /** 科目名；空串表示未排科目。 */
  @Param subjectName: string = '';
  @Param teacherName: string = '';

  /** 该格是课间 / 分割线（只显示文字，不显示课程）。 */
  @Param isBreakCell: boolean = false;
  /** 该格是分割线，连文字都没有。 */
  @Param isSeparatorCell: boolean = false;
  /** 课间 / 分割线的文字（课间名）。 */
  @Param breakLabel: string = '';

  @Param disabled: boolean = false;
  @Param hideDefault: boolean = false;
  @Param changed: boolean = false;
  @Param current: boolean = false;
  @Param next: boolean = false;

  // 返回类型必须是 ResourceColor 而不是 string：$r() 给的是 Resource，
  // 声明成 string 会被判类型不匹配。
  private bodyColor(): ResourceColor {
    if (this.isBreakCell) {
      return $r('app.color.ch_surface_alt');
    }
    if (this.current) {
      return $r('app.color.ch_accent_soft');
    }
    return $r('app.color.ch_surface');
  }

  private mainTextColor(): ResourceColor {
    if (this.isBreakCell) {
      return $r('app.color.ch_text_secondary');
    }
    return $r('app.color.ch_text_primary');
  }

  @Builder
  private breakContent() {
    Column() {
      if (this.breakLabel.length > 0) {
        Text(this.breakLabel)
          .fontSize(11)
          .fontColor($r('app.color.ch_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private classContent() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        if (this.subjectName.length > 0) {
          Text(this.subjectName)
            .fontSize(13)
            .fontWeight(this.current ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(this.mainTextColor())
            .fontStyle(this.disabled || this.hideDefault ? FontStyle.Italic : FontStyle.Normal)
            .decoration({
              type: this.disabled ? TextDecorationType.LineThrough : TextDecorationType.None,
              color: $r('app.color.ch_text_secondary')
            })
            .opacity(this.disabled ? 0.5 : 1.0)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          if (this.teacherName.length > 0) {
            Text(this.teacherName)
              .fontSize(10)
              .fontColor($r('app.color.ch_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 1 })
          }
        } else {
          // 「（无）」：课程格存在但没排科目。与课间格的区别是这里保留课程格的边框。
          Text(EMPTY_SUBJECT_TEXT)
            .fontSize(13)
            .fontStyle(FontStyle.Italic)
            .fontColor(this.mainTextColor())
            .opacity(0.25)
            .maxLines(1)
            .width('100%')
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Start)

      if (this.changed) {
        // 调课标记。桌面版是 8px 的强调色圆点，这里用 6vp 免得太抢眼。
        Circle({ width: 6, height: 6 })
          .fill($r('app.color.ch_accent'))
          .margin({ top: 4, right: 4 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 5, right: 5 })
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row() {
        if (this.current) {
          // 左侧强调条：比整格染色更克制，也不会盖住课表线。
          Row()
            .width(3)
            .height('100%')
            .backgroundColor($r('app.color.ch_accent'))
        }
        if (this.isBreakCell) {
          this.breakContent()
        } else if (this.subjectName.length > 0 || !this.isSeparatorCell) {
          this.classContent()
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.bodyColor())
    .border({
      width: this.next ? 1 : 0.5,
      color: this.next ? $r('app.color.ch_next') : $r('app.color.ch_outline'),
      style: this.next ? BorderStyle.Dashed : BorderStyle.Solid
    })
  }
}
