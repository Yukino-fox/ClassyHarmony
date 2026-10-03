/*
 * 行动注册表。对应桌面版的 IActionService.ActionInfos +
 * ActionRegistryExtensions.AddAction。
 *
 * 为什么是显式表
 * ------------
 * 与 TriggerCatalog 同一条理由。桌面版靠 DI + 特性反射，这里不能。
 *
 * 7 个行动，5 个已实现
 * ------------------
 * 已实现：
 *   classisland.action.sleep        等 N 秒。整条链路里唯一「什么都不做」的行动，
 *                                  但它是编排的关键（等 5 秒再说下一句），不能省。
 *   classisland.settings            改一项应用设置。**七个里唯一支持恢复的**
 *                                  （ModifyAppSettingsAction 覆写了 OnRevert），
 *                                  所以「改完再改回来」这条链在鸿蒙侧是通的。
 *   classisland.app.quit            退出应用。
 *   classisland.showNotification    显示一条本地通知。P9 已实现，P11c 才把标注
 *                                  改对（此前一直挂着「等 P9」的旧理由）。
 *   classisland.notification.weather 显示天气提醒。P11c 落地（预报 / 预警 / 逐时）。
 *
 * 未实现（2 个），照常列出、可以配（值原样落盘），但界面上标出来：
 *   classisland.os.run              鸿蒙应用不能拉起任意进程 / 执行命令行。
 *   classisland.app.restart         重启要走 startAbility + terminateSelf，
 *                                  进程被杀时系统可能不给回调，新起的进程也
 *                                  拿不到原来的状态。桌面版靠 Environment.Exit
 *                                  + Process.Start，这套在鸿蒙上没有对应物。
 *
 * isRevertable 照抄桌面版的算法
 * ----------------------------
 * 桌面版 `info.IsRevertable = HasOverriddenOnRevert(actionType)`，即「有没有
 * 覆写 OnRevert」。七个行动里只有 ModifyAppSettingsAction 覆写了，所以只有
 * classisland.settings 为 true。这一栏决定 ActionSet.IsRevertEnabled 打开时，
 * 恢复阶段哪些行动会被回滚。
 *
 * 为什么不藏起来
 * --------------
 * 规则那边把无实现的规则藏在设置控件后面（只是不显示），但行动不行：用户从
 * 桌面版同步过来的行动组里可能有「显示提醒」，这边若在列表里少一条，用户
 * 没有任何地方能看出「这个行动在这台设备上不会发生」。所以照常列出、标出来。
 */

import { t } from '../i18n/I18n';
import {
  AppRestartActionSettings,
  JsonNode,
  JsonObject,
  ModifyAppSettingsActionSettings,
  NotificationActionSettings,
  RunActionSettings,
  SleepActionSettings,
  WeatherNotificationActionSettings,
  ActionIds,
  ActionItem
} from 'common_shared';
import {
  PluginActionPlan,
  planPluginAction,
  settingsOfActionExtension
} from '../plugins/PluginActionEval';
import { ExtensionRegistry } from '../plugins/ExtensionRegistry';

/** 行动实现状态。决定编辑器给它打什么标。 */
export enum ActionSupport {
  /** 执行器里有实现，能真的做。 */
  Implemented = 0,
  /** 已注册但鸿蒙侧无对应物，跑到它时跳过并记一笔。 */
  Unsupported = 1,
  /** 配置里的陌生 id。跑到它时跳过并记一笔。 */
  Unknown = 2
}

/** 行动设置的类型标签。解码分支集中在 settingsOf。 */
export enum ActionSettingsKind {
  None = 0,
  AppRestart = 1,
  ModifyAppSettings = 2,
  Notification = 3,
  Run = 4,
  Sleep = 5,
  WeatherNotification = 6,
  /**
   * 声明式扩展提供的行动（P12）。Settings 原样承载一份动作描述
   * （见 plugins/PluginActionEval.planPluginAction），解成 PluginActionPlan。
   */
  Plugin = 7
}

