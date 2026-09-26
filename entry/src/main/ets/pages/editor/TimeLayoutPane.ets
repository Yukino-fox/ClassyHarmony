/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 时间表页。
 *
 * 行的行序就是用户排的，不排序
 * ----------------------------
 * 新增一行是「插到最后」，上下移动是「挪一格」，只有显式点「按时段重排」才按
 * 开始时刻整体排一次。这与桌面版一致：UpdateTimeLayout（Sort + Reverse，净效果
 * 升序）只挂在那个按钮上。
 *
 * 界面若在每次改动后自动排序，用户精心排的「大课间在上午、午休在中午」会被
 * 一次无关的改名打乱，而用户没有做任何要求重排的操作。
 *
 * 删中间一节课会连带删掉对应课次
 * ---------------------------
 * 这是与桌面版的一处有意分歧，理由写在 ScheduleMutations.removeTimePoint 的
 * 头注里：桌面版那处 Remove 分支和它的调用点都被注释掉了，只在末尾截断，
 * 会静默丢掉最后一节的排课。落盘格式一致，只是这个操作的结果不同，所以界面上
 * 删的确认文案必须写明「对应课次会一并删除」。
 */

import {
  SubjectRow,
  TimeLayoutRow,
  TimePointRow,
  TimeSpanRow,
  newTimeSpanRow,
  parseClockText,
  parseDurationText,
  timeRangeConflictIndex
} from 'common_core';
import { ScheduleEditorViewModel } from '../../viewmodel/ScheduleEditorViewModel';
import { UiFeedback } from '../../common/UiFeedback';
import {
  EditorChip,
  EditorDeleteButton,
  EditorEmptyHint,
  EditorHeader,
  EditorTextField,
  TimeLayoutRowHeader,
  TimePointRowSummary
} from '../../components/EditorWidgets';

/** 三个快速添加按钮。加的位置由本类算，这里只给类型。 */
@ComponentV2
struct QuickAddRow {
  @Event onAddClass: () => void = () => {};
  @Event onAddBreak: () => void = () => {};
  @Event onAddSeparator: () => void = () => {};

  build() {
    Row() {
      EditorChip({ text: '加一节课', onTap: () => { this.onAddClass(); } })
        .margin({ right: 8 })
      EditorChip({ text: '加一个课间', onTap: () => { this.onAddBreak(); } })
        .margin({ right: 8 })
      EditorChip({ text: '加一条分割线', onTap: () => { this.onAddSeparator(); } })
    }
    .width('100%')
    .padding({ top: 8 })
  }
}

@ComponentV2
export struct TimeLayoutPane {
  @Require @Param vm: ScheduleEditorViewModel;
  @Param stack: NavPathStack = new NavPathStack();

  @Local expanded: string = '';
  /** 正在改哪一行的时刻。空串表示没在改。 */
  @Local editingRow: string = '';

  private rowKey(guid: string, rowIndex: number): string {
    return `${guid}#${rowIndex}`;
  }

  /**
   * 加一节课。起点接在最后一行之后。
   *
   * 接续而不是写死 08:00：加第二行时如果还从 08:00 开始，它会和第一行撞在
   * 同一时刻，用户要自己改。这里的默认值对「加第二行」这个最常见的场景
   * 恰好是对的；第一行是新建时间表自带的 00:00 占位，所以第一次点也是接着走。
   */
  private addClass(row: TimeLayoutRow): void {
    const at: number = this.nextStart(row, 45 * 60);
    this.vm.addTimePoint(row.guid, 0, at, 45);
  }

  /**
   * 加一个课间。
   *
   * 课间默认 15 分钟 —— 课表里最常见的两种是 10 分钟（小课间）与 20 分钟
   * （大课间），取中间的 15 会让前两种都要改。改成「接在最后一行之后 10 分钟」，
   * 因为 10 分钟是最不容易与前后节同时冲突的短间隔，用户拖一下比敲一个数字
   * 更容易判断对不对。
   */
  private addBreak(row: TimeLayoutRow): void {
    const at: number = this.nextStart(row, 10 * 60);
    this.vm.addTimePoint(row.guid, 1, at, 10);
  }

  /**
   * 加一条分割线。
   *
   * 分割线没有时长（0 秒），它只是把行分成几段。给了时长它就会显示成一个
   * 有起止时刻的行，界面上看起来像漏了结束时刻的一节课。
   */
  private addSeparator(row: TimeLayoutRow): void {
    const at: number = this.lastEnd(row);
    this.vm.addTimePoint(row.guid, 2, at, 0);
  }

  /** 最后一行结束之后 gap 秒的时刻（秒）。表是空的就从 08:00 起。 */
  private nextStart(row: TimeLayoutRow, gap: number): number {
    return this.lastEnd(row) + gap;
  }

