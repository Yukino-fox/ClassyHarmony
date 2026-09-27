/*
 * 主界面组件布局的渲染模型。
 *
 * 为什么不直接让 ArkUI 去读 ComponentSettings
 * ---------------------------------------
 * 两个理由。
 *
 * 一是嵌套容器的子列表是解析出来的副本（见 ComponentCatalog.childrenOf 的头注），
 * ArkUI 里每帧去重新解析一遍 JSON 会让界面在展开/折叠时抖动，而抖动的位置还随
 * 用户点了什么变。
 *
 * 二是可测。「倒计时在 CountdownSource=3 时该显示几天」这种问题，写在纯函数里
 * 几行就验完，写在 @Builder 里就只能靠眼睛看。P1 定下的规矩在这里照旧：凡是能
 * 变成纯函数的推导都搬到 common_core，Node 测试台直接跑。
 *
 * 设置的读法只有一条路
 * ------------------
 * 全部走 ComponentCatalog.decode（未识别组件除外，它压根没注册）。不在这里
 * 重写一套「按字段名读 JsonObject」的代码：那份代码与 ComponentPayloads 的
 * 字段名一一对应，多一处就要多维护一处，而漏同步的那一处不报错 —— 只是那个
 * 设置悄悄读成了默认值。
 *
 * 颜色在这里就换成 ArkUI 的写法
 * ---------------------------
 * 落盘是 #RRGGBBAA（透明度在末尾，桌面版 Color 的字节序），ArkUI 是 #AARRGGBB。
 * 换序在 ColorValue.toArkUi 里做一次，界面直接拿字符串用。在界面里换的话每处都
 * 要记得调，漏一处的表现是「颜色全反了但没人报错」。
 *
 * 未实现的部分照实显示
 * ------------------
 * 规则集判定是 P8，天气要联网是 P11。这两处给出明确文案而不是画个空白：用户看到
 * 「天气组件要联网，还没接」能判断该不该等，看到空白只会以为面板坏了。
 */

import {
  ClassPlan,
  ColorValue,
  ComponentProfile,
  ComponentSettings,
  DateTimeValue,
  JsonNode,
  MainWindowLineSettings,
  Profile,
  Ruleset,
  Subject,
  TimeLayout,
  TimeLayoutItem,
  TIME_TYPE_CLASS
} from 'common_shared';
import { ClassPlanResolver, ResolvedClassPlan } from '../engine/ClassPlanResolver';
import { EngineSettings } from '../engine/EngineSettings';
import { LessonsEngine } from '../engine/LessonsEngine';
import { LessonsSnapshot } from '../engine/LessonsSnapshot';
import { RuleContext, RuleEngine } from '../rules/RuleEngine';
import { weekDayName } from '../view/TextFormat';
import {
  COMPONENT_CLOCK,
  COMPONENT_COUNTDOWN,
  COMPONENT_DATE,
  COMPONENT_GROUP,
  COMPONENT_ROLLING,
  COMPONENT_SCHEDULE,
  COMPONENT_SEPARATOR,
  COMPONENT_SLIDE,
  COMPONENT_STACK,
  COMPONENT_TEXT,
  COMPONENT_WEATHER,
  ComponentCatalog,
  ComponentDescriptor
} from '../components/ComponentCatalog';
import {
  ClockPayload,
  CountDownPayload,
  RollingPayload,
  SchedulePayload,
  SlidePayload,
  TextPayload
} from '../components/ComponentPayloads';

/**
 * 面板最多展平多少层容器。
 *
 * 与 ComponentLayoutViewModel.MAX_LAYOUT_DEPTH 同值但**互不引用**：那边是编辑
 * 树的决策，这边是渲染的硬边界。两处各写一个常量而不是让 core 反向依赖 entry，
 * 是为了保住「面板视图模型可在 Node 测试台里跑」这条性质。
 *
 * 12 是个随便取的数：容器只有分组/堆叠/滚动/轮播四种，实用上没人嵌过三层。取一
 * 个明确的数是为了让文件被改坏时有个确定终点 —— 布局文件是外部可写的，手改一份
 * JSON 就能造出环，无限递归的表现是页面卡死且不报错。
 */
const MAX_DEPTH: number = 12;

/** 空课表时课程表组件显示的占位文字，与小组件一致。 */
const EMPTY_SUBJECT_TEXT: string = '（无）';

/** 引擎给出的兜底文案。 */
const NO_CLASS_TODAY: string = '今天没有课程。';
const ALL_CLASS_ENDED: string = '今日课程已全部结束。';
/** 倒计时组件在非紧凑模式下、名称前面那一段固定文字。抄桌面版模板里的 TextBlockTo。 */
const COUNTDOWN_PREFIX: string = '距离';

const NO_PROFILE: string = '还没有课表档案，先去编辑页导入或新建一份。';

/** 跨零点的课（第二节上到凌晨）时用来把负的秒差掰回来的天数。 */
const SECONDS_PER_DAY: number = 86400;

/** 进度百分比的分母下限。防「一节课 0 秒长」除出 NaN。 */
const MIN_SPAN_SECONDS: number = 1;

/**
 * 节点种类。
 *
 * 字符串常量而不是 enum：ArkUI 侧要把它当 key 比对，字符串少一层「两个同名
 * enum 互不兼容」的坑（见 P3 的记录）。
 */
export class PanelNodeKind {
  static readonly UNKNOWN: string = 'unknown';
  static readonly CLOCK: string = 'clock';
  static readonly DATE: string = 'date';
  static readonly TEXT: string = 'text';
  static readonly COUNT_DOWN: string = 'countdown';
  static readonly SCHEDULE: string = 'schedule';
  static readonly WEATHER: string = 'weather';
  static readonly SEPARATOR: string = 'separator';
  static readonly GROUP: string = 'group';
  static readonly STACK: string = 'stack';
  static readonly ROLLING: string = 'rolling';
  static readonly SLIDE: string = 'slide';
}

/** 宽度语义。对应 ComponentSettings 的四个 Is*WidthEnabled。 */
export class PanelWidthKind {
  /** 不限，跟着内容走。 */
  static readonly AUTO: number = 0;
  static readonly FIXED: number = 1;
  static readonly MIN: number = 2;
  static readonly MAX: number = 3;
}

/** 课程表组件里的一节课。 */
export class PanelLesson {
  /** 课次下标（0 起）。 */
  classSlot: number = -1;
  /** 「第 1 节」。 */
  slotText: string = '';
  /** 「08:00-08:45」。 */
  rangeText: string = '';
  subjectName: string = '';
  teacherName: string = '';
  /**
   * 时刻下方的补充说明。取值由 ExtraInfoType 决定（0 区间 / 1 已过 / 2 剩余 /
   * 3 已过百分比 / 4 剩余向上取整 / 5 剩余截断）。空串表示不显示。
   */
  extraText: string = '';
  /** 临上课的倒计时文本。空串表示不在倒计时窗口内。 */
  countdownText: string = '';
  /** 没有排科目。 */
  isEmpty: boolean = false;
  /** 调课 / 换课。 */
  isChangedClass: boolean = false;
  /** 就是此刻正在上的那节课。 */
  isCurrent: boolean = false;
  /** 接下来第一节。正在上的那节课不算「下一节」—— 它已经是「现在」了。 */
  isNext: boolean = false;
  /** 已经上完。与 isCurrent 互斥。 */
  isFinished: boolean = false;
  /** 这节课的进度 0..100。-1 表示不算进度（没在上课）。 */
  progressPercent: number = -1;
}