/** 一个行动的注册信息。对应桌面版 ActionInfo。 */
export class ActionInfo {
  id: string = '';
  /** 显示名。桌面版注册时给的中文名。 */
  name: string = '';
  /** 桌面版是 Segoe Fluent 图标的码位。保留字段但不渲染，同 TriggerInfo。 */
  iconGlyph: string = '';
  support: ActionSupport = ActionSupport.Unsupported;
  settingsKind: ActionSettingsKind = ActionSettingsKind.None;
  /**
   * 是否支持恢复。对应桌面版 `HasOverriddenOnRevert`。
   * 七个里只有 classisland.settings 为 true。
   */
  isRevertable: boolean = false;
  /** 未实现时给用户看的一句话。实现了就是空串。 */
  unsupportedReason: string = '';
}

function entry(id: string, name: string, glyph: string, kind: ActionSettingsKind,
  isRevertable: boolean, reason: string = ''): ActionInfo {
  const out: ActionInfo = new ActionInfo();
  out.id = id;
  out.name = name;
  out.iconGlyph = glyph;
  out.settingsKind = kind;
  out.isRevertable = isRevertable;
  out.support = reason.length > 0 ? ActionSupport.Unsupported : ActionSupport.Implemented;
  out.unsupportedReason = reason;
  return out;
}

const OS_RUN_REASON: string = t('action_run_unsupported');
const APP_RESTART_REASON: string = t('action_restart_unsupported');

const REGISTRY: ActionInfo[] = [
  entry(ActionIds.APP_QUIT, t('action_app_quit'), '', ActionSettingsKind.None, false),
  entry(ActionIds.APP_RESTART, t('action_app_restart'), '', ActionSettingsKind.AppRestart, false,
    APP_RESTART_REASON),
  entry(ActionIds.SETTINGS, t('action_settings'), '', ActionSettingsKind.ModifyAppSettings, true),
  entry(ActionIds.SHOW_NOTIFICATION, t('action_show_notification'), '', ActionSettingsKind.Notification, false),
  entry(ActionIds.OS_RUN, t('action_os_run'), '', ActionSettingsKind.Run, false, OS_RUN_REASON),
  entry(ActionIds.SLEEP, t('action_sleep'), '', ActionSettingsKind.Sleep, false),
  entry(ActionIds.NOTIFICATION_WEATHER, t('action_notification_weather'), '',
    ActionSettingsKind.WeatherNotification, false)
];

export class ActionCatalog {
  /** 扩展注册的行动（P12）。与 REGISTRY 分开，理由同 TriggerCatalog。 */
  private static pluginEntries: ActionInfo[] = [];

  static find(id: string): ActionInfo | undefined {
    for (const each of REGISTRY) {
      if (each.id === id) {
        return each;
      }
    }
    for (const each of ActionCatalog.pluginEntries) {
      if (each.id === id) {
        return each;
      }
    }
    return undefined;
  }

  /** 全部已注册行动：先内置、后扩展。编辑器的新增菜单按这个顺序排。 */
  static all(): ActionInfo[] {
    const out: ActionInfo[] = [];
    for (const each of REGISTRY) {
      out.push(each);
    }
    for (const each of ActionCatalog.pluginEntries) {
      out.push(each);
    }
    return out;
  }

  /** 注册一条扩展行动。重复 id 抛错，与 ComponentCatalog.register 同一口径。 */
  static register(info: ActionInfo): void {
    if (ActionCatalog.find(info.id) !== undefined) {
      throw new Error(`行动 id ${info.id} 已被占用`);
    }
    ActionCatalog.pluginEntries.push(info);
  }

  /** 注册一条扩展行动，冲突时返回 false 而不是抛（装载一批扩展用）。 */
  static registerPlugin(info: ActionInfo): boolean {
    if (ActionCatalog.find(info.id) !== undefined) {
      return false;
    }
    ActionCatalog.pluginEntries.push(info);
    return true;
  }

