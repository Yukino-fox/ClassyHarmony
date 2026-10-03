/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 面板预览。
 *
 * 只画 core 算好的 PanelModel
 * --------------------------
 * 行序、可见性、隐藏行计数、占位文案全在 PanelModel 里定好了，这里不判断。
 * 唯一的输入就是 model，唯一的输出就是那几行 —— 预览与将来真正的面板页共用
 * 这一个组件，免得两边各画一套、然后不一致。
 *
 * 为什么没有背景板
 * ---------------
 * 面板在桌面版是贴在桌面上的透明浮层，鸿蒙侧的信息面板也是。为了看清组件间的
 * 间距，这里铺一层浅底与一圈描边；换成深色只是配色，不影响行为。
 */

import { t, tf } from 'common_core';
import { PanelLine, PanelModel, PanelNode } from 'common_core';
import { HIDDEN_DIM_OPACITY, panelHiddenMark } from './HiddenMark';
import { PanelNodeView } from './PanelNodeView';

/**
 * 行与行之间的纵向间距（vp）。
 *
 * 出处：桌面版 MainWindow.axaml 的行 ItemsPanel 是
 * `<StackPanel Spacing="{Binding ViewModel.Settings.MainWindowLineVerticalMargin}"/>`，
 * 而 Settings.cs 里 `_mainWindowLineVerticalMargin = 5`。
 *
 * 取的是桌面版**默认值**而不是用户值：这个值存在桌面版的 settings.json 里，
 * 而桌面版那边的键名是 MainWindowLineVerticalMargin，鸿蒙侧的 PrefKeys 里
 * 没有对应项（P10 加的是界面与课表那几项，这一项属于「面板自身的间距」，
 * 归 P11 的面板打磨一起做）。照抄默认值至少视觉一致。
 */
const LINE_GAP: number = 5;

/**
 * 面板外框的内边距（vp）。
 *
 * 桌面版没有这一层（浮层直接贴桌面），这里是预览框自己要的 —— 免得组件紧贴
 * 描边，看不出间距。
 */
const PREVIEW_PADDING: number = 12;

@ComponentV2
export struct PanelPreview {
  @Require @Param model: PanelModel = new PanelModel();

  /**
   * 编辑模式。
   *
   * 开着时，被隐藏规则藏掉的行与组件照常占位，只是淡化 + 45° 斜纹。照抄桌面版
   * 编辑模式下的行为（`IsVisible = IsVisibleInternal || InEditMode`）。
   *
   * 默认关着：这个组件将来会被真正的面板页复用，那边要的是「藏了就消失」。
   * 编辑页自己显式传 true，别把默认值改成 true —— 忘了传就等于真面板把藏起来的
   * 内容也画出来，那是最不该犯的错。
   */
  @Param inEditMode: boolean = false;

  build() {
    Column() {
      if (this.model.isEmpty) {
        this.emptyState()
      } else {
        Column({ space: LINE_GAP }) {
          ForEach(this.model.lines, (line: PanelLine) => {
            this.lineView(line)
          }, (line: PanelLine) => `${line.lineIndex}`)
        }
        .width('100%')
      }
      if (this.model.hiddenLineCount > 0) {
        // 隐藏的行不进模型，但要让用户知道「有一行被你关掉了」，否则他对着一个
        // 比预期少一行的预览会以为改动没生效。
        Text(tf('pl_hidden_rows', `${this.model.hiddenLineCount}`))
          .fontSize(12)
          .fontColor($r('app.color.ch_text_hint'))
          .margin({ top: LINE_GAP })
      }
      if (this.model.ruleHiddenLineCount > 0) {
        // 规则藏的行与用户自己关掉的行不是一回事：前者改规则就能恢复，位置也
        // 还在预览里（编辑模式）。混成一句话会让用户跑去行列表里找开关。
        Text(tf('pl_rule_hidden_rows', `${this.model.ruleHiddenLineCount}`))
          .fontSize(12)
          .fontColor($r('app.color.ch_text_hint'))
          .margin({ top: LINE_GAP })
      }
    }
    .width('100%')
    .padding(PREVIEW_PADDING)
  }

  @Builder
  private emptyState() {
    Column() {
      Text(t('pp_no_visible_rows'))
        .fontSize(14)
        .fontColor($r('app.color.ch_text_secondary'))
      Text(t('pp_add_row_hint'))
        .fontSize(12)
        .fontColor($r('app.color.ch_text_hint'))
        .margin({ top: 4 })
    }
    .width('100%')
    .padding({ top: 24, bottom: 24 })
  }

  /**
   * 一行。
   *
   * 行的背景色与圆角是「给整行铺底」用的；桌面版把那层底画在 MainWindowLine 的
   * ContentClipBorder 上，比组件自己的背景更靠后，所以这里的行底包在组件外面。
   * 行的 opacity 叠在最外层 —— 桌面版是把 Opacity 设在 MainWindowLine 这个
   * 控件上，效果相同。
   */
  @Builder
  private lineView(line: PanelLine) {
    if (line.isRuleHidden && !this.inEditMode) {
      // 真面板：整行不画。桌面版的 MainWindowLine 同样是 IsVisible=false
      // 被摘出布局。
      Column() {}
    } else {
      this.lineShell(line)
    }
  }

  @Builder
  private lineShell(line: PanelLine) {
    Stack({ alignContent: Alignment.Start }) {
      Column() {
        Row({ space: 6 }) {
          ForEach(line.nodes, (node: PanelNode) => {
            PanelNodeView({ node: node, inEditMode: this.inEditMode })
          }, (node: PanelNode) => node.guid)
        }
        .alignItems(VerticalAlign.Center)
        .width('100%')
      }
      .width('100%')
      if (line.isRuleHidden) {
        panelHiddenMark()
      }
    }
    .width('100%')
    .padding({ top: 2, bottom: 2 })
    .backgroundColor(line.backgroundColor.length > 0 ? line.backgroundColor : Color.Transparent)
    .borderRadius(line.cornerRadius)
    .clip(true)
    .opacity(line.isRuleHidden ? line.opacity * HIDDEN_DIM_OPACITY : line.opacity)
  }
}