/** 面板里的一个可渲染节点。 */
export class PanelNode {
  /** 组件 GUID。容器用它自己的。 */
  guid: string = '';
  /** 节点种类，决定用哪个视图渲染。 */
  kind: string = PanelNodeKind.UNKNOWN;
  /** 显示名。逐级退化，从不为空串。 */
  displayName: string = '';
  /** 未注册的组件。只显示提示，不进渲染分支。 */
  isUnknown: boolean = false;
  /** 容器因为层数上限没展开子节点。 */
  isTruncated: boolean = false;

  /**
   * 这一节点被自己的隐藏规则命中了。
   *
   * 口径照抄桌面版 `ComponentPresenter.CheckHideRule`：
   * `HideOnRule && HidingRules != null && IsRulesetSatisfied(HidingRules)`。
   * 两个前置条件缺一不可 —— 光配规则不勾开关是不生效的，这一点很容易忘。
   *
   * 界面上不画这个节点。真面板直接消失，编辑页淡化 + 45° 斜纹（照抄
   * `ComponentPresenter.axaml` 的 `IsVisible = IsVisibleInternal || InEditMode`
   * 与那个 RotateTransform(45) 的 OpacityMask）。
   */
  isRuleHidden: boolean = false;
  /**
   * 自己的规则没命中，但所有子节点都命中了。
   *
   * 桌面版 `UpdateComponentHidState` 算的是
   * `Settings.IsVisible = IsVisibleInternal && !_isAllComponentsHid`，
   * 也就是「子节点全藏了就把自己也标成不可见」，然后由父节点读这个标记往上冒。
   *
   * 界面上**不**因此跳过本节点：桌面版的 presenter 只按 IsVisibleInternal 决定
   * 自己的可见性，一个子节点全空的容器仍会渲染（渲染成空的）。照抄。
   * 这个字段给的是父节点往上冒时要看的那一份。
   */
  allChildrenHidden: boolean = false;

  /** 主文本。 */
  primaryText: string = '';
  /** 主文本下面那行小字。 */
  secondaryText: string = '';
  /** 再下面那行（教师名、说明）。 */
  detailText: string = '';
  /** 提示语。空串表示不是提示态（未识别组件 / 未接入的组件 / 空课表占位）。 */
  hintText: string = '';

  /** 前景色，#AARRGGBB。 */
  foregroundColor: string = '#FFFFFFFF';
  /** 背景色，#AARRGGBB。空串表示不画背景。 */
  backgroundColor: string = '';
  /** 圆角，vp。 */
  cornerRadius: number = 0;
  /** 整体不透明度 0..1。 */
  opacity: number = 1;
  /** 自定义外边距，vp。没开 IsCustomMarginEnabled 时全 0。 */
  marginLeft: number = 0;
  marginTop: number = 0;
  marginRight: number = 0;
  marginBottom: number = 0;

  /** 主文本字号，vp。 */
  fontSize: number = 16;
  /** 次要文本字号，vp。 */
  secondaryFontSize: number = 14;
  /** 强调文本字号，vp。 */
  emphasisFontSize: number = 18;

  /** 宽度语义与数值。 */
  widthKind: number = PanelWidthKind.AUTO;
  widthValue: number = 0;
  /** 横向对齐，0 拉伸 / 1 居中 / 2 左 / 3 右。 */
  horizontalAlignment: number = 0;

  /**
   * 倒计时组件那几段「提示性文字」。空串表示不显示这一段。
   *
   * 拆成四段而不是给一个拼好的字符串，是因为桌面版 CountDownComponent.axaml 里
   * 「距离」和「连接词」是 l-instructive 弱化色，「名称」和「数值」是 FontColor +
   * FontSize。拼成一个字符串就没法让其中两段变弱化色了。primaryText 仍然保留
   * 拼好的版本，供签名单独判断内容变没变。
   */
  prefixText: string = '';
  nameText: string = '';
  connectorText: string = '';
  /** 连接词是否也用 FontColor。false 时走弱化色。 */
  connectorEmphasized: boolean = false;
  valueText: string = '';
  /**
   * 进度条形态：0 = 圆环，1 = 横条。对应桌面版 ProgressBarMode。
   * 只有 progressPercent >= 0 时才有意义。
   */
  progressMode: number = 0;
  /** 进度 0..100。-1 表示不画进度条。 */
  progressPercent: number = -1;
  /** 进度条是否倒着填。 */
  progressInverted: boolean = false;

  /** 课程表组件的课表行。 */
  lessons: PanelLesson[] = [];
  /** 容器子节点。 */
  children: PanelNode[] = [];
  /** 滚动速度，vp/秒。 */
  scrollSpeed: number = 40;
  /** 轮播停留秒数。 */
  slideSeconds: number = 15;
}

/** 面板的一行。 */
export class PanelLine {
  /** 第几行（0 基）。对应 MainWindowLineSettings 在布局里的下标。 */
  lineIndex: number = 0;
  /**
   * 是不是主行。
   *
   * 落盘、照传，界面上不据此改变外观。桌面版拿它做两件事：入场动画（那段代码
   * 在 1.x 已被注释掉）与通知消费者注册（鸿蒙侧走 P6 的平台提醒，与此无关）。
   * 照传是因为它是用户可见的开关，编辑页将来要能改。
   */
  isMainLine: boolean = false;
  /** 行是否可见。落在 MainWindowLineSettings.IsVisible 上。 */
  isVisible: boolean = true;
  /**
   * 整行被自己的隐藏规则命中了。
   *
   * 注意桌面版 `MainWindowLine.UpdateHiddenState` 里
   * `Settings.IsVisible = IsVisibleInternal` —— 行的落盘可见性**只**反映自己的规则，
   * 不与子节点的状态做与运算（子节点全空另有一个 `IsAllComponentsHid` 字段，
   * 只用于「要不要发提醒」，不用于渲染）。所以一行里所有组件都被规则藏了之后，
   * 这一行仍会渲染，只是渲染成空的。照抄。
   */
  isRuleHidden: boolean = false;
  /** 整行背景色，#AARRGGBB。空串表示不画。 */
  backgroundColor: string = '';
  /** 整行圆角，vp。 */
  cornerRadius: number = 0;
  /** 整行不透明度 0..1。 */
  opacity: number = 1;
  /** 本行的组件。 */
  nodes: PanelNode[] = [];
}

