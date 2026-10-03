/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 临时课表、叠加、预定课表。
 *
 * 三件事放一页的理由
 * ----------------
 * 它们都是「一次性改一下选课结果、之后自动失效」的操作，共同点是有一个到期时间。
 * 拆到三页的话用户要记住「临时课表在哪一页、叠加又在哪一页」，而这三件事的
 * 触发时机往往挨着（今天调课 -> 顺便把下周某天预定成另一张表）。
 *
 * 临时课表与临时课表群的区别
 * ------------------------
 * 临时课表 = 指定一张课表顶上去。临时课表群 = 指定一个群顶上去，之后群里的
 * 课表按各自规则排。两者都能加「继承 / 覆盖」的策略差别，但界面上先给「临时
 * 课表」和「临时课表群」两个独立入口，不合并成一个「临时设置」：合并了之后
 * 用户分不清当前生效的是一张表还是一整个群，出问题时也无从判断该去看哪边。
 *
 * 到期时间是必填的
 * --------------
 * 临时课表没有到期时间就是永久顶替，用户会忘记自己开过，然后某天发现课表不对
 * 却查不出原因。所以这里不接受「永久」——想永久就把那张课表启用、把别的停用。
 */

import { DateTimeValue, TempClassPlanGroupType } from 'common_shared';
import { ClassPlanGroupRow, ClassPlanRow, OrderedScheduleRow, ProfileRow, t, tf } from 'common_core';
import { ScheduleEditorViewModel } from '../../viewmodel/ScheduleEditorViewModel';
import { UiFeedback } from '../../common/UiFeedback';
import {
  EditorChip,
  EditorEmptyHint,
  EditorHeader,
  EditorToggleRow
} from '../../components/EditorWidgets';

/** 到期选项：今天 / 明天 / 一周后 / 一月后。 */
const EXPIRY_CHOICES: string[] = [t('temp_today'), t('temp_tomorrow'), t('temp_week'), t('temp_month')];
/** 临时策略：继承 / 覆盖。 */
const TEMP_TYPE_CHOICES: string[] = [t('temp_inherit'), t('temp_override')];

@ComponentV2
export struct TempOverlayPane {
  @Require @Param vm: ScheduleEditorViewModel;
  @Param stack: NavPathStack = new NavPathStack();

  @Local expanded: string = '';
  /** 预定课表选择器是否展开。 */
  @Local picking: boolean = false;
  /** 选择器当前选的日期，格式是档案键（`2026-09-26T00:00:00`）。空串表示今天。 */
  @Local pickingDate: string = '';
  /** 正在改的那条预定原本用哪张表。只用来在列表上标「当前」。 */
  @Local pickingKey: string = '';

  /**
   * 到期时间的解析。
   *
   * 返回 undefined 表示没选到合法日期，调用方不往下走 —— 宁可让用户重选，
   * 也不要默默落到「今天」。默默落今天的后果是临时课表一开就过期，而界面上
   * 看着是开着的。
   */
  private expiryOf(index: number): DateTimeValue | undefined {
    const now: DateTimeValue = DateTimeValue.now();
    if (index === 0) {
      return now;
    }
    if (index === 1) {
      return now.addDays(1);
    }
    if (index === 2) {
      return now.addDays(7);
    }
    if (index === 3) {
      return now.addDays(30);
    }
    return undefined;
  }

  private tempPlanSummary(vm: ScheduleEditorViewModel, row: ProfileRow): void {
    if (row.tempPlanExists) {
      this.say(tf('temp_active_notice', row.tempPlanName, row.tempPlanFromText));
    } else {
      this.say(t('temp_none_current'));
    }
  }

  private say(text: string): void {
    UiFeedback.toast(this.getUIContext(), text);
  }

