/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 信息面板布局编辑的状态。
 *
 * 为什么单独一个 ViewModel，而不是挂在编辑页那个上面
 * -----------------------------------------------
 * 两边的草稿生命周期不同：档案草稿由「编辑课表」这个 Navigation 管，面板草稿
 * 由「信息面板」这个页面管。放同一个实例里的话，在面板里改布局会点亮编辑页的
 * 保存条（用户在另一个界面上看到「有未保存的改动」，却不知道自己做了什么），
 * 反过来也一样。两者还是两个文件：档案要与桌面版字节级往返，面板布局不能碰它。
 *
 * 改动层是唯一入口
 * ---------------
 * 界面不直接调 ComponentLayoutMutations。改动落到草稿上之后一律走 settle：
 * 重建视图行 → 刷脏标记 → 落提示。散在几十个点击回调里的话，漏一次 rebuild
 * 的表现是「点完没反应」，而漏一次脏标记的表现更糟 —— 改动在内存里生效了
 * 但保存条不亮，用户以为没改，关掉页面就丢了。
 *
 * 脏检查靠序列化比对
 * -----------------
 * 与档案编辑页同一套理由：布尔标志判不出「改了又改回原样」，而面板里这种
 * 操作很常见（把组件从 A 容器拖到 B 容器，又拖回来）。
 *
 * 组件没有身份，位置就是身份
 * -------------------------
 * 容器的子组件在 JSON 上只是 Settings.Children 里的一个元素，没有自己的 Id。
 * 所以所有操作都用「哪一行 + 逐层下标」定位，界面持有的也是下标而不是组件
 * 引用。代价是：一次改动之后所有指向旧下标的操作都要重算 —— 所以每次改动
 * 都整体重建视图行，界面每次都拿最新的下标，不缓存。
 */

import {
  ComponentProfile,
  ComponentSettings,
  DateTimeValue,
  JsonNode,
  MainWindowLineSettings,
  Profile,
  Ruleset,
  Subject,
  RulesetLogicalMode
} from 'common_shared';
import { t, tf } from 'common_core';
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
  ComponentLayoutMutations,
  ComponentLocation,
  ComponentPayload,
  EngineSettings,
  LessonsEngine,
  LessonsSnapshot,
  PanelBuilder,
  PanelModel,
  PanelNode,
  RuleChoiceRow,
  RuleContext,
  RuleSupport,
  RulesetEditModel,
  RulesetEditor,
  RulesetMutations
} from 'common_core';
import {
  ComponentLayoutRepository,
  DEFAULT_PANEL_SCHEME,
  isValidPanelScheme
} from '../data/ComponentLayoutRepository';
import { ProfileRepository } from '../data/ProfileRepository';
import { defaultEngineSettings } from '../common/AppSettings';
import { currentWeatherSnapshot } from '../weather/WeatherService';

/** 提示行显示多久（毫秒）。到点自动清空，避免旧提示一直挂着误导用户。 */
const STATUS_TTL_MS: number = 4000;

/**
 * 预览开着实时时钟时的重算间隔（毫秒）。
 *
 * 一秒一次，与桌面版面板的时钟节奏一致。面板节点是几十量级，整份重算的成本可以
 * 接受；真觉得卡，把这个数调大或干脆关掉实时开关。
 */
const CLOCK_TICK_MS: number = 1000;

/**
 * 布局最多展平多少层。
 *
 * 12 是随便取的：桌面版的容器只有分组/堆叠/滚动/轮播四种，实用上没人嵌过三层。
 * 取一个明确的数而不是「一直递归下去」，是为了让文件被改坏时有个确定的终点。
 */
const MAX_LAYOUT_DEPTH: number = 12;

/**
 * 可添加的组件类型。顺序即界面上显示的顺序。
 *
 * 导出是因为 addableComponents() 是 public 函数，返回它就得导出 —— ArkTS
 * 里导出函数用到了未导出的类型，调用点会拿不到这个类型。
 */
export interface AddableComponent {
  guid: string;
  name: string;
}

const ADDABLE: AddableComponent[] = [
  { guid: COMPONENT_DATE, name: t('clvm_date') },
  { guid: COMPONENT_CLOCK, name: t('clvm_clock') },
  { guid: COMPONENT_TEXT, name: t('clvm_text') },
  { guid: COMPONENT_COUNTDOWN, name: t('clvm_countdown') },
  { guid: COMPONENT_SCHEDULE, name: t('clvm_schedule') },
  { guid: COMPONENT_WEATHER, name: t('clvm_weather') },
  { guid: COMPONENT_SEPARATOR, name: t('clvm_separator') },
  { guid: COMPONENT_GROUP, name: t('clvm_group') },
  { guid: COMPONENT_STACK, name: t('clvm_stack') },
  { guid: COMPONENT_ROLLING, name: t('clvm_rolling') },
  { guid: COMPONENT_SLIDE, name: t('clvm_slide') }
];

/** 可添加的组件类型，供界面取用。返回副本，界面改了不会影响下一个人。 */
export function addableComponents(): AddableComponent[] {
  return ADDABLE.slice();
}

/** 一个行节点。 */
export class PanelLineRow {
  /** 第几行（0 基），界面上显示成「第 N 行」。 */
  lineIndex: number = 0;
  /** 行是否可见。落在 MainWindowLineSettings.IsVisible 上。 */
  isVisible: boolean = true;
  /** 是否开了「按规则隐藏」。 */
  hideOnRule: boolean = false;
  /** 规则当下成立，也就是这一行现在会被藏掉。 */
  isRuleHidden: boolean = false;
  /** 这一行有几个直接子组件。 */
  childCount: number = 0;
  /** 这一行有几个已注册的组件。未注册的单独计数，用于提示用户。 */
  knownCount: number = 0;
}