/** 整个面板的渲染模型。 */
export class PanelModel {
  /** 行，按行序。只含 isVisible 为 true 的。 */
  lines: PanelLine[] = [];
  /**
   * 被关掉的行数。
   *
   * 隐藏的行不进模型，但计数留着：界面上要能区分「这一行是空的」和「这一行被你
   * 关掉了」，后者在编辑页里有开关可改，前者只能加组件。
   */
  hiddenLineCount: number = 0;
  /**
   * 被规则藏起来的行数。
   *
   * 与 hiddenLineCount 分开数：前者在真面板与编辑页都消失（用户自己在
   * `IsVisible` 上关掉的），后者两边都留着 —— 真面板不画，编辑页淡化显示，
   * 否则用户改规则时看不到「我刚藏的那个去哪了」。
   */
  ruleHiddenLineCount: number = 0;
  /** 没有任何可见行。 */
  isEmpty: boolean = true;
  /**
   * 时钟的冒号这一拍显示不显示。
   *
   * 时钟组件在「不显示秒 + 冒号闪烁」时是 `HH:mm` 与 `HH mm` 交替（桌面版靠
   * 两个 TextBlock 互相盖实现）。这里给一个布尔，界面照它决定显示哪一种。
   */
  clockShowsSeparator: boolean = true;

  /**
   * 展示指纹。用来判断「重算之后内容真的变了吗」。
   *
   * 面板每秒都会重算（时钟在走）。指纹不变说明只有时钟那一格变了，界面就只更新
   * 那一格而不必重建整棵树 —— 重建在嵌套容器多时肉眼可见地闪。
   */
  buildSignature(): string {
    const parts: string[] = [
      `${this.isEmpty}`, `${this.hiddenLineCount}`, `${this.ruleHiddenLineCount}`,
      `${this.clockShowsSeparator}`
    ];
    for (const line of this.lines) {
      parts.push(`L${line.lineIndex},${line.isMainLine},${line.backgroundColor},` +
        `${line.cornerRadius},${line.opacity},${line.isRuleHidden};`);
      parts.push(PanelBuilder.signatureOf(line.nodes));
    }
    return parts.join('|');
  }
}

export class PanelBuilder {
  /**
   * 把组件布局算成可渲染的模型。
   *
   * @param layout 组件布局
   * @param profile 课表档案。传 undefined 用于编辑预览（还没课表时也能排面板）。
   * @param settings 引擎参数（单周起始日等）
   * @param now 当前时刻
   */
  static build(layout: ComponentProfile, profile: Profile | undefined, settings: EngineSettings,
    now: DateTimeValue): PanelModel {
    const model: PanelModel = new PanelModel();
    // 隐藏规则整块求值一次，逐条规则喂同一份课表状态。
    // 面板每秒重算一次，所以这里不能再按节点各算一遍课表快照 ——
    // 一个面板挂十几个组件是常事，那等于每秒多算十几次全量课表。
    const context: RuleContext = new RuleContext();
    context.now = now;
    context.profile = profile;
    context.snapshot = profile === undefined
      ? new LessonsSnapshot() : LessonsEngine.compute(profile, settings, now);
    for (let i: number = 0; i < layout.lines.length; i++) {
      const line: MainWindowLineSettings = layout.lines[i];
      if (!line.isVisible) {
        model.hiddenLineCount++;
        continue;
      }
      const row: PanelLine = new PanelLine();
      row.lineIndex = i;
      row.isMainLine = line.isMainLine;
      row.isRuleHidden = PanelBuilder.isRuleHidden(line.hideOnRule, line.hidingRules, context);
      if (row.isRuleHidden) {
        model.ruleHiddenLineCount++;
      }
      row.backgroundColor = PanelBuilder.lineBackgroundOf(line);
      row.cornerRadius = line.isCustomCornerRadiusEnabled ? line.customCornerRadius : 0;
      row.opacity = PanelBuilder.clamp01(line.opacity);
      for (const child of line.children) {
        row.nodes.push(PanelBuilder.nodeOf(child, line, profile, settings, now, 0, context));
      }
      model.lines.push(row);
    }
    model.isEmpty = model.lines.length === 0;
    model.clockShowsSeparator = now.second % 2 === 1;
    return model;
  }

  /**
   * 一组子节点是不是全被藏了。
   *
   * 递归口径：子节点的「有效可见」= 它自己没被规则藏 **且** 它的子节点不是全空的。
   * 与桌面版 `_isAllComponentsHid` + `Settings.IsVisible = IsVisibleInternal &&
   * !_isAllComponentsHid` 逐字对应。
   *
   * 空列表算「全藏」。桌面版 `Children.FirstOrDefault(x => x.IsVisible) == null`
   * 对空列表同样成立（FirstOrDefault 返回 null），而一个没有子节点的容器
   * 之所以还显示着，靠的是它自己的 IsVisibleInternal，不靠这里。
   */
  private static allChildrenHiddenOf(children: PanelNode[]): boolean {
    for (const child of children) {
      if (!child.isRuleHidden && !child.allChildrenHidden) {
        return false;
      }
    }
    return true;
  }

  /**
   * 求一次隐藏规则。
   *
   * `hideOnRule` 与 `hidingRules` 挂在 ComponentSettings 与 MainWindowLineSettings
   * 上，语义完全一样（桌面版两个类各有同名的一对属性），所以合成一个函数。
   *
   * hidingRules 是裸 JsonNode（未注册规则的设置要原样透传，见 Ruleset.ets 文件头），
   * 所以每次现解。布局里没有规则时早退，不浪费一次 parse。
   */
  static isRuleHidden(hideOnRule: boolean, hidingRules: JsonNode | undefined,
    context: RuleContext): boolean {
    if (!hideOnRule || hidingRules === undefined) {
      return false;
    }
    return RuleEngine.evaluate(Ruleset.parse(hidingRules), context).satisfied;
  }