  /**
   * 最后一行的结束时刻。
   *
   * 取最后一行而不是「最大值」：用户可能故意把某行排在末尾之后（虽然那会被
   * 重排按钮纠正），而「接在用户排的最后一行后面」永远符合他的直觉。
   */
  private lastEnd(row: TimeLayoutRow): number {
    if (row.rows.length === 0) {
      return 8 * 3600;
    }
    const last: TimePointRow = row.rows[row.rows.length - 1];
    return this.secondsOf(last.endText);
  }

  build() {
    NavDestination() {
      Column() {
        EditorHeader({ title: '时间表', stack: this.stack })

        Scroll() {
          Column() {
            if (this.vm.timeLayouts.length === 0) {
              EditorEmptyHint({ text: '还没有时间表。课表要绑定一张时间表才能排课。' })
            }
            ForEach(this.vm.timeLayouts, (row: TimeLayoutRow) => {
              Column() {
                TimeLayoutRowHeader({
                  row: row,
                  isExpanded: this.expanded === row.guid,
                  onToggle: () => {
                    this.expanded = this.expanded === row.guid ? '' : row.guid;
                    this.editingRow = '';
                  }
                })

                if (this.expanded === row.guid) {
                  this.detail(this.vm, row)
                }
              }
              .width('100%')
              .padding({ bottom: 8 })

              Divider().color($r('app.color.ch_outline'))
            }, (row: TimeLayoutRow) => row.guid)

            EditorChip({ text: '新建时间表', onTap: () => { this.newLayout(); } })
              .margin({ top: 16 })
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 24 })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
  }

  private newLayout(): void {
    this.expanded = this.vm.addTimeLayout('新时间表');
    this.editingRow = '';
  }

  @Builder
  private detail(vm: ScheduleEditorViewModel, row: TimeLayoutRow) {
    Column() {
      EditorTextField({
        label: '名称',
        value: row.name,
        placeholder: '时间表名',
        onCommit: (text: string) => { vm.renameTimeLayout(row.guid, text); }
      })

      Text(row.boundPlanNames.length > 0
        ? `被这些课表使用：${row.boundPlanNames}`
        : '还没有课表用这张时间表。')
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .margin({ top: 4, bottom: 4 })

      Row() {
        EditorChip({
          text: '按时段重排',
          onTap: () => { vm.sortTimeLayout(row.guid); }
        })
          .margin({ right: 8 })
        EditorDeleteButton({
          text: '删除时间表',
          message: row.usedByPlans > 0
            ? `有 ${row.usedByPlans} 张课表绑在这张时间表上，删除后它们会被解绑、不再参与选课。`
            : '这张时间表没有课表在用，删了不会影响课表。',
          onConfirm: () => { vm.removeTimeLayout(row.guid); }
        })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      QuickAddRow({
        onAddClass: () => { this.addClass(row); },
        onAddBreak: () => { this.addBreak(row); },
        onAddSeparator: () => { this.addSeparator(row); }
      })

      Divider().color($r('app.color.ch_outline')).margin({ top: 8, bottom: 4 })

      if (row.rows.length === 0) {
        EditorEmptyHint({ text: '这张时间表还没有时段。' })
      }
      ForEach(row.rows, (point: TimePointRow) => {
        Column() {
          TimePointRowSummary({ row: point })
          this.pointActions(vm, row, point)
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        Divider().color($r('app.color.ch_outline'))
      }, (point: TimePointRow) => `${row.guid}#${point.rowIndex}`)
    }
    .width('100%')
    .padding({ left: 8, top: 4 })
  }

  /**
   * 一行时段下方的操作。
   *
   * 编辑时刻用「点开 -> 填 -> 提交」而不是常驻输入框：一行时段已经占了一整行
   * 摘要，再加两个输入框，一屏放不下三行。
   */
  @Builder
  private pointActions(vm: ScheduleEditorViewModel, layout: TimeLayoutRow, point: TimePointRow) {
    Column() {
      if (this.editingRow === this.rowKey(layout.guid, point.rowIndex)) {
        this.pointEditor(vm, layout, point)
      } else {
        Row() {
          EditorChip({
            text: '上移',
            onTap: () => { vm.moveTimePoint(layout.guid, point.rowIndex, -1); }
          })
            .margin({ right: 8 })
          EditorChip({
            text: '下移',
            onTap: () => { vm.moveTimePoint(layout.guid, point.rowIndex, 1); }
          })
            .margin({ right: 8 })
          EditorChip({
            text: '改时刻',
            onTap: () => {
              this.editingRow = this.editingRow === this.rowKey(layout.guid, point.rowIndex)
                ? '' : this.rowKey(layout.guid, point.rowIndex);
            }
          })
          Blank()
          EditorDeleteButton({
            text: '删除',
            message: point.isClass
              ? `第 ${point.classSlot + 1} 节课。删除会一并删掉所有用这张时间表的课表里` +
                '对应的那一节课。'
              : '删除这个时段。',
            onConfirm: () => { vm.removeTimePoint(layout.guid, point.rowIndex); }
          })
        }
        .width('100%')

        if (point.isClass) {
          this.defaultSubjectRow(vm, layout, point)
        }
      }
    }
    .width('100%')
    .padding({ top: 4 })
  }

  /**
   * 预置科目。
   *
   * 预置是「这张时间表的这一节默认上什么」，设一次会刷到所有绑定的课表上，
   * 所以它属于时间表而不属于某一节课。这一点要在界面上说清楚，否则用户会
   * 以为只改了自己看到的那张表。
   */
  @Builder
  private defaultSubjectRow(vm: ScheduleEditorViewModel, layout: TimeLayoutRow,
    point: TimePointRow) {
    Row() {
      Text('预置')
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width(36)

      if (point.defaultSubjectName.length > 0) {
        Text(point.defaultSubjectName)
          .fontSize(12)
          .fontColor($r('app.color.ch_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        Text('未设')
          .fontSize(12)
          .fontColor($r('app.color.ch_text_hint'))
          .layoutWeight(1)
      }

      // 整行 bindMenu：点哪都一样打开科目菜单。菜单第一项就是「清除预置」，
      // 单独再给一个清除按钮的话，同一个动作有两个入口，而两者清掉的是不同
      // 东西（按钮清 DefaultClassId，菜单项清 DefaultClassId + IsHideDefault）
      Text('选择…')
        .fontSize(12)
        .fontColor($r('app.color.ch_accent'))
        .margin({ right: 12 })

      if (point.defaultAppliedCount > 0) {
        Text(`已刷到 ${point.defaultAppliedCount} 张表`)
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 4, bottom: 2 })
    .bindMenu(this.subjectMenu(vm, layout, point))
  }

  @Builder
  private subjectMenu(vm: ScheduleEditorViewModel, layout: TimeLayoutRow, point: TimePointRow) {
    Menu() {
      MenuItem({ content: '清除预置' }).onChange(() => {
        vm.setDefaultClass(layout.guid, point.rowIndex, '', false);
      })
      ForEach(vm.subjects, (subject: SubjectRow) => {
        MenuItem({ content: subject.name }).onChange(() => {
          vm.setDefaultClass(layout.guid, point.rowIndex, subject.guid, point.isHideDefault);
        })
      }, (subject: SubjectRow) => subject.guid)
    }
  }

  /**
   * 改时刻。
   *
   * 输入不合规时把原文退回而不是静默改成 00:00：用户敲了「25:00」，如果界面
   * 悄悄把时间点挪到午夜，他不会知道自己输错了。
   */
  @Builder
  private pointEditor(vm: ScheduleEditorViewModel, layout: TimeLayoutRow, point: TimePointRow) {
    Row() {
      EditorTextField({
        label: '开始',
        value: point.startText,
        placeholder: '08:00',
        onCommit: (text: string) => { this.commitClock(vm, layout, point, text, point.durationText); }
      })
      EditorTextField({
        label: '时长',
        value: point.durationText,
        placeholder: '45 分钟',
        onCommit: (text: string) => { this.commitClock(vm, layout, point, point.startText, text); }
      })
    }
    .width('100%')
  }

  private commitClock(vm: ScheduleEditorViewModel, layout: TimeLayoutRow, point: TimePointRow,
    clockText: string, durationText: string): void {
    const start: number | undefined = parseClockText(clockText);
    if (start === undefined) {
      UiFeedback.toast(this.getUIContext(), '开始时刻格式不对，例：08:00');
      return;
    }
    const minutes: number | undefined = parseDurationText(durationText);
    if (minutes === undefined) {
      UiFeedback.toast(this.getUIContext(), '时长格式不对，例：45 分钟');
      return;
    }
    const clash: number = this.conflictOf(layout, point, start, minutes);
    if (clash >= 0) {
      UiFeedback.toast(this.getUIContext(),
        `与 ${layout.rows[clash].classSlotText} 的时间重叠`);
      return;
    }
    vm.updateTimePoint(layout.guid, point.rowIndex, point.timeType, start, minutes,
      point.breakName);
    this.editingRow = '';
  }

  /**
   * 改后的时段会不会和别的行撞。
   *
   * 只与「课程行」比：课间本来就该是空的，落在课间里不算冲突。判重写在
   * TimeRange 里，这里只负责把行喂给它。
   */
  private conflictOf(layout: TimeLayoutRow, self: TimePointRow, start: number,
    minutes: number): number {
    const spans: TimeSpanRow[] = [];
    for (const point of layout.rows) {
      if (point.rowIndex === self.rowIndex || !point.isClass) {
        continue;
      }
      spans.push(newTimeSpanRow(point.rowIndex,
        this.secondsOf(point.startText), this.secondsOf(point.endText), point.classSlotText));
    }
    return timeRangeConflictIndex(spans, start, start + minutes * 60);
  }

  private secondsOf(text: string): number {
    const parsed: number | undefined = parseClockText(text);
    return parsed === undefined ? 0 : parsed;
  }
}