/** 一个组件节点。 */
export class PanelComponentRow {
  /** 定位。内部是数组拷贝，界面可以安全留着。 */
  location: ComponentLocation = ComponentLocation.of(0, []);
  /** 显示名。逐级退化，从不为空串。 */
  displayName: string = '';
  /** 组件类型 GUID。 */
  componentGuid: string = '';
  /** 是否已注册。未注册的只展示，不提供设置。 */
  isKnown: boolean = false;
  /** 是否是容器。容器才能往里加组件。 */
  isContainer: boolean = false;
  /**
   * 是否开了「按规则隐藏」。
   *
   * 这条是「隐藏规则成立」而不是「开关开着」——两者不同：开关开着但规则当下
   * 不成立时组件照常显示，界面上标成「正在被规则管着」比标成「已隐藏」准确。
   */
  hideOnRule: boolean = false;
  /** 规则当下成立，也就是这块内容现在会被藏掉。 */
  isRuleHidden: boolean = false;
  /** 缩进层数：0 是行的直接子组件。 */
  depth: number = 0;
  /** 同一层里是第几个。界面据此决定「前移/后移」该不该可点。 */
  siblingIndex: number = 0;
  /** 同一层里一共几个。 */
  siblingCount: number = 0;
  /**
   * 是否因为层数上限而没展开子组件。
   *
   * 只有容器会置位。界面上要标出来：让用户以为「这个容器是空的」比让他知道
   * 「这里有东西但太深了」更糟。
   */
  isTruncated: boolean = false;
}

/**
 * 「科目是」这条规则的一个候选。
 *
 * 放这里而不是 RulesetEditModel：那是规则编辑的行数据（规则集、组、规则），
 * 这一条是档案里的东西 —— 取自档案的科目表，不属于规则结构。
 */
export class RuleSubjectChoice {
  guid: string = '';
  name: string = '';
}

/**
 * 隐藏规则的宿主快照。
 *
 * 「按规则隐藏」这一对字段（HideOnRule / HidingRules）在桌面版挂在两个类上：
 * ComponentSettings 与 MainWindowLineSettings，字段名与语义一模一样。桌面版为
 * 两者各写一套 UI 后共用同一个 RulesetControl，所以这边也不把「改规则」绑死在
 * 某一类宿主上，而是先把这两个字段摘出来成一��快照，改完再按宿主类型写回去。
 *
 * 快照而不是引用：写回时组件可能已经被移走（同一帧里的另一次改动），
 * 拿着引用写会写到一个已经不属于布局的数组元素上。exists 标记就是给这种情况的 ——
 * 写不回时整次改动丢弃，界面上自然回到与布局一致的状态。
 *
 * 不加 @Trace：它是纯中转，界面从不观察它。改动的可见效果由 draft 经 settle()
 * 整体重建行数组带出来。
 */
class RuleHost {
  hideOnRule: boolean = false;
  hidingRules: JsonNode | undefined = undefined;
  /** 宿主还在不在。false 时这次改动要整个丢弃。 */
  exists: boolean = false;
}

@ObservedV2
export class ComponentLayoutViewModel {
  // ------------------------------------------------------------ 视图数据

  /** 行节点，按行序。整体替换。 */
  @Trace lines: PanelLineRow[] = [];

  /**
   * 组件节点，按「行 → 层内下标」展平。
   *
   * 展平而不是嵌套结构，是为了让 ArkUI 的 ForEach 只跑一层：嵌套深度由数据
   * 决定，递归渲染要靠 @Builder 递归调用，而 @Builder 只能间接一层。
   * 展平顺序天然是「行 → 从左到右 → 深度优先」，界面上按 depth 缩进即可。
   */
  @Trace components: PanelComponentRow[] = [];

  /** 当前方案名。 */
  @Trace schemeName: string = DEFAULT_PANEL_SCHEME;

  /** 可切换到的方案名，按名称升序。 */
  @Trace schemeNames: string[] = [];

  /** 是否有未保存的改动。 */
  @Trace isDirty: boolean = false;

  /** 底部提示行。空串表示不显示。 */
  @Trace statusText: string = '';

  /** 载入时是否出了错。非空表示磁盘上那份读不出来，当前看到的是临时草稿。 */
  @Trace loadErrorText: string = '';

  /**
   * 预览的渲染模型。
   *
   * 由 core 的 PanelBuilder 算出来，ArkUI 侧不碰 JSON。改一次草稿就整份替换 ——
   * 面板的节点是几十量级，比算清楚哪些节点变了更不容易出错（与 rebuild() 同理由）。
   */
  @Trace panelModel: PanelModel = new PanelModel();

  /**
   * 预览里的时钟要不要跟着走。
   *
   * 默认关着。开着就每秒重算一次整个面板：内容不变时 buildSignature 相同，
   * 界面只刷新时钟那一格；一旦开着面板卡顿，先看这里。
   */
  @Trace liveClock: boolean = false;

  // ---------------------------------------------------------------- 内部

  private readonly repository: ComponentLayoutRepository;
  private readonly profiles: ProfileRepository;
  private draft: ComponentProfile = ComponentProfile.defaultProfile();
  /** 基线：上次载入或保存时的序列化结果。 */
  private baseline: string = '';
  private statusTimer: number = -1;
  private loaded: boolean = false;
  private clockTimer: number = -1;
  /**
   * 预览用的课表档案缓存。
   *
   * 不加 @Trace：预览的整体替换是 panelModel 一个字段的事，档案本身换了引用也不会
   * 有人单独观察它。读盘的时机见 reloadProfileForPreview()。
   */
  private previewProfile: Profile | undefined = undefined;