  /**
   * 递归算一个节点。
   *
   * @param line 行设置。组件没开 IsResourceOverridingEnabled 时样式全部继承行。
   * @param depth 0 是行的直接子组件。
   */
  private static nodeOf(component: ComponentSettings, line: MainWindowLineSettings,
    profile: Profile | undefined, settings: EngineSettings, now: DateTimeValue,
    depth: number, context: RuleContext): PanelNode {
    const node: PanelNode = new PanelNode();
    node.guid = component.id;
    node.kind = PanelBuilder.kindOf(component.id);
    node.displayName = PanelBuilder.displayNameOf(component);
    node.isRuleHidden =
      PanelBuilder.isRuleHidden(component.hideOnRule, component.hidingRules, context);
    PanelBuilder.applyStyle(node, component, line);

    const descriptor: ComponentDescriptor | undefined = ComponentCatalog.find(component.id);
    if (descriptor === undefined) {
      node.isUnknown = true;
      node.hintText = `组件 id ${component.id} 没有被识别，设置原样保留在文件里。`;
      return node;
    }

    // 容器先递归：子节点用同一行的样式上下文，先算子再填自己，免得容器分支里
    // 提前 return 掉了子节点还没算。
    if (descriptor.isContainer) {
      if (depth + 1 >= MAX_DEPTH) {
        // 到顶就停。布局文件外部可写，一个环会让这里无限递归，表现为页面卡死
        // 且不报错 —— 用户连「文件坏了」都猜不到。
        node.isTruncated = true;
        return node;
      }
      for (const child of ComponentCatalog.childrenOf(component)) {
        node.children.push(
          PanelBuilder.nodeOf(child, line, profile, settings, now, depth + 1, context));
      }
      node.allChildrenHidden = PanelBuilder.allChildrenHiddenOf(node.children);
    }

    switch (node.kind) {
      case PanelNodeKind.CLOCK:
        PanelBuilder.fillClock(node, component, now);
        break;
      case PanelNodeKind.DATE:
        node.primaryText = PanelBuilder.dateText(now);
        break;
      case PanelNodeKind.TEXT:
        PanelBuilder.fillText(node, component);
        break;
      case PanelNodeKind.COUNT_DOWN:
        PanelBuilder.fillCountDown(node, component, profile, settings, now);
        break;
      case PanelNodeKind.SCHEDULE:
        PanelBuilder.fillSchedule(node, component, profile, settings, now);
        break;
      case PanelNodeKind.WEATHER:
        node.hintText = '天气要联网取数据，鸿蒙侧还没接上。';
        break;
      case PanelNodeKind.SEPARATOR:
        // 桌面版是一条 2×25 的竖线，纯装饰，没有文字。
        break;
      case PanelNodeKind.ROLLING:
        node.scrollSpeed = PanelBuilder.rollingSpeedOf(component);
        break;
      case PanelNodeKind.SLIDE:
        node.slideSeconds = PanelBuilder.slideSecondsOf(component);
        break;
      default:
        // 容器：primaryText 留空，界面只画子节点。
        break;
    }
    return node;
  }

  // ---------------------------------------------------------------- 样式

  /**
   * 把组件与行的样式合成到节点上。
   *
   * 合成规则照桌面版 ComponentPresenter.axaml + MainWindowLine.axaml：字号与前景
   * 色是「组件开了覆盖就用组件的，否则继承行」；背景色是「组件先看，没有就看行，
   * 都没有就不画」；圆角只看组件自己（桌面版行的 CustomCornerRadius 是给整行用的）。
   */
  private static applyStyle(node: PanelNode, component: ComponentSettings,
    line: MainWindowLineSettings): void {
    const override: boolean = component.isResourceOverridingEnabled;
    node.fontSize = override ? component.mainWindowBodyFontSize : line.mainWindowBodyFontSize;
    node.secondaryFontSize = override
      ? component.mainWindowSecondaryFontSize : line.mainWindowSecondaryFontSize;
    node.emphasisFontSize = override
      ? component.mainWindowEmphasizedFontSize : line.mainWindowEmphasizedFontSize;
    node.foregroundColor = PanelBuilder.foregroundOf(component, line);
    node.backgroundColor = PanelBuilder.backgroundOf(component, line);
    node.cornerRadius = component.isCustomCornerRadiusEnabled ? component.customCornerRadius : 0;
    node.opacity = PanelBuilder.clamp01(component.opacity);
    if (component.isCustomMarginEnabled) {
      node.marginLeft = Math.max(0, component.marginLeft);
      node.marginTop = Math.max(0, component.marginTop);
      node.marginRight = Math.max(0, component.marginRight);
      node.marginBottom = Math.max(0, component.marginBottom);
    }
    if (component.isFixedWidthEnabled) {
      node.widthKind = PanelWidthKind.FIXED;
      node.widthValue = Math.max(0, component.fixedWidth);
    } else if (component.isMinWidthEnabled) {
      node.widthKind = PanelWidthKind.MIN;
      node.widthValue = Math.max(0, component.minWidth);
    } else if (component.isMaxWidthEnabled) {
      node.widthKind = PanelWidthKind.MAX;
      node.widthValue = Math.max(0, component.maxWidth);
    } else {
      node.widthKind = PanelWidthKind.AUTO;
      node.widthValue = 0;
    }
    node.horizontalAlignment = component.horizontalAlignment;
  }

  private static foregroundOf(component: ComponentSettings,
    line: MainWindowLineSettings): string {
    if (component.isCustomForegroundColorEnabled) {
      return component.foregroundColor.toArkUi();
    }
    if (line.isCustomForegroundColorEnabled) {
      return line.foregroundColor.toArkUi();
    }
    return ColorValue.white().toArkUi();
  }

  /**
   * 背景色。
   *
   * 没开自定义背景色就返回空串而不是给个半透明黑：桌面版在这种情况下靠窗口底色
   * 透出来，给个默认黑底会让「没设背景」看起来像「设了黑底」。
   */
  private static backgroundOf(component: ComponentSettings,
    line: MainWindowLineSettings): string {
    if (component.isCustomBackgroundColorEnabled) {
      return PanelBuilder.tint(component.backgroundColor,
        component.isCustomBackgroundOpacityEnabled ? component.backgroundOpacity : 1);
    }
    if (line.isCustomBackgroundColorEnabled) {
      return PanelBuilder.tint(line.backgroundColor,
        line.isCustomBackgroundOpacityEnabled ? line.backgroundOpacity : 1);
    }
    return '';
  }

  private static lineBackgroundOf(line: MainWindowLineSettings): string {
    if (!line.isCustomBackgroundColorEnabled) {
      return '';
    }
    return PanelBuilder.tint(line.backgroundColor,
      line.isCustomBackgroundOpacityEnabled ? line.backgroundOpacity : 1);
  }

  /**
   * 给颜色套一个不透明度。0..1，越界夹住。
   *
   * 新建一个而不是改原对象的 a：颜色是落盘模型里的共享值，节点样式是在渲染时
   * 算出来的，就地改会把布局草稿也改了 —— 表现是「看一眼面板就把某个组件的
   * 背景色改了」，而且不保存也丢不掉。
   */
  private static tint(color: ColorValue, alpha: number): string {
    return new ColorValue(Math.round(PanelBuilder.clamp01(alpha) * 255),
      color.r, color.g, color.b).toArkUi();
  }

  private static clamp01(value: number): number {
    if (!Number.isFinite(value) || value < 0) {
      return 0;
    }
    return value > 1 ? 1 : value;
  }

  // ------------------------------------------------------------ 各类组件

  /**
   * 时钟。
   *
   * 冒号闪烁：桌面版在「不显示秒」时把 `HH:mm` 与 `HH` `mm` 两套 TextBlock 叠在
   * 一起，按秒数的奇偶切换谁可见（`CurrentTime.Second % 2 == 1`）。这里压成一个
   * 布尔交给界面，其余完全照抄。
   */
  private static fillClock(node: PanelNode, component: ComponentSettings,
    now: DateTimeValue): void {
    const payload: ClockPayload = ComponentCatalog.decode(component) as ClockPayload;
    const showSeconds: boolean = payload.showSeconds;
    const showSeparator: boolean = !payload.flashTimeSeparator || showSeconds ||
      now.second % 2 === 1;
    const hour: string = PanelBuilder.pad2(now.hour);
    const minute: string = PanelBuilder.pad2(now.minute);
    node.primaryText = showSeparator ? `${hour}:${minute}` : `${hour} ${minute}`;
    if (showSeconds) {
      node.primaryText += `:${PanelBuilder.pad2(now.second)}`;
    }
    node.fontSize = node.emphasisFontSize;
  }

