/*
 * 声明式扩展清单：模型 + 编解码。
 *
 * 字段名用 camelCase（不是桌面版的 PascalCase）
 * ------------------------------------------
 * 桌面版一切落盘 JSON 都是 PascalCase，因为那边是 System.Text.Json 按 C# 属性名
 * 直接序列化出来的。扩展清单是**新格式**：它不是从桌面版抄来的数据，而是我们
 * 自己的规范。跟着 PascalCase 走只会让「哪些字段是跟桌面版对齐的」这个问题变得
 * 含混 —— 事实上没有任何字段需要对齐（P11c 的天气与 P11d 的公开状态用 camelCase
 * 也是同一个理由）。所以整份清单一律 camelCase。
 *
 * 五类条目的形状为什么各不相同
 * --------------------------
 * 它们在运行时被消费的地方本来就不同，捏成一个带一堆可空字段的万能条目只会让
 * 「这条到底声明了什么」在类型上变得不可判定：
 *   component               → 塞进 ComponentCatalog，形状 = 内置组件的哪一类 + 默认设置
 *   trigger                 → 塞进 TriggerCatalog，形状 = 一份日程
 *   action                  → 塞进 ActionCatalog，形状 = 一条要做的事
 *   notificationProvider    → 只登记元信息，设置页展示用（鸿蒙侧暂无自定义通知源运行时）
 *   theme                   → 一组颜色，映射到 ArkUI 配色
 *
 * 无法扩展的部分，写在文件头
 * --------------------------
 * ArkTS 没有运行时代码加载，所以一份声明能带来的**只有数据**。插件不能新增渲染
 * 代码、不能新增行动实现、不能碰网络与文件。声明式组件的做法是「拿一个内置渲染
 * 器 + 换一份默认设置」，这听起来抠，但它是这个平台上唯一能同时保住「用户能装东西」
 * 与「不引入任意代码执行」的路。
 */

import {
  JsonArray,
  JsonNode,
  JsonNumber,
  JsonObject,
  JsonReader,
  JsonString,
  JsonValue,
  JsonWriter,
  ModelCodec
} from 'common_shared';

/** 扩展条目类别。 */
export enum ExtensionKind {
  Component = 'component',
  Trigger = 'trigger',
  Action = 'action',
  NotificationProvider = 'notificationProvider',
  Theme = 'theme'
}

/** 五类条目在清单里的数组字段名。 */
export function extensionKindField(kind: ExtensionKind): string {
  switch (kind) {
    case ExtensionKind.Component:
      return 'components';
    case ExtensionKind.Trigger:
      return 'triggers';
    case ExtensionKind.Action:
      return 'actions';
    case ExtensionKind.NotificationProvider:
      return 'notificationProviders';
    default:
      return 'themes';
  }
}

/** 全部五类，按清单里的固定顺序。 */
export const EXTENSION_KINDS: ExtensionKind[] = [
  ExtensionKind.Component,
  ExtensionKind.Trigger,
  ExtensionKind.Action,
  ExtensionKind.NotificationProvider,
  ExtensionKind.Theme
];

/**
 * 声明式组件：借用某类内置渲染器，默认设置由扩展给。
 *
 * payloadKind 只能取内置的组件渲染类别（'text' / 'clock' / 'countdown' / 'date' /
 * 'separator' / 'schedule' / 'rolling' / 'slide' / 'group' / 'stack'）。它不是组件
 * GUID，而是渲染类别名 —— 扩展给的是「新 id + 老渲染器」，这样面板、小组件、
 * 编辑器三条路径都不需要为它加任何分支。
 */
export class ComponentExtension {
  /** 组件 GUID（小写 D 格式）。 */
  id: string = '';
  name: string = '';
  description: string = '';
  /** 借用哪一类内置渲染器。 */
  payloadKind: string = '';
  /** 新建这个组件时写进 Settings 的默认值。 */
  settings: JsonObject = new JsonObject();
}

/** 声明式触发器的日程类别。 */
export enum PluginScheduleKind {
  /** 没有日程（恒不触发）。装上就能看见，但不会响。 */
  None = 'none',
  /** cron 表达式，字段由 CronExpression 那套六段式解释。 */
  Cron = 'cron',
  /** 每天某个时刻（当日第几秒，0~86399）。 */
  DailyAt = 'dailyAt',
  /** 每 N 分钟整点（对当日秒数取模）。 */
  EveryMinutes = 'everyMinutes'
}

export class TriggerExtension {
  id: string = '';
  name: string = '';
  description: string = '';
  scheduleKind: PluginScheduleKind = PluginScheduleKind.None;
  /** Cron 类别时用的表达式。 */
  cronExpression: string = '';
  /** DailyAt 类别时的当日秒数。 */
  atSeconds: number = 0;
  /** EveryMinutes 类别时的分钟数，最小 1。 */
  everyMinutes: number = 0;
}