  constructor(repository: ComponentLayoutRepository, profiles: ProfileRepository) {
    this.repository = repository;
    this.profiles = profiles;
  }

  // ------------------------------------------------------------ 载入保存

  /**
   * 载入布局。只在首次调用时生效。
   *
   * 重复调用会丢掉未保存的改动，所以第二次起直接返回。要重新读取请走 reload()，
   * 那条路会先问用户。
   */
  load(schemeName: string): void {
    if (this.loaded) {
      return;
    }
    const name: string = isValidPanelScheme(schemeName) ? schemeName : DEFAULT_PANEL_SCHEME;
    this.schemeName = name;
    try {
      this.draft = this.repository.load(name);
      this.loadErrorText = '';
    } catch (err) {
      // 读不出来时也给出可用的草稿：空布局能让人从零开始排，而不是对着一屏
      // 错误提示发呆。草稿不会自动保存，除非用户自己点保存。
      this.draft = ComponentProfile.defaultProfile();
      this.loadErrorText = t('clv_load_failed');
    }
    this.baseline = ComponentProfile.stringify(this.draft);
    this.loaded = true;
    this.refreshSchemeNames();
    this.rebuild();
  }

  /** 方案列表是否已经拿到。界面用它决定要不要显示载入中的空态。 */
  hasLoaded(): boolean {
    return this.loaded;
  }

  private refreshSchemeNames(): void {
    const names: string[] = this.repository.list();
    if (names.indexOf(this.schemeName) < 0) {
      names.push(this.schemeName);
    }
    names.sort();
    this.schemeNames = names;
  }

  /**
   * 保存。成功返回 true。
   *
   * 保存失败不抛：界面需要据此显示「保存失败」而不是让整个页面崩掉。失败时
   * 草稿与基线都不动，于是保存条还亮着，用户可以再点一次。
   */
  save(): boolean {
    if (!this.loaded) {
      return false;
    }
    const text: string = ComponentProfile.stringify(this.draft);
    try {
      this.repository.save(this.schemeName, this.draft);
    } catch (err) {
      this.say(t('clvm_save_failed'));
      return false;
    }
    this.baseline = text;
    this.loadErrorText = '';
    this.refreshSchemeNames();
    this.rebuild();
    this.say(t('clv_saved'));
    return true;
  }

  /**
   * 从磁盘重读。丢弃未保存的改动。
   *
   * 界面在调之前必须先跟用户确认：这一下丢的是他刚排好的面板。
   */
  reload(): void {
    this.loaded = false;
    this.load(this.schemeName);
    this.say(t('clv_reloaded'));
  }

  /** 丢掉改动，回到上次载入或保存的状态。 */
  discardChanges(): void {
    this.draft = ComponentProfile.parse(this.baseline);
    this.rebuild();
    this.say(t('clv_discarded'));
  }

  // ------------------------------------------------------------ 方案切换

  /**
   * 切到另一个方案。
   *
   * 有未保存改动时直接返回 false 且不动任何状态：丢弃是界面该问用户的事，
   * 这里擅自换过去再换回来，用户会以为面板被改了。
   */
  switchScheme(name: string): boolean {
    if (!isValidPanelScheme(name) || name === this.schemeName || this.isDirty) {
      return false;
    }
    this.loaded = false;
    this.load(name);
    this.say(tf('clvm_switched', name));
    return true;
  }

  /**
   * 把当前草稿改名成一个新方案。
   *
   * 不落盘新方案 —— 切过去之后用户看到的是同一份内容，要不要保存由他决定。
   * 这跟桌面版「新建方案」的语义一致：先有一份可编辑的东西，再谈落盘。
   */
  duplicateScheme(name: string): boolean {
    if (!isValidPanelScheme(name) || this.schemeNames.indexOf(name) >= 0) {
      return false;
    }
    this.schemeName = name;
    this.rebuild();
    this.say(tf('clvm_duplicated', name));
    return true;
  }

  /** 删掉一个方案。当前方案不能删 —— 那会让用户连回退的地方都没有。 */
  removeScheme(name: string): boolean {
    if (name === this.schemeName || !isValidPanelScheme(name)) {
      return false;
    }
    try {
      this.repository.remove(name);
    } catch (err) {
      this.say(t('clvm_delete_failed'));
      return false;
    }
    this.refreshSchemeNames();
    this.say(tf('clvm_deleted', name));
    return true;
  }

  // ------------------------------------------------------------ 行的改动

  addLine(afterIndex: number): void {
    if (!ComponentLayoutMutations.addLine(this.draft, afterIndex + 1)) {
      return;
    }
    this.settle(t('clv_row_added'));
  }

  removeLine(lineIndex: number): void {
    if (!ComponentLayoutMutations.removeLine(this.draft, lineIndex)) {
      return;
    }
    this.settle(t('clv_row_deleted'));
  }

  /**
   * 移动一行。to 是移动完成后的下标。
   *
   * 界面把「上移」「下移」翻成这个参数，所以这里不做 ±1 的换算 —— 那种换算
   * 在首行/末行上要额外判断，写在界面里就散了。
   */
  moveLine(from: number, to: number): void {
    if (!ComponentLayoutMutations.moveLine(this.draft, from, to)) {
      return;
    }
    this.settle(t('clv_row_reordered'));
  }

  toggleLineVisible(lineIndex: number): void {
    if (lineIndex < 0 || lineIndex >= this.draft.lines.length) {
      return;
    }
    const line: MainWindowLineSettings = this.draft.lines[lineIndex];
    line.isVisible = !line.isVisible;
    this.settle(line.isVisible ? t('clv_row_visible') : t('clv_row_hidden'));
  }