  /**
   * 日期。抄桌面版的 `{0:ddd MM/dd}`，结果是「周六 09/26」。
   *
   * 用 weekDayName 而不是 weekDayShortName：后者是编辑页紧凑选择器用的单字「六」，
   * 对应的是 .NET 的 `d` 而不是 `ddd`。桌面版在 zh-CN 下的 AbbreviatedDayNames 是
   * 「周六」这种两字形，单字是 CJK 里另一套缩写习惯，两者不能互换。
   */
  private static dateText(now: DateTimeValue): string {
    return `${weekDayName(now.dayOfWeek())} ` +
      `${PanelBuilder.pad2(now.month)}/${PanelBuilder.pad2(now.day)}`;
  }

  /**
   * 文本组件。
   *
   * 这里覆盖 applyStyle 算出来的字号与前景色，是有意的：桌面版
   * `TextComponent.axaml` 把 `FontSize="{Binding Settings.FontSize}"` 直接绑在
   * TextBlock 上，那是**局部值**，在 Avalonia 的优先级链里压过
   * `ComponentPresenter` 用 DynamicResource 设的 `TextElement.FontSize`（继承值）。
   * 换句话说文本组件的 FontSize 一直是它自己的，行上的 MainWindowBodyFontSize 对
   * 它无效 —— 桌面版就是这样，不照抄的话鸿蒙侧会多出一个桌面版没有的「继承」行为。
   *
   * 前景色同理：`:custom-font-color` 选择器匹配时才设 Foreground，匹配不上就走继承。
   */
  private static fillText(node: PanelNode, component: ComponentSettings): void {
    const payload: TextPayload = ComponentCatalog.decode(component) as TextPayload;
    node.primaryText = payload.textContent;
    node.fontSize = payload.fontSize;
    if (payload.useCustomFontColor) {
      node.foregroundColor = payload.fontColor.toArkUi();
    }
  }

  /**
   * 倒计时。
   *
   * 顺序：先定起止时刻（CountdownSource 四档），再算剩余，最后套格式串。与桌面版
   * UpdateContent 一致，其中 delta 为负时夹到 0。
   */
  private static fillCountDown(node: PanelNode, component: ComponentSettings,
    profile: Profile | undefined, settings: EngineSettings, now: DateTimeValue): void {
    const payload: CountDownPayload = ComponentCatalog.decode(component) as CountDownPayload;
    const range: TimeRange = PanelBuilder.countDownRange(payload, profile, settings, now);
    let deltaSeconds: number = PanelBuilder.secondsBetween(now, range.end);
    if (deltaSeconds < 0) {
      deltaSeconds = 0;
    }
    const totalSeconds: number = Math.max(
      PanelBuilder.secondsBetween(range.start, range.end), MIN_SPAN_SECONDS);
    const remaining: string =
      PanelBuilder.formatCountDown(payload.customStringFormat, deltaSeconds, totalSeconds);

    // 桌面版是四段：TextBlockTo「距离」(l-instructive) → CountDownName(FontColor)
    // → CountDownConnector(l-instructive) → DaysLeft(FontColor)。前两段的
    // IsVisible 都绑在 `!IsCompactModeEnabled` 上，而名称那段没绑 —— 所以紧凑模式
    // 去掉的是「距离」和「连接词」，名称留着。照这个来，别顺手把名称也省了。
    node.prefixText = payload.isCompactModeEnabled ? '' : COUNTDOWN_PREFIX;
    node.nameText = payload.countDownName;
    node.connectorText = payload.isCompactModeEnabled ? '' : payload.countDownConnector;
    node.valueText = remaining;
    node.connectorEmphasized = payload.isConnectorColorEmphasized;
    node.foregroundColor = payload.fontColor.toArkUi();
    node.fontSize = payload.fontSize;
    node.progressMode = payload.progressBarMode;
    node.progressInverted = payload.isProgressInverted;
    node.primaryText = PanelBuilder.joinParts(
      node.prefixText, node.nameText, node.connectorText, node.valueText);
    if (payload.showProgress) {
      // 反向时填「已过」的比例，正向时填「剩余」的比例。桌面版
      // `value = Inverted ? end - now : now - start`。
      const value: number = payload.isProgressInverted
        ? deltaSeconds : totalSeconds - deltaSeconds;
      node.progressPercent = PanelBuilder.clampPercent((value / totalSeconds) * 100);
    }
  }

  /**
   * 倒计时的起止时刻。
   *
   * 四档对应桌面版的 GetTimeRangeFor{StaticTime,Cycle,Today,Week}。自然日口径
   * （NatureTimeUseMode）只在「今天 / 本周」两档有意义：0 用课表首末节课的时刻，
   * 1 用整天，2 课表找不到时不显示。
   */
  private static countDownRange(payload: CountDownPayload, profile: Profile | undefined,
    settings: EngineSettings, now: DateTimeValue): TimeRange {
    const source: number = payload.countdownSource;
    if (source === 0) {
      return TimeRange.of(payload.startTime, payload.overTime);
    }
    if (source === 1) {
      return PanelBuilder.cycleRange(payload, now);
    }
    if (source === 2) {
      const day: DayRange = PanelBuilder.dayRange(profile, settings, now.dateOnly());
      if (day.hasLayout) {
        return TimeRange.of(day.start, day.end);
      }
      if (payload.natureTimeUseMode === 2) {
        // 桌面版回退到 (DateTime.MinValue, DateTime.MinValue)，delta 夹成 0，
        // 格式串于是算出「0天」。这里给一个空区间，界面上会显示提示。
        return TimeRange.of(now, now);
      }
      return TimeRange.of(now.dateOnly(), now.dateOnly().addSeconds(SECONDS_PER_DAY));
    }
    if (source === 3) {
      return PanelBuilder.weekRange(payload, profile, settings, now);
    }
    return TimeRange.of(now, now);
  }

