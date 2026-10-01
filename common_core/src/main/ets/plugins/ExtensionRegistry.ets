/*
 * 扩展运行期注册表。
 *
 * 它是干什么的
 * ------------
 * 桌面版的插件加载完会往 DI 容器里注册一堆服务，注册表是那套容器的一部分。鸿蒙侧
 * 没有代码可加载，能注册的只有数据，所以这个注册表记的是「这份扩展声明了什么、
 * 它是开着的还是关着的、它有没有加载失败」。设置页列的就是它，卸载也是从它摘掉。
 *
 * 为什么状态在 core 而不是 entry
 * ---------------------------
 * 因为「关掉一个扩展」这件事必须在**引擎看得到的地方**生效。声明式触发器与行动
 * 装进 TriggerCatalog / ActionCatalog 时带的是 settings 节点，节点本身不含
 * 「谁提供的」；引擎判断「这条触发器有没有被停用」时要问注册表。注册表要是放在
 * entry，core 的引擎就问不到 —— 除非引擎反过来收一个回调，那更绕。
 *
 * 可重入
 * ------
 * 与其它 core 模块同一条纪律：没有跨实例可变状态之外的隐藏单例（`plugins` 这一份
 * 是进程级的、由 entry 在启动时重建，widget 侧可以独立再重建一份，两者不共享）。
 */

import {
  ActionExtension,
  ComponentExtension,
  ExtensionKind,
  ExtensionManifest,
  TriggerExtension
} from './PluginManifest';
import { PluginIssue } from './PluginValidation';

/** 一个已登记的扩展条目。 */
export class ExtensionEntryRecord {
  kind: ExtensionKind = ExtensionKind.Component;
  /** 条目 id。组件为小写 D 格式 GUID。 */
  id: string = '';
  name: string = '';
  description: string = '';
  /** 提供这个条目的扩展 id。 */
  pluginId: string = '';
  /** 扩展的显示名（列表里「X（Y）」的那个 Y）。 */
  pluginName: string = '';
  /** 条目在清单里的下标，用于按顺序列出。 */
  order: number = 0;
}

/** 一个扩展的登记状态。 */
export class PluginRecord {
  pluginId: string = '';
  name: string = '';
  version: string = '';
  description: string = '';
  author: string = '';
  /** 用户有没有把它关掉。关掉的条目不注册进各类注册表。 */
  enabled: boolean = true;
  /** 加载是否成功。失败时 reason 有话说。 */
  loaded: boolean = false;
  /** 加载失败或被关掉时的说明，空串表示一切正常。 */
  reason: string = '';
  /** 本次实际登记了几个条目（关掉或失败时为 0）。 */
  entryCount: number = 0;
  /** 原始清单。设置页的「声明了什么」明细面板要读它。 */
  manifest: ExtensionManifest | undefined = undefined;
  /**
   * 真正注册成功的条目 id，按类别。
   *
   * 摘除只认这里，不认 manifest —— manifest 里可能有**这一条并没有真正生效**
   * 的条目（id 撞了内置或另一个扩展，那条被跳过）。按 manifest 摘的话，
   * 卸载扩展 B 会把扩展 A 的条目一起摘掉：A 的清单里没有它，但 B 声明了同一个 id，
   * 于是 A 的面板上凭空少了一个组件，而 A 明明还装着。
   *
   * 只有三类进这里 —— 通知提供者与主题不注册，本来就没有可摘的东西。
   */
  attachedComponents: string[] = [];
  attachedTriggers: string[] = [];
  attachedActions: string[] = [];
  /**
   * 装载时发现的问题（校验 + 冲突）。
   *
   * 挂在记录上而不是让调用方自己存一份：问题分两批产生（validateManifest 与
   * installComponents 逐条跳过时的 conflicts），而「哪个问题属于哪个扩展」这件事
   * 只有 core 知道 —— entry 那边拿到的只是一个 ExtensionManifest。
   */
  issues: PluginIssue[] = [];
}

/**
 * 扩展注册表（进程级单例，由 entry 负责重建）。
 *
 * 读多写少：写只发生在「装载 / 开关 / 卸载」三个时刻，读发生在每次 tick 与每次
 * 打开设置页。所以这里不设通知机制，改了就下次读的时候看到。
 */
