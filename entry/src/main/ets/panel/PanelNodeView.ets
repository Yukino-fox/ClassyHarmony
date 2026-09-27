/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 面板里一个组件节点的视图。
 *
 * 这里只负责「把 core 算好的 PanelNode 画出来」
 * --------------------------------------------
 * 时间计算、格式串、四种倒计时源、课表筛选、样式合成全在 common_core 的
 * PanelBuilder 里，ArkUI 侧不碰 JSON、也不重算一遍。两边分开的理由与
 * WidgetModel / ReminderPlan 一样：那段逻辑是纯计算，放 core 才进得了 Node
 * 测试台（entry 依赖 @kit.CoreFileKit，进不去）。所以这个文件里读不到任何
 * 组件设置字段，看到的全是节点上已经算好的值。
 *
 * 尺寸为什么大半照抄桌面版而不是自己定的
 * --------------------------------------
 * 面板是「一眼扫过去」的东西，间距差 2px 就看得出来，而桌面版的数值是量的。
 * 下面每处常量后面都写了出处，改之前先确认桌面版是不是有意为之；凡是没照抄的
 * 都在注释里说明了为什么。
 *
 * 递归为什么用自引用 struct 而不是 @Builder
 * -----------------------------------------
 * @Builder 递归只可靠地间接一层（见 ComponentTreeView 的头注）。容器深度由数据
 * 决定，面板里的分组/堆叠/滚动/轮播四层随便嵌，所以这里让 struct 引用自己。
 */

import { PanelLesson, PanelNode, PanelNodeKind, PanelWidthKind } from 'common_core';
import { HIDDEN_DIM_OPACITY, panelHiddenMark } from './HiddenMark';

/**
 * 行内与容器内相邻组件的横向间距（vp）。
 *
 * 桌面版把间距做在每个子组件的 `Margin="6 0"` 上、容器自己 `Margin="-6 0"` 把
 * 两端负回去（见 FluentTheme/Styles.axaml 的 ContentTemplate）。净效果就是
 * 「相邻之间 6、容器两端 0」，与这里直接用间距等价，且不用再手工抵消。
 */
const CHILD_GAP: number = 6;

/**
 * 倒计时四段之间的间距（vp）。
 *
 * 出处：CountDownComponent.axaml 的 `<StackPanel Orientation="Horizontal" Spacing="2">`。
 */
const COUNTDOWN_GAP: number = 2;

/**
 * 倒计时圆环进度：直径、描边宽（vp）、环与文字之间的额外右间距（vp）。
 *
 * 出处：CountDownComponent.axaml 的 `Ellipse Width="21.4" StrokeThickness="2.6"`
 * 与 `Panel#CircleProgressRoot Margin="0 0 4 0"`。那个 4 是环自己的右边距、
 * 不在 Spacing=2 里，所以要单列。
 */
const RING_DIAMETER: number = 21.4;
const RING_STROKE: number = 2.6;
const RING_GAP: number = 4;

/**
 * 分割线：宽、高（vp）。
 *
 * 出处：SeparatorComponent.axaml 的 `<Grid Width="2">` 加
 * `Line StartPoint="0,0" EndPoint="0,25" StrokeThickness="2"`。描边本身也是 2，
 * 落在 2 宽的格子里正好填满，所以这里只给宽高。
 */
const SEPARATOR_WIDTH: number = 2;
const SEPARATOR_HEIGHT: number = 25;

/**
 * 分割线的不透明度。
 *
 * 出处：SeparatorComponent.axaml 的 `Opacity="0.8"`。颜色用的是主题的
 * TextFillColorSecondaryBrush，对应本工程的 ch_text_secondary。
 */
const SEPARATOR_OPACITY: number = 0.8;

/**
 * 一节课那行的高度（vp）。
 *
 * 出处：LessonsListBox.axaml 的 ControlTheme `Height="40"` 与 ListBoxItem
 * `MaxHeight="40"`。桌面版是固定高度不是自适应，所以这里也是固定值。
 */
const LESSON_ROW_HEIGHT: number = 40;