  /**
   * 周期倒计时。
   *
   * 桌面版：`cycles = min(floor((now - start) / totalDuration), 限次 ? CycleCountLimit
   * : ∞)`，区间是 `[start + cycles * totalDuration + before, +duration]`。限次那个
   * min 是有意的语义（数到第 N 轮就停在第 N 轮），不是防溢出。
   */
  private static cycleRange(payload: CountDownPayload, now: DateTimeValue): TimeRange {
    const start: DateTimeValue = payload.cycleStartTime;
    const before: number = payload.isAdvancedCycleTimingEnabled
      ? payload.cycleBeforeDuration.toSeconds() : 0;
    const duration: number = payload.cycleDuration.toSeconds();
    const total: number = before + duration +
      (payload.isAdvancedCycleTimingEnabled ? payload.cycleAfterDuration.toSeconds() : 0);
    if (total <= 0) {
      return TimeRange.of(start, start);
    }
    let cycles: number = Math.floor(PanelBuilder.secondsBetween(start, now) / total);
    if (payload.isCycleCountLimited && cycles > payload.cycleCountLimit) {
      cycles = payload.cycleCountLimit;
    }
    const timingStart: number = cycles * total + before;
    return TimeRange.of(start.addSeconds(timingStart), start.addSeconds(timingStart + duration));
  }

  /** 本周：从起始星期几的零点（或首节课）到周末那天的零点（或末节课结束）。 */
  private static weekRange(payload: CountDownPayload, profile: Profile | undefined,
    settings: EngineSettings, now: DateTimeValue): TimeRange {
    const today: DateTimeValue = now.dateOnly();
    const startDay: number = payload.isCustomWeekCountdownStartDayEnabled
      ? payload.weekCountdownStartDay : settings.singleWeekStartTime.dayOfWeek();
    const offset: number = (today.dayOfWeek() - startDay + 7) % 7;
    const weekStart: DateTimeValue = today.addDays(-offset);
    if (payload.natureTimeUseMode === 1) {
      return TimeRange.of(weekStart, weekStart.addSeconds(SECONDS_PER_DAY * 7));
    }
    const first: DayRange = PanelBuilder.dayRange(profile, settings, weekStart);
    const last: DayRange = PanelBuilder.dayRange(profile, settings, weekStart.addDays(6));
    if (first.hasLayout && last.hasLayout) {
      return TimeRange.of(first.start, last.end);
    }
    if (payload.natureTimeUseMode === 2) {
      return TimeRange.of(now, now);
    }
    return TimeRange.of(weekStart, weekStart.addSeconds(SECONDS_PER_DAY * 7));
  }

  /**
   * 某天的首末节课时刻。
   *
   * hasLayout 为 false 表示那天没有可用的课表（没选课表，或这张表当天没课）。区间
   * 退回那天的 0 点到 24 点，与桌面版 NatureTimeUseMode == 0 的 fallback 一致。
   */
  private static dayRange(profile: Profile | undefined, settings: EngineSettings,
    date: DateTimeValue): DayRange {
    const out: DayRange = new DayRange();
    out.start = date;
    out.end = date.addSeconds(SECONDS_PER_DAY);
    if (profile === undefined) {
      return out;
    }
    const resolved: ResolvedClassPlan = ClassPlanResolver.resolve(profile, date, settings);
    const plan: ClassPlan | undefined = resolved.plan;
    const layout: TimeLayout | undefined = plan === undefined ? undefined : plan.resolveTimeLayout();
    if (plan === undefined || layout === undefined) {
      return out;
    }
    const classes: TimeLayoutItem[] = [];
    for (const item of plan.validTimeLayoutItems()) {
      if (item.timeType === TIME_TYPE_CLASS) {
        classes.push(item);
      }
    }
    if (classes.length === 0) {
      return out;
    }
    out.hasLayout = true;
    out.start = date.addSeconds(classes[0].startTime.toSeconds());
    out.end = date.addSeconds(classes[classes.length - 1].endTime.toSeconds());
    return out;
  }

  /**
   * 课程表组件。
   *
   * 只排「今天」。「同时显示明天」是 P11 的事：它要处理跨零点的时刻表（第二节上
   * 到凌晨 1 点时，「明天」的课其实是今天这张表的延续）。在那之前把这个开关原样
   * 留着而界面上不列出来，比给一个算错的明天更诚实。
   */
  private static fillSchedule(node: PanelNode, component: ComponentSettings,
    profile: Profile | undefined, settings: EngineSettings, now: DateTimeValue): void {
    if (profile === undefined) {
      node.hintText = NO_PROFILE;
      return;
    }
    const payload: SchedulePayload = ComponentCatalog.decode(component) as SchedulePayload;
    const today: DateTimeValue = now.dateOnly();
    const nowSeconds: number = now.timeOfDaySeconds();
    const resolved: ResolvedClassPlan = ClassPlanResolver.resolve(profile, today, settings);
    const plan: ClassPlan | undefined = resolved.plan;
    const layout: TimeLayout | undefined = plan === undefined ? undefined : plan.resolveTimeLayout();
    if (plan === undefined || layout === undefined) {
      // 桌面版「今天没课」这个伪类是由 `CurrentClassPlan == null` 驱动的
      // （ScheduleComponent.axaml:18 的 Classes.TodayScheduleEmpty），而
      // CurrentClassPlan 为 null 同时包含「没选课表」与「今天这张表没课」两种情况，
      // 两者共用同一句占位文案。照抄这一点而不是自己分两种，是为了让用户改完设置后
      // 看到的结果与桌面版一致 —— 分成两句话本身没有错，但排查问题时「桌面版说没有课程
      // 而这边说没选课表」会让人怀疑是数据坏了。
      if (payload.showPlaceholderOnEmptyClassPlan) {
        node.hintText = payload.placeholderTextNoClass.length > 0
          ? payload.placeholderTextNoClass : NO_CLASS_TODAY;
      }
      return;
    }

    let sawAnyClass: boolean = false;
    let sawUpcoming: boolean = false;
    let lastEnd: number = -1;
    const items: TimeLayoutItem[] = plan.validTimeLayoutItems();
    for (let i: number = 0; i < items.length; i++) {
      const item: TimeLayoutItem = items[i];
      if (!item.isClass()) {
        continue;
      }
      const layoutIndex: number = layout.layouts.indexOf(item);
      const slot: number = plan.getClassIndex(layoutIndex);
      if (slot < 0 || slot >= plan.classes.length) {
        continue;
      }
      const info = plan.classes[slot];
      if (!info.isEnabled) {
        // 停用 = 这节课不上。摆在列表里等于骗用户。
        continue;
      }
      sawAnyClass = true;
      const startSeconds: number = item.startTime.toSeconds();
      const endSeconds: number = item.endTime.toSeconds();
      lastEnd = endSeconds;

      const isCurrent: boolean = nowSeconds >= startSeconds && nowSeconds < endSeconds;
      const isFinished: boolean = endSeconds <= nowSeconds;
      if (payload.showCurrentLessonOnlyOnClass && !isCurrent) {
        continue;
      }
      if (payload.hideFinishedClass && isFinished) {
        continue;
      }

      const lesson: PanelLesson = new PanelLesson();
      lesson.classSlot = slot;
      lesson.slotText = `第 ${slot + 1} 节`;
      lesson.rangeText =
        `${PanelBuilder.clockOf(startSeconds)}-${PanelBuilder.clockOf(endSeconds)}`;
      lesson.isChangedClass = info.isChangedClass;
      lesson.isCurrent = isCurrent;
      // 淡化与隐藏是两种诉求：淡化要保留这节课（用户要能回顾），隐藏才是不摆出来。
      lesson.isFinished = isFinished && payload.fadeCompletedClasses;
      // 「接下来第一节」= 列表里第一节还没开始也没结束的课。正在上的那节虽然也没
      // 结束，但它是「现在」不是「接下来」，所以跳过它 —— 与小组件同一个口径。
      if (!isCurrent && !isFinished && !sawUpcoming) {
        lesson.isNext = true;
        sawUpcoming = true;
      }

      const subject: Subject | undefined = ClassPlanResolver.subjectAt(profile, plan, slot);
      if (subject === undefined) {
        lesson.isEmpty = true;
        lesson.subjectName = EMPTY_SUBJECT_TEXT;
      } else {
        lesson.subjectName = subject.name.length > 0 ? subject.name : EMPTY_SUBJECT_TEXT;
        lesson.teacherName = subject.teacherName;
      }
      if (payload.showExtraInfoOnTimePoint) {
        lesson.extraText =
          PanelBuilder.extraInfo(payload.extraInfoType, startSeconds, endSeconds, nowSeconds);
      }
      if (payload.isCountdownEnabled && !isCurrent && !isFinished) {
        const left: number = startSeconds - nowSeconds;
        if (left >= 0 && left <= payload.countdownSeconds) {
          lesson.countdownText = `${left} 秒后上课`;
        }
      }
      if (isCurrent) {
        const span: number = Math.max(endSeconds - startSeconds, MIN_SPAN_SECONDS);
        lesson.progressPercent =
          PanelBuilder.clampPercent(((nowSeconds - startSeconds) / span) * 100);
      }
      node.lessons.push(lesson);
    }

    if (node.lessons.length > 0) {
      return;
    }
    if (!sawAnyClass) {
      if (payload.showPlaceholderOnEmptyClassPlan) {
        node.hintText = payload.placeholderTextNoClass.length > 0
          ? payload.placeholderTextNoClass : NO_CLASS_TODAY;
      }
      return;
    }
    if (!payload.showPlaceholderOnEmptyClassPlan) {
      return;
    }
    // 有课但一节都没摆出来，只可能是「今天已经上完了」或「只显示当前这节、而现在
    // 不在上课」。这两种要用不同文案 —— 都写「没有课程」的话，上完课回家看到它
    // 会说谎。
    const ended: boolean = lastEnd >= 0 && lastEnd <= nowSeconds;
    node.hintText = ended
      ? (payload.placeholderTextAllClassEnded.length > 0
        ? payload.placeholderTextAllClassEnded : ALL_CLASS_ENDED)
      : (payload.placeholderTextNoClass.length > 0
        ? payload.placeholderTextNoClass : NO_CLASS_TODAY);
  }

