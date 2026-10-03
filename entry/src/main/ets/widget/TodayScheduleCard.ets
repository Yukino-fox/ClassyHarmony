/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 今日课程表卡片。
 *
 * 数据从哪来
 * ----------
 * FormExtensionAbility 通过 FormBindingData 推进两个字符串键（payload / dimension），
 * 平台把它们注入下面那个 LocalStorage，本文件用 @LocalStorageProp 接。
 *
 * 三个必须写对的点，任意一个写错都不报错、只是卡片一片空白
 * --------------------------------------------------------
 * 1. @Entry 必须带那个 LocalStorage 实例。注入的是「@Entry 参数里那个」，
 *    @LocalStorageProp 读的是「绑定的那个」，两个不是同一个就静默失联。
 * 2. 键名只能有字母数字下划线。带点号会被编译器拒绝（'payload' / 'dimension' 安全）。
 * 3. 载荷必须是 Record 字面量，不能塞模型对象。扩展侧那边有同样的约束。
 *
 * 这个文件刻意用 V1 的 @Component + @LocalStorageProp，而不是工程里其它地方的 V2
 * ---------------------------------------------------------------------
 * 两条都是编译器的硬约束，不是风格选择：@StorageLink 在卡片里被直接拒绝
 * （错误码 11706006「can't support form application」），而 @LocalStorageProp 这对
 * 装饰器在 V2 里不是一等公民（V2 的入口是 @Local / @Param / @Trace）。与其手搓
 * 一份「变了就重解码」的机制，不如在卡片这个受平台约束的表面上用平台自己的写法。
 * 应用内的页面仍然是 V2，两边互不影响。
 *
 * 卡面上不做任何推导
 * ------------------
 * 该显示什么、显示几节、什么时候该刷新，全在 common_core 的 WidgetBuilder 里算完了
 * （纯函数，有测试台）。这里只做「把字符串画成字」。推导搬进卡片的后果是只有装机才
 * 看得见，而卡片 10 秒就被回收，没法在真机上反复调。
 *
 * 不用深色资源，也不用毛玻璃
 * --------------------------
 * 两件事都是同一个原因：本工程的颜色目前只有 base 一份（见 P10 的待办）。
 * 给卡片单独加一套 dark 资源会让它和其它页面在夜间亮度不一致；开毛玻璃就得让卡片
 * 背景带 alpha，而带 alpha 的颜色只能是字面量（颜色资源表达不了 alpha 通道），
 * 于是卡片又和应用的取色分成两套。都比「整块白卡片」更让人意外，所以这里跟应用
 * 保持一致，等 P10 统一处理。form_config.json 里的 enableBlurBackground 同理关掉了。
 */

import { WidgetCodec, WidgetDimension, WidgetLesson, WidgetModel, t } from 'common_core';

/**
 * 卡片自己的 LocalStorage。
 *
 * 必须是模块级单例并显式交给 @Entry，理由见文件头注第 1 条。官方示例里也都是
 * `new LocalStorage()` 而不是可选项。
 */
const cardStorage: LocalStorage = new LocalStorage();

@Entry(cardStorage)
@Component
struct TodayScheduleCard {
  /**
   * 扩展推过来的载荷。键名与 EntryFormAbility.bindingOf() 里的 Record 字面量一一对应。
   *
   * Prop 而非 Link：数据是单向的（扩展 -> 卡片）。卡片不写这个字段，写了也不会回到
   * 扩展侧 —— 用 Link 只会让人误以为那条路存在。
   */
  @LocalStorageProp('payload') @Watch('onPayloadChanged') payload: string = '';

  /**
   * 解码后的模型。
   *
   * 整体替换而不是就地改：替换引用的行为更接近「这份内容是重新算出来的」，
   * 读代码时不用再想哪一层是响应式的。
   */
  @State model: WidgetModel = WidgetCodec.decode('');

  aboutToAppear(): void {
    // 首帧要走这里而不是只靠 @Watch：@LocalStorageProp 是在字段初始化阶段就绑上
    // LocalStorage 的，那一刻的值不会触发 @Watch，只有之后的变化才会。
    this.model = WidgetCodec.decode(this.payload);
  }

  private onPayloadChanged(): void {
    this.model = WidgetCodec.decode(this.payload);
  }

  private isCurrentLesson(index: number): boolean {
    return index === this.model.currentIndex;
  }