/**
 * 课程表每行左右各留的缩进（vp）。
 *
 * 出处：LessonControlExpanded.axaml 首尾各一个
 * `<LayoutTransformControl><Border Width="16"/></LayoutTransformControl>`。
 * 它们里面是空的，纯粹是留白 —— 桌面版靠列表左边的分隔条表达「第几节」，鸿蒙
 * 侧这版没画那个分隔条，所以 16 的缩进先留着，不要因为看着「空」就删掉：那会
 * 让科目名顶到面板边上，与桌面版不一致。
 */
const LESSON_INDENT: number = 16;

/**
 * 课程表行内「额外信息」与科目名之间的间距（vp）。
 *
 * 出处：LessonControlExpanded.axaml 的
 * `<Panel Margin="6 0 0 0" Classes="l-secondary">`。
 */
const LESSON_EXTRA_GAP: number = 6;

/**
 * 上下两节课之间的纵向间距（vp）。
 *
 * **没有照抄桌面版**：它的 LessonsListBox 没给 ListBoxItem 设 Margin、Padding
 * 又是 0，行与行之间贴着。这里留 2 是因为上完课的淡化行若与下一节黏在一起就
 * 读不出是两节课 —— 刻意的观感调整，不是抄漏了。
 */
const LESSON_ROW_GAP: number = 2;

/**
 * 上完的课的不透明度。
 *
 * 出处：LessonsListBox.axaml 的 `Grid#_LessonsRoot.faded { Opacity 0.6 }`。
 */
const FINISHED_OPACITY: number = 0.6;

/**
 * 圆环「还没走完」那一段的颜色：前景色压到两成不透明度。
 *
 * 桌面版是主题 token `ControlStrongStrokeColorDisabledBrush`。鸿蒙侧没有对应
 * token，改成前景色的低透明度版本 —— 至少保证用户在面板上换了前景色时环的底
 * 也跟着走，不会出现「白字配一圈深灰描边」这种在浅色底板上几乎看不见的配色。
 */
const RING_TRACK_ALPHA: number = 0.2;

/**
 * 滚动容器的步进间隔（毫秒）。
 *
 * 桌面版是每个动画帧按 `ScrollSpeed` 推进；鸿蒙侧没有 scrollSpeed 属性
 * （SDK 26 的 ScrollAttribute 里没有这一项），只能自己定步长。取 40ms 是在
 * 「看不出来是一格一格跳」与「每秒最多重排 25 次」之间的折中。
 */
const ROLLING_TICK_MS: number = 40;

/** 滚动容器一帧至少走多远（vp/秒）。低于这个值就直接当静止，省掉定时器。 */
const ROLLING_MIN_SPEED: number = 1;

/**
 * 按对齐值（0 拉伸 / 1 居中 / 2 左 / 3 右）取 Stack 的 Alignment。
 *
 * 抽成函数是因为同一份映射要在节点根、堆叠容器、预览三处用，而 ArkTS 不允许
 * 在 build 的多分支语句块里 return 组件。
 *
 * 拉伸（0）落在 Center 上：在横排里给「拉伸」真的拉满会把别的组件挤走，而桌面版
 * 在横排的 StackPanel 里本来就忽略子项的 HorizontalAlignment（见文件头注），
 * 所以「拉伸」在横排语境下等于「按内容居中」。真要拉伸的是堆叠容器 —— 但那里
 * 也不拉伸：桌面版 ComponentPresenter 上挂的是 HorizontalAlignment 而不是
 * 拉伸语义，拉满会把叠在一起的几张内容互相盖住。
 */
function stackAlignOf(horizontalAlignment: number): Alignment {
  if (horizontalAlignment === 2) {
    return Alignment.Start;
  }
  if (horizontalAlignment === 3) {
    return Alignment.End;
  }
  return Alignment.Center;
}

/**
 * 宽度的尺寸约束。取不到时给一个空壳，等于不加约束。
 *
 * 固定宽（FIXED）不在这里：外层 Stack 的 width 直接吃固定值，constraintSize 只
 * 承担 min/max 两档。
 */
function constraintOf(node: PanelNode): ConstraintSizeOptions {
  if (node.widthKind === PanelWidthKind.FIXED) {
    const fixed: ConstraintSizeOptions = { minWidth: node.widthValue, maxWidth: node.widthValue };
    return fixed;
  }
  if (node.widthKind === PanelWidthKind.MIN) {
    const only: ConstraintSizeOptions = { minWidth: node.widthValue };
    return only;
  }
  if (node.widthKind === PanelWidthKind.MAX) {
    const only: ConstraintSizeOptions = { maxWidth: node.widthValue };
    return only;
  }
  return {};
}

