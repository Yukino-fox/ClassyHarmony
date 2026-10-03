/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 编辑主页。
 *
 * 五个入口而不是一个大表单
 * ----------------------
 * 档案里四类东西的量级差得很远：科目几十个、时间表三五张、课表七到十张、
 * 课表群两三个。塞进一个页面的话，科目那几十行会把其余四个入口推到屏幕外，
 * 而改一节课的时间根本不需要看到科目列表。分开的另一个理由是它们的风险等级
 * 不同：改课次是日常，删课表群是事故，放在一屏里用户会习惯性地连着点。
 *
 * 导入导出放主页而不是某个分页
 * --------------------------
 * 导入是「换一整份档案」，导出是「备份当前这一份」。它们不属于任何一类内容，
 * 放最外层反而最不容易被漏掉 —— 放在课表分页里，用户会以为导出只导课表。
 */

import { t, tf } from 'common_core';
import { common } from '@kit.AbilityKit';
import { ScheduleEditorViewModel } from '../../viewmodel/ScheduleEditorViewModel';
import { EditorHeader, EditorTextField } from '../../components/EditorWidgets';
import {
  ROUTE_GROUPS,
  ROUTE_LAYOUTS,
  ROUTE_PLANS,
  ROUTE_REMINDER,
  ROUTE_SUBJECTS,
  ROUTE_TEMP
} from '../../common/EditorRoutes';

/** 一个入口行：标题、一句话说明、当前数量、右侧箭头。 */
@ComponentV2
struct EntryRow {
  @Param title: string = '';
  @Param hint: string = '';
  @Param count: string = '';
  @Event onTap: () => void = () => {};

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(15)
          .fontColor($r('app.color.ch_text_primary'))
        Text(this.hint)
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.count.length > 0) {
        Text(this.count)
          .fontSize(13)
          .fontColor($r('app.color.ch_text_secondary'))
          .margin({ right: 8 })
      }
      Text('›')
        .fontSize(20)
        .fontColor($r('app.color.ch_text_hint'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 12, bottom: 12 })
    .onClick(() => {
      this.onTap();
    })
  }
}

@ComponentV2
export struct EditorHomePane {
  // 不给默认值：这两个都必须由父组件传入。给了假默认值的话，父组件漏传就会
  // 静默拿到一个空壳 ViewModel，界面上是一排点了没反应的按钮。
  @Require @Param vm: ScheduleEditorViewModel;
  @Param stack: NavPathStack = new NavPathStack();

  private go(route: string): void {
    this.stack.pushPath({ name: route });
  }

