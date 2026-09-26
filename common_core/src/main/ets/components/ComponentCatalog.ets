/*
 * 组件注册表。
 *
 * 为什么要自己写而不用反射
 * ----------------------
 * 桌面版靠 ComponentInfoAttribute + 反射扫描来注册。ArkTS 没有运行时反射
 * （而且就算有，从元数据里 new 出组件实例在小程序化运行时里也未必被允许），
 * 所以这里是显式的表。这跟 DI 容器手写工厂是同一个理由：注册表的价值在于
 * 「有一份能读懂的清单」，反射提供的灵活性这里一处都用不上。
 *
 * GUID 一个都不能改
 * ---------------
 * ComponentSettings.Id 是与桌面版档案对齐的唯一依据，改了就等于让用户在桌面版
 * 排好的面板全部变成「未识别组件」。11 个 GUID 取自各组件类上的
 * [ComponentInfo(...)]，落盘时统一小写（桌面版 Id 的 setter 会 ToLower）。
 *
 * Settings 的三种归属
 * ------------------
 *   1. 有设置对象（ComponentBase<T>，T 非空）—— decode 出强类型视图，可编辑
 *   2. 无设置对象（裸 ComponentBase：日期、分割线）—— Settings 恒为 null，
 *      桌面版读文件时对它们提前返回不动 Settings
 *   3. 容器（另加 [ContainerComponent]）—— 子组件在 Settings.Children
 *
 * 未注册的组件（插件带来的、或用户文件里手工塞的）不算错，只是查不到名字。
 * 面板上要显示成「未识别组件（GUID 前 8 位）」，而不是跳过 —— 跳过了用户会以为
 * 面板里少了个东西，却不知道它去了哪。
 */

import { ComponentSettings, JsonObject, JsonValue } from 'common_shared';
import {
  ClockPayload,
  ComponentPayload,
  ContainerPayload,
  CountDownPayload,
  RollingPayload,
  SchedulePayload,
  SlidePayload,
  TextPayload,
  WeatherPayload
} from './ComponentPayloads';

/** 11 个内置组件的 GUID（小写）。 */
export const COMPONENT_CLOCK: string = '9e1af71d-8f77-4b21-a342-448787104dd9';
export const COMPONENT_COUNTDOWN: string = '7c645d35-8151-48ba-b4ac-15017460d994';
export const COMPONENT_DATE: string = 'df3f8295-21f6-482e-bada-fa0e5f14bb66';
export const COMPONENT_GROUP: string = 'c911d762-107f-40c6-84cc-0146ab3c86b1';
export const COMPONENT_ROLLING: string = '70fcd5ea-3fae-4e06-aca2-4f4df47f9acd';
export const COMPONENT_SCHEDULE: string = '1db2017d-e374-4bc6-9d57-0b4adf03a6b8';
export const COMPONENT_SEPARATOR: string = 'ab0f26d5-9df6-4575-b844-73b04d0907c1';
export const COMPONENT_SLIDE: string = '7e19a113-d281-4f33-970a-834a0b78b5ad';
export const COMPONENT_STACK: string = '2d849ece-9f21-4c78-9434-415cfc283294';
export const COMPONENT_TEXT: string = 'ee8f66bd-c423-4e7c-ab46-aa9976b00e08';
export const COMPONENT_WEATHER: string = 'ca495086-e297-4beb-9603-c5c1c1a8551e';

/**
 * 一个已注册组件的元信息。
 *
 * 插件接入点就在这里：外部代码可以 register 一个自己的实现（见
 * ComponentCatalog.register），布局与面板对它一视同仁。
 */
export class ComponentDescriptor {
  guid: string = '';
  name: string = '';
  description: string = '';
  /**
   * 是否带设置对象。对应 C# 那边 `ComponentBase<T>` 的 T 是否非空。
   * 为 false 时 Settings 恒为 null，新建组件也不生成节点。
   */
  hasSettings: boolean = false;
  /** 是否容器。容器才有 Children。 */
  isContainer: boolean = false;
  /** 读出强类型设置视图。node 为 undefined 时返回默认实例。 */
  decode: (node: JsonObject | undefined) => ComponentPayload = (): ComponentPayload => {
    return new ComponentPayload();
  };

  static create(guid: string, name: string, description: string, hasSettings: boolean,
    isContainer: boolean, decode: (node: JsonObject | undefined) => ComponentPayload): ComponentDescriptor {
    const out: ComponentDescriptor = new ComponentDescriptor();
    out.guid = guid;
    out.name = name;
    out.description = description;
    out.hasSettings = hasSettings;
    out.isContainer = isContainer;
    out.decode = decode;
    return out;
  }
}

export class ComponentCatalog {
  private static descriptors: Map<string, ComponentDescriptor> = new Map<string, ComponentDescriptor>();
  /** 面板「添加组件」列表的顺序，与桌面版 ComponentsService 的注册顺序一致。 */
  private static order: string[] = [];

