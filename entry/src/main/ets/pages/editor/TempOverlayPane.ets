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
import { ClassPlanGroupRow, ClassPlanRow, ProfileRow } from 'common_core';
import { ScheduleEditorViewModel } from '../../viewmodel/ScheduleEditorViewModel';
import { UiFeedback } from '../../common/UiFeedback';
import {
  EditorChip,
  EditorEmptyHint,
  EditorHeader,
  EditorToggleRow
} from '../../components/EditorWidgets';

/** 到期选项：今天 / 明天 / 一周后 / 一月后。 */
const EXPIRY_CHOICES: string[] = ['今天', '明天', '一周后', '一月后'];
/** 临时策略：继承 / 覆盖。 */
const TEMP_TYPE_CHOICES: string[] = ['继承', '覆盖'];

@ComponentV2
export struct TempOverlayPane {
  @Require @Param vm: ScheduleEditorViewModel;
  @Param stack: NavPathStack = new NavPathStack();

  @Local expanded: string = '';

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
      this.say(`临时生效中：${row.tempPlanName}（自 ${row.tempPlanFromText}）`);
    } else {
      this.say('当前没有临时课表。');
    }
  }

  private say(text: string): void {
    UiFeedback.toast(this.getUIContext(), text);
  }

  build() {
    NavDestination() {
      Column() {
        EditorHeader({ title: '临时与叠加', stack: this.stack })

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
      Text('叠加课表')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
        .width('100%')

      Text('叠加表是挂在某张表之上的临时修改（例如这周把那节体育改成自习）。' +
        '总开关关着时，叠加表完全不参与选课。')
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .margin({ top: 2, bottom: 6 })

      EditorToggleRow({
        label: '启用叠加',
        hint: '关着时所有叠加表都不生效',
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
                ? `叠加自 ${plan.overlaySourceName}`
                : '叠加源已失效，这张表不参与选课')
                .fontSize(11)
                .fontColor(plan.overlaySourceName.length > 0
                  ? $r('app.color.ch_text_hint')
                  : $r('app.color.ch_accent'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text('取消叠加')
              .fontSize(12)
              .fontColor($r('app.color.ch_accent'))
              .onClick(() => {
                UiFeedback.confirm(
                  this.getUIContext(),
                  '取消叠加',
                  `「${plan.name}」会从叠加关系里摘掉。课表本身保留，可以当成普通课表启用。`,
                  '取消叠加',
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
      Text('临时课表')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
        .width('100%')

      if (vm.profile.tempPlanExists) {
        Text(`当前：${vm.profile.tempPlanName}（自 ${vm.profile.tempPlanFromText} 起）`)
          .fontSize(12)
          .fontColor($r('app.color.ch_accent'))
          .width('100%')
          .margin({ top: 4 })
        EditorChip({
          text: '取消临时课表',
          onTap: () => { vm.cancelTempClassPlan(); }
        })
          .margin({ top: 6 })
      } else {
        Text('选一张课表临时顶上去，到期后自动失效。')
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
          Text('临时用')
            .fontSize(12)
            .fontColor($r('app.color.ch_accent'))
            .onClick(() => { this.startTempPlan(vm, plan); })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 5, bottom: 5 })
      }, (plan: ClassPlanRow) => plan.guid)

      if (vm.classPlans.length === 0) {
        EditorEmptyHint({ text: '还没有课表，先到「课表」建一张。' })
      }
    }
    .width('100%')
  }

  /** 临时启用要连到期时间一起定，不给「永久」。理由写在这一段的头注里。 */
  private startTempPlan(vm: ScheduleEditorViewModel, plan: ClassPlanRow): void {
    const host = this.getUIContext();
    this.getUIContext().showAlertDialog({
      title: `临时用「${plan.name}」`,
      message: '选一个到期时间，到期后自动恢复正常选课。',
      buttons: [
        { value: '取消', action: () => {} },
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
      Text('临时课表群')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
        .width('100%')

      if (vm.profile.isTempGroupEnabled) {
        Text(`当前：${vm.profile.tempGroupName}（到 ${vm.profile.tempGroupExpireText}，` +
          `${vm.profile.tempGroupTypeText}）`)
          .fontSize(12)
          .fontColor($r('app.color.ch_accent'))
          .width('100%')
          .margin({ top: 4 })
        EditorChip({
          text: '取消临时课表群',
          onTap: () => { vm.cancelTempClassPlanGroup(); }
        })
          .margin({ top: 6 })
      } else {
        Text('把一整个群临时顶上去。群里的课表按各自规则排，所以一周里不同天可能落到不同的表。')
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
          Text(`${group.planCount} 张`)
            .fontSize(11)
            .fontColor($r('app.color.ch_text_hint'))
            .margin({ right: 10 })
          Text('临时用')
            .fontSize(12)
            .fontColor($r('app.color.ch_accent'))
            .onClick(() => { this.startTempGroup(group.guid, group.name); })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 5, bottom: 5 })
      }, (group: ClassPlanGroupRow) => group.guid)

      if (vm.groups.length === 0) {
        EditorEmptyHint({ text: '还没有课表群。' })
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
      title: `临时用「${groupName}」`,
      message: '选策略与到期时间。',
      buttons: [
        { value: '取消', action: () => {} },
        {
          value: `${TEMP_TYPE_CHOICES[0]} · 到期`,
          action: () => { this.commitTempGroup(groupId, 0, 2); }
        },
        {
          value: `${TEMP_TYPE_CHOICES[1]} · 到期`,
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

  @Builder
  private orderedSection(vm: ScheduleEditorViewModel) {
    Column() {
      Text('预定课表')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
        .width('100%')

      if (vm.profile.orderedScheduleCount === 0) {
        Text('没有预定的日子。预定让某一天用另一张表，比如期中考试那天。')
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .width('100%')
          .margin({ top: 2 })
      } else {
        Text(`有 ${vm.profile.orderedScheduleCount} 天预定了课表。`)
          .fontSize(12)
          .fontColor($r('app.color.ch_text_secondary'))
          .width('100%')
          .margin({ top: 2, bottom: 4 })
      }

      Text('预定按日期逐条设置。这个入口先把日期与课表一起给你，配好之后逐条加。')
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
  }
}
