/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 课表页（含排课）。
 *
 * 一张课表 = 一周里几天上什么
 * ----------------------------
 * 所以这一页的主结构是「课表列表 -> 单张课表 -> 排课网格」。展开态里同时给出
 * 轮转规则（周几 / 单双周）和逐节课的排课，因为这两件事总是一起改的：改了
 * 规则立刻要看排课对不对，反过来也一样。分两屏的话每次验证都要来回切。
 *
 * 网格按行显示的是原始行序，不是过滤后的
 * ---------------------------------------
 * 这里刻意用 PlanEditRow（含课间与分割线），而课表页（P2 的主页面）用的是
 * validTimeLayoutItems（按停用过滤）。编辑页呈现的是「这张时间表有哪些行」，
 * 主页面呈现的是「今天看得到什么」。停用掉的一节课在编辑页必须还能看见并改回来
 * —— 它要是消失了，用户根本不知道那一节课曾经存在，也就无从恢复。
 *
 * 轮转规则用下拉而不是手打数字
 * --------------------------
 * 周几是 0..6 的固定枚举（0=周日，与桌面版一致），手打数字的话打错一个 7 就是
 * 「每周都不匹配」——界面上什么都不显示，而用户看不出是哪错了。
 */

import { t, tf } from 'common_core';
import {
  ClassPlanRow,
  ClassSlotRow,
  PlanEditRow,
  SubjectRow,
  TimeLayoutRow,
  weekDayShortName
} from 'common_core';
import { ScheduleEditorViewModel } from '../../viewmodel/ScheduleEditorViewModel';
import { UiFeedback } from '../../common/UiFeedback';
import {
  EditorChip,
  EditorDeleteButton,
  EditorEmptyHint,
  EditorHeader,
  EditorTextField,
  EditorToggleRow
} from '../../components/EditorWidgets';

/** 周几下拉的可选项，与引擎的 0=周日 一致。 */
const WEEKDAY_LABELS: string[] =
  [t('week_sunday'), t('week_monday'), t('week_tuesday'), t('week_wednesday'), t('week_thursday'), t('week_friday'), t('week_saturday')];

/** 单双周分母的可选项。0 之外只给常见的 1/2/3/4。 */
const ROTATION_TOTALS: string[] = [t('cp_rot_week'), t('cp_rot_odd'), t('cp_rot_even'), t('cp_rot_3w'), t('cp_rot_4w')];

/**
 * 一行：左边是行摘要（节次 + 时刻），右边是挂着的科目。
 *
 * 课间与分割线也占一行，标灰不排课。它们不是「空行」：用户在时间表里排好的
 * 顺序里就有一节课间，编辑页把它抹掉的话，用户看到的行号与他排的不一致，
 * 改的时候不知道自己改的是第几节。
 */
@ComponentV2
struct PlanSlotLine {
  @Require @Param vm: ScheduleEditorViewModel;
  @Param planGuid: string = '';
  @Param edit: PlanEditRow = new PlanEditRow();
  @Param slot: ClassSlotRow = new ClassSlotRow();

  private isClass(): boolean {
    return this.edit.isClass && this.edit.classSlot >= 0;
  }