  /**
   * 注册一个组件。重复 GUID 抛错。
   *
   * 抛而不覆盖：桌面版的 Register 也是抛（"此组件id {} 已经被占用"）。覆盖的
   * 后果是同一个 GUID 在不同模块解析出不同实现，症状是面板上同一类组件时而正常
   * 时而空白，而日志里什么也没有。
   */
  static register(descriptor: ComponentDescriptor): void {
    if (ComponentCatalog.descriptors.has(descriptor.guid)) {
      throw new Error(`组件 id ${descriptor.guid} 已被占用`);
    }
    ComponentCatalog.descriptors.set(descriptor.guid, descriptor);
    ComponentCatalog.order.push(descriptor.guid);
  }

  static find(guid: string): ComponentDescriptor | undefined {
    return ComponentCatalog.descriptors.get(guid.toLowerCase());
  }

  /** 按注册顺序列出全部已注册组件。 */
  static all(): ComponentDescriptor[] {
    const out: ComponentDescriptor[] = [];
    for (const guid of ComponentCatalog.order) {
      const descriptor: ComponentDescriptor | undefined = ComponentCatalog.descriptors.get(guid);
      if (descriptor !== undefined) {
        out.push(descriptor);
      }
    }
    return out;
  }

  /** Id 与 NameCache 都为空时的占位名。 */
  static readonly UNKNOWN_NAME: string = '未识别组件';

  /**
   * 组件的显示名。
   *
   * 查不到时退回 NameCache（桌面版在组件未加载时也用它顶名字），再退回
   * GUID 前 8 位，最后才用固定占位名。逐级退化但**从不返回空串** —— 界面上
   * 一个空名字会占掉一整行宽，用户看不出那里本来有个组件，更看不出它丢了。
   */
  static displayNameOf(settings: ComponentSettings): string {
    const descriptor: ComponentDescriptor | undefined = ComponentCatalog.find(settings.id);
    if (descriptor !== undefined) {
      return descriptor.name;
    }
    if (settings.nameCache.length > 0) {
      return settings.nameCache;
    }
    return settings.id.length >= 8 ? settings.id.substring(0, 8) : ComponentCatalog.UNKNOWN_NAME;
  }

  /** 查不到时给个可读的说明，界面拿它做角标。 */
  static isKnown(guid: string): boolean {
    return ComponentCatalog.descriptors.has(guid.toLowerCase());
  }

  // ---- 实例化 --------------------------------------------------------

  /**
   * 新建一个组件实例。
   *
   * 对齐桌面版 ButtonAddComponentToTargetList_OnClick：它 new 出 ComponentSettings
   * 之后调 LoadComponentSettings，于是有设置对象的组件会立刻拿到一份默认实例。
   * 差别在于桌面版只对**顶层**组件这么做（LoadConfig 的循环是
   * Lines.SelectMany(x => x.Children)），嵌套的留着 null；这里对谁都一样，
   * 因为「新建」本来就是用户主动加的，桌面版在用户点开设置面板时同样会补上。
   */
  static create(guid: string): ComponentSettings {
    const normalized: string = guid.toLowerCase();
    const out: ComponentSettings = new ComponentSettings();
    out.id = normalized;
    const descriptor: ComponentDescriptor | undefined = ComponentCatalog.find(normalized);
    if (descriptor === undefined) {
      // 未注册的组件：Settings 留 null，桌面版读它时也是原样透传。
      return out;
    }
    out.nameCache = descriptor.name;
    if (descriptor.hasSettings) {
      const node: JsonObject = new JsonObject();
      // Children 先写：容器设置类的 C# 字段声明顺序都是 Children 打头
      // （GroupComponentSettings 只有它，Rolling/Slide 是 Children, Speed…, …）。
      // JsonObject.set 对新键是追加，所以顺序由这里的调用次序决定。
      if (descriptor.isContainer) {
        ContainerPayload.writeChildren(node, []);
      }
      descriptor.decode(node).applyTo(node);
      out.settings = node;
    }
    return out;
  }

  /** 读出强类型设置视图。组件未注册或没有设置时返回空 payload。 */
  static decode(settings: ComponentSettings): ComponentPayload {
    const descriptor: ComponentDescriptor | undefined = ComponentCatalog.find(settings.id);
    if (descriptor === undefined || !descriptor.hasSettings) {
      return new ComponentPayload();
    }
    return descriptor.decode(JsonValue.asObject(settings.settings));
  }

  /**
   * 把强类型视图写回组件。就地改键，Settings 为 null 时先建一个对象。
   *
   * 组件未注册时不动 Settings —— 我们读不懂它，就别碰它。
   */
  static encode(settings: ComponentSettings, payload: ComponentPayload): void {
    const descriptor: ComponentDescriptor | undefined = ComponentCatalog.find(settings.id);
    if (descriptor === undefined || !descriptor.hasSettings) {
      return;
    }
    let node: JsonObject | undefined = JsonValue.asObject(settings.settings);
    if (node === undefined) {
      node = new JsonObject();
      settings.settings = node;
    }
    payload.applyTo(node);
  }