/** 声明式动作的类别。 */
export enum PluginActionKind {
  /** 没有动作（装上能看见，但跑起来什么也不做）。 */
  None = 'none',
  /** 发一条本地通知，标题与正文支持模板变量。 */
  Notification = 'notification',
  /** 改一项应用设置。键必须落在白名单里（沙箱）。 */
  ModifySetting = 'modifySetting'
}

export class ActionExtension {
  id: string = '';
  name: string = '';
  description: string = '';
  actionKind: PluginActionKind = PluginActionKind.None;
  /** Notification 类别：标题模板。 */
  title: string = '';
  /** Notification 类别：正文模板。 */
  content: string = '';
  /** Notification 类别：通知分类，取值与 NotificationCategory 同名。 */
  category: string = '';
  /** ModifySetting 类别：要改的设置键。 */
  settingKey: string = '';
  /** ModifySetting 类别：改成的值（按设置键的类型解释）。 */
  settingValue: string = '';
}

/**
 * 声明式通知提供者。
 *
 * 鸿蒙侧目前没有「插件自带通知生产者」的运行时（自定义通知源要执行代码才能取数，
 * 声明式做不到）。这一类只登记元信息：设置页能列出「这份扩展声明了一个通知源」，
 * 并说明它在本版本不生效。这不是留坑，是把「用户装了个东西但它什么都不做」这件事
 * 提前说清楚，而不是等到运行时报错。
 */
export class NotificationProviderExtension {
  id: string = '';
  name: string = '';
  description: string = '';
  /** 声明的类别，自由文本（'weather' / 'lesson' / ...）。 */
  providerKind: string = '';
  /** 声明它挂在哪个触发器上。只作展示，不参与求值。 */
  triggerId: string = '';
}

/** 声明式主题：mode + 一组颜色。 */
export class ThemeExtension {
  id: string = '';
  name: string = '';
  description: string = '';
  /** 'light' / 'dark' / 'both'。 */
  mode: string = 'both';
  /** 颜色名 → #RRGGBB 或 #AARRGGBB。 */
  colors: Map<string, string> = new Map<string, string>();
}

/** 一份扩展清单。 */
export class ExtensionManifest {
  id: string = '';
  name: string = '';
  version: string = '';
  apiVersion: string = '';
  author: string = '';
  description: string = '';
  homepage: string = '';
  components: ComponentExtension[] = [];
  triggers: TriggerExtension[] = [];
  actions: ActionExtension[] = [];
  notificationProviders: NotificationProviderExtension[] = [];
  themes: ThemeExtension[] = [];
}

/** 深拷贝一个 JSON 对象。 */
function cloneJsonObject(source: JsonObject): JsonObject {
  const cloned: JsonObject | undefined = JsonValue.asObject(ModelCodec.cloneNode(source));
  return cloned === undefined ? new JsonObject() : cloned;
}

export class ExtensionManifestCodec {
  // -------------------------------------------------------------- 读

  /** 从 JSON 文本解。顶层不是对象时返回 undefined。 */
  static parseText(text: string): ExtensionManifest | undefined {
    return ExtensionManifestCodec.parse(JsonReader.parse(text));
  }