/**
 * 把 #AARRGGBB 里的 alpha 换成给定的百分比。
 *
 * ArkUI 的 8 位十六进制颜色里 alpha 在**最前**，core 给的也是这个序，所以只需要
 * 改头两位。解析不了就原样返回：宁可环的底色和前景一样亮，也不要因为一个颜色
 * 字符串把整棵子树渲崩。
 */
function withAlpha(color: string, percent: number): string {
  if (color.length !== 9 || !color.startsWith('#')) {
    return color;
  }
  const value: number = Math.max(0, Math.min(255, Math.round(percent * 2.55)));
  const hex: string = value.toString(16).toUpperCase();
  const padded: string = hex.length === 1 ? `0${hex}` : hex;
  return `#${padded}${color.substring(3)}`;
}

/**
 * 一节课。
 *
 * 单独一个 struct 而不是 @Builder：这一行的内边距与对齐规则不少，塞进 @Builder
 * 会让父组件的 build 长到没法看；而行里的进度条要不要画只看 lesson 自己的
 * progressPercent，不需要任何额外状态。
 */
@ComponentV2
struct PanelLessonRow {
  @Require @Param lesson: PanelLesson;
  /** 科目名的字号（强调档）。 */
  @Param fontSize: number = 16;
  /** 额外信息的字号（次要档）。 */
  @Param secondaryFontSize: number = 14;
  /** 主色。 */
  @Param textColor: ResourceColor = '#FFFFFFFF';
  /** 次要色。 */
  @Param secondaryColor: ResourceColor = '';

  build() {
    Column() {
      Row() {
        Blank().width(LESSON_INDENT)
        Text(this.lesson.subjectName)
          .fontSize(this.fontSize)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textColor)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.lesson.extraText.length > 0) {
          Text(this.lesson.extraText)
            .fontSize(this.secondaryFontSize)
            .fontColor(this.secondaryColor)
            .maxLines(1)
            .margin({ left: LESSON_EXTRA_GAP })
        }
        Blank().width(LESSON_INDENT)
      }
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .layoutWeight(1)

      if (this.lesson.progressPercent >= 0) {
        // 正在上的那节才有进度条，贴行底。桌面版是 Maximum=1，core 给的是
        // 0..100 的百分数，所以 total 传 100。
        Progress({ value: this.lesson.progressPercent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(2)
          .color(this.textColor)
      }
    }
    .width('100%')
    .height(LESSON_ROW_HEIGHT)
    .opacity(this.lesson.isFinished ? FINISHED_OPACITY : 1)
  }
}

/**
 * 滚动容器。
 *
 * 为什么要单独一个 struct
 * ----------------------
 * 定时器与 Scroller 都得在 aboutToDisappear 里清掉，而清理逻辑挂在组件的生命
 * 周期上。塞进 PanelNodeView 就意味着每个节点都要带着一套「我可能不需要」的
 * 定时器字段，滚动容器一多就有一堆空转的定时器。
 *
 * 桌面版是在 Canvas 里摆**两份**子组件、推进偏移量、滚过一整份后瞬移回去
 * （RollingComponent.axaml 的 `ColumnDefinitions="Auto,16,Auto"` 就是那两份之间
 * 留的接缝）。这里不摆两份，改成内容宽度处瞬移：视觉上等价，少一份拷贝，也不会
 * 在接缝处看到半个组件。
 */
@ComponentV2
struct PanelRollingView {
  @Require @Param node: PanelNode;
  /** 编辑页里被规则藏掉的内容仍然显示（淡化 + 斜纹）。见 PanelNodeView 的同名参数。 */
  @Param inEditMode: boolean = false;

  /**
   * Scroller 不能加 @Local/@State —— SDK 的 build_config.json 把它列进
   * forbiddenUseStateType，装饰器会报 10605034。普通私有字段即可。
   */
  private scroller: Scroller = new Scroller();
  /**
   * 已经走过的距离（vp）。
   *
   * 名字不叫 offset：CustomComponent 自带一个 offset（设位置偏移的通用属性），
   * 撞名会被判「成员与基类同名但类型不同」而编译不过。
   */
  private travel: number = 0;
  private timer: number = -1;
  /** 内容宽度，由内容区的 onAreaChange 量出来。0 表示还没量到，先不滚。 */
  @Local contentWidth: number = 0;

