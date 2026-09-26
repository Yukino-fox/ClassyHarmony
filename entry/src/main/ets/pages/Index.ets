/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 课表页。
 *
 * 三种形态
 * --------
 *   Single   (< 600vp)       单栏：日期条 + 选中那一天的竖排课程
 *   Dual     (600 ~ 1100vp)  双栏：左边单日，右边整周网格（横向滚动）
 *   DualWide (>= 1100vp)     双栏加宽，网格列均分吃满宽度
 *
 * 形态由根容器 onAreaChange 量出的宽度喂给 core 的 layoutFormOf() 归约，
 * 不走 GridRow 的 breakpoints。原因写在 common_core/view/LayoutForm.ets 的
 * 头注里：GridRow 省略 columns 时会用默认列数，要正确表达「横幅占满、
 * 下面两栏并排」就得同时维护 columns 与 span 两张耦合的表。
 *
 * 为什么 2in1 仍保留单日栏
 * ----------------------
 * 「今天要上什么」和「这周整体怎么排」是两个不同的问题：前者适合竖排速读，
 * 后者适合横向对比。并排放不冲突，反而省掉一次切换。
 */

import { common } from '@kit.AbilityKit';
import { LayoutForm, layoutFormOf } from 'common_core';
import { resolveClassTableViewModel } from '../common/AppServices';
import { ClassTableViewModel } from '../viewmodel/ClassTableViewModel';
import { LessonBannerView } from '../components/LessonBannerView';
import { ScheduleDayView } from '../components/ScheduleDayView';
import { ScheduleGridView } from '../components/ScheduleGridView';
import { WeekStripView } from '../components/WeekStripView';

@Entry
@ComponentV2
struct Index {
  /**
   * ViewModel 引用不加装饰器。
   *
   * 变化通知靠 ViewModel 自己身上的 @Trace：渲染时读 vm.banner，ArkUI 记下这条
   * 依赖，之后 banner 被整体替换就通知本页重绘。持有它的字段是什么装饰器与这条
   * 链路无关，而给一个 @ObservedV2 实例加 @Local 反而多一层深拷贝的语义要提防。
   */
  private vm: ClassTableViewModel | undefined = undefined;

  /**
   * 当前布局形态。
   *
   * 初值取最窄的一档而不是最宽的：宽度未知时按窄排，界面至多朴素一点；
   * 按宽排则可能在手机竖屏上摆出横向溢出的两栏。
   */
  @Local form: LayoutForm = LayoutForm.Single;

  aboutToAppear(): void {
    // 在这里而不是字段初始化里取 context：getHostContext 依赖组件已挂到窗口，
    // 字段初始化时还没挂。aboutToAppear 一定早于首次 build，所以不会漏。
    const host: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.vm = resolveClassTableViewModel(host);
    this.vm.start();
  }

  aboutToDisappear(): void {
    // 页面销毁可能不经过 aboutToAppear（冷启动异常路径），所以走可选调用。
    this.vm?.stop();
  }

  private isSingleColumn(): boolean {
    return this.form === LayoutForm.Single;
  }

  @Builder
  private loadingView(message: string, isError: boolean) {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color($r('app.color.ch_accent'))
      Text(message)
        .fontSize(13)
        .fontColor(isError ? $r('app.color.ch_text_secondary') : $r('app.color.ch_text_hint'))
        .margin({ top: 12 })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  @Builder
  private noProfileView() {
    Column() {
      Text('还没有课表')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
      Text('导入课表文件后会显示在这里')
        .fontSize(13)
        .fontColor($r('app.color.ch_text_hint'))
        .margin({ top: 6 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 单日栏。
   *
   * 两个分支都用 layoutWeight 而不是写死宽高：单栏时它是 Column 里横幅下面的
   * 那个孩子，双栏时它是 Row 里的左半边，同一套写法在两处都对。
   */
  @Builder
  private dayPane(vm: ClassTableViewModel) {
    Column() {
      if (this.isSingleColumn()) {
        // 双栏形态下不显示日期条：整周网格已经把七天都摊开了，再给一排日期
        // 芯片只是重复，且会让人误以为选中某天会改变右边的网格。
        WeekStripView({
          grid: vm.grid,
          selectedIndex: vm.effectiveRowIndex(),
          onPick: (index: number) => {
            vm.selectRow(index);
          }
        })
          .margin({ bottom: 8 })
      }

      Scroll() {
        ScheduleDayView({
          grid: vm.grid,
          rowIndex: vm.effectiveRowIndex()
        })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .layoutWeight(1)
    .height('100%')
  }

  @Builder
  private weekGridPane(vm: ClassTableViewModel) {
    Column() {
      Row() {
        Text('本周课表')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ch_text_primary'))
        Blank()
        if (vm.grid.templateLayoutName.length > 0) {
          Text(vm.grid.templateLayoutName)
            .fontSize(11)
            .fontColor($r('app.color.ch_text_hint'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .textAlign(TextAlign.End)
        }
      }
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 8 })

      Scroll() {
        ScheduleGridView({
          grid: vm.grid,
          fillWidth: this.form === LayoutForm.DualWide
        })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .layoutWeight(1)
    .height('100%')
  }

  build() {
    Column() {
      if (this.vm === undefined) {
        // aboutToAppear 早于首次 build，所以这个分支只在极端异常路径上出现。
        this.loadingView('正在准备…', false)
      } else if (!this.vm.isReady) {
        // 档案读不出来时没有网格可言，横幅与网格都无从谈起。
        this.loadingView(
          this.vm.errorText.length > 0 ? this.vm.errorText : '正在读取课表…',
          this.vm.errorText.length > 0)
      } else if (this.vm.grid.isEmpty()) {
        this.noProfileView()
      } else {
        LessonBannerView({ banner: this.vm.banner })

        if (this.isSingleColumn()) {
          this.dayPane(this.vm)
        } else {
          // 两栏之间留 12vp 缝。不画分隔线：两栏底色一样，一条线反而像表格线，
          // 而这里要表达的是「两个独立区域」而不是「一张表的分栏」。
          Row() {
            this.dayPane(this.vm)
            this.weekGridPane(this.vm)
          }
          .width('100%')
          .layoutWeight(1)
          .alignItems(VerticalAlign.Top)
          .padding({ left: 12 })
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.start_window_background'))
    // 量的是页面自身可用宽度而不是窗口宽度：分屏、悬浮窗、折叠屏展开后页面
    // 拿到的宽度都不同于窗口，量页面就自动跟着变，不必再监听 windowSizeChange。
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.form = layoutFormOf(this.widthVpOf(newArea));
    })
  }

  /**
   * Area 的宽度是 Length（数字 / 百分比字符串 / 资源三者之一），这里只认数字。
   *
   * onAreaChange 报的始终是像素值，所以非数字分支实际上到不了；显式收窄是为了
   * 满足类型检查，也顺手挡住将来有人把 onAreaChange 挪到别的组件上后传进
   * 百分比或资源的情况 —— 那会让 layoutFormOf 拿到 NaN 而永远排成单栏。
   *
   * px2vp 走 UIContext 而非全局函数：全局那个自 API 18 起废弃。
   */
  private widthVpOf(area: Area): number {
    const raw: Length = area.width;
    if (typeof raw !== 'number') {
      return 0;
    }
    return this.getUIContext().px2vp(raw);
  }
}
