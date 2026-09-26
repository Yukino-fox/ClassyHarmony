/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 档案编辑页的壳。
 *
 * 一次载入，全程不重读
 * ------------------
 * aboutToAppear 只在首次进入时载入档案。用户从编辑页跳到课表页再跳回来时
 * 草稿必须原样还在 —— 重新载入等于把用户半小时的改动静默丢掉，而界面上
 * 什么提示都没有。所以「重新读取」是一个显式按钮（带确认），不是自动行为。
 *
 * 保存条只在有改动时出现
 * --------------------
 * 挂在底部常驻的话，干净状态下也占着一条，而且「保存」这个按钮一直可点，
 * 用户会点它然后什么也没发生。改成有改动才出现，「有未保存的东西」这件事
 * 本身就变成了提示，不需要再加一行文字解释。
 *
 * 返回时拦一道
 * -----------
 * 有未保存改动时按返回要问一次。丢掉的是用户几十分钟的劳动，而且这个操作
 * 不可逆 —— 没有第二次机会。把提示放在动作发生之前，而不是事后写进提示行。
 */

import { common } from '@kit.AbilityKit';
import { resolveScheduleEditorViewModel } from '../common/AppServices';
import { UiFeedback } from '../common/UiFeedback';
import {
  ROUTE_GROUPS,
  ROUTE_LAYOUTS,
  ROUTE_PLANS,
  ROUTE_REMINDER,
  ROUTE_SUBJECTS,
  ROUTE_TEMP
} from '../common/EditorRoutes';
import { ScheduleEditorViewModel } from '../viewmodel/ScheduleEditorViewModel';
import { EditorHomePane } from './editor/EditorHomePane';
import { SubjectPane } from './editor/SubjectPane';
import { TimeLayoutPane } from './editor/TimeLayoutPane';
import { ClassPlanPane } from './editor/ClassPlanPane';
import { ClassPlanGroupPane } from './editor/ClassPlanGroupPane';
import { TempOverlayPane } from './editor/TempOverlayPane';
import { ReminderPane } from './editor/ReminderPane';

@Entry
@ComponentV2
struct Editor {
  /**
   * ViewModel 引用不加装饰器，理由同课表页：变化通知靠 ViewModel 自身的
   * @Trace，持有它的字段用不用装饰器与这条链路无关。
   */
  private vm: ScheduleEditorViewModel | undefined = undefined;
  private stack: NavPathStack = new NavPathStack();
  private loaded: boolean = false;

  aboutToAppear(): void {
    if (this.loaded) {
      return;
    }
    // getHostContext 依赖组件已挂到窗口，aboutToAppear 一定早于首次 build。
    const host: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.vm = resolveScheduleEditorViewModel(host);
    this.vm.load();
    this.loaded = true;
  }

  /**
   * 路由表。
   *
   * 每个分支一个 NavDestination。返回统一的错误页而不是空分支：路由名写错
   * 在开发期是静默白屏，用户那边是「点进去什么都没有」，很难查。
   */
  @Builder
  private destination(name: string) {
    if (name === ROUTE_SUBJECTS) {
      SubjectPane({ vm: this.vm })
    } else if (name === ROUTE_LAYOUTS) {
      TimeLayoutPane({ vm: this.vm })
    } else if (name === ROUTE_PLANS) {
      ClassPlanPane({ vm: this.vm })
    } else if (name === ROUTE_GROUPS) {
      ClassPlanGroupPane({ vm: this.vm })
    } else if (name === ROUTE_TEMP) {
      TempOverlayPane({ vm: this.vm })
    } else if (name === ROUTE_REMINDER) {
      // 不传 vm：提醒设置不在草稿里，它自己读自己写。见 ReminderPane 的头注。
      ReminderPane({ stack: this.stack })
    } else {
      NavDestination() {
        Text(`未知页面：${name}`)
          .fontSize(13)
          .fontColor($r('app.color.ch_text_hint'))
      }
    }
  }

  /**
   * 返回的处理。
   *
   * 子页面先自己退：用户在「科目」里按返回，期望是回到编辑主页，而不是被问
   * 「要不要保存」。Navigation 不会自己吃掉这个返回（mode 是 Stack），所以要
   * 在这里手动 pop —— 漏了的话从子页面按返回会直接关掉整个编辑页，草稿随之
   * 丢掉，而且没有任何提示。
   */
  onBackPress(): boolean {
    if (this.stack.size() > 1) {
      this.stack.pop();
      return true;
    }
    if (this.vm === undefined || !this.vm.isDirty) {
      return false;
    }
    const vm: ScheduleEditorViewModel = this.vm as ScheduleEditorViewModel;
    UiFeedback.confirmDiscardOrSave(
      this.getUIContext(),
      '有未保存的改动',
      '返回之前要怎么处理这些改动？',
      '丢掉改动并返回',
      () => { this.leave(); },
      () => {
        if (vm.save()) {
          this.leave();
        }
      }
    );
    return true;
  }

  private leave(): void {
    this.getUIContext().getRouter().back();
  }

  build() {
    Column() {
      if (this.vm === undefined) {
        // aboutToAppear 早于首次 build，这个分支只在极端异常路径上出现
        Text('正在准备…')
          .fontSize(13)
          .fontColor($r('app.color.ch_text_hint'))
      } else {
        Navigation(this.stack) {
          EditorHomePane({ vm: this.vm, stack: this.stack })
        }
          .navDestination(this.destination)
          .hideTitleBar(true)
          .mode(NavigationMode.Stack)
          .layoutWeight(1)
          .width('100%')

        this.statusBar(this.vm)

        if (this.vm.isDirty) {
          this.saveBar(this.vm)
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.start_window_background'))
  }

  /** 底部提示行。只在有提示文案时占位。 */
  @Builder
  private statusBar(vm: ScheduleEditorViewModel) {
    if (vm.statusText.length > 0) {
      Text(vm.statusText)
        .fontSize(12)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 4, bottom: 4 })
    }
  }

  /** 未保存提示与三个动作。 */
  @Builder
  private saveBar(vm: ScheduleEditorViewModel) {
    Column() {
      Row() {
        Text('有未保存的改动')
          .fontSize(12)
          .fontColor($r('app.color.ch_accent'))
          .layoutWeight(1)
        Text('重新读取')
          .fontSize(13)
          .fontColor($r('app.color.ch_text_secondary'))
          .margin({ right: 16 })
          .onClick(() => {
            UiFeedback.confirm(
              this.getUIContext(),
              '重新读取档案',
              '这会丢掉所有未保存的改动，从磁盘重读一遍。',
              '重新读取',
              () => { vm.reload(); }
            );
          })
        Text('保存')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ch_accent'))
          .onClick(() => {
            vm.save();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    }
    .width('100%')
    .backgroundColor($r('app.color.ch_surface_alt'))
  }
}