  private isNextLesson(index: number): boolean {
    return index === this.model.nextIndex;
  }

  /**
   * 行底色：正在上 > 下一节 > 无。
   *
   * 返回 ResourceColor 而不是 string：函数体里返回 $r() 时，声明的返回类型必须是
   * ResourceColor，否则 ArkTS 类型检查不过（这是本工程踩过的坑之一）。
   *
   * 「无」档是透明而不是画一层白：卡片底色已经是浅色，再叠一层只会让行与行之间
   * 出现没必要分界，课表本身已经用留白分行了。
   */
  private rowBackground(index: number): ResourceColor {
    if (this.isCurrentLesson(index)) {
      return $r('app.color.ch_accent_soft');
    }
    if (this.isNextLesson(index)) {
      return $r('app.color.ch_surface_weak');
    }
    return Color.Transparent;
  }

  /**
   * 时刻列宽。4*4 上课表名也长，挤掉时刻比挤掉科目更让人读不下去。
   */
  private timeWidth(): number {
    return this.model.dimension === WidgetDimension.ROOMY ? 78 : 66;
  }

  @Builder
  private header() {
    Row() {
      Text(this.model.dayLabel)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_accent'))
      Text(this.model.dateText)
        .fontSize(12)
        .fontColor($r('app.color.ch_text_secondary'))
        .margin({ left: 6 })
      Blank()
      if (this.model.planTag.length > 0) {
        // 用了临时课表或预定课表就标出来，否则用户查不出课表为什么变了。
        Text(this.model.planTag)
          .fontSize(11)
          .fontColor($r('app.color.ch_surface'))
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .backgroundColor($r('app.color.ch_next'))
          .borderRadius(4)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private headline() {
    Column() {
      Text(this.model.headline)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.ch_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.model.headlineHint)
        .fontSize(12)
        .fontColor($r('app.color.ch_text_secondary'))
        .margin({ top: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 6, bottom: 8 })
  }

  @Builder
  private lessonRow(lesson: WidgetLesson, index: number) {
    Row() {
      Text(lesson.rangeText)
        .fontSize(11)
        .fontColor($r('app.color.ch_text_secondary'))
        .width(this.timeWidth())
      Text(lesson.slotText)
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width(46)
      Text(lesson.subjectName)
        .fontSize(15)
        .fontWeight(this.isCurrentLesson(index) ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(lesson.isEmpty ? $r('app.color.ch_text_hint') : $r('app.color.ch_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (lesson.isChangedClass) {
        // 换课/调课。只有在叠加课表下才会出现，主课表上这个标记恒为 false。
        Text(t('wg_changed_badge'))
          .fontSize(10)
          .fontColor($r('app.color.ch_next'))
          .margin({ left: 4 })
      }
    }
    .width('100%')
    .height(26)
    .padding({ left: 6, right: 6 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.rowBackground(index))
    .borderRadius(4)
  }

  @Builder
  private lessonList() {
    Column() {
      ForEach(this.model.lessons, (lesson: WidgetLesson, index: number) => {
        this.lessonRow(lesson, index)
      }, (lesson: WidgetLesson, index: number) => `${index}-${lesson.classSlot}`)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Start)
    // 卡片被用户拉成比 supportDimensions 更矮时（系统偶尔会给 1*1 之外的非标高度），
    // 多出来的那几节被裁掉而不是挤走标题。裁掉的行会缺一个尾巴，但总比标题被顶出
    // 卡片、整张卡只剩半行字要好 —— 后者用户看不出这是课表。
    .clip(true)
  }

  @Builder
  private emptyState() {
    Column() {
      Text(this.model.emptyHint)
        .fontSize(14)
        .fontColor($r('app.color.ch_text_secondary'))
      Text(this.model.dateText)
        .fontSize(12)
        .fontColor($r('app.color.ch_text_hint'))
        .margin({ top: 4 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private body() {
    Column() {
      if (this.model.isEmpty) {
        this.emptyState()
      } else {
        this.header()
        this.headline()
        this.lessonList()
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    FormLink({
      // 点卡片进应用内课表页。带上 dayOffset 是因为卡片可能显示的是明天或下周一 ——
      // 直接进课表页却停在今天，用户会以为卡片在骗他。
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        dayOffset: this.model.dayOffset
      }
    }) {
      Column() {
        this.body()
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.ch_surface'))
      .borderRadius(16)
    }
  }
}