  /** 从节点解。顶层不是对象时返回 undefined。 */
  static parse(node: JsonNode | undefined): ExtensionManifest | undefined {
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return undefined;
    }
    const out: ExtensionManifest = new ExtensionManifest();
    out.id = ModelCodec.string(obj, 'id', '');
    out.name = ModelCodec.string(obj, 'name', '');
    out.version = ModelCodec.string(obj, 'version', '');
    out.apiVersion = ModelCodec.string(obj, 'apiVersion', '');
    out.author = ModelCodec.string(obj, 'author', '');
    out.description = ModelCodec.string(obj, 'description', '');
    out.homepage = ModelCodec.string(obj, 'homepage', '');
    out.components = ModelCodec.readArray(obj, 'components',
      (item: JsonNode): ComponentExtension => ComponentExtensionCodec.parse(item));
    out.triggers = ModelCodec.readArray(obj, 'triggers',
      (item: JsonNode): TriggerExtension => TriggerExtensionCodec.parse(item));
    out.actions = ModelCodec.readArray(obj, 'actions',
      (item: JsonNode): ActionExtension => ActionExtensionCodec.parse(item));
    out.notificationProviders = ModelCodec.readArray(obj, 'notificationProviders',
      (item: JsonNode): NotificationProviderExtension => NotificationProviderExtensionCodec.parse(item));
    out.themes = ModelCodec.readArray(obj, 'themes',
      (item: JsonNode): ThemeExtension => ThemeExtensionCodec.parse(item));
    return out;
  }

  // -------------------------------------------------------------- 写

  /**
   * 序列化成 JSON 文本。
   *
   * indentSize 省略时紧凑输出；给出则按该宽度缩进（2 是给人看的清单文件的标准）。
   */
  static writeText(manifest: ExtensionManifest, indentSize: number = -1): string {
    return JsonWriter.write(ExtensionManifestCodec.write(manifest), indentSize);
  }

  /** 序列化成节点树。 */
  static write(manifest: ExtensionManifest): JsonObject {
    const out: JsonObject = new JsonObject();
    // 固定顺序写出，不按「哪个字段有值」决定顺序：清单是要给人和别的实现读的，
    // 稳定字段顺序让 diff 只剩真正改动的行。
    out.set('id', new JsonString(manifest.id));
    out.set('name', new JsonString(manifest.name));
    out.set('version', new JsonString(manifest.version));
    out.set('apiVersion', new JsonString(manifest.apiVersion));
    out.set('author', new JsonString(manifest.author));
    out.set('description', new JsonString(manifest.description));
    out.set('homepage', new JsonString(manifest.homepage));
    out.set('components', ComponentExtensionCodec.writeArray(manifest.components));
    out.set('triggers', TriggerExtensionCodec.writeArray(manifest.triggers));
    out.set('actions', ActionExtensionCodec.writeArray(manifest.actions));
    out.set('notificationProviders', NotificationProviderExtensionCodec.writeArray(
      manifest.notificationProviders));
    out.set('themes', ThemeExtensionCodec.writeArray(manifest.themes));
    return out;
  }
}

/** 内置组件渲染类别名。与 ComponentPayloads 的解码分支一一对应。 */
export const PLUGIN_COMPONENT_KINDS: string[] = [
  'text', 'clock', 'countdown', 'date', 'separator',
  'schedule', 'rolling', 'slide', 'group', 'stack'
];

export class ComponentExtensionCodec {
  static parse(node: JsonNode | undefined): ComponentExtension {
    const out: ComponentExtension = new ComponentExtension();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.id = ModelCodec.string(obj, 'id', '');
    out.name = ModelCodec.string(obj, 'name', '');
    out.description = ModelCodec.string(obj, 'description', '');
    out.payloadKind = ModelCodec.string(obj, 'payloadKind', '');
    const settings: JsonObject | undefined = JsonValue.asObject(obj.tryGet('settings'));
    if (settings !== undefined) {
      out.settings = cloneJsonObject(settings);
    }
    return out;
  }

  static writeArray(values: ComponentExtension[]): JsonArray {
    return ModelCodec.writeArray(values, (value: ComponentExtension): JsonNode => {
      const obj: JsonObject = new JsonObject();
      obj.set('id', new JsonString(value.id));
      obj.set('name', new JsonString(value.name));
      obj.set('description', new JsonString(value.description));
      obj.set('payloadKind', new JsonString(value.payloadKind));
      obj.set('settings', cloneJsonObject(value.settings));
      return obj;
    });
  }
}

export class TriggerExtensionCodec {
  static parse(node: JsonNode | undefined): TriggerExtension {
    const out: TriggerExtension = new TriggerExtension();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.id = ModelCodec.string(obj, 'id', '');
    out.name = ModelCodec.string(obj, 'name', '');
    out.description = ModelCodec.string(obj, 'description', '');
    out.scheduleKind = TriggerExtensionCodec.parseScheduleKind(
      ModelCodec.string(obj, 'scheduleKind', ''));
    out.cronExpression = ModelCodec.string(obj, 'cronExpression', '');
    out.atSeconds = ModelCodec.int(obj, 'atSeconds', 0);
    out.everyMinutes = ModelCodec.int(obj, 'everyMinutes', 0);
    return out;
  }

  static writeArray(values: TriggerExtension[]): JsonArray {
    return ModelCodec.writeArray(values, (value: TriggerExtension): JsonNode => {
      const obj: JsonObject = new JsonObject();
      obj.set('id', new JsonString(value.id));
      obj.set('name', new JsonString(value.name));
      obj.set('description', new JsonString(value.description));
      obj.set('scheduleKind', new JsonString(value.scheduleKind));
      obj.set('cronExpression', new JsonString(value.cronExpression));
      obj.set('atSeconds', JsonNumber.ofInt(value.atSeconds));
      obj.set('everyMinutes', JsonNumber.ofInt(value.everyMinutes));
      return obj;
    });
  }

  /** 陌生取值一律落 None —— 恒不触发比「按最近的一个类别猜」安全。 */
  static parseScheduleKind(text: string): PluginScheduleKind {
    if (text === PluginScheduleKind.Cron) {
      return PluginScheduleKind.Cron;
    }
    if (text === PluginScheduleKind.DailyAt) {
      return PluginScheduleKind.DailyAt;
    }
    if (text === PluginScheduleKind.EveryMinutes) {
      return PluginScheduleKind.EveryMinutes;
    }
    return PluginScheduleKind.None;
  }
}