  /**
   * 时刻下方的补充说明。
   *
   * 六档对应桌面版 LessonControlExpanded.axaml 里按 DetailIndex 切换的六个
   * TextBlock。跨零点的课（第二节上到凌晨）会让 nowSeconds < startSeconds，先补
   * 一天再算。
   */
  private static extraInfo(kind: number, startSeconds: number, endSeconds: number,
    nowSeconds: number): string {
    let span: number = endSeconds - startSeconds;
    if (span <= 0) {
      span += SECONDS_PER_DAY;
    }
    let passed: number = nowSeconds - startSeconds;
    if (passed < 0) {
      passed += SECONDS_PER_DAY;
    }
    if (passed > span) {
      passed = span;
    }
    const left: number = span - passed;
    if (kind === 0) {
      return `${PanelBuilder.clockOf(startSeconds)}-${PanelBuilder.clockOf(endSeconds)}`;
    }
    if (kind === 1) {
      return PanelBuilder.clockOf(passed);
    }
    if (kind === 2) {
      return `-${PanelBuilder.clockOf(left)}`;
    }
    if (kind === 3) {
      return `${Math.round((passed / span) * 100)}%`;
    }
    if (kind === 4) {
      return `-${PanelBuilder.clockOf(Math.ceil(left))}`;
    }
    if (kind === 5) {
      return `-${PanelBuilder.clockOf(left)}`;
    }
    return '';
  }

  // ------------------------------------------------------------ 倒计时格式

  /**
   * 倒计时格式串。
   *
   * 抄桌面版 UpdateContent 的替换表，逐字对应：
   *
   *   %D 天数向上取整  %H 小时向上取整  %M 分钟向上取整  %S 秒向上取整
   *   %X 毫秒向上取整  %P 已过百分比取整  %p 已过百分比两位  %L 剩余百分比取整
   *   %d 天（截断）     %h 时（0..23）   %m 分（两位）      %s 秒（两位）
   *   %x 毫秒（三位）
   *
   * 大小写不是笔误：C# 的 Replace 大小写敏感，两组是不同的占位符 —— %M 是
   * 「还有 3 分钟」里的 3，%m 是「03」里的 03。用 split/join 而不是 replaceAll
   * 是因为 ArkTS 的 String.replaceAll 在部分版本上对 `%` 无特殊含义但对 `$` 有，
   * 而 %P 的替换值里本来就带 `$` 的概率不为零；split/join 没有这个问题。
   */
  static formatCountDown(format: string, deltaSeconds: number, totalSeconds: number): string {
    if (format.length === 0) {
      return '';
    }
    const clamped: number = Math.max(0, deltaSeconds);
    const millis: number = clamped * 1000;
    const used: number = totalSeconds <= 0 ? 0 : Math.min(clamped / totalSeconds, 1);
    const passedRatio: number = 1 - used;
    let out: string = format;
    out = out.split('%D').join(`${Math.ceil(clamped / SECONDS_PER_DAY)}`);
    out = out.split('%H').join(`${Math.ceil(clamped / 3600)}`);
    out = out.split('%M').join(`${Math.ceil(clamped / 60)}`);
    out = out.split('%S').join(`${Math.ceil(clamped)}`);
    out = out.split('%X').join(`${Math.ceil(millis)}`);
    out = out.split('%P').join(`${Math.round(passedRatio * 100)}%`);
    out = out.split('%p').join(`${PanelBuilder.fixed2(passedRatio * 100)}%`);
    out = out.split('%L').join(`${Math.round(used * 100)}%`);
    out = out.split('%d').join(`${Math.floor(clamped / SECONDS_PER_DAY)}`);
    out = out.split('%h').join(`${Math.floor(clamped / 3600) % 24}`);
    out = out.split('%m').join(PanelBuilder.pad2(Math.floor(clamped / 60) % 60));
    out = out.split('%s').join(PanelBuilder.pad2(Math.floor(clamped) % 60));
    out = out.split('%x').join(PanelBuilder.pad3(Math.floor(millis) % 1000));
    return out;
  }

  // ---------------------------------------------------------------- 杂项

