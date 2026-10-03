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
 *
 * 顶栏只放三样东西
 * ---------------
 * 标题、「设置」与「编辑」。再多就会开始抢课表本身的注意力 —— 课表页的主角是
 * 课表，任何常驻控件都在跟它抢垂直空间。档案状态、导入导出这些都在编辑页里，
 * 因为那些是「偶尔做一次」的事，不该在每天看的那个界面上占位。
 * 「面板」是唯一的例外：它只在宽形态上出现（见 openPanel 的说明）。
 */

import { common } from '@kit.AbilityKit';
import { t } from 'common_core';
import { LayoutForm, layoutFormOf } from 'common_core';
import { resolveClassTableViewModel } from '../common/AppServices';
import { UiFeedback } from '../common/UiFeedback';
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

  /**
   * 从编辑页返回时重读一次档案。
   *
   * 不重读的话，用户在编辑页改完保存、返回看到的还是旧的课表，要等到下一个
   * 15 秒 tick 才更新。他会以为保存没生效，于是又去保存一遍。
   *
   * 首次进入时 onPageShow 也会跑在 aboutToAppear 之后，多读一次档案而已，
   * reloadProfile 是幂等的。
   */
  onPageShow(): void {
    this.vm?.reloadProfile();
    this.applyWidgetJump();
  }

  /**
   * 处理桌面卡片带来的跳转参数。
   *
   * 卡片可能显示的是明天或下周一（放学后它会主动滚到下一个有课的日子），
   * 而这一页默认停在今天。不跟着跳的话，用户点卡片进来看到的日期和卡片上写的
   * 不是一天，会以为卡片在骗他。
   *
   * 一次性消费由 ViewModel 负责，不在这里做：onPageShow 每次进页面都会跑，
   * 在这里去清参数既没有可靠的时机，也容易在「参数本来就是空」时把状态弄脏。
   */
  private applyWidgetJump(): void {
    const raw: Object = this.getUIContext().getRouter().getParams();
    if (raw === undefined || raw === null || typeof raw !== 'object') {
      return;
    }
    const record: Record<string, Object> = raw as Record<string, Object>;
    const value: Object | undefined = record['dayOffset'];
    // 只认 number。卡片那边写的是数值，别的类型（比如被外部应用塞进来的字符串）
    // 当作没有参数处理，宁可不跳也不要把一个乱解析出来的天数定位过去。
    if (typeof value === 'number') {
      this.vm?.focusDayFromWidget(value);
    }
  }

  /**
   * 进编辑页。
   *
   * 走 UIContext 的 Router 而不是全局 router：后者从 API 18 起废弃。
   * 跳转失败（页面没注册、栈满）不静默 —— 表现会是「点了没反应」，
   * 至少让用户知道是哪里出了问题。
   */
  private openEditor(): void {
    const uiContext: UIContext = this.getUIContext();
    uiContext.getRouter().pushUrl({ url: 'pages/Editor' }).catch(() => {
      UiFeedback.toast(uiContext, t('ix_open_editor_failed'));
    });
  }

  /**
   * 进信息面板。
   *
   * 只在平板与 2in1 上有入口。面板的价值在于常驻可见、能一眼扫到，而手机上有
   * 小组件与临上课提醒占着常驻那一屏；再给一个要手动打开才能看的面板只是多一个
   * 入口，还会让用户在两个「看今天上什么」的地方之间犹豫。
   */
  private openPanel(): void {
    const uiContext: UIContext = this.getUIContext();
    uiContext.getRouter().pushUrl({ url: 'pages/Panel' }).catch(() => {
      UiFeedback.toast(uiContext, t('ix_open_panel_failed'));
    });
  }

  /**
   * 进设置页。
   *
   * 设置是「偶尔做一次」的事，所以入口放在编辑页而不是课表页顶栏 ——
   * 顶栏每多一个常驻入口都在跟课表本身抢注意力（同 openPanel 的理由）。
   */
  private openSettings(): void {
    const uiContext: UIContext = this.getUIContext();
    uiContext.getRouter().pushUrl({ url: 'pages/Settings' }).catch(() => {
      UiFeedback.toast(uiContext, t('ix_open_settings_failed'));
    });
  }

  /**
   * 顶栏。
   *
   * 高度给 40vp：这个页面的垂直空间在单栏形态下最紧张，而顶栏每多占一行，
   * 整周网格在 2in1 上就少一行课。40 够放一行 15vp 的字。
   */
  @Builder
  private topBar() {
    Row() {
      Text(t('ix_tab_schedule'))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
        .layoutWeight(1)
      if (!this.isSingleColumn()) {
        Text(t('ix_tab_panel'))
          .fontSize(14)
          .fontColor($r('app.color.ch_accent'))
          .padding({ right: 16, top: 4, bottom: 4 })
          .onClick(() => {
            this.openPanel();
          })
      }
      Text(t('ix_tab_settings'))
        .fontSize(14)
        .fontColor($r('app.color.ch_accent'))
        .padding({ right: 16, top: 4, bottom: 4 })
        .onClick(() => {
          this.openSettings();
        })
      Text(t('ix_tab_edit'))
        .fontSize(14)
        .fontColor($r('app.color.ch_accent'))
        .padding({ left: 16, top: 4, bottom: 4 })
        .onClick(() => {
          this.openEditor();
        })
    }
    .width('100%')
    .height(40)
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 4 })
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
      Text(t('ctv_no_schedule'))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
      Text(t('ix_import_hint'))
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
        Text(t('ix_this_week'))
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
      this.topBar()

      if (this.vm === undefined) {
        // aboutToAppear 早于首次 build，所以这个分支只在极端异常路径上出现。
        this.loadingView(t('ix_preparing'), false)
      } else if (!this.vm.isReady) {
        // 档案读不出来时没有网格可言，横幅与网格都无从谈起。
        this.loadingView(
          this.vm.errorText.length > 0 ? this.vm.errorText : t('ix_loading'),
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