export class ActionExtensionCodec {
  static parse(node: JsonNode | undefined): ActionExtension {
    const out: ActionExtension = new ActionExtension();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.id = ModelCodec.string(obj, 'id', '');
    out.name = ModelCodec.string(obj, 'name', '');
    out.description = ModelCodec.string(obj, 'description', '');
    out.actionKind = ActionExtensionCodec.parseActionKind(ModelCodec.string(obj, 'actionKind', ''));
    out.title = ModelCodec.string(obj, 'title', '');
    out.content = ModelCodec.string(obj, 'content', '');
    out.category = ModelCodec.string(obj, 'category', '');
    out.settingKey = ModelCodec.string(obj, 'settingKey', '');
    out.settingValue = ModelCodec.string(obj, 'settingValue', '');
    return out;
  }

  static writeArray(values: ActionExtension[]): JsonArray {
    return ModelCodec.writeArray(values, (value: ActionExtension): JsonNode => {
      const obj: JsonObject = new JsonObject();
      obj.set('id', new JsonString(value.id));
      obj.set('name', new JsonString(value.name));
      obj.set('description', new JsonString(value.description));
      obj.set('actionKind', new JsonString(value.actionKind));
      obj.set('title', new JsonString(value.title));
      obj.set('content', new JsonString(value.content));
      obj.set('category', new JsonString(value.category));
      obj.set('settingKey', new JsonString(value.settingKey));
      obj.set('settingValue', new JsonString(value.settingValue));
      return obj;
    });
  }

  /** 陌生取值一律落 None —— 跑起来什么也不做，比猜一个类别去执行强。 */
  static parseActionKind(text: string): PluginActionKind {
    if (text === PluginActionKind.Notification) {
      return PluginActionKind.Notification;
    }
    if (text === PluginActionKind.ModifySetting) {
      return PluginActionKind.ModifySetting;
    }
    return PluginActionKind.None;
  }
}

export class NotificationProviderExtensionCodec {
  static parse(node: JsonNode | undefined): NotificationProviderExtension {
    const out: NotificationProviderExtension = new NotificationProviderExtension();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.id = ModelCodec.string(obj, 'id', '');
    out.name = ModelCodec.string(obj, 'name', '');
    out.description = ModelCodec.string(obj, 'description', '');
    out.providerKind = ModelCodec.string(obj, 'providerKind', '');
    out.triggerId = ModelCodec.string(obj, 'triggerId', '');
    return out;
  }

  static writeArray(values: NotificationProviderExtension[]): JsonArray {
    return ModelCodec.writeArray(values, (value: NotificationProviderExtension): JsonNode => {
      const obj: JsonObject = new JsonObject();
      obj.set('id', new JsonString(value.id));
      obj.set('name', new JsonString(value.name));
      obj.set('description', new JsonString(value.description));
      obj.set('providerKind', new JsonString(value.providerKind));
      obj.set('triggerId', new JsonString(value.triggerId));
      return obj;
    });
  }
}

export class ThemeExtensionCodec {
  static parse(node: JsonNode | undefined): ThemeExtension {
    const out: ThemeExtension = new ThemeExtension();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.id = ModelCodec.string(obj, 'id', '');
    out.name = ModelCodec.string(obj, 'name', '');
    out.description = ModelCodec.string(obj, 'description', '');
    out.mode = ModelCodec.string(obj, 'mode', 'both');
    const colors: JsonObject | undefined = JsonValue.asObject(obj.tryGet('colors'));
    if (colors !== undefined) {
      // 顺序按写出顺序（插入序），不做字典序重排 —— 清单是人写的，
      // 写的时候把相近的颜色放一起是有意义的。
      for (const member of colors.entries()) {
        const color: string = JsonValue.asStringLoose(member.value, '');
        if (color.length > 0) {
          out.colors.set(member.name, color);
        }
      }
    }
    return out;
  }

  static writeArray(values: ThemeExtension[]): JsonArray {
    return ModelCodec.writeArray(values, (value: ThemeExtension): JsonNode => {
      const obj: JsonObject = new JsonObject();
      obj.set('id', new JsonString(value.id));
      obj.set('name', new JsonString(value.name));
      obj.set('description', new JsonString(value.description));
      obj.set('mode', new JsonString(value.mode));
      const colors: JsonObject = new JsonObject();
      value.colors.forEach((color: string, key: string) => {
        colors.set(key, new JsonString(color));
      });
      obj.set('colors', colors);
      return obj;
    });
  }
}