export class ExtensionRegistry {
  private static records: Map<string, PluginRecord> = new Map<string, PluginRecord>();
  private static entries: Map<string, ExtensionEntryRecord[]> = new Map<string, ExtensionEntryRecord[]>();
  private static order: string[] = [];

  /**
   * 登记一个扩展（无论加载成功与否）。
   *
   * 同 id 后登的覆盖先登的并保留原有位置 —— 与 JsonObject.set、KeyedMap.set
   * 同一口径。「重装同一份扩展」是常见操作，位置不该跳到列表末尾。
   */
  static putPlugin(record: PluginRecord): void {
    if (!ExtensionRegistry.records.has(record.pluginId)) {
      ExtensionRegistry.order.push(record.pluginId);
    }
    ExtensionRegistry.records.set(record.pluginId, record);
    ExtensionRegistry.rebuildEntries();
  }

  /** 卸载一个扩展：连条目一起摘掉。 */
  static removePlugin(pluginId: string): boolean {
    const removed: boolean = ExtensionRegistry.records.delete(pluginId);
    if (removed) {
      const next: string[] = [];
      for (const id of ExtensionRegistry.order) {
        if (id !== pluginId) {
          next.push(id);
        }
      }
      // 换序必须整体重写：order 是个普通数组，splice 只在按下标时才用得上，
      // 而这里的键是插件 id。
      ExtensionRegistry.order = next;
      ExtensionRegistry.rebuildEntries();
    }
    return removed;
  }

  /** 清空。装载前调一次，保证重装后不残留上一次的条目。 */
  static clear(): void {
    ExtensionRegistry.records = new Map<string, PluginRecord>();
    ExtensionRegistry.entries = new Map<string, ExtensionEntryRecord[]>();
    ExtensionRegistry.order = [];
  }

  /** 查一个扩展。 */
  static findPlugin(pluginId: string): PluginRecord | undefined {
    return ExtensionRegistry.records.get(pluginId);
  }

  /** 全部扩展，按登记顺序。 */
  static plugins(): PluginRecord[] {
    const out: PluginRecord[] = [];
    for (const id of ExtensionRegistry.order) {
      const record: PluginRecord | undefined = ExtensionRegistry.records.get(id);
      if (record !== undefined) {
        out.push(record);
      }
    }
    return out;
  }

  /**
   * 某类已登记条目，按扩展登记顺序 + 清单内顺序。
   *
   * 只含「加载成功且用户没关掉」的扩展，且只含真正注册上去的条目 ——
   * 见 rebuildEntries 与 collectEntriesOf 的说明。
   * 需要「不管开没开都要看」的场景请用 ownerOfAnyState。
   */
  static entriesOf(kind: ExtensionKind): ExtensionEntryRecord[] {
    const found: ExtensionEntryRecord[] | undefined = ExtensionRegistry.entries.get(kind);
    return found === undefined ? [] : found;
  }

  /** 查某类里的一个条目。 */
  static findEntry(kind: ExtensionKind, id: string): ExtensionEntryRecord | undefined {
    const list: ExtensionEntryRecord[] = ExtensionRegistry.entriesOf(kind);
    for (const entry of list) {
      if (entry.id === id) {
        return entry;
      }
    }
    return undefined;
  }

  /** 这个条目由哪个扩展提供；不是扩展提供的返回 undefined。 */
  static providerOf(kind: ExtensionKind, id: string): string | undefined {
    const found: ExtensionEntryRecord | undefined = ExtensionRegistry.findEntry(kind, id);
    return found === undefined ? undefined : found.pluginId;
  }

  /**
   * 开 / 关一个扩展。
   *
   * 走这个函数而不是直接改 record.enabled：条目表是**关掉那一刻**摊平的，
   * 直接改字段的话 entriesOf / providerOf / findEntry 仍然会给出关掉的扩展的条目，
   * 于是用户在设置里关了它，工作流编辑器里照样还能选到它的触发器。
   */
  static setEnabled(pluginId: string, enabled: boolean): boolean {
    const record: PluginRecord | undefined = ExtensionRegistry.records.get(pluginId);
    if (record === undefined || record.enabled === enabled) {
      return false;
    }
    record.enabled = enabled;
    ExtensionRegistry.rebuildEntries();
    return true;
  }

