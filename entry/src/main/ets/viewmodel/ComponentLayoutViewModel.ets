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

import { ComponentProfile, ComponentSettings, MainWindowLineSettings } from 'common_shared';
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
  ComponentPayload
} from 'common_core';
import {
  ComponentLayoutRepository,
  DEFAULT_PANEL_SCHEME,
  isValidPanelScheme
} from '../data/ComponentLayoutRepository';

/** 提示行显示多久（毫秒）。到点自动清空，避免旧提示一直挂着误导用户。 */
const STATUS_TTL_MS: number = 4000;

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
  { guid: COMPONENT_DATE, name: '日期' },
  { guid: COMPONENT_CLOCK, name: '时钟' },
  { guid: COMPONENT_TEXT, name: '文本' },
  { guid: COMPONENT_COUNTDOWN, name: '倒计时' },
  { guid: COMPONENT_SCHEDULE, name: '课程表' },
  { guid: COMPONENT_WEATHER, name: '天气简报' },
  { guid: COMPONENT_SEPARATOR, name: '分割线' },
  { guid: COMPONENT_GROUP, name: '分组容器' },
  { guid: COMPONENT_STACK, name: '堆叠容器' },
  { guid: COMPONENT_ROLLING, name: '滚动容器' },
  { guid: COMPONENT_SLIDE, name: '轮播容器' }
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
  /** 是否开了「按规则隐藏」。规则判定在 P8，这里只透出这个开关本身。 */
  hideOnRule: boolean = false;
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

  // ---------------------------------------------------------------- 内部

  private readonly repository: ComponentLayoutRepository;
  private draft: ComponentProfile = ComponentProfile.defaultProfile();
  /** 基线：上次载入或保存时的序列化结果。 */
  private baseline: string = '';
  private statusTimer: number = -1;
  private loaded: boolean = false;

  constructor(repository: ComponentLayoutRepository) {
    this.repository = repository;
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
      this.loadErrorText = '读不出信息面板布局，可能是文件损坏了。你看到的这份还没有保存。';
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
      this.say('保存失败：写入信息面板目录时出错');
      return false;
    }
    this.baseline = text;
    this.loadErrorText = '';
    this.refreshSchemeNames();
    this.rebuild();
    this.say('已保存');
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
    this.say('已重新读取');
  }

  /** 丢掉改动，回到上次载入或保存的状态。 */
  discardChanges(): void {
    this.draft = ComponentProfile.parse(this.baseline);
    this.rebuild();
    this.say('已丢弃改动');
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
    this.say(`已切换到「${name}」`);
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
    this.say(`已复制到「${name}」，保存后生效`);
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
      this.say('删除失败：文件删不掉');
      return false;
    }
    this.refreshSchemeNames();
    this.say(`已删除「${name}」`);
    return true;
  }

  // ------------------------------------------------------------ 行的改动

  addLine(afterIndex: number): void {
    if (!ComponentLayoutMutations.addLine(this.draft, afterIndex + 1)) {
      return;
    }
    this.settle('已加一行');
  }

  removeLine(lineIndex: number): void {
    if (!ComponentLayoutMutations.removeLine(this.draft, lineIndex)) {
      return;
    }
    this.settle('已删一行');
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
    this.settle('已调整行的顺序');
  }

  toggleLineVisible(lineIndex: number): void {
    if (lineIndex < 0 || lineIndex >= this.draft.lines.length) {
      return;
    }
    const line: MainWindowLineSettings = this.draft.lines[lineIndex];
    line.isVisible = !line.isVisible;
    this.settle(line.isVisible ? '这一行已显示' : '这一行已隐藏');
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
      this.say('加不进去：目标不是容器');
      return false;
    }
    this.settle(`已添加${ComponentCatalog.displayNameOf(component)}`);
    return true;
  }

  removeComponent(location: ComponentLocation): void {
    if (!ComponentLayoutMutations.removeComponent(this.draft, location)) {
      return;
    }
    this.settle('已删除组件');
  }

  moveComponent(from: ComponentLocation, to: ComponentLocation, insertIndex: number): void {
    if (!ComponentLayoutMutations.moveComponent(this.draft, from, to, insertIndex)) {
      // 移动失败布局原样不变（改动层内部会回滚），所以这里只提示。
      // 最常见的原因是「移进自己的子孙」—— 那会形成环，面板会卡死。
      this.say('移不过去：不能把容器移进它自己或它的子容器里');
      return;
    }
    this.settle('已移动组件');
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
    this.settle(`已换成${ComponentCatalog.displayNameOf(fresh)}`);
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

  /** 改一个组件的「按规则隐藏」开关。 */
  setHideOnRule(location: ComponentLocation, value: boolean): void {
    const component: ComponentSettings | undefined = this.componentAt(location);
    if (component === undefined) {
      return;
    }
    component.hideOnRule = value;
    if (!value) {
      // 关掉规则时把规则集本身也清掉。留着的话用户下次打开「按规则隐藏」会
      // 看到一条自己从没设过的规则，以为是别人改的。
      component.hidingRules = undefined;
    }
    this.settle(value ? '已按规则隐藏（规则判定尚未实现）' : '已取消按规则隐藏');
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
   */
  private rebuild(): void {
    const lineRows: PanelLineRow[] = [];
    const componentRows: PanelComponentRow[] = [];

    for (let i: number = 0; i < this.draft.lines.length; i++) {
      const line: MainWindowLineSettings = this.draft.lines[i];
      const row: PanelLineRow = new PanelLineRow();
      row.lineIndex = i;
      row.isVisible = line.isVisible;
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

  /**
   * 丢弃页面时清掉提示定时器。
   *
   * 不清的话定时器会一直挂着并持有 this，页面销毁后这个 ViewModel 仍被引用着。
   */
  dispose(): void {
    if (this.statusTimer >= 0) {
      clearTimeout(this.statusTimer);
      this.statusTimer = -1;
    }
  }
}
