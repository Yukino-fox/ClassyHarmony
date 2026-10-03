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

import { t } from '../i18n/I18n';
import { ComponentSettings, JsonObject, JsonValue, ModelCodec } from 'common_shared';
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
  /**
   * 新建实例时先铺进去的设置（P12 清单里的 settings）。
   *
   * 内置组件恒为 undefined —— 它们的新建实例一律是「解码器的默认值写回去」，
   * 也就是桌面版 LoadComponentSettings 那个 new T()。扩展组件有值：作者在清单里
   * 声明的默认值必须真的生效，否则字段就成了摆设（作者写了、往返测试也过，
   * 但用户新建出来的东西不是他写的那样）。
   *
   * 铺在解码之前：解码器的 applyTo 会把没给的键补成自己的默认值，作者显式给的值
   * 因为已经在节点里而被保住。
   */
  defaultSettings: JsonObject | undefined = undefined;

  static create(guid: string, name: string, description: string, hasSettings: boolean,
    isContainer: boolean, decode: (node: JsonObject | undefined) => ComponentPayload,
    defaultSettings?: JsonObject): ComponentDescriptor {
    const out: ComponentDescriptor = new ComponentDescriptor();
    out.guid = guid;
    out.name = name;
    out.description = description;
    out.hasSettings = hasSettings;
    out.isContainer = isContainer;
    out.decode = decode;
    if (defaultSettings !== undefined) {
      out.defaultSettings = defaultSettings;
    }
    return out;
  }
}

export class ComponentCatalog {
  private static descriptors: Map<string, ComponentDescriptor> = new Map<string, ComponentDescriptor>();
  /** 面板「添加组件」列表的顺序，与桌面版 ComponentsService 的注册顺序一致。 */
  private static order: string[] = [];
  /** 扩展注册的 GUID（P12）。unregister 只认这里面的，其余一律拒。 */
  private static pluginGuids: Set<string> = new Set<string>();

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

  /**
   * 注册一个扩展带来的组件（P12）。
   *
   * 与 register 的区别只在两处：失败时**返回 false 而不是抛**，以及记下这个 GUID
   * 是扩展来的（好让 unregister 能认）。
   *
   * 为什么不抛：装载一批扩展时，一条冲突不该让整个装载过程中断。冲突的那一条
   * 跳过并报 issue，剩下的照装 —— 用户装了三个扩展，两个能用比三个都因为
   * 「第二个的 id 撞了」而装不上要好。
   */
  static registerPlugin(descriptor: ComponentDescriptor): boolean {
    if (ComponentCatalog.descriptors.has(descriptor.guid)) {
      return false;
    }
    ComponentCatalog.pluginGuids.add(descriptor.guid);
    ComponentCatalog.descriptors.set(descriptor.guid, descriptor);
    ComponentCatalog.order.push(descriptor.guid);
    return true;
  }

  /** 这个组件是不是扩展注册的。 */
  static isPlugin(guid: string): boolean {
    return ComponentCatalog.pluginGuids.has(guid.toLowerCase());
  }

  /** 摘掉全部扩展注册的组件。装载前调一次。 */
  static unregisterAllPlugins(): void {
    for (const guid of Array.from(ComponentCatalog.pluginGuids)) {
      ComponentCatalog.unregister(guid);
    }
    ComponentCatalog.pluginGuids.clear();
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
  static readonly UNKNOWN_NAME: string = t('component_unknown');

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
      // 起点是扩展声明的默认值（内置组件没有，从空节点起）。
      // 复制而不是直接用同一个 JsonObject：descriptor 是进程级静态的，
      // 共享同一个节点的话第一个用户改设置就会改到后来所有用户的组件上。
      const node: JsonObject = descriptor.defaultSettings === undefined
        ? new JsonObject()
        : ModelCodec.cloneNode(descriptor.defaultSettings) as JsonObject;
      // Children 先写：容器设置类的 C# 字段声明顺序都是 Children 打头
      // （GroupComponentSettings 只有它，Rolling/Slide 是 Children, Speed…, …）。
      // JsonObject.set 对新键是追加，所以顺序由这里的调用次序决定。
      // 声明里已经给了 Children 的（扩展作者可能预置子组件）不覆盖。
      if (descriptor.isContainer && !node.has('Children')) {
        ContainerPayload.writeChildren(node, []);
      }
      descriptor.decode(node).applyTo(node);
      out.settings = node;
    }
    return out;
  }

  /** 读出强类型设置视图。组件未注册或没有设置时返回空 payload。 */
  /**
   * 注销一个组件（P12 卸载扩展用）。内置组件不在这里。
   *
   * 没有「已注册但要留着标记」的中间态：卸载意味着这个组件不该再能被解析出来，
   * 面板上那些位置会立刻显示成「未识别组件（GUID 前 8 位）」。这与桌面版
   * 卸载插件后的表现一致 —— 用户看得出少了什么，而不是面板静默少一块。
   */
  static unregister(guid: string): boolean {
    const key: string = guid.toLowerCase();
    // 只允许摘扩展注册的。内置组件被摘掉之后没有任何东西会把它装回来，
    // 而这个函数是导出给插件卸载用的 —— 让它有能力拆掉内置 11 个，
    // 一次误用就足以让应用在没有扩展的环境里坏掉。
    if (!ComponentCatalog.pluginGuids.has(key)) {
      return false;
    }
    ComponentCatalog.pluginGuids.delete(key);
    ComponentCatalog.descriptors.delete(key);
    const next: string[] = [];
    for (const each of ComponentCatalog.order) {
      if (each !== key) {
        next.push(each);
      }
    }
    ComponentCatalog.order = next;
    return true;
  }

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

