/*
 * 触发器注册表。对应桌面版的 IAutomationService.RegisteredTriggers +
 * TriggerRegistryExtensions.AddTrigger。
 *
 * 为什么是显式表
 * --------------
 * 与 RuleCatalog 同一条理由：桌面版靠 DI 容器 + 特性反射逐个 AddTrigger<T>()，
 * ArkTS 侧没有反射，而且 core 的可测性全靠「能进 Node 测试台」这一点。
 * 12 个触发器写成一张表，好处是编辑器直接遍历它、不另需一份显示名清单，
 * 漏注册在代码审阅时就能看出来。
 *
 * 12 个触发器，8 个已实现
 * ----------------------
 * 已实现（引擎里能算）：
 *   lifetime.startup / lifetime.stopping
 *   cron
 *   lessons.currentTimeStateChanged / onClass / onBreakingTime / onAfterSchool
 *   lessons.preTimePoint
 *
 * 未实现（4 个），恒不触发：
 *   ruleSet.rulesetChanged  桌面版挂在 RulesetService.StatusUpdated 上。鸿蒙侧
 *                           规则集只在面板里被求值，没有一个全局的「状态更新」
 *                           事件源；硬造一个只会让用户收到大量无意义触发。
 *   signal                  信号由 v2 行动 classisland.broadcastSignal 发出，
 *                           鸿蒙侧没有 v2 行动，等于永远收不到。
 *   trayMenu                鸿蒙没有托盘。
 *   uri                     桌面版走 ClassIsland.Desktop 的单实例互操作；
 *                           鸿蒙侧的对应物是 ability 的 want.uri，需要先在
 *                           module.json5 里声明 skills 匹配规则。
 *
 * 「恒不触发」而不是「恒为假」
 * --------------------------
 * 与规则那边的分档不同：规则不成立是一句可解释的话（不满足条件），而触发器
 * 恒不触发是「这个功能在这台设备上不存在」。所以编辑器把这一档标成
 * Unsupported 并说明原因，而不是像规则那样假装它被判定过。
 */

import {
  CronTriggerSettings,
  JsonNode,
  JsonObject,
  PreTimePointTriggerSettings,
  SignalTriggerSettings,
  TriggerIds,
  TriggerSettings,
  TrayMenuTriggerSettings,
  UriTriggerSettings
} from 'common_shared';

/** 触发器实现状态。决定编辑器给它打什么标。 */
export enum TriggerSupport {
  /** 引擎里有实现，能触发。 */
  Implemented = 0,
  /** 已注册但鸿蒙侧无对应物，永远不会触发。 */
  Unsupported = 1,
  /** 配置里的陌生 id（用户手改文件，或桌面版插件注册的）。 */
  Unknown = 2
}

/** 触发器设置的类型标签。解码分支集中在 settingsOf。 */
export enum TriggerSettingsKind {
  None = 0,
  Cron = 1,
  PreTimePoint = 2,
  Signal = 3,
  TrayMenu = 4,
  Uri = 5
}

/** 一个触发器的注册信息。对应桌面版 TriggerInfo。 */
export class TriggerInfo {
  id: string = '';
  /** 显示名。桌面版注册时给的中文名。 */
  name: string = '';
  /**
   * 桌面版是 Segoe Fluent 图标的码位。鸿蒙侧没有那套字体，保留字段但不渲染：
   * 等 P10 做主题时再决定换成什么符号。
   */
  iconGlyph: string = '';
  support: TriggerSupport = TriggerSupport.Unsupported;
  settingsKind: TriggerSettingsKind = TriggerSettingsKind.None;
  /**
   * 未实现时给用户看的一句话。实现了就是空串。
   *
   * 这一栏是这一档存在的意义：把「为什么这个触发器在这台设备上不会响」写死在
   * 代码里，界面上直接显示。用户不该靠猜。
   */
  unsupportedReason: string = '';
  /**
   * 这个触发器会不会要求撤销（桌面版调 TriggerRevert 而非 Trigger）。
   *
   * 12 个里只有两个会：
   *   - preTimePoint：当前状态已经等于目标状态时要求撤销（提前提醒要能收回去）
   *   - signal      ：收到的信号自带 Revert 标记
   * 其余十个只会 Trigger。
   *
   * 与行动那边的 isRevertable 不是一回事，别混：那个是「这个行动能不能被回滚」，
   * 这个是「这个触发器会不会说出撤销」。一个工作流能不能撤销，由行动那边的
   * 那一栏说了算。
   */
  canRevert: boolean = false;
}

function entry(id: string, name: string, glyph: string, kind: TriggerSettingsKind,
  reason: string = '', canRevert: boolean = false): TriggerInfo {
  const out: TriggerInfo = new TriggerInfo();
  out.id = id;
  out.name = name;
  out.iconGlyph = glyph;
  out.settingsKind = kind;
  out.support = reason.length > 0 ? TriggerSupport.Unsupported : TriggerSupport.Implemented;
  out.unsupportedReason = reason;
  out.canRevert = canRevert;
  return out;
}

const RULESET_CHANGED_REASON: string =
  '桌面版这个触发器挂在「规则集状态更新」事件上。鸿蒙侧规则集只在面板里被求值，' +
  '没有一个全局的状态更新事件源 —— 硬造一个只会让工作流收到大量无意义的触发。';
const SIGNAL_REASON: string =
  '信号由 v2 行动 classisland.broadcastSignal 发出，鸿蒙侧没有 v2 行动，' +
  '等于永远收不到这个信号。';