  // ---------------------------------------------------------- 组件的改动

  /**
   * 加一个组件。
   *
   * @param target 加到哪里。path 为空表示加到行里，否则加到 path 指向的容器里。
   *        目标不是容器时返回 false —— 静默加到行首的话，用户以为组件进了
   *        容器，结果它出现在行的最前面，位置完全对不上。
   */
  addComponent(target: ComponentLocation, guid: string): boolean {
    if (!ComponentCatalog.isKnown(guid)) {
      return false;
    }
    const component: ComponentSettings = ComponentCatalog.create(guid);
    if (!ComponentLayoutMutations.addComponent(this.draft, target, component)) {
      this.say(t('clvm_add_not_container'));
      return false;
    }
    this.settle(tf('clvm_added', ComponentCatalog.displayNameOf(component)));
    return true;
  }

  removeComponent(location: ComponentLocation): void {
    if (!ComponentLayoutMutations.removeComponent(this.draft, location)) {
      return;
    }
    this.settle(t('clv_component_deleted'));
  }

  moveComponent(from: ComponentLocation, to: ComponentLocation, insertIndex: number): void {
    if (!ComponentLayoutMutations.moveComponent(this.draft, from, to, insertIndex)) {
      // 移动失败布局原样不变（改动层内部会回滚），所以这里只提示。
      // 最常见的原因是「移进自己的子孙」—— 那会形成环，面板会卡死。
      this.say(t('clv_cannot_move_into_self'));
      return;
    }
    this.settle(t('clv_component_moved'));
  }

  /**
   * 同层前移/后移一个组件。
   *
   * 与 moveComponent 分成两个方法，是因为界面在渲染出来之前就能算出该不该可点
   * （首项的「前移」是灰的），而那个判断需要知道同层总数，那是视图数据。
   */
  shiftSibling(location: ComponentLocation, delta: number): void {
    if (location.path.length === 0) {
      return;
    }
    const parent: ComponentLocation = ComponentLocation.of(location.lineIndex,
      location.path.slice(0, location.path.length - 1));
    this.moveComponent(location, parent,
      location.path[location.path.length - 1] + delta);
  }

  /** 把一个组件移出它所在的容器，放到行的末尾。 */
  moveOutToLine(location: ComponentLocation): void {
    if (location.path.length <= 1) {
      return;
    }
    this.moveComponent(location, ComponentLocation.of(location.lineIndex, []),
      this.draft.lines[location.lineIndex].children.length);
  }

  /**
   * 换掉某个位置上的组件类型。
   *
   * 保留 nameCache：那是用户自己起的名字，换了组件类型之后原来那个名字多半还是
   * 想留着的（比如把「文本」换成「倒计时」，但仍叫「午休倒计时」）。
   */
  replaceComponentAt(location: ComponentLocation, guid: string): boolean {
    if (!ComponentCatalog.isKnown(guid) || location.path.length === 0) {
      return false;
    }
    const current: ComponentSettings | undefined = this.componentAt(location);
    if (current === undefined) {
      return false;
    }
    const fresh: ComponentSettings = ComponentCatalog.create(guid);
    fresh.nameCache = current.nameCache;
    const parent: ComponentLocation = location.path.length === 1
      ? ComponentLocation.of(location.lineIndex, [])
      : ComponentLocation.of(location.lineIndex,
        location.path.slice(0, location.path.length - 1));
    const list: ComponentSettings[] = this.lineChildrenAt(parent);
    const index: number = location.path[location.path.length - 1];
    if (index < 0 || index >= list.length) {
      return false;
    }
    list[index] = fresh;
    if (parent.path.length === 0) {
      // 行的直接子列表是活数组，就地替换已经生效
      this.draft.lines[parent.lineIndex].children = list;
    } else {
      const holder: ComponentSettings | undefined = this.componentAt(parent);
      if (holder === undefined) {
        return false;
      }
      ComponentCatalog.setChildrenOf(holder, list);
    }
    this.settle(tf('clvm_replaced', ComponentCatalog.displayNameOf(fresh)));
    return true;
  }

  // ------------------------------------------------------------ 设置的读写

  /**
   * 取一个位置的组件。取不到返回 undefined。
   *
   * 空 path 指的是「行」这一层，不是某个组件，所以返回 undefined。要取行的
   * 直接子列表请用 lineChildrenAt。
   */
  componentAt(location: ComponentLocation): ComponentSettings | undefined {
    if (location.path.length === 0 ||
      location.lineIndex < 0 || location.lineIndex >= this.draft.lines.length) {
      return undefined;
    }
    let list: ComponentSettings[] = this.draft.lines[location.lineIndex].children;
    let node: ComponentSettings | undefined = undefined;
    for (const index of location.path) {
      node = list[index];
      if (node === undefined) {
        return undefined;
      }
      list = ComponentCatalog.childrenOf(node);
    }
    return node;
  }

  /**
   * 某个位置所在列表的内容。path 为空时是行的直接子列表（活数组本身）。
   *
   * 返回嵌套容器的子列表时给的是副本，改完必须走 setChildrenOf 写回 ——
   * 这条约束写在 ComponentLayoutMutations 的头注里。
   */
  lineChildrenAt(location: ComponentLocation): ComponentSettings[] {
    if (location.lineIndex < 0 || location.lineIndex >= this.draft.lines.length) {
      return [];
    }
    if (location.path.length === 0) {
      return this.draft.lines[location.lineIndex].children;
    }
    const parent: ComponentLocation = ComponentLocation.of(location.lineIndex,
      location.path.slice(0, location.path.length - 1));
    const holder: ComponentSettings | undefined = this.componentAt(parent);
    return holder === undefined ? [] : ComponentCatalog.childrenOf(holder);
  }