  /** 注销一条扩展行动。内置的不受影响。 */
  static unregister(id: string): boolean {
    const next: ActionInfo[] = [];
    let found: boolean = false;
    for (const each of ActionCatalog.pluginEntries) {
      if (each.id === id) {
        found = true;
        continue;
      }
      next.push(each);
    }
    ActionCatalog.pluginEntries = next;
    return found;
  }

  /** 只清扩展注册项。装载前调一次。 */
  static unregisterAll(): void {
    ActionCatalog.pluginEntries = [];
  }

  static supportOf(id: string): ActionSupport {
    const found: ActionInfo | undefined = ActionCatalog.find(id);
    return found === undefined ? ActionSupport.Unknown : found.support;
  }

  /** 显示名。未知 id 回显 id。 */
  static displayNameOf(id: string): string {
    const found: ActionInfo | undefined = ActionCatalog.find(id);
    return found === undefined ? id : found.name;
  }

  /**
   * 这一条支持不支持恢复。
   *
   * 未知 id 返回 false —— 与桌面版
   * `if (!ActionInfos.TryGetValue(...) || !actionInfo.IsRevertable) return;` 一致。
   */
  static isRevertable(id: string): boolean {
    const found: ActionInfo | undefined = ActionCatalog.find(id);
    return found !== undefined && found.isRevertable;
  }

  /**
   * 把行动项上的 Settings 解成强类型对象。
   *
   * Settings 为 null 时按「空对象」解，等价于桌面版
   * `i.Settings ?? Activator.CreateInstance(settingsType)`。
   */
  static settingsOf(item: ActionItem): Object | undefined {
    const found: ActionInfo | undefined = ActionCatalog.find(item.id);
    if (found === undefined) {
      return undefined;
    }
    const raw: JsonNode = item.settings === undefined ? new JsonObject() : item.settings;
    if (found.settingsKind === ActionSettingsKind.AppRestart) {
      return AppRestartActionSettings.parse(raw);
    }
    if (found.settingsKind === ActionSettingsKind.ModifyAppSettings) {
      return ModifyAppSettingsActionSettings.parse(raw);
    }
    if (found.settingsKind === ActionSettingsKind.Notification) {
      return NotificationActionSettings.parse(raw);
    }
    if (found.settingsKind === ActionSettingsKind.Run) {
      return RunActionSettings.parse(raw);
    }
    if (found.settingsKind === ActionSettingsKind.Sleep) {
      return SleepActionSettings.parse(raw);
    }
    if (found.settingsKind === ActionSettingsKind.WeatherNotification) {
      return WeatherNotificationActionSettings.parse(raw);
    }
    if (found.settingsKind === ActionSettingsKind.Plugin) {
      return planPluginAction(raw, ExtensionRegistry.writableSettingKeys);
    }
    return undefined;
  }

  /** 新建一条该 id 的行动时该带什么设置。未知 id 返回 undefined。 */
  static defaultSettingsOf(id: string): Object | undefined {
    const found: ActionInfo | undefined = ActionCatalog.find(id);
    if (found === undefined) {
      return undefined;
    }
    if (found.settingsKind === ActionSettingsKind.AppRestart) {
      return new AppRestartActionSettings();
    }
    if (found.settingsKind === ActionSettingsKind.ModifyAppSettings) {
      return new ModifyAppSettingsActionSettings();
    }
    if (found.settingsKind === ActionSettingsKind.Notification) {
      return new NotificationActionSettings();
    }
    if (found.settingsKind === ActionSettingsKind.Run) {
      return new RunActionSettings();
    }
    if (found.settingsKind === ActionSettingsKind.Sleep) {
      return new SleepActionSettings();
    }
    if (found.settingsKind === ActionSettingsKind.WeatherNotification) {
      return new WeatherNotificationActionSettings();
    }
    if (found.settingsKind === ActionSettingsKind.Plugin) {
      // 声明式行动的默认设置 = 扩展声明的那份描述（模板变量原样留着，执行时渲染）。
      const entry = ExtensionRegistry.findActionExtension(found.id);
      return entry === undefined ? new PluginActionPlan() : settingsOfActionExtension(entry);
    }
    return undefined;
  }
}