const TRAY_MENU_REASON: string = '鸿蒙没有托盘，从托盘菜单运行这一条没有对应物。';
const URI_REASON: string =
  '鸿蒙侧的对应物是 ability 的 want.uri（深链），需要先在 module.json5 里声明 ' +
  'skills 匹配规则才能收到，那一步还没做。';

/** 12 个内置触发器，顺序照 Services/Automation/Triggers 目录下的文件顺序。 */
const REGISTRY: TriggerInfo[] = [
  entry(TriggerIds.LIFETIME_STARTUP, '应用启动时', '', TriggerSettingsKind.None),
  entry(TriggerIds.LIFETIME_STOPPING, '应用退出时', '', TriggerSettingsKind.None),
  entry(TriggerIds.CRON, 'cron', '', TriggerSettingsKind.Cron),
  entry(TriggerIds.LESSONS_CURRENT_TIME_STATE_CHANGED, '当前时间状态变化时', '',
    TriggerSettingsKind.None),
  entry(TriggerIds.LESSONS_ON_AFTER_SCHOOL, '放学时', '', TriggerSettingsKind.None),
  entry(TriggerIds.LESSONS_ON_BREAKING_TIME, '课间休息时', '',
    TriggerSettingsKind.None),
  entry(TriggerIds.LESSONS_ON_CLASS, '上课时', '', TriggerSettingsKind.None),
  entry(TriggerIds.LESSONS_PRE_TIME_POINT, '特定时间点前', '',
    TriggerSettingsKind.PreTimePoint, '', true),
  entry(TriggerIds.RULESET_CHANGED, '规则集更新时', '', TriggerSettingsKind.None,
    RULESET_CHANGED_REASON),
  entry(TriggerIds.SIGNAL, '收到信号时', '', TriggerSettingsKind.Signal, SIGNAL_REASON, true),
  entry(TriggerIds.TRAY_MENU, '从托盘菜单运行时', '', TriggerSettingsKind.TrayMenu,
    TRAY_MENU_REASON),
  entry(TriggerIds.URI, '调用 Uri 时', '', TriggerSettingsKind.Uri, URI_REASON)
];

export class TriggerCatalog {
  /** 查一条触发器的注册信息。未知 id 返回 undefined。 */
  static find(id: string): TriggerInfo | undefined {
    for (const each of REGISTRY) {
      if (each.id === id) {
        return each;
      }
    }
    return undefined;
  }

  /** 全部内置触发器，按注册顺序。编辑器的新增菜单按这个顺序排。 */
  static all(): TriggerInfo[] {
    return REGISTRY;
  }

  /** 这条触发器现在能不能算。 */
  static supportOf(id: string): TriggerSupport {
    const found: TriggerInfo | undefined = TriggerCatalog.find(id);
    return found === undefined ? TriggerSupport.Unknown : found.support;
  }

  /**
   * 显示名。
   *
   * 未知 id 直接回显 id，与规则那边同一个意图：让用户看得见自己填了些什么，
   * 而不是一行空白。
   */
  static displayNameOf(id: string): string {
    const found: TriggerInfo | undefined = TriggerCatalog.find(id);
    return found === undefined ? id : found.name;
  }

  /**
   * 把触发器上的 Settings 解成强类型对象。
   *
   * 未知 id 或无设置的触发器返回 undefined。Settings 为 null 时按「空对象」解，
   * 等价于桌面版 `settings ?? Activator.CreateInstance(settingsType)`。
   */
  static settingsOf(trigger: TriggerSettings): Object | undefined {
    const found: TriggerInfo | undefined = TriggerCatalog.find(trigger.id);
    if (found === undefined) {
      return undefined;
    }
    // 自写判定函数不做类型收窄，所以这里要显式给一个 JsonNode 而不是 undefined。
    const raw: JsonNode = trigger.settings === undefined ? new JsonObject() : trigger.settings;
    if (found.settingsKind === TriggerSettingsKind.Cron) {
      return CronTriggerSettings.parse(raw);
    }
    if (found.settingsKind === TriggerSettingsKind.PreTimePoint) {
      return PreTimePointTriggerSettings.parse(raw);
    }
    if (found.settingsKind === TriggerSettingsKind.Signal) {
      return SignalTriggerSettings.parse(raw);
    }
    if (found.settingsKind === TriggerSettingsKind.TrayMenu) {
      return TrayMenuTriggerSettings.parse(raw);
    }
    if (found.settingsKind === TriggerSettingsKind.Uri) {
      return UriTriggerSettings.parse(raw);
    }
    return undefined;
  }

  /** 新建一条该 id 的触发器时该带什么设置。未知 id 返回 undefined。 */
  static defaultSettingsOf(id: string): Object | undefined {
    const found: TriggerInfo | undefined = TriggerCatalog.find(id);
    if (found === undefined) {
      return undefined;
    }
    if (found.settingsKind === TriggerSettingsKind.Cron) {
      return new CronTriggerSettings();
    }
    if (found.settingsKind === TriggerSettingsKind.PreTimePoint) {
      return new PreTimePointTriggerSettings();
    }
    if (found.settingsKind === TriggerSettingsKind.Signal) {
      return new SignalTriggerSettings();
    }
    if (found.settingsKind === TriggerSettingsKind.TrayMenu) {
      return new TrayMenuTriggerSettings();
    }
    if (found.settingsKind === TriggerSettingsKind.Uri) {
      return new UriTriggerSettings();
    }
    return undefined;
  }
}