  /** 一个位置所在容器里有几个子组件。path 为空表示行。 */
  childCountOf(location: ComponentLocation): number {
    return this.lineChildrenAt(location).length;
  }

  /**
   * 读一个位置的设置视图。
   *
   * 嵌套位置的组件是刚从裸节点解析出来的副本，所以要配 writePayloadAt 用。
   */
  readPayloadAt(location: ComponentLocation): ComponentPayload {
    const component: ComponentSettings | undefined = this.componentAt(location);
    if (component === undefined) {
      return new ComponentPayload();
    }
    if (location.path.length === 1) {
      // 行的直接子组件就是活数组里的那个对象本身，改它就地生效
      return ComponentCatalog.decode(component);
    }
    // 嵌套的必须配 writePayloadAt 里的 encodeChild
    const holder: ComponentSettings | undefined = this.componentAt(
      ComponentLocation.of(location.lineIndex, location.path.slice(0, location.path.length - 1)));
    if (holder === undefined) {
      return new ComponentPayload();
    }
    return ComponentCatalog.decodeChild(holder, location.path[location.path.length - 1]);
  }

  /**
   * 写一个位置的设置。
   *
   * 嵌套位置必须走 encodeChild（内部已写回）。直接 encode 一个副本是无效操作，
   * 表现是「改了没反应」—— 见 ComponentCatalog.childrenOf 的头注。
   */
  writePayloadAt(location: ComponentLocation, payload: ComponentPayload): boolean {
    if (location.path.length === 1) {
      const direct: ComponentSettings | undefined = this.componentAt(location);
      if (direct === undefined) {
        return false;
      }
      ComponentCatalog.encode(direct, payload);
      this.settle('');
      return true;
    }
    const holder: ComponentSettings | undefined = this.componentAt(
      ComponentLocation.of(location.lineIndex, location.path.slice(0, location.path.length - 1)));
    if (holder === undefined) {
      return false;
    }
    if (!ComponentCatalog.encodeChild(holder, location.path[location.path.length - 1], payload)) {
      return false;
    }
    this.settle('');
    return true;
  }

  // ------------------------------------------------------------ 隐藏规则

  /**
   * 某个组件的规则编辑态。
   *
   * 每次现解不缓存：草稿上的 hidingRules 只有这一处真源（见 mutateRules），
   * 缓存一份就得多一套失效逻辑，而规则集是几十字节量级，解一次的成本可以忽略。
   */
  ruleModelFor(location: ComponentLocation): RulesetEditModel {
    return this.ruleModel(this.snapshotHost(location, false));
  }

  /** 某一行的规则编辑态。行的 HideOnRule / HidingRules 与组件同名同义。 */
  lineRuleModel(lineIndex: number): RulesetEditModel {
    return this.ruleModel(this.snapshotHost(ComponentLocation.of(lineIndex, []), true));
  }

  /** 规则选择器的 13 个选项（外加「还没挑」）。 */
  ruleChoices(): RuleChoiceRow[] {
    return RulesetEditor.choices();
  }

  /**
   * 「科目是」这条规则的候选科目。
   *
   * 取自预览用的那份档案，与 ruleContext() 是同一份 —— 换了档案、课表改了，
   * 编辑器里的科目列表与规则判定看到的就对不上了，而这种「规则用旧课表判」
   * 的错从界面上完全看不出来。
   *
   * 按名称排。档案里科目的存放顺序是 KeyedMap 的插入序，是用户历次改动的
   * 副产品，与「语文数学英语」这种习惯顺序没有半点关系，而一个每次打开顺序
   * 都不一样的下拉会被当成列表在乱跳。
   *
   * 没有档案时给空数组：界面上只显示「还没选课表」，不崩。
   */
  subjectChoices(): RuleSubjectChoice[] {
    const out: RuleSubjectChoice[] = [];
    if (this.previewProfile === undefined) {
      return out;
    }
    this.previewProfile.subjects.forEach((subject: Subject, guid: string) => {
      const row: RuleSubjectChoice = new RuleSubjectChoice();
      row.guid = guid;
      row.name = subject.name;
      out.push(row);
    });
    out.sort((a: RuleSubjectChoice, b: RuleSubjectChoice) => {
      const byName: number = a.name.localeCompare(b.name);
      return byName !== 0 ? byName : (a.guid < b.guid ? -1 : 1);
    });
    return out;
  }

  /**
   * 改一个组件的「按规则隐藏」开关。
   *
   * 关掉时把规则集本身也清掉。留着的话用户下次打开这个开关会看到一条
   * 自己从没设过的规则，以为是别人改的。
   */
  setHideOnRule(location: ComponentLocation, value: boolean): void {
    const host: RuleHost = this.snapshotHost(location, false);
    if (!host.exists) {
      return;
    }
    host.hideOnRule = value;
    if (!value) {
      host.hidingRules = undefined;
    }
    this.writeHost(host, location, false);
    this.settle(value ? t('clv_hide_rules_on') : t('clv_hide_rules_off'));
  }

  /** 改一行的「按规则隐藏」开关。 */
  setLineHideOnRule(lineIndex: number, value: boolean): void {
    const host: RuleHost = this.snapshotHost(ComponentLocation.of(lineIndex, []), true);
    if (!host.exists) {
      return;
    }
    host.hideOnRule = value;
    if (!value) {
      host.hidingRules = undefined;
    }
    this.writeHost(host, ComponentLocation.of(lineIndex, []), true);
    this.settle(value ? tf('clvm_line_rules_on', `${lineIndex + 1}`) : tf('clvm_line_rules_off', `${lineIndex + 1}`));
  }