  /**
   * 容器的直接子组件。
   *
   * **返回的是副本。** 子组件的 Settings 是从父节点的裸 JSON 里读出来的新对象，
   * 改它不会影响布局树。改了之后必须 setChildrenOf 写回，否则「改了没反应」。
   *
   * 唯一不需要写回的例外是行的直接子列表：那是 MainWindowLineSettings.children
   * 本身。但从调用方视角看两者行为不一致，所以统一按「要写回」写代码。
   * 需要一步到位的子组件设置读写用 encodeChild。
   */
  static childrenOf(settings: ComponentSettings): ComponentSettings[] {
    const descriptor: ComponentDescriptor | undefined = ComponentCatalog.find(settings.id);
    if (descriptor === undefined || !descriptor.isContainer) {
      return [];
    }
    return ContainerPayload.readChildren(JsonValue.asObject(settings.settings));
  }

  /** 读容器里第 index 个组件的设置视图。 */
  static decodeChild(settings: ComponentSettings, index: number): ComponentPayload {
    const child: ComponentSettings | undefined = ComponentCatalog.childrenOf(settings)[index];
    return child === undefined ? new ComponentPayload() : ComponentCatalog.decode(child);
  }

  /**
   * 写容器里第 index 个组件的设置。内部已写回。
   *
   * 与 encode 的区别就在这一处：encode 只改传进来的那个对象，而 childrenOf
   * 给的是副本，于是「读 childrenOf → 改 → encode」在嵌套组件上是无效操作。
   * 这两个方法并存就是踩了这个坑的代价，所以嵌套层级一律走 encodeChild。
   */
  static encodeChild(settings: ComponentSettings, index: number, payload: ComponentPayload): boolean {
    const children: ComponentSettings[] = ComponentCatalog.childrenOf(settings);
    const child: ComponentSettings | undefined = children[index];
    if (child === undefined) {
      return false;
    }
    ComponentCatalog.encode(child, payload);
    ComponentCatalog.setChildrenOf(settings, children);
    return true;
  }

  /** 替换容器的直接子组件。 */
  static setChildrenOf(settings: ComponentSettings, children: ComponentSettings[]): void {
    const descriptor: ComponentDescriptor | undefined = ComponentCatalog.find(settings.id);
    if (descriptor === undefined || !descriptor.isContainer) {
      return;
    }
    let node: JsonObject | undefined = JsonValue.asObject(settings.settings);
    if (node === undefined) {
      node = new JsonObject();
      settings.settings = node;
    }
    ContainerPayload.writeChildren(node, children);
  }
}

/** 一次性注册 11 个内置组件。 */
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_CLOCK, '时钟',
  '显示现在的时间，支持精确到秒。', true, false, (node: JsonObject | undefined): ComponentPayload => {
    return ClockPayload.decode(node ?? new JsonObject());
  }));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_COUNTDOWN, '倒计时',
  '显示距离某一天的倒计时。', true, false, (node: JsonObject | undefined): ComponentPayload => {
    return CountDownPayload.decode(node ?? new JsonObject());
  }));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_DATE, '日期',
  '显示今天的日期和星期。', false, false, (): ComponentPayload => new ComponentPayload()));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_GROUP, '分组容器',
  '将多个组件组合到一个组件中显示。', true, true, (): ComponentPayload => new ContainerPayload()));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_ROLLING, '滚动容器',
  '滚动显示组件内的内容。', true, true, (node: JsonObject | undefined): ComponentPayload => {
    return RollingPayload.decode(node ?? new JsonObject());
  }));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_SCHEDULE, '课程表',
  '显示当前的课程表信息。', true, false, (node: JsonObject | undefined): ComponentPayload => {
    return SchedulePayload.decode(node ?? new JsonObject());
  }));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_SEPARATOR, '分割线',
  '显示一个分割线，视觉上对组件进行分组。', false, false, (): ComponentPayload => new ComponentPayload()));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_SLIDE, '轮播容器',
  '轮播多个组件。', true, true, (node: JsonObject | undefined): ComponentPayload => {
    return SlidePayload.decode(node ?? new JsonObject());
  }));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_STACK, '堆叠容器',
  '将多个容器堆叠显示。', true, true, (): ComponentPayload => new ContainerPayload()));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_TEXT, '文本',
  '显示自定义文本。', true, false, (node: JsonObject | undefined): ComponentPayload => {
    return TextPayload.decode(node ?? new JsonObject());
  }));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_WEATHER, '天气简报',
  '显示当前的天气概况和气象预警。', true, false, (node: JsonObject | undefined): ComponentPayload => {
    return WeatherPayload.decode(node ?? new JsonObject());
  }));