  build() {
    NavDestination() {
      Column() {
        EditorHeader({ title: t('eh_title'), stack: this.stack })

        if (!this.vm.isReady) {
          Text(this.vm.errorText.length > 0 ? this.vm.errorText : t('eh_loading'))
            .fontSize(13)
            .fontColor($r('app.color.ch_text_secondary'))
            .padding(20)
        } else {
          Scroll() {
            Column() {
              this.summary(this.vm)
              this.entries(this.vm)

              // 分界：上面五个改的是课表草稿，下面两个改的是应用设置与文件。
              // 混在一列里，用户会以为改提醒也要点保存。
              Divider().color($r('app.color.ch_outline')).margin({ top: 8, bottom: 8 })

              this.operations(this.vm)
              Divider().color($r('app.color.ch_outline')).margin({ top: 8, bottom: 8 })

              this.fileOps(this.vm)
            }
            .width('100%')
            .padding({ left: 14, right: 14, bottom: 24 })
          }
          .layoutWeight(1)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
  }

  /** 档案摘要：名字 + 四类内容各多少。名字可改。 */
  @Builder
  private summary(vm: ScheduleEditorViewModel) {
    Column() {
      EditorTextField({
        label: t('eh_profile_name'),
        value: vm.profile.name === '（未命名档案）' ? '' : vm.profile.name,
        placeholder: t('eh_unnamed_profile'),
        onCommit: (text: string) => {
          vm.renameProfile(text);
        }
      })

      Row() {
        Text(tf('eh_count_subjects', `${vm.profile.subjectCount}`))
          .fontSize(12)
          .fontColor($r('app.color.ch_text_hint'))
          .margin({ right: 12 })
        Text(tf('eh_count_layouts', `${vm.profile.timeLayoutCount}`))
          .fontSize(12)
          .fontColor($r('app.color.ch_text_hint'))
          .margin({ right: 12 })
        Text(tf('eh_count_plans', `${vm.profile.classPlanCount}`))
          .fontSize(12)
          .fontColor($r('app.color.ch_text_hint'))
          .margin({ right: 12 })
        Text(tf('eh_count_groups', `${vm.profile.groupCount}`))
          .fontSize(12)
          .fontColor($r('app.color.ch_text_hint'))
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .padding({ top: 8, bottom: 12 })
  }

  @Builder
  private entries(vm: ScheduleEditorViewModel) {
    Column() {
      EntryRow({
        title: t('eh_entry_subjects'),
        hint: t('eh_entry_subjects_hint'),
        count: `${vm.subjects.length}`,
        onTap: () => { this.go(ROUTE_SUBJECTS); }
      })
      Divider().color($r('app.color.ch_outline'))
      EntryRow({
        title: t('eh_entry_layouts'),
        hint: t('eh_entry_layouts_hint'),
        count: `${vm.timeLayouts.length}`,
        onTap: () => { this.go(ROUTE_LAYOUTS); }
      })
      Divider().color($r('app.color.ch_outline'))
      EntryRow({
        title: t('eh_entry_plans'),
        hint: t('eh_entry_plans_hint'),
        count: `${vm.classPlans.length}`,
        onTap: () => { this.go(ROUTE_PLANS); }
      })
      Divider().color($r('app.color.ch_outline'))
      EntryRow({
        title: t('eh_entry_groups'),
        hint: t('eh_entry_groups_hint'),
        count: `${vm.groups.length}`,
        onTap: () => { this.go(ROUTE_GROUPS); }
      })
      Divider().color($r('app.color.ch_outline'))
      EntryRow({
        title: t('eh_temp_header'),
        hint: t('eh_temp_desc'),
        onTap: () => { this.go(ROUTE_TEMP); }
      })
    }
    .width('100%')
  }

  /**
   * 提醒设置。
   *
   * 放在编辑页而不是课表页顶栏：它是「偶尔做一次」的事，而顶栏刻意只留了
   * 标题与「编辑」两个位置（见 Index.ets 的头注），加第三个入口会开始跟
   * 课表本身抢注意力。
   */
  @Builder
  private operations(vm: ScheduleEditorViewModel) {
    Column() {
      EntryRow({
        title: t('eh_entry_reminder'),
        hint: t('eh_entry_reminder_hint'),
        onTap: () => { this.go(ROUTE_REMINDER); }
      })
    }
    .width('100%')
  }

  @Builder
  private fileOps(vm: ScheduleEditorViewModel) {
    Column() {
      Text(t('eh_profile_file'))
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
        .width('100%')
        .margin({ bottom: 4 })

      Text(t('eh_import_export_hint'))
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Text(t('eh_import_file'))
          .fontSize(13)
          .fontColor($r('app.color.ch_accent'))
          .padding({ right: 20 })
          .onClick(() => {
            this.doImport(vm);
          })
        Text(t('eh_export_file'))
          .fontSize(13)
          .fontColor($r('app.color.ch_accent'))
          .onClick(() => {
            this.doExport(vm);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: 8 })
  }

  /**
   * 导入。导入会整份替换草稿，所以先确认。
   *
   * 确认放在动作之前：导入是不可撤销的，用户点完「取消」再想导入一次时，
   * 期望还是能看到现在的内容。
   */
  private doImport(vm: ScheduleEditorViewModel): void {
    this.getUIContext().showAlertDialog({
      title: t('eh_import_file'),
      message: t('eh_import_confirm'),
      buttons: [
        { value: t('common_cancel'), action: () => {} },
        {
          value: t('eh_pick_file'),
          fontColor: $r('app.color.ch_accent'),
          action: () => { void this.pickAndImport(vm); }
        }
      ]
    });
  }

  private async pickAndImport(vm: ScheduleEditorViewModel): Promise<void> {
    const host: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    await vm.importFrom(host);
  }

  private async doExport(vm: ScheduleEditorViewModel): Promise<void> {
    const host: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    await vm.exportTo(host);
  }
}