  /** 组件 GUID → 节点种类。未知返回 UNKNOWN。 */
  private static kindOf(guid: string): string {
    switch (guid.toLowerCase()) {
      case COMPONENT_CLOCK:
        return PanelNodeKind.CLOCK;
      case COMPONENT_DATE:
        return PanelNodeKind.DATE;
      case COMPONENT_TEXT:
        return PanelNodeKind.TEXT;
      case COMPONENT_COUNTDOWN:
        return PanelNodeKind.COUNT_DOWN;
      case COMPONENT_SCHEDULE:
        return PanelNodeKind.SCHEDULE;
      case COMPONENT_WEATHER:
        return PanelNodeKind.WEATHER;
      case COMPONENT_SEPARATOR:
        return PanelNodeKind.SEPARATOR;
      case COMPONENT_GROUP:
        return PanelNodeKind.GROUP;
      case COMPONENT_STACK:
        return PanelNodeKind.STACK;
      case COMPONENT_ROLLING:
        return PanelNodeKind.ROLLING;
      case COMPONENT_SLIDE:
        return PanelNodeKind.SLIDE;
      default:
        return PanelNodeKind.UNKNOWN;
    }
  }

  /**
   * 显示名。
   *
   * 查不到内置名就用 NameCache，再不行用 GUID 前 8 位。逐级退化，从不为空串 ——
   * 空串会让界面上出现一个什么都没写的按钮，用户点了不知道发生了什么。
   */
  static displayNameOf(component: ComponentSettings): string {
    const descriptor: ComponentDescriptor | undefined = ComponentCatalog.find(component.id);
    if (descriptor !== undefined) {
      return descriptor.name;
    }
    if (component.nameCache.length > 0) {
      return component.nameCache;
    }
    return component.id.length > 8 ? component.id.substring(0, 8) : component.id;
  }

  /**
   * 递归取一个节点的签名，用于整体比较。
   *
   * 公开是因为 PanelModel.buildSignature 要调它，而那是 PanelModel 的方法 ——
   * ArkTS 没有友元，放成私有就编不过。签名本身是纯函数，公开出去也无害。
   */
  static signatureOf(nodes: PanelNode[]): string {
    let out: string = '';
    for (const node of nodes) {
      // isRuleHidden / allChildrenHidden 必须进指纹。课表状态一变，被规则藏掉的
      // 那个组件就可能换人，而这类组件（文本、倒计时以外的）内容往往一个字都没
      // 变 —— 不进指纹的话内容没变、隐藏状态变了，面板就不重绘，藏起来的那个
      // 要等到下一次别的内容变化才跟着消失。
      out += `${node.guid},${node.kind},${node.isUnknown},${node.isTruncated},` +
        `${node.isRuleHidden},${node.allChildrenHidden},` +
        `${node.primaryText},${node.secondaryText},${node.detailText},${node.hintText},` +
        `${node.foregroundColor},${node.backgroundColor},${node.cornerRadius},${node.opacity},` +
        `${node.fontSize},${node.secondaryFontSize},${node.emphasisFontSize},` +
        `${node.widthKind},${node.widthValue},${node.horizontalAlignment},` +
        `${node.prefixText},${node.nameText},${node.connectorText},` +
        `${node.connectorEmphasized},${node.valueText},${node.progressMode},` +
        `${node.progressPercent},${node.progressInverted},` +
        `${node.scrollSpeed},${node.slideSeconds},` +
        `${node.marginLeft},${node.marginTop},${node.marginRight},${node.marginBottom};`;
      for (const lesson of node.lessons) {
        out += `L${lesson.classSlot},${lesson.slotText},${lesson.rangeText},` +
          `${lesson.subjectName},${lesson.teacherName},${lesson.extraText},` +
          `${lesson.countdownText},${lesson.isEmpty},${lesson.isChangedClass},` +
          `${lesson.isCurrent},${lesson.isNext},${lesson.isFinished},${lesson.progressPercent};`;
      }
      if (node.children.length > 0) {
        out += '{' + PanelBuilder.signatureOf(node.children) + '}';
      }
    }
    return out;
  }

  private static rollingSpeedOf(component: ComponentSettings): number {
    const payload: RollingPayload = ComponentCatalog.decode(component) as RollingPayload;
    // 0 会让内容不动，用户看到的是一个「滚不动的滚动容器」而界面上没有任何提示。
    return payload.speedPixelPerSecond === 0 ? 40 : payload.speedPixelPerSecond;
  }

  private static slideSecondsOf(component: ComponentSettings): number {
    const payload: SlidePayload = ComponentCatalog.decode(component) as SlidePayload;
    return payload.slideSeconds > 0 ? payload.slideSeconds : 15;
  }

  // ------------------------------------------------------------ 时间小工具

  /** 秒差。to - from。跨天时是负数，调用点自己决定怎么处理。 */
  private static secondsBetween(from: DateTimeValue, to: DateTimeValue): number {
    return (to.toLocalMillis() - from.toLocalMillis()) / 1000;
  }

  /** 秒 → HH:mm。与 TextFormat.formatClock 同形，单独一份是为了少引一个包。 */
  private static clockOf(seconds: number): string {
    const total: number = Math.max(0, Math.floor(seconds));
    return `${PanelBuilder.pad2(Math.floor(total / 3600) % 24)}:` +
      `${PanelBuilder.pad2(Math.floor(total / 60) % 60)}`;
  }

  /** 把几段文字用空格接起来，跳过空段。给 primaryText 用，签名与预览文案都靠它。 */
  private static joinParts(prefix: string, name: string, connector: string,
    value: string): string {
    const parts: string[] = [];
    if (prefix.length > 0) {
      parts.push(prefix);
    }
    if (name.length > 0) {
      parts.push(name);
    }
    if (connector.length > 0) {
      parts.push(connector);
    }
    if (value.length > 0) {
      parts.push(value);
    }
    return parts.join(' ');
  }

  private static pad2(value: number): string {
    const text: string = `${Math.floor(value)}`;
    return text.length >= 2 ? text : `0${text}`;
  }

  private static pad3(value: number): string {
    const text: string = `${Math.floor(value)}`;
    if (text.length >= 3) {
      return text;
    }
    return text.length === 2 ? `0${text}` : `00${text}`;
  }

  private static fixed2(value: number): string {
    return value.toFixed(2);
  }

  private static clampPercent(value: number): number {
    if (!Number.isFinite(value) || value < 0) {
      return 0;
    }
    return value > 100 ? 100 : value;
  }
}

/** 倒计时的起止区间。 */
class TimeRange {
  start: DateTimeValue = DateTimeValue.now();
  end: DateTimeValue = DateTimeValue.now();

  static of(start: DateTimeValue, end: DateTimeValue): TimeRange {
    const out: TimeRange = new TimeRange();
    out.start = start;
    out.end = end;
    return out;
  }
}

/** 某天的首末节课。hasLayout 为 false 表示那天没有可用课表。 */
class DayRange {
  hasLayout: boolean = false;
  start: DateTimeValue = DateTimeValue.now();
  end: DateTimeValue = DateTimeValue.now();
}