  build() {
    Row() {
      Text(this.edit.isClass ? this.edit.label : this.edit.timeRange)
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width(96)
        .maxLines(1)

      if (!this.isClass()) {
        Text(this.edit.isSeparator ? t('cp_separator') : t('cp_break'))
          .fontSize(12)
          .fontColor($r('app.color.ch_text_hint'))
          .layoutWeight(1)
      } else {
        Text(this.slot.isEmpty ? t('cp_slot_empty') : this.slot.subjectName)
          .fontSize(14)
          .fontColor(this.slot.isEmpty
            ? $r('app.color.ch_text_hint')
            : $r('app.color.ch_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        if (this.slot.hasDefault) {
          Text(t('cp_has_default'))
            .fontSize(11)
            .fontColor($r('app.color.ch_text_hint'))
            .margin({ right: 8 })
        }

        Toggle({ type: ToggleType.Switch, isOn: this.slot.isEnabled })
          .width(40)
          .height(20)
          .selectedColor($r('app.color.ch_accent'))
          .onChange((next: boolean) => {
            this.vm.setClassEnabled(this.planGuid, this.edit.classSlot, next);
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .bindMenu(this.menu)
  }

  /**
   * 一节课的菜单。
   *
   * 「这节课今天不上」做成菜单项而不是行内 Toggle 之外的另一个入口：排课的
   * 主动作是「换成什么」，调课是例外路径。把调课塞进菜单，菜单里就是
   * 「换成什么」和「不上」两件事，用户扫一眼就知道有哪些选择。
   */
  @Builder
  private menu() {
    Menu() {
      MenuItem({ content: t('cp_clear_class') }).onChange(() => {
        this.vm.setClassSubject(this.planGuid, this.edit.classSlot, '');
      })
      MenuItem({
        content: this.slot.isEnabled ? t('cp_skip_today') : t('cp_take_today')
      }).onChange(() => {
        this.vm.setClassEnabled(this.planGuid, this.edit.classSlot, !this.slot.isEnabled);
      })
      MenuItem({
        content: this.slot.isChangedClass ? t('cp_unmark_adjust') : t('cp_mark_adjust')
      }).onChange(() => {
        this.vm.setClassChanged(this.planGuid, this.edit.classSlot, !this.slot.isChangedClass);
      })
      ForEach(this.vm.subjects, (subject: SubjectRow) => {
        MenuItem({ content: subject.name }).onChange(() => {
          this.vm.setClassSubject(this.planGuid, this.edit.classSlot, subject.guid);
        })
      }, (subject: SubjectRow) => subject.guid)
    }
  }
}

@ComponentV2
export struct ClassPlanPane {
  @Require @Param vm: ScheduleEditorViewModel;
  @Param stack: NavPathStack = new NavPathStack();

  @Local expanded: string = '';

  private toggle(guid: string): void {
    this.expanded = this.expanded === guid ? '' : guid;
  }

  private newPlan(): void {
    // 新建要绑一张时间表，而选哪张是用户的事。绑不上的课表不参与选课，
    // 建出来就是一张空壳。所以先让用户选时间表，选不下去就不建。
    if (this.vm.timeLayouts.length === 0) {
      UiFeedback.toast(this.getUIContext(), t('cp_no_timelayout_first'));
      return;
    }
    const first: string = this.vm.timeLayouts[0].guid;
    this.expanded = this.vm.addClassPlan(first, t('cp_default_name'));
  }

  build() {
    NavDestination() {
      Column() {
        EditorHeader({ title: t('cp_title'), stack: this.stack })

        Scroll() {
          Column() {
            if (this.vm.classPlans.length === 0) {
              EditorEmptyHint({ text: t('cp_no_schedule') })
            }
            ForEach(this.vm.classPlans, (row: ClassPlanRow) => {
              Column() {
                this.header(this.vm, row)
                if (this.expanded === row.guid) {
                  this.detail(this.vm, row)
                }
              }
              .width('100%')
              .padding({ top: 6, bottom: 10 })

              Divider().color($r('app.color.ch_outline'))
            }, (row: ClassPlanRow) => row.guid)

            EditorChip({ text: t('cp_new_schedule'), onTap: () => { this.newPlan(); } })
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

  /** 收起态那一行。 */
  @Builder
  private header(vm: ScheduleEditorViewModel, row: ClassPlanRow) {
    Row() {
      Column() {
        Row() {
          Text(row.name)
            .fontSize(14)
            .fontColor($r('app.color.ch_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (row.isOverlay) {
            Text(t('cp_overlay_badge'))
              .fontSize(11)
              .fontColor($r('app.color.ch_next'))
              .margin({ left: 6 })
          }
          if (!row.isEnabled) {
            Text(t('cp_disabled'))
              .fontSize(11)
              .fontColor($r('app.color.ch_text_hint'))
              .margin({ left: 6 })
          }
          if (row.isActiveOnBaseDate) {
            Text(t('cp_active_today'))
              .fontSize(11)
              .fontColor($r('app.color.ch_accent'))
              .margin({ left: 6 })
          }
        }
        .width('100%')

        Text(tf('cp_plan_progress', row.weekDayText, row.weekRotationText, `${row.filledCount}`, `${row.classCount}`))
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.expanded === row.guid ? t('cp_collapse') : t('cp_expand'))
        .fontSize(12)
        .fontColor($r('app.color.ch_accent'))
        .onClick(() => { this.toggle(row.guid); })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  private detail(vm: ScheduleEditorViewModel, row: ClassPlanRow) {
    Column() {
      EditorTextField({
        label: t('cp_name'),
        value: row.name,
        placeholder: t('cp_name_placeholder'),
        onCommit: (text: string) => { vm.renameClassPlan(row.guid, text); }
      })

      // ---- 绑定时间表 ----
      Row() {
        Text(t('cp_time_layout'))
          .fontSize(13)
          .fontColor($r('app.color.ch_text_secondary'))
          .width(76)
        Text(row.timeLayoutName)
          .fontSize(13)
          .fontColor(row.hasTimeLayout
            ? $r('app.color.ch_text_primary')
            : $r('app.color.ch_accent'))
          .layoutWeight(1)
          .maxLines(1)
        Text(t('cp_change'))
          .fontSize(12)
          .fontColor($r('app.color.ch_accent'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 4, bottom: 4 })
      .bindMenu(this.layoutMenu(vm, row))

      if (!row.hasTimeLayout) {
        Text(t('cp_timelayout_stale'))
          .fontSize(11)
          .fontColor($r('app.color.ch_accent'))
          .width('100%')
          .padding({ bottom: 4 })
      }

      // ---- 轮转规则 ----
      Row() {
        Text(t('cp_weekday'))
          .fontSize(13)
          .fontColor($r('app.color.ch_text_secondary'))
          .width(76)
        this.weekdayRow(vm, row)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 4, bottom: 4 })

      Row() {
        Text(t('cp_rotation'))
          .fontSize(13)
          .fontColor($r('app.color.ch_text_secondary'))
          .width(76)
        this.rotationRow(vm, row)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 4, bottom: 4 })

      EditorToggleRow({
        label: t('cp_enable_schedule'),
        hint: t('cp_disable_hint'),
        isOn: row.isEnabled,
        onToggle: (isOn: boolean) => { vm.setClassPlanEnabled(row.guid, isOn); }
      })

      // ---- 排课 ----
      Divider().color($r('app.color.ch_outline')).margin({ top: 8, bottom: 4 })

      Text(t('cp_assign_lessons'))
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
        .width('100%')
      Text(t('cp_edit_class_hint'))
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .margin({ top: 2, bottom: 6 })

      if (row.editRows.length === 0) {
        EditorEmptyHint({ text: t('cp_timelayout_no_periods') })
      }
      ForEach(row.editRows, (edit: PlanEditRow, index: number) => {
        PlanSlotLine({
          vm: vm,
          planGuid: row.guid,
          edit: edit,
          slot: edit.classSlot >= 0 ? row.slots[edit.classSlot] : new ClassSlotRow()
        })
      }, (edit: PlanEditRow, index: number) => `${row.guid}#${index}`)

      // ---- 危险操作 ----
      Divider().color($r('app.color.ch_outline')).margin({ top: 8, bottom: 4 })
      Row() {
        EditorChip({
          text: t('cp_build_overlay'),
          onTap: () => {
            vm.createOverlay(row.guid, `${row.name}${t('cp_overlay_suffix')}`);
          }
        })
          .margin({ right: 8 })
        Blank()
        EditorDeleteButton({
          text: t('cp_delete_plan'),
          message: `「${row.name}」会被删除。${
            row.isOverlay ? t('cp_overlay_children_affected') : ''}`,
          onConfirm: () => { vm.removeClassPlan(row.guid); }
        })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
    }
    .width('100%')
    .padding({ left: 8, top: 4 })
  }

  /** 七个星期按钮，横向排。选中那个高亮。 */
  @Builder
  private weekdayRow(vm: ScheduleEditorViewModel, row: ClassPlanRow) {
    Row() {
      ForEach(WEEKDAY_LABELS, (label: string, index: number) => {
        Text(weekDayShortName(index))
          .fontSize(12)
          .fontColor(index === row.weekDay
            ? $r('app.color.ch_accent')
            : $r('app.color.ch_text_secondary'))
          .backgroundColor(index === row.weekDay
            ? $r('app.color.ch_accent_soft')
            : $r('app.color.ch_surface_alt'))
          .borderRadius(8)
          .padding({ left: 7, right: 7, top: 4, bottom: 4 })
          .margin({ right: 4 })
          .onClick(() => {
            vm.setClassPlanRule(row.guid, index, row.weekCountDiv, row.weekCountDivTotal);
          })
      }, (label: string, index: number) => label)
    }
    .layoutWeight(1)
  }

  /** 轮转下拉。 */
  @Builder
  private rotationRow(vm: ScheduleEditorViewModel, row: ClassPlanRow) {
    Row() {
      ForEach(ROTATION_TOTALS, (label: string, index: number) => {
        Text(label)
          .fontSize(12)
          .fontColor(index === row.weekCountDivTotal
            ? $r('app.color.ch_accent')
            : $r('app.color.ch_text_secondary'))
          .backgroundColor(index === row.weekCountDivTotal
            ? $r('app.color.ch_accent_soft')
            : $r('app.color.ch_surface_alt'))
          .borderRadius(8)
          .padding({ left: 7, right: 7, top: 4, bottom: 4 })
          .margin({ right: 4 })
          .onClick(() => {
            // index 0 对应 weekCountDiv=0（每周都匹配），1..4 对应单/双/三/四周
            vm.setClassPlanRule(row.guid, row.weekDay, index, index);
          })
      }, (label: string, index: number) => label)
    }
    .layoutWeight(1)
  }

  @Builder
  private layoutMenu(vm: ScheduleEditorViewModel, row: ClassPlanRow) {
    Menu() {
      ForEach(vm.timeLayouts, (layout: TimeLayoutRow) => {
        MenuItem({ content: layout.name }).onChange(() => {
          vm.setClassPlanTimeLayout(row.guid, layout.guid);
        })
      }, (layout: TimeLayoutRow) => layout.guid)
    }
  }

}