  /**
   * 对某个宿主的规则集做一次改动。
   *
   * 「读出来 → 改 → 写回去」三步合成一个调用，中间的 Ruleset 对象不外泄。
   * 这么做的理由是规则集在草稿里存的是裸 JsonNode（未注册规则的设置要原样透传），
   * 不这样包一层的话每次改动都要在界面里手写这三步，漏掉写回就表现为
   * 「改了规则但存盘后没了」。
   */
  private mutateRules(location: ComponentLocation, isLine: boolean,
    mutate: (ruleset: Ruleset) => void): boolean {
    const host: RuleHost = this.snapshotHost(location, isLine);
    if (!host.exists) {
      return false;
    }
    if (!host.hideOnRule) {
      // 规则没开就没必要改：桌面版关掉 HideOnRule 时 HidingRules 也不参与求值，
      // 留着上次配的内容会让人以为它还在生效。
      return false;
    }
    const ruleset: Ruleset = host.hidingRules === undefined
      ? Ruleset.defaultRuleset() : Ruleset.parse(host.hidingRules);
    mutate(ruleset);
    host.hidingRules = ruleset.toJson();
    this.writeHost(host, location, isLine);
    this.settle('');
    return true;
  }

  setRulesetMode(location: ComponentLocation, isLine: boolean, mode: RulesetLogicalMode): void {
    this.mutateRules(location, isLine, (rs: Ruleset) => { RulesetMutations.setRulesetMode(rs, mode); });
  }

  setRulesetReversed(location: ComponentLocation, isLine: boolean, value: boolean): void {
    this.mutateRules(location, isLine, (rs: Ruleset) => { RulesetMutations.setRulesetReversed(rs, value); });
  }

  addRuleGroup(location: ComponentLocation, isLine: boolean, index: number): void {
    this.mutateRules(location, isLine, (rs: Ruleset) => { RulesetMutations.addGroup(rs, index); });
  }

  removeRuleGroup(location: ComponentLocation, isLine: boolean, index: number): void {
    this.mutateRules(location, isLine, (rs: Ruleset) => { RulesetMutations.removeGroup(rs, index); });
  }

  setRuleGroupMode(location: ComponentLocation, isLine: boolean, groupIndex: number,
    mode: RulesetLogicalMode): void {
    this.mutateRules(location, isLine, (rs: Ruleset) => {
      RulesetMutations.setGroupMode(rs, groupIndex, mode);
    });
  }

  setRuleGroupReversed(location: ComponentLocation, isLine: boolean, groupIndex: number,
    value: boolean): void {
    this.mutateRules(location, isLine, (rs: Ruleset) => {
      RulesetMutations.setGroupReversed(rs, groupIndex, value);
    });
  }

  setRuleGroupEnabled(location: ComponentLocation, isLine: boolean, groupIndex: number,
    value: boolean): void {
    this.mutateRules(location, isLine, (rs: Ruleset) => {
      RulesetMutations.setGroupEnabled(rs, groupIndex, value);
    });
  }

  addRule(location: ComponentLocation, isLine: boolean, groupIndex: number, index: number,
    ruleId: string): void {
    this.mutateRules(location, isLine, (rs: Ruleset) => {
      RulesetMutations.addRule(rs, groupIndex, index, ruleId);
    });
  }

  removeRule(location: ComponentLocation, isLine: boolean, groupIndex: number, ruleIndex: number): void {
    this.mutateRules(location, isLine, (rs: Ruleset) => {
      RulesetMutations.removeRule(rs, groupIndex, ruleIndex);
    });
  }

  moveRule(location: ComponentLocation, isLine: boolean, groupIndex: number, from: number,
    to: number): void {
    this.mutateRules(location, isLine, (rs: Ruleset) => {
      RulesetMutations.moveRule(rs, groupIndex, from, to);
    });
  }

  setRuleId(location: ComponentLocation, isLine: boolean, groupIndex: number, ruleIndex: number,
    ruleId: string): void {
    this.mutateRules(location, isLine, (rs: Ruleset) => {
      RulesetMutations.setRuleId(rs, groupIndex, ruleIndex, ruleId);
    });
  }

  setRuleReversed(location: ComponentLocation, isLine: boolean, groupIndex: number, ruleIndex: number,
    value: boolean): void {
    this.mutateRules(location, isLine, (rs: Ruleset) => {
      RulesetMutations.setRuleReversed(rs, groupIndex, ruleIndex, value);
    });
  }

  /** 写回一条规则的强类型设置。 */
  writeRuleSettings(location: ComponentLocation, isLine: boolean, groupIndex: number,
    ruleIndex: number, settings: Object): void {
    this.mutateRules(location, isLine, (rs: Ruleset) => {
      RulesetMutations.writeSettings(rs, groupIndex, ruleIndex, settings);
    });
  }

  /**
   * 求值用的上下文。
   *
   * 与 refreshPreview() 喂给 PanelBuilder 的是同一份（同一份 previewProfile、
   * 同一份引擎参数、同一时刻读一次 now），所以编辑器里看到的结论与预览里
   * 组件消失与否必然一致。两边分开算的话，会出现「预览里已经藏了，编辑器里
   * 却说规则不成立」，用户根本没法判断该信哪个。
   */
  private ruleContext(): RuleContext {
    const now: DateTimeValue = DateTimeValue.now();
    const context: RuleContext = new RuleContext();
    context.now = now;
    context.profile = this.previewProfile;
    context.snapshot = this.previewProfile === undefined
      ? new LessonsSnapshot()
      : LessonsEngine.compute(this.previewProfile, defaultEngineSettings(now), now);
    context.weather = currentWeatherSnapshot();
    return context;
  }