  aboutToAppear(): void {
    if (this.node.scrollSpeed < ROLLING_MIN_SPEED) {
      return;
    }
    this.timer = setInterval(() => {
      this.step();
    }, ROLLING_TICK_MS);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private step(): void {
    if (this.contentWidth <= 0) {
      return;
    }
    this.travel += this.node.scrollSpeed * (ROLLING_TICK_MS / 1000);
    if (this.travel >= this.contentWidth) {
      // 走满一整圈就退回一整圈，落在 [0, 宽度) 里。取模而不是减一，是因为速度很高
      // 时一帧就能跨过好几圈，减一会退回一圈之后仍然越界。
      this.travel = this.travel % this.contentWidth;
    }
    this.scroller.scrollTo({ xOffset: this.travel, yOffset: 0, animation: false });
  }

  build() {
    Scroll(this.scroller) {
      Row({ space: CHILD_GAP }) {
        ForEach(this.node.children, (child: PanelNode) => {
          PanelNodeView({ node: child, inEditMode: this.inEditMode })
        }, (child: PanelNode) => child.guid)
      }
      .height('100%')
      .alignItems(VerticalAlign.Center)
      .onAreaChange((_old: Area, area: Area) => {
        this.contentWidth = Number(area.width);
      })
    }
    .width('100%')
    .height('100%')
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    // 滚到头不发光：桌面版的接缝设在「内容宽度」处而不是「可视宽度」处，这里同理，
    // 到圈尾就该硬接回去，不该闪一下。
    .edgeEffect(EdgeEffect.None, { alwaysEnabled: false })
    // 预览里不给手拖：桌面版的滚动容器是自动的，拖动是编辑模式的事。
    .enableScrollInteraction(false)
  }
}

/**
 * 一个节点。
 *
 * 递归在这里：容器分支里直接再摆一个 PanelNodeView。ArkUI 允许自定义组件引用
 * 自己，限制只针对 @Builder。
 */
@ComponentV2
export struct PanelNodeView {
  @Require @Param node: PanelNode;

  /**
   * 编辑页里被规则藏掉的内容仍然显示（淡化 + 斜纹）。
   *
   * 照抄桌面版 `ComponentPresenter.axaml` 的
   * `IsVisible = IsVisibleInternal || MainWindowInEditMode` —— 隐藏项在编辑
   * 模式下照常占位，否则用户改完规则回头看面板会发现「我藏的那个去哪了」，
   * 而分不清是规则生效了还是自己把它删了。
   *
   * 只管这一件事：真面板与预览的其余部分完全一样。
   */
  @Param inEditMode: boolean = false;

  build() {
    if (this.node.isRuleHidden && !this.inEditMode) {
      // 真面板：整块不画。桌面版是 UserControl.IsVisible=false，Avalonia 把它
      // 从布局里摘掉（不占位），所以这里给一个空壳而不是留白。
      Column() {}
    } else {
      this.shell()
    }
  }

  /**
   * 节点外壳。
   *
   * 外层只管样式（背景、圆角、外边距、宽度、不透明度），里层按种类画内容。
   * 分两层是因为背景要裹住全部内容，而内容区的排布（横排 / 叠放 / 滚动 /
   * 轮播）随种类变。
   */
  @Builder
  private shell() {
    Stack({ alignContent: stackAlignOf(this.node.horizontalAlignment) }) {
      Column() {
        this.body()
      }
      .width('100%')
      if (this.node.isRuleHidden) {
        // 编辑页里的被藏标记。盖在内容上面，且不吃触摸 —— 面板上的组件本来
        // 也不接收点击（P6 的提醒走系统通知），但别让这层斜条挡住别的命中。
        panelHiddenMark()
      }
    }
    .width('100%')
    .padding({ left: this.node.marginLeft, top: this.node.marginTop,
      right: this.node.marginRight, bottom: this.node.marginBottom })
    .backgroundColor(this.node.backgroundColor.length > 0
      ? this.node.backgroundColor : Color.Transparent)
    .borderRadius(this.node.cornerRadius)
    .constraintSize(constraintOf(this.node))
    .clip(true)
    // 被规则藏掉的那份淡化：桌面版靠遮罩的两档透明度（0.69 / 0.31）达到平均
    // 约 0.5，这里用同一个平均值。没有遮罩就至少保证「明显不是正常显示」。
    .opacity(this.node.isRuleHidden
      ? this.node.opacity * HIDDEN_DIM_OPACITY : this.node.opacity)
  }

