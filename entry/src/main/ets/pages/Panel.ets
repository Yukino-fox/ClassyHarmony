/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 信息面板页。
 *
 * 为什么单独一页而不是编辑页的一个分页
 * -----------------------------------
 * 布局是另一个文件、另一份草稿、另一套保存时机。挂在编辑页下面的话，进来就是
 * 同一个 Navigation、同一个返回键、同一根保存条，而那根保存条管的是课表档案 ——
 * 用户在面板里改了两行布局，看到的提示却是「课表有未保存的改动」。分开之后两边的
 * 状态互不干扰，代价只是多一个路由。
 *
 * 返回时拦一道
 * -----------
 * 与编辑页同一个理由：丢掉的是用户花时间排的面板，而且不可逆。
 *
 * 什么设备上能进来
 * ---------------
 * 只有平板与 2in1。入口在 Index 的顶栏上按布局形态显示，这里不再判断一次 ——
 * 同一个条件在两处各写一遍，早晚会有一个地方忘了同步。这里只负责「进来之后
 * 好好干活」。
 */

import { t } from 'common_core';
import { common } from '@kit.AbilityKit';
import { resolveComponentLayoutViewModel } from '../common/AppServices';
import { UiFeedback } from '../common/UiFeedback';
import { ComponentLayoutViewModel } from '../viewmodel/ComponentLayoutViewModel';
import { ComponentLayoutPane } from './panel/ComponentLayoutPane';
import { PANEL_MAX_WIDTH } from '../components/ContentWidth';

/*
 * struct 叫 PanelPage 而不是 Panel：ArkUI 有个内置的 Panel 组件，@Entry 的
 * struct 与它同名会被判 10905227（重名）和 10905237（撞保留 tag 名）。
 * 路由名仍然是 pages/Panel —— 那个来自 main_pages.json，与 struct 名无关。
 */
@Entry
@ComponentV2
struct PanelPage {
  /**
   * ViewModel 引用不加装饰器，理由同 Index.ets：变化通知靠它自己身上的 @Trace，
   * 持有它的字段是什么装饰器与这条链路无关。
   */
  private vm: ComponentLayoutViewModel | undefined = undefined;

  aboutToAppear(): void {
    // getHostContext 依赖组件已挂到窗口，aboutToAppear 一定早于首次 build。
    const host: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.vm = resolveComponentLayoutViewModel(host);
    // ViewModel 是进程内单例，可能已经活过一整段会话。这里重读一次课表档案，让
    // 预览跟上编辑页那边刚保存的内容 —— 之所以不在 ViewModel 构造时读，是因为
    // 那时还没有「用户进过面板页」这回事，而每次进页面读一次就够了。
    this.vm.reloadProfileForPreview();
  }

  onBackPress(): boolean {
    if (this.vm === undefined || !this.vm.isDirty) {
      return false;
    }
    const vm: ComponentLayoutViewModel = this.vm as ComponentLayoutViewModel;
    UiFeedback.confirmDiscardOrSave(
      this.getUIContext(),
      t('ed_unsaved'),
      '返回之前要怎么处理信息面板的改动？',
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
        Text('正在准备…')
          .fontSize(13)
          .fontColor($r('app.color.ch_text_hint'))
      } else {
        ComponentLayoutPane({
          vm: this.vm as ComponentLayoutViewModel,
          onExit: () => { this.leave(); }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.start_window_background'))
    // 宽屏封顶居中，理由见 ContentWidth.ets 头注
    .constraintSize({ maxWidth: PANEL_MAX_WIDTH })
    .alignSelf(ItemAlign.Center)
  }
}