  private ruleModel(host: RuleHost): RulesetEditModel {
    if (!host.exists) {
      return new RulesetEditModel();
    }
    const ruleset: Ruleset = host.hidingRules === undefined
      ? Ruleset.defaultRuleset() : Ruleset.parse(host.hidingRules);
    // 没开开关时不求值：界面上整块是收起的，给一组「无」比给一份会变的结论
    // 少一处让人以为它在生效的地方。
    return RulesetEditor.build(ruleset, host.hideOnRule ? this.ruleContext() : undefined);
  }

  /** 读出宿主的两个规则字段。组件不存在时 exists 为 false。 */
  private snapshotHost(location: ComponentLocation, isLine: boolean): RuleHost {
    const host: RuleHost = new RuleHost();
    if (isLine) {
      const index: number = location.lineIndex;
      if (index < 0 || index >= this.draft.lines.length) {
        return host;
      }
      const line: MainWindowLineSettings = this.draft.lines[index];
      host.hideOnRule = line.hideOnRule;
      host.hidingRules = line.hidingRules;
      host.exists = true;
      return host;
    }
    const component: ComponentSettings | undefined = this.componentAt(location);
    if (component === undefined) {
      return host;
    }
    host.hideOnRule = component.hideOnRule;
    host.hidingRules = component.hidingRules;
    host.exists = true;
    return host;
  }

  /** 把宿主的两个规则字段写回。写不回（位置已不存在）时不动草稿。 */
  private writeHost(host: RuleHost, location: ComponentLocation, isLine: boolean): void {
    if (isLine) {
      const index: number = location.lineIndex;
      if (index < 0 || index >= this.draft.lines.length) {
        return;
      }
      const line: MainWindowLineSettings = this.draft.lines[index];
      line.hideOnRule = host.hideOnRule;
      line.hidingRules = host.hidingRules;
      return;
    }
    const component: ComponentSettings | undefined = this.componentAt(location);
    if (component === undefined) {
      return;
    }
    component.hideOnRule = host.hideOnRule;
    component.hidingRules = host.hidingRules;
  }

  /** 改一个组件的自定义名。 */
  setNameCache(location: ComponentLocation, name: string): void {
    const component: ComponentSettings | undefined = this.componentAt(location);
    if (component === undefined) {
      return;
    }
    component.nameCache = name;
    this.settle('');
  }

  /** 某一行能不能再往上/往下移。界面据此把按钮灰掉。 */
  canMoveLine(lineIndex: number, delta: number): boolean {
    const target: number = lineIndex + delta;
    return target >= 0 && target < this.draft.lines.length;
  }