  /** 这个扩展是不是处于「用户关掉了」的状态。 */
  static isDisabled(pluginId: string): boolean {
    const record: PluginRecord | undefined = ExtensionRegistry.records.get(pluginId);
    return record !== undefined && !record.enabled;
  }

  /**
   * 声明式行动允许改的设置键。
   *
   * 由 entry 在装载时按 AppPreferences 的真源填一次。放在这里而不是每次调用都传参：
   * `ActionCatalog.settingsOf` 的签名是对齐既有代码的（只收 ActionItem），
   * 塞一个参数进去就得改所有调用点，而这一栏只有一个真源。
   */
  static writableSettingKeys: Set<string> = new Set<string>();

  /** 改一次就整份换掉（不支持增删的语义，反而更安全）。 */
  static setWritableSettingKeys(keys: string[]): void {
    const next: Set<string> = new Set<string>();
    for (const key of keys) {
      next.add(key);
    }
    ExtensionRegistry.writableSettingKeys = next;
  }

  /** 找一个扩展声明的行动条目。找不到返回 undefined（被卸载 / 被关掉 / id 写错）。 */
  static findActionExtension(actionId: string): ActionExtension | undefined {
    for (const record of ExtensionRegistry.plugins()) {
      if (record.manifest === undefined) {
        continue;
      }
      for (const entry of record.manifest.actions) {
        if (entry.id === actionId) {
          return entry;
        }
      }
    }
    return undefined;
  }

  /** 找一个扩展声明的触发器条目。找不到返回 undefined。 */
  static findTriggerExtension(triggerId: string): TriggerExtension | undefined {
    for (const record of ExtensionRegistry.plugins()) {
      if (record.manifest === undefined) {
        continue;
      }
      for (const entry of record.manifest.triggers) {
        if (entry.id === triggerId) {
          return entry;
        }
      }
    }
    return undefined;
  }

  /** 找一个扩展声明的组件条目。找不到返回 undefined。 */
  static findComponentExtension(guid: string): ComponentExtension | undefined {
    const key: string = guid.toLowerCase();
    for (const record of ExtensionRegistry.plugins()) {
      if (record.manifest === undefined) {
        continue;
      }
      for (const entry of record.manifest.components) {
        if (entry.id.toLowerCase() === key) {
          return entry;
        }
      }
    }
    return undefined;
  }

  /**
   * 这个条目是不是已经不可用了（扩展被关掉、被卸载，或它自己加载失败）。
   *
   * 自动化引擎每 tick 都要判断一遍，所以返回 bool 而不是 undefined：
   * 「不在注册表里」既可能是没注册也可能是被摘了，这里把这两种合成一个问题 ——
   * 对引擎而言都意味着「这条触发器现在不会有任何反应」。
   */
  static isEntryInactive(kind: ExtensionKind, id: string): boolean {
    // 直接扫记录，不走 providerOf —— 后者查的是 entriesOf，而 entriesOf 里
    // **不含已关掉的扩展**，于是「关掉扩展 → 该判定不可用」这一步永远得到
    // 「这不是扩展条目」，返回值恒 false，声明式触发器会继续按旧日程触发。
    const owner: PluginRecord | undefined = ExtensionRegistry.ownerOfAnyState(kind, id);
    if (owner === undefined) {
      return false;
    }
    return !owner.loaded || !owner.enabled;
  }

  /**
   * 找一个条目由哪个扩展声明（不管那个扩展开没开、装没装成功）。
   *
   * 与 providerOf 的区别：providerOf 走 entriesOf，只含「加载成功且开着」的；
   * 这里含全部。判「这条是不是已经不可用了」要用后者。
   */
  static ownerOfAnyState(kind: ExtensionKind, id: string): PluginRecord | undefined {
    for (const record of ExtensionRegistry.plugins()) {
      if (record.manifest === undefined) {
        continue;
      }
      for (const entry of collectEntriesOf(record)) {
        if (entry.kind === kind && entry.id === id) {
          return record;
        }
      }
    }
    return undefined;
  }