  @Builder
  private body() {
    if (this.node.hintText.length > 0) {
      // 提示态：未识别的组件 / 天气未接入 / 空课表占位。这几种在桌面版上都是
      // 「不画内容，只画一句说明」，所以共用这一支。
      Text(this.node.hintText)
        .fontSize(this.node.secondaryFontSize)
        .fontColor($r('app.color.ch_text_hint'))
    } else if (this.node.isTruncated) {
      Text('这一层没展开')
        .fontSize(this.node.secondaryFontSize)
        .fontColor($r('app.color.ch_text_hint'))
    } else if (this.node.kind === PanelNodeKind.CLOCK || this.node.kind === PanelNodeKind.DATE ||
      this.node.kind === PanelNodeKind.TEXT) {
      this.singleText()
    } else if (this.node.kind === PanelNodeKind.SEPARATOR) {
      this.separator()
    } else if (this.node.kind === PanelNodeKind.COUNT_DOWN) {
      this.countDown()
    } else if (this.node.kind === PanelNodeKind.SCHEDULE) {
      this.schedule()
    } else if (this.node.kind === PanelNodeKind.GROUP) {
      this.group()
    } else if (this.node.kind === PanelNodeKind.STACK) {
      this.stack()
    } else if (this.node.kind === PanelNodeKind.ROLLING) {
      this.rolling()
    } else if (this.node.kind === PanelNodeKind.SLIDE) {
      this.slide()
    } else {
      // 未识别组件的兜底分支。正常走不到（hintText 已经拦住了），留在这里是
      // 为了 core 将来加新种类时这里不会静默画成空白。
      Text(this.node.displayName)
        .fontSize(this.node.secondaryFontSize)
        .fontColor($r('app.color.ch_text_hint'))
    }
  }

  /** 时钟 / 日期 / 文本：都是一行字，只是字号不同（core 已按种类选好）。 */
  @Builder
  private singleText() {
    Text(this.node.primaryText)
      .fontSize(this.node.fontSize)
      .fontColor(this.node.foregroundColor)
      .maxLines(1)
  }

  /** 分割线：2×25 的竖条。 */
  @Builder
  private separator() {
    Divider()
      .vertical(true)
      .width(SEPARATOR_WIDTH)
      .height(SEPARATOR_HEIGHT)
      .color($r('app.color.ch_text_secondary'))
      .opacity(SEPARATOR_OPACITY)
  }