  /** 某一行下的组件（已展平，按容器深度优先）。界面按行取。 */
  rowsInLine(lineIndex: number): PanelComponentRow[] {
    const out: PanelComponentRow[] = [];
    for (const row of this.components) {
      if (row.location.lineIndex === lineIndex) {
        out.push(row);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- 内部

  /**
   * 改动的统一收尾。少调一次的表现是「点完没反应」或「保存条不亮」。
   */
  private settle(statusText: string): void {
    this.rebuild();
    if (statusText.length > 0) {
      this.say(statusText);
    }
  }

  /**
   * 整体重建视图行。
   *
   * 一次改动之后所有下标都可能变（移进容器会把一串组件的 path 全变），所以
   * 不用增量更新 —— 组件数量是几十量级，重建比算清楚哪些变了更不容易出错。
   *
   * 预览也在这里重排，而不是塞进 settle()：load / save / discardChanges /
   * duplicateScheme 这四条路是直接调 rebuild() 的（它们不走 settle，那套
   * 「改完给个提示」的语义对它们不适用），漏掉一处就表现为「换了方案，预览还
   * 停在旧方案上」。统一收在这里，少一个地方会忘。
   */
  private rebuild(): void {
    // 预览先排，规则状态随后从它里面取 —— 树里标的「正在被规则藏掉」与预览里
    // 组件消失与否必须是同一份结论。两边各算一次的话，会出现树上说没藏、预览里
    // 却空了一块，用户没法判断该信哪个。
    this.refreshPreview();

    const lineRows: PanelLineRow[] = [];
    const componentRows: PanelComponentRow[] = [];

    for (let i: number = 0; i < this.draft.lines.length; i++) {
      const line: MainWindowLineSettings = this.draft.lines[i];
      const row: PanelLineRow = new PanelLineRow();
      row.lineIndex = i;
      row.isVisible = line.isVisible;
      row.hideOnRule = line.hideOnRule;
      row.isRuleHidden = this.lineRuleHidden(i);
      row.childCount = line.children.length;
      let known: number = 0;
      for (const child of line.children) {
        if (ComponentCatalog.isKnown(child.id)) {
          known++;
        }
      }
      row.knownCount = known;
      this.walk(i, [], line.children, 0, componentRows);
      lineRows.push(row);
    }

    this.lines = lineRows;
    this.components = componentRows;
    this.isDirty = ComponentProfile.stringify(this.draft) !== this.baseline;
  }

  /**
   * 从预览模型里取某一行被规则藏了没有。
   *
   * 行被显式关掉（IsVisible=false）时压根没进预览模型，那种情况不算「被规则藏」——
   * 树里已经有独立的可见性开关在标它了，两处都标会让用户以为规则也在管它。
   */
  private lineRuleHidden(lineIndex: number): boolean {
    if (lineIndex < 0 || lineIndex >= this.panelModel.lines.length) {
      return false;
    }
    return this.panelModel.lines[lineIndex].isRuleHidden;
  }

  /** 从预览模型里按位置取节点，用来给树行标「正在被规则藏掉」。 */
  private nodeRuleHiddenAt(lineIndex: number, path: number[]): boolean {
    if (lineIndex < 0 || lineIndex >= this.panelModel.lines.length) {
      return false;
    }
    let level: PanelNode[] = this.panelModel.lines[lineIndex].nodes;
    let found: PanelNode | undefined = undefined;
    for (const step of path) {
      if (step < 0 || step >= level.length) {
        return false;
      }
      found = level[step];
      level = found.children;
    }
    return found !== undefined && found.isRuleHidden;
  }

  /**
   * 深度优先展平一层的子组件，追加到 out。
   *
   * depth 到 MAX_LAYOUT_DEPTH 就停手。改动层已经挡了「移进自己的子孙」，但布局
   * 文件是外部可写的，手改一份 JSON 就能造出环来；顺着环递归下去是无限递归，
   * 界面表现是页面直接卡死，而用户面对一个不响应也不报错的界面，连「文件坏了」
   * 都猜不到。停在固定深度上，环那一支就不展开，界面上会看到那一层是空的 ——
   * 所以那一行要标出「没展开」。
   */
  private walk(lineIndex: number, parentPath: number[], list: ComponentSettings[],
    depth: number, out: PanelComponentRow[]): void {
    for (let i: number = 0; i < list.length; i++) {
      const component: ComponentSettings = list[i];
      const path: number[] = parentPath.concat([i]);
      const row: PanelComponentRow = new PanelComponentRow();
      row.location = ComponentLocation.of(lineIndex, path);
      row.componentGuid = component.id;
      row.displayName = ComponentCatalog.displayNameOf(component);
      row.isKnown = ComponentCatalog.isKnown(component.id);
      row.isContainer = ComponentCatalog.find(component.id)?.isContainer === true;
      row.hideOnRule = component.hideOnRule;
      row.isRuleHidden = this.nodeRuleHiddenAt(lineIndex, path);
      row.depth = depth;
      row.siblingIndex = i;
      row.siblingCount = list.length;
      row.isTruncated = row.isContainer && depth + 1 >= MAX_LAYOUT_DEPTH;
      out.push(row);

      if (row.isContainer && !row.isTruncated) {
        this.walk(lineIndex, path, ComponentCatalog.childrenOf(component), depth + 1, out);
      }
    }
  }

  private say(text: string): void {
    this.statusText = text;
    if (this.statusTimer >= 0) {
      clearTimeout(this.statusTimer);
    }
    this.statusTimer = setTimeout(() => {
      this.statusTimer = -1;
      this.statusText = '';
    }, STATUS_TTL_MS);
  }

  // ------------------------------------------------------------------ 预览

  /**
   * 按当前草稿重算预览模型。
   *
   * 走的是与桌面版同一条路：core 的 PanelBuilder 把布局算成节点树，界面只消费
   * 结果。这里唯一需要自己拿的是「课表档案」与「引擎参数」。
   *
   * 档案读的是**磁盘上已保存**的那份，不看编辑页里没保存的草稿 —— 面板是另一个
   * 文件、另一份草稿，两边的未保存状态刻意不互相污染（同 pages/Panel.ets 顶上
   * 写的那条理由）。代价是：编辑页改了课表还没保存时，面板预览里看不到。
   */
  refreshPreview(): void {
    const now: DateTimeValue = DateTimeValue.now();
    const settings: EngineSettings = defaultEngineSettings(now);
    this.panelModel = PanelBuilder.build(this.draft, this.previewProfile, settings, now,
      currentWeatherSnapshot());
  }

  /**
   * 重读一次课表档案，再重排预览。
   *
   * 与 refreshPreview() 分开是因为读档案要解析整个 profile.json，而实时时钟每秒
   * 都会 refreshPreview() 一次 —— 每秒解析一遍档案是白扔的 CPU。档案只会在编辑页
   * 保存时变，所以重读交给「进面板页」这个时机（PanelPage.aboutToAppear）。
   *
   * 读失败不是面板的问题：预览照样能排（时间、日期、时钟都不依赖档案），只是课程表
   * 与倒计时会显示占位文案。刻意不抛 —— 抛了整页预览就没了，而用户真正要改的是布局。
   */
  reloadProfileForPreview(): void {
    let profile: Profile | undefined = undefined;
    try {
      if (this.profiles.exists()) {
        const loaded: Profile = this.profiles.load();
        // 与小组件同一个坑：load() 出来的那份派生状态是空的，要自己刷一遍
        loaded.refreshDerivedState();
        profile = loaded;
      }
    } catch (error) {
      profile = undefined;
    }
    this.previewProfile = profile;
    this.refreshPreview();
  }

  /**
   * 预览里的时钟开关。
   *
   * 开：每秒重算一次整个面板。开着卡的话先关它看看是不是这里。
   */
  setLiveClock(enabled: boolean): void {
    if (this.liveClock === enabled) {
      return;
    }
    this.liveClock = enabled;
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
    if (enabled) {
      this.clockTimer = setInterval(() => {
        this.refreshPreview();
      }, CLOCK_TICK_MS);
    }
  }

  /**
   * 丢弃页面时清掉提示定时器与时钟定时器。
   *
   * 不清的话定时器会一直挂着并持有 this，页面销毁后这个 ViewModel 仍被引用着。
   */
  dispose(): void {
    if (this.statusTimer >= 0) {
      clearTimeout(this.statusTimer);
      this.statusTimer = -1;
    }
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
  }
}