/**
 * 渲染类别名 → 解码器（P12 声明式组件的接入点）。
 *
 * 键就是 PLUGIN_COMPONENT_KINDS 那十个名字。清单里写 `payloadKind: "countdown"`
 * 就走这里取 CountDownPayload.decode。
 *
 * 为什么与内置注册分开列
 * --------------------
 * 内置那 11 条是「guid → 描述符」，声明式要的是「类别名 → 解码器」：前者带
 * GUID 与显示名（每条都不同），后者的解码器其实只有 8 种（date / separator 无设置，
 * 共用空 payload；group / stack 共用 ContainerPayload）。硬要把两边统一成一张表，
 * 就得让内置那 11 条也带上类别名 —— 而那个名字目前只存在于插件格式里，
 * 往内置模型上加工反而会让「类别」变成内置注册表要维护的不变量。
 */
const DECODER_BY_KIND: Map<string, (node: JsonObject | undefined) => ComponentPayload> =
  new Map<string, (node: JsonObject | undefined) => ComponentPayload>();

/** 登记一个渲染类别（P12 用）。内置那 11 条的类别在文件末尾统一登记。 */
function registerDecoderOfKind(kind: string,
  decode: (node: JsonObject | undefined) => ComponentPayload): void {
  DECODER_BY_KIND.set(kind, decode);
}

/** 取某类渲染类别的解码器。未知类别返回 undefined。 */
export function componentDecoderOfKind(kind: string): ((node: JsonObject | undefined) => ComponentPayload) | undefined {
  return DECODER_BY_KIND.get(kind);
}

/** 一次性注册 11 个内置组件。 */
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_CLOCK, t('component_clock'),
  t('component_clock_desc'), true, false, (node: JsonObject | undefined): ComponentPayload => {
    return ClockPayload.decode(node ?? new JsonObject());
  }));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_COUNTDOWN, t('component_countdown'),
  t('component_countdown_desc'), true, false, (node: JsonObject | undefined): ComponentPayload => {
    return CountDownPayload.decode(node ?? new JsonObject());
  }));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_DATE, t('component_date'),
  t('component_date_desc'), false, false, (): ComponentPayload => new ComponentPayload()));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_GROUP, t('component_group'),
  t('component_group_desc'), true, true, (): ComponentPayload => new ContainerPayload()));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_ROLLING, t('component_rolling'),
  t('component_rolling_desc'), true, true, (node: JsonObject | undefined): ComponentPayload => {
    return RollingPayload.decode(node ?? new JsonObject());
  }));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_SCHEDULE, t('component_schedule'),
  t('component_schedule_desc'), true, false, (node: JsonObject | undefined): ComponentPayload => {
    return SchedulePayload.decode(node ?? new JsonObject());
  }));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_SEPARATOR, t('component_separator'),
  t('component_separator_desc'), false, false, (): ComponentPayload => new ComponentPayload()));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_SLIDE, t('component_slide'),
  t('component_slide_desc'), true, true, (node: JsonObject | undefined): ComponentPayload => {
    return SlidePayload.decode(node ?? new JsonObject());
  }));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_STACK, t('component_stack'),
  t('component_stack_desc'), true, true, (): ComponentPayload => new ContainerPayload()));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_TEXT, t('component_text'),
  t('component_text_desc'), true, false, (node: JsonObject | undefined): ComponentPayload => {
    return TextPayload.decode(node ?? new JsonObject());
  }));
ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_WEATHER, t('component_weather'),
  t('component_weather_desc'), true, false, (node: JsonObject | undefined): ComponentPayload => {
    return WeatherPayload.decode(node ?? new JsonObject());
  }));

/**
 * 十个渲染类别的登记（P12 声明式组件的借用表）。
 *
 * 顺序与 PLUGIN_COMPONENT_KINDS 一致，便于对照。
 * date 与 separator 在内置里是「无设置」，这里给的解码器返回一个空 payload ——
 * 声明式组件一律带 settings 节点，解出空 payload 的效果与内置一致（面板按
 * payloadKind 分支渲染，不读字段）。
 */
registerDecoderOfKind('text', (node: JsonObject | undefined): ComponentPayload => {
  return TextPayload.decode(node ?? new JsonObject());
});
registerDecoderOfKind('clock', (node: JsonObject | undefined): ComponentPayload => {
  return ClockPayload.decode(node ?? new JsonObject());
});
registerDecoderOfKind('countdown', (node: JsonObject | undefined): ComponentPayload => {
  return CountDownPayload.decode(node ?? new JsonObject());
});
registerDecoderOfKind('date', (): ComponentPayload => new ComponentPayload());
registerDecoderOfKind('separator', (): ComponentPayload => new ComponentPayload());
registerDecoderOfKind('schedule', (node: JsonObject | undefined): ComponentPayload => {
  return SchedulePayload.decode(node ?? new JsonObject());
});
registerDecoderOfKind('rolling', (node: JsonObject | undefined): ComponentPayload => {
  return RollingPayload.decode(node ?? new JsonObject());
});
registerDecoderOfKind('slide', (node: JsonObject | undefined): ComponentPayload => {
  return SlidePayload.decode(node ?? new JsonObject());
});
registerDecoderOfKind('group', (): ComponentPayload => new ContainerPayload());
registerDecoderOfKind('stack', (): ComponentPayload => new ContainerPayload());