  /** 一句话汇总（设置页状态行用）。 */
  static summaryText(): string {
    if (ExtensionRegistry.order.length === 0) {
      return '没有安装扩展';
    }
    let active: number = 0;
    let broken: number = 0;
    for (const id of ExtensionRegistry.order) {
      const record: PluginRecord | undefined = ExtensionRegistry.records.get(id);
      if (record === undefined) {
        continue;
      }
      if (record.loaded && record.enabled) {
        active++;
      } else if (!record.loaded) {
        broken++;
      }
    }
    if (broken === 0) {
      return `${active} 个扩展在用`;
    }
    return `${active} 个扩展在用，${broken} 个没装上`;
  }

  /** 把已登记的扩展重新摊平成五类条目表。 */
  private static rebuildEntries(): void {
    const next: Map<string, ExtensionEntryRecord[]> = new Map<string, ExtensionEntryRecord[]>();
    for (const kind of [ExtensionKind.Component, ExtensionKind.Trigger, ExtensionKind.Action,
      ExtensionKind.NotificationProvider, ExtensionKind.Theme]) {
      next.set(kind, []);
    }
    for (const id of ExtensionRegistry.order) {
      const record: PluginRecord | undefined = ExtensionRegistry.records.get(id);
      // 只摊开「加载成功且用户没关掉」的：关掉的扩展不能贡献条目，否则用户关了
      // 却还能在工作流编辑器里选到它的触发器。
      if (record === undefined || !record.loaded || !record.enabled) {
        continue;
      }
      for (const entry of collectEntriesOf(record)) {
        const list: ExtensionEntryRecord[] | undefined = next.get(entry.kind);
        if (list !== undefined) {
          list.push(entry);
        }
      }
    }
    ExtensionRegistry.entries = next;
  }
}

/**
 * 取出一个扩展声明的全部条目。
 *
 * 单独一个函数而不是内联在 rebuildEntries 里：它同时被设置页「这个扩展声明了什么」
 * 那个明细面板复用（那里要连没启用的扩展也显示出来）。
 */
export function collectEntriesOf(record: PluginRecord): ExtensionEntryRecord[] {
  const manifest: ExtensionManifest | undefined = record.manifest;
  const out: ExtensionEntryRecord[] = [];
  if (manifest === undefined) {
    return out;
  }
  for (let i = 0; i < manifest.components.length; i++) {
    const item = manifest.components[i];
    if (record.attachedComponents.indexOf(item.id) >= 0) {
      out.push(makeEntry(ExtensionKind.Component, item.id, item.name, item.description,
        record, i));
    }
  }
  for (let i = 0; i < manifest.triggers.length; i++) {
    const item = manifest.triggers[i];
    if (record.attachedTriggers.indexOf(item.id) >= 0) {
      out.push(makeEntry(ExtensionKind.Trigger, item.id, item.name, item.description,
        record, i));
    }
  }
  for (let i = 0; i < manifest.actions.length; i++) {
    const item = manifest.actions[i];
    if (record.attachedActions.indexOf(item.id) >= 0) {
      out.push(makeEntry(ExtensionKind.Action, item.id, item.name, item.description,
        record, i));
    }
  }
  for (let i = 0; i < manifest.notificationProviders.length; i++) {
    const item = manifest.notificationProviders[i];
    out.push(makeEntry(ExtensionKind.NotificationProvider, item.id, item.name, item.description,
      record, i));
  }
  for (let i = 0; i < manifest.themes.length; i++) {
    const item = manifest.themes[i];
    out.push(makeEntry(ExtensionKind.Theme, item.id, item.name, item.description,
      record, i));
  }
  return out;
}

function makeEntry(kind: ExtensionKind, id: string, name: string, description: string,
  record: PluginRecord, order: number): ExtensionEntryRecord {
  const out: ExtensionEntryRecord = new ExtensionEntryRecord();
  out.kind = kind;
  out.id = id;
  out.name = name;
  out.description = description;
  out.pluginId = record.pluginId;
  out.pluginName = record.name;
  out.order = order;
  return out;
}