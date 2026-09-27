/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 编辑页里「这块被规则藏掉了」的标记：一层 45° 斜条盖在内容上 + 整体淡化。
 *
 * 为什么是顶层 @Builder 函数而不是自定义组件
 * ----------------------------------------
 * 节点级（PanelNodeView）与行级（PanelPreview）两处都要用它。两处不是同一个
 * 组件：行是一个 Stack，节点是另一个 Stack，各自负责自己的 clip 与淡化。
 *
 * 写成自定义组件的话，codelinter 的 avoid-overusing-custom-component-check 会
 * 报它（无参、无状态、无生命周期的 struct 应当用 @Builder）—— 而这条建议在
 * 单文件场景下是对的。跨文件共享才是这里的关键：@Builder 方法不能被别的组件
 * 调用，自定义组件却要为它付出一次实例化。顶层 @Builder 两条都占：可以导出
 * 出去给两个文件各调一次，又不新建组件。
 *
 * 淡化到多少只有一份定义（HIDDEN_DIM_OPACITY 导出去），行淡化了而组件没淡化、
 * 或者反过来，视觉上都会像是坏了一半。
 *
 * 出处与刻意偏离的部分
 * ------------------
 * 桌面版 ComponentPresenter.axaml 在编辑模式下给被规则藏掉的组件挂一个
 * `OpacityMask`：45° 旋转、`SpreadMethod=Repeat` 的线性渐变，色标是
 * 0→#afffffff、0.5→#afffffff、0.5→#50ffffff、1→#50ffffff。两档透明度分别是
 * 0.69 与 0.31 交替出现，也就是「暗一半、亮一半的斜条」。
 *
 * 没有照抄成遮罩：ArkUI 的 OpacityMask 对应物 `mask()` 在 SDK 26 里只剩
 * ProgressMask 与形状两种，渐变遮罩拿不到了（CommonMethod#mask 从 API 12 起
 * 被 maskShape 取代，渐变那条路没有替代品）。所以改成「画一层斜条盖在内容上
 * + 整体淡化到同样的平均不透明度」：观感一致，代价是斜条本身会盖住内容 ——
 * 桌面版的遮罩是乘上去的、不遮字。
 */

/** 斜条宽度。 */
const HIDDEN_STRIPE_WIDTH: number = 2;

/** 斜条间距。 */
const HIDDEN_STRIPE_PITCH: number = 9;

/**
 * 被规则藏掉的那份淡化到多少。
 *
 * 桌面版靠遮罩的两档透明度（0.69 / 0.31）达到平均约 0.5，这里用同一个平均值。
 * 没有遮罩就至少保证「明显不是正常显示」。
 */
export const HIDDEN_DIM_OPACITY: number = 0.5;

/**
 * 斜条数量。给固定值而不是按尺寸算：斜纹是装饰，而节点的高度由内容定、事先
 * 拿不到。给少了会在高节点上露出空白 —— 而「这里什么都没有」恰好也是空白行的
 * 读法，比密一点更容易误解；所以宁可多给几条让调用方的 clip 切掉。
 */
const HIDDEN_STRIPE_COUNT: number = 24;

/** 斜条那根细长 Column 的宽度。转 45° 之后要够宽才盖得住整个节点。 */
const HIDDEN_STRIPE_SPAN: number = 400;

/**
 * 45° 斜条盖层。叠在内容之上；clip 与淡化由调用方负责。
 *
 * 斜条用一根转 45° 的细长 Column 摆出来。两个理由：
 *   - 斜纹的疏密与倾角只取决于几个常量，一眼能核对；
 *   - 组件自己画，不用图片资源，缩放不会糊。
 *
 * 不吃触摸：面板上的组件本来也不接收点击（P6 的提醒走系统通知），但别让这层
 * 斜条挡住同一行里别的东西的命中。
 */
@Builder
export function panelHiddenMark() {
  // 斜条用中性深灰而不是组件自己的颜色：这是编辑器给的标记，不是组件内容，
  // 跟着组件的配色走会让「这个组件本来就是这个色」与「它被藏了」分不开。
  Column() {
    ForEach(Array.from({ length: HIDDEN_STRIPE_COUNT }, (_v: number, i: number) => i),
      (step: number) => {
        Divider()
          .strokeWidth(HIDDEN_STRIPE_WIDTH)
          .color('#33000000')
          .margin({ top: HIDDEN_STRIPE_PITCH })
      }, (step: number) => `${step}`)
  }
  .width(HIDDEN_STRIPE_SPAN)
  .rotate({ angle: 45 })
}