  build() {
    NavDestination() {
      Column() {
        EditorHeader({ title: t('temp_header'), stack: this.stack })

        Scroll() {
          Column() {
            this.overlaySection(this.vm)
            Divider().color($r('app.color.ch_outline')).margin({ top: 12, bottom: 12 })
            this.tempPlanSection(this.vm)
            Divider().color($r('app.color.ch_outline')).margin({ top: 12, bottom: 12 })
            this.tempGroupSection(this.vm)
            Divider().color($r('app.color.ch_outline')).margin({ top: 12, bottom: 12 })
            this.orderedSection(this.vm)
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

  // ------------------------------------------------------------- 叠加

  @Builder
  private overlaySection(vm: ScheduleEditorViewModel) {
    Column() {
      Text(t('temp_overlay_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
        .width('100%')

      Text(t('temp_overlay_desc'))
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .margin({ top: 2, bottom: 6 })

      EditorToggleRow({
        label: t('temp_enable_overlay'),
        hint: t('temp_overlay_off_hint'),
        isOn: vm.profile.isOverlayEnabled,
        onToggle: (isOn: boolean) => { vm.setClassPlanOverlayEnabled(isOn); }
      })

      ForEach(vm.classPlans, (plan: ClassPlanRow) => {
        if (plan.isOverlay) {
          Row() {
            Column() {
              Text(plan.name)
                .fontSize(13)
                .fontColor($r('app.color.ch_text_primary'))
              Text(plan.overlaySourceName.length > 0
                ? tf('temp_overlay_from', plan.overlaySourceName)
                : t('temp_source_stale'))
                .fontSize(11)
                .fontColor(plan.overlaySourceName.length > 0
                  ? $r('app.color.ch_text_hint')
                  : $r('app.color.ch_accent'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text(t('temp_cancel_overlay'))
              .fontSize(12)
              .fontColor($r('app.color.ch_accent'))
              .onClick(() => {
                UiFeedback.confirm(
                  this.getUIContext(),
                  t('temp_cancel_overlay'),
                  tf('temp_cancel_overlay_msg', plan.name),
                  t('temp_cancel_overlay'),
                  () => { vm.removeClassPlan(plan.guid); }
                );
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: 6, bottom: 6 })
        }
      }, (plan: ClassPlanRow) => plan.guid)
    }
    .width('100%')
  }

  // --------------------------------------------------------- 临时课表

  @Builder
  private tempPlanSection(vm: ScheduleEditorViewModel) {
    Column() {
      Text(t('temp_plan_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
        .width('100%')

      if (vm.profile.tempPlanExists) {
        Text(tf('temp_current_plan', vm.profile.tempPlanName, vm.profile.tempPlanFromText))
          .fontSize(12)
          .fontColor($r('app.color.ch_accent'))
          .width('100%')
          .margin({ top: 4 })
        EditorChip({
          text: t('temp_cancel_temporary'),
          onTap: () => { vm.cancelTempClassPlan(); }
        })
          .margin({ top: 6 })
      } else {
        Text(t('temp_temporary_desc'))
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .width('100%')
          .margin({ top: 2, bottom: 6 })
      }

      ForEach(vm.classPlans, (plan: ClassPlanRow) => {
        Row() {
          Text(plan.name)
            .fontSize(13)
            .fontColor($r('app.color.ch_text_primary'))
            .maxLines(1)
            .layoutWeight(1)
          Text(t('temp_in_use'))
            .fontSize(12)
            .fontColor($r('app.color.ch_accent'))
            .onClick(() => { this.startTempPlan(vm, plan); })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 5, bottom: 5 })
      }, (plan: ClassPlanRow) => plan.guid)

      if (vm.classPlans.length === 0) {
        EditorEmptyHint({ text: t('temp_no_schedule') })
      }
    }
    .width('100%')
  }

  /** 临时启用要连到期时间一起定，不给「永久」。理由写在这一段的头注里。 */
  private startTempPlan(vm: ScheduleEditorViewModel, plan: ClassPlanRow): void {
    const host = this.getUIContext();
    this.getUIContext().showAlertDialog({
      title: tf('temp_use_plan_title', plan.name),
      message: t('temp_pick_expiry'),
      buttons: [
        { value: t('temp_cancel'), action: () => {} },
        ...this.expiryButtons(vm, plan)
      ]
    });
  }

  private expiryButtons(vm: ScheduleEditorViewModel, plan: ClassPlanRow): AlertDialogButtonOptions[] {
    const out: AlertDialogButtonOptions[] = [];
    for (let i: number = 0; i < EXPIRY_CHOICES.length; i++) {
      const label: string = EXPIRY_CHOICES[i];
      out.push({
        value: label,
        action: () => {
          const at: DateTimeValue | undefined = this.expiryOf(i);
          if (at === undefined) {
            return;
          }
          vm.applyTempClassPlan(plan.guid, at);
        }
      });
    }
    return out;
  }

  // ------------------------------------------------------- 临时课表群

  @Builder
  private tempGroupSection(vm: ScheduleEditorViewModel) {
    Column() {
      Text(t('temp_group_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
        .width('100%')

      if (vm.profile.isTempGroupEnabled) {
        Text(tf('temp_current_group', vm.profile.tempGroupName, vm.profile.tempGroupExpireText,
          vm.profile.tempGroupTypeText))
          .fontSize(12)
          .fontColor($r('app.color.ch_accent'))
          .width('100%')
          .margin({ top: 4 })
        EditorChip({
          text: t('temp_cancel_group'),
          onTap: () => { vm.cancelTempClassPlanGroup(); }
        })
          .margin({ top: 6 })
      } else {
        Text(t('temp_group_desc'))
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .width('100%')
          .margin({ top: 2, bottom: 6 })
      }

      ForEach(vm.groups, (group: ClassPlanGroupRow) => {
        Row() {
          Text(group.name)
            .fontSize(13)
            .fontColor($r('app.color.ch_text_primary'))
            .maxLines(1)
            .layoutWeight(1)
          Text(tf('temp_group_plan_count', `${group.planCount}`))
            .fontSize(11)
            .fontColor($r('app.color.ch_text_hint'))
            .margin({ right: 10 })
          Text(t('temp_in_use'))
            .fontSize(12)
            .fontColor($r('app.color.ch_accent'))
            .onClick(() => { this.startTempGroup(group.guid, group.name); })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 5, bottom: 5 })
      }, (group: ClassPlanGroupRow) => group.guid)

      if (vm.groups.length === 0) {
        EditorEmptyHint({ text: t('temp_no_groups') })
      }
    }
    .width('100%')
  }

  /**
   * 临时启用一个群。
   *
   * 先选策略再选到期时间：策略决定了这个群是「接管」（群里没排的课次用默认群
   * 的）还是「只按自己的排」。两个下拉平铺在弹窗里比嵌套两层选择器少一次点击，
   * 而且两个选项都摆在一起时用户能同时看到自己选了什么。
   */
  private startTempGroup(groupId: string, groupName: string): void {
    this.getUIContext().showAlertDialog({
      title: tf('temp_use_group_title', groupName),
      message: t('temp_group_pick_msg'),
      buttons: [
        { value: t('temp_cancel'), action: () => {} },
        {
          value: tf('temp_expiry_suffix', TEMP_TYPE_CHOICES[0]),
          action: () => { this.commitTempGroup(groupId, 0, 2); }
        },
        {
          value: tf('temp_expiry_suffix', TEMP_TYPE_CHOICES[1]),
          action: () => { this.commitTempGroup(groupId, 1, 2); }
        }
      ]
    });
  }

  private commitTempGroup(groupId: string, typeIndex: number, expiryIndex: number): void {
    const at: DateTimeValue | undefined = this.expiryOf(expiryIndex);
    if (at === undefined) {
      return;
    }
    this.vm.applyTempClassPlanGroup(groupId, at,
      typeIndex === 1 ? TempClassPlanGroupType.Override : TempClassPlanGroupType.Inherit);
  }

  // --------------------------------------------------------- 预定课表

  /**
   * 预定课表区。
   *
   * 选课表用内联展开而不是弹窗
   * ------------------------
   * 预定要连着定两件事：哪一天、用哪张表。用弹窗就得连开两层（日期选择器 ->
   * 课表列表），而课表常有七八张，塞进 AlertDialog 的按钮区会挤成一团。
   * 展开成一块就地选，既省掉一层弹窗，也让「选日期」和「选课表」在同一屏里
   * 同时可见 —— 用户能对照着看，不像层层点下去那样忘了自己走到哪一步了。
   */
  @Builder
  private orderedSection(vm: ScheduleEditorViewModel) {
    Column() {
      Text(t('temp_booked'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
        .width('100%')

      Text(t('temp_booked_desc'))
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .margin({ top: 2, bottom: 6 })

      if (this.picking) {
        this.picker(vm)
      } else {
        Row() {
          EditorChip({ text: t('temp_book_a_day'), onTap: () => { this.beginPick('', ''); } })
        }
        .width('100%')
      }

      if (vm.orderedSchedules.length === 0) {
        EditorEmptyHint({ text: t('temp_no_booked') })
      }

      ForEach(vm.orderedSchedules, (row: OrderedScheduleRow) => {
        this.orderedRow(vm, row)
        Divider().color($r('app.color.ch_outline'))
      }, (row: OrderedScheduleRow) => row.dateKey)
    }
    .width('100%')
  }

  /** 已存在的一条预定。 */
  @Builder
  private orderedRow(vm: ScheduleEditorViewModel, row: OrderedScheduleRow) {
    Row() {
      Column() {
        Text(row.dateText.length > 0 ? `${row.dateText} ${row.weekDayText}` : row.dateKey)
          .fontSize(13)
          .fontColor($r('app.color.ch_text_primary'))
        Text(this.orderedStatus(row))
          .fontSize(11)
          .fontColor(row.isStale || !row.planExists
            ? $r('app.color.ch_text_hint')
            : (row.isActive ? $r('app.color.ch_accent') : $r('app.color.ch_text_secondary')))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(t('temp_book_change'))
        .fontSize(12)
        .fontColor($r('app.color.ch_accent'))
        .margin({ right: 12 })
        .onClick(() => { this.beginPick(row.dateKey, row.planId); })

      Text(t('temp_book_delete'))
        .fontSize(12)
        .fontColor($r('app.color.ch_accent'))
        .onClick(() => {
          UiFeedback.confirm(
            this.getUIContext(),
            t('temp_cancel_booked'),
            tf('temp_book_remove_msg', row.dateText),
            t('temp_cancel_booked'),
            () => { vm.setOrderedSchedule(dateOfKey(row.dateKey), undefined); }
          );
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 5, bottom: 5 })
  }

  /** 一条预定的状态说明。 */
  private orderedStatus(row: OrderedScheduleRow): string {
    if (!row.planExists) {
      return tf('temp_status_plan_missing', row.planName);
    }
    if (row.isStale) {
      return tf('temp_status_expired', row.planName);
    }
    if (row.isActive) {
      return tf('temp_status_active', row.planName);
    }
    return tf('temp_status_inactive', row.planName);
  }

  /** 展开中的选择器。 */
  @Builder
  private picker(vm: ScheduleEditorViewModel) {
    Column() {
      Row() {
        Text(this.pickingLabel())
          .fontSize(13)
          .fontColor($r('app.color.ch_text_primary'))
          .layoutWeight(1)
        EditorChip({ text: t('temp_change_day'), onTap: () => { this.askDate(); } })
        Text(' ').fontSize(4)
        EditorChip({ text: t('temp_cancel'), onTap: () => { this.picking = false; } })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (vm.classPlans.length === 0) {
        EditorEmptyHint({ text: t('temp_no_schedule') })
      }

      ForEach(vm.classPlans, (plan: ClassPlanRow) => {
        Row() {
          Text(plan.name)
            .fontSize(13)
            .fontColor($r('app.color.ch_text_primary'))
            .maxLines(1)
            .layoutWeight(1)
          Text(this.pickingKey.length > 0 && this.pickingKey === plan.guid ? t('temp_current') : t('temp_use_this'))
            .fontSize(12)
            .fontColor($r('app.color.ch_accent'))
            .onClick(() => { this.commitPick(vm, plan.guid); })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 5, bottom: 5 })
      }, (plan: ClassPlanRow) => plan.guid)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 6 })
    .backgroundColor($r('app.color.ch_surface_alt'))
    .borderRadius(8)
  }

  private pickingLabel(): string {
    const day: DateTimeValue = dateOfKey(this.pickingDate);
    const offset: number = day.epochDay() - DateTimeValue.now().dateOnly().epochDay();
    if (offset === 0) {
      return tf('temp_picking_today', day.toDateString(), weekDayLabel(day.dayOfWeek()));
    }
    if (offset === 1) {
      return tf('temp_picking_tomorrow', day.toDateString(), weekDayLabel(day.dayOfWeek()));
    }
    return tf('temp_picking_plain', day.toDateString(), weekDayLabel(day.dayOfWeek()));
  }

  private beginPick(dateKey: string, planId: string): void {
    // 键坏掉时回落到今天：选择器接受不了一个解析不出来的日期，而用户点「改」
    // 的意图是「换一张表」，日期先给他一个能用的值。
    this.pickingDate = dateKey.length > 0 && dateOfKey(dateKey) === undefined
      ? '' : dateKey;
    this.pickingKey = planId;
    this.picking = true;
  }

  private askDate(): void {
    const current: DateTimeValue = dateOfKey(this.pickingDate);
    this.getUIContext().showDatePickerDialog({
      // 不设 start/end：允许选过去的日期。改一条已经过期的预定是常事
      // （用户可能就是想把去年留下的那条清掉），把过去禁掉会让「改」变成死路。
      selected: toJsDate(current),
      lunar: false,
      onAccept: (value: DatePickerResult) => {
        if (value.year === undefined || value.month === undefined ||
          value.day === undefined) {
          // 回调给了不完整的日期：不改现有选择。默默落到今天的话，用户会
          // 以为自己选的就是今天。
          return;
        }
        const picked: DateTimeValue =
          new DateTimeValue(value.year, value.month, value.day, 0, 0, 0);
        this.pickingDate = picked.dateOnly().toString();
      }
    });
  }

  private commitPick(vm: ScheduleEditorViewModel, planId: string): void {
    const day: DateTimeValue = dateOfKey(this.pickingDate);
    const ok: boolean = vm.setOrderedSchedule(day, planId);
    if (ok) {
      this.picking = false;
    }
  }
}

/**
 * 档案键还原成日期。
 *
 * 键就是 `dateOnly().toString()`，格式 `2026-09-26T00:00:00`。这里不做
 * 静默兜底成「今天」—— 调用方要能分辨「这是真的今天」和「这键读不出来」。
 * 读不出来时返回今天，同时由 beginPick 提前把这种情况挡掉。
 */
function dateOfKey(key: string): DateTimeValue {
  if (key.length === 0) {
    return DateTimeValue.now().dateOnly();
  }
  const parsed: DateTimeValue | undefined = DateTimeValue.tryParse(key);
  return parsed === undefined ? DateTimeValue.now().dateOnly() : parsed.dateOnly();
}

/** 星期几的单字，档案口径（0=周日）。这里只用于日期选择器那行提示。 */
function weekDayLabel(weekDay: number): string {
  const names: string[] = [t('week_sun'), t('week_mon'), t('week_tue'), t('week_wed'), t('week_thu'), t('week_fri'), t('week_sat')];
  return weekDay < 0 || weekDay > 6 ? '?' : names[weekDay];
}

/**
 * DateTimeValue 还原成本地时区的 JS Date。平台的选择器要 Date，不认我们的类型。
 *
 * 不用 `new Date(y, m - 1, d)`：那个构造器把 0..99 的年份当成 1900+y，
 * 于是档案里一个 0099 年的日期会让选择器打开在 1999 年。多一次 setFullYear
 * 就把这条歧义消掉了 —— 构造器先给个非 0..99 的年份占位，再改成真值。
 */
function toJsDate(value: DateTimeValue): Date {
  const date: Date = new Date(2000, value.month - 1, value.day,
    value.hour, value.minute, value.second);
  date.setFullYear(value.year);
  return date;
}