  /**
   * 倒计时：四段 + 可选进度。
   *
   * 「距离」与连接词是弱化色，名称与数值是组件自己的颜色和字号 —— 桌面版就是
   * 这么分的（`Classes="connector l-instructive"` 对 `Foreground={FontColor}`）。
   * 紧凑模式下弱化那两段在 core 里就置空了，这里按空串跳过。
   */
  @Builder
  private countDown() {
    Column() {
      Row({ space: COUNTDOWN_GAP }) {
        if (this.node.progressPercent >= 0 && this.node.progressMode === 0) {
          this.ring()
        }
        if (this.node.prefixText.length > 0) {
          Text(this.node.prefixText)
            .fontSize(this.node.fontSize)
            .fontColor($r('app.color.ch_text_secondary'))
        }
        Text(this.node.nameText)
          .fontSize(this.node.fontSize)
          .fontColor(this.node.foregroundColor)
        if (this.node.connectorText.length > 0) {
          Text(this.node.connectorText)
            .fontSize(this.node.fontSize)
            .fontColor(this.node.connectorEmphasized
              ? this.node.foregroundColor : $r('app.color.ch_text_secondary'))
        }
        Text(this.node.valueText)
          .fontSize(this.node.fontSize)
          .fontColor(this.node.foregroundColor)
      }
      .alignItems(VerticalAlign.Center)

      if (this.node.progressPercent >= 0 && this.node.progressMode === 1) {
        Progress({ value: this.node.progressPercent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(2)
          .color(this.node.foregroundColor)
      }
    }
  }

  /**
   * 倒计时圆环。
   *
   * 底下垫一个同尺寸的圆当轨道：ArkUI 的 Ring 进度只给指示段的颜色，没法设轨道
   * 色，而桌面版轨道是 `ControlStrongStrokeColorDisabledBrush`。
   */
  @Builder
  private ring() {
    Stack() {
      Column()
        .width(RING_DIAMETER)
        .height(RING_DIAMETER)
        .borderRadius(RING_DIAMETER / 2)
        .border({ width: RING_STROKE, color: withAlpha(this.node.foregroundColor, RING_TRACK_ALPHA) })
      Progress({ value: this.node.progressPercent, total: 100, type: ProgressType.Ring })
        .width(RING_DIAMETER)
        .height(RING_DIAMETER)
        .style({ strokeWidth: RING_STROKE })
        .color(this.node.foregroundColor)
    }
    .width(RING_DIAMETER)
    .height(RING_DIAMETER)
    .margin({ right: RING_GAP })
  }

  /**
   * 课程表：一列课次行。
   *
   * 行高固定（LESSON_ROW_HEIGHT），纵向不加 layoutWeight —— 桌面版是一屏放不下的
   * 时候让 LessonsListBox 自己裁，而面板上没有滚动，让它自然溢出即可。
   */
  @Builder
  private schedule() {
    Column({ space: LESSON_ROW_GAP }) {
      ForEach(this.node.lessons, (lesson: PanelLesson) => {
        PanelLessonRow({
          lesson: lesson,
          fontSize: this.node.emphasisFontSize,
          secondaryFontSize: this.node.secondaryFontSize,
          textColor: this.node.foregroundColor,
          secondaryColor: $r('app.color.ch_text_secondary')
        })
      }, (lesson: PanelLesson) => `${lesson.classSlot}`)
    }
  }

  /**
   * 分组容器：横排。
   *
   * 出处：GroupComponent.axaml 的 `StackPanel Classes="components-panel"`，而
   * ComponentsPanelStyles.axaml 把这个类设成 `Orientation="Horizontal"`。
   */
  @Builder
  private group() {
    if (this.node.children.length > 0) {
      Row({ space: CHILD_GAP }) {
        ForEach(this.node.children, (child: PanelNode) => {
          PanelNodeView({ node: child, inEditMode: this.inEditMode })
        }, (child: PanelNode) => child.guid)
      }
      .alignItems(VerticalAlign.Center)
    }
  }

  /**
   * 堆叠容器：所有子节点叠在同一个位置。
   *
   * 出处：StackComponent.axaml 的 ItemsPanel 是 `<Panel>`，Avalonia 的 Panel
   * 全部按 0,0 排布，所以「堆叠」就是字面意思地叠在一起。
   */
  @Builder
  private stack() {
    if (this.node.children.length > 0) {
      Stack({ alignContent: stackAlignOf(this.node.horizontalAlignment) }) {
        ForEach(this.node.children, (child: PanelNode) => {
          PanelNodeView({ node: child, inEditMode: this.inEditMode })
        }, (child: PanelNode) => child.guid)
      }
    }
  }

  @Builder
  private rolling() {
    if (this.node.children.length > 0) {
      PanelRollingView({ node: this.node, inEditMode: this.inEditMode })
    }
  }

  /**
   * 轮播容器：一次显示一个，按设置的秒数自动切换，不循环。
   *
   * 桌面版是 ListBox 配一个空的 Grid 当 ItemsPanel（子项全在同一格里），靠动画
   * 在格子之间交叉淡入淡出，到末尾就停。ArkUI 的 Swiper 正是这个语义。
   *
   * Swiper 的子项直接放内容、不套 SwiperItem —— SDK 26 的 component_config.json
   * 里 Swiper 没有声明 children，装 SwiperItem 会被判「找不到这个名字」。
   */
  @Builder
  private slide() {
    if (this.node.children.length > 0) {
      Swiper() {
        ForEach(this.node.children, (child: PanelNode) => {
          PanelNodeView({ node: child, inEditMode: this.inEditMode })
        }, (child: PanelNode) => child.guid)
      }
      .width('100%')
      .height('100%')
      .autoPlay(this.node.slideSeconds > 0)
      .interval(Math.max(1, this.node.slideSeconds) * 1000)
      .loop(false)
      .displayCount(1)
      .indicator(false)
    }
  }
}
