/*
 * 规则注册表。对应桌面版的 IRulesetService.Rules + RulesetRegistryExtensions.AddRule。
 *
 * 为什么是显式表而不是「注册表 + 插件扫描」
 * ----------------------------------------
 * 桌面版用 DI 容器在 App.Services.xaml.cs 里逐个 AddRule<T>，插件可以往里追加。
 * 鸿蒙侧的插件系统在 P12 之后才有，且那时的插件形态还没定；先把 13 条内置规则
 * 写成一张显式表，好处是：
 *   - 没有反射，进得了 Node 测试台（core 的可测性全靠这一点）；
 *   - 重名 / 漏注册在代码审阅时就看得出来，不用等运行时抛 KeyNotFoundException；
 *   - 编辑器的规则选择器直接遍历这张表，不另需一份「显示名」清单。
 * 代价是加规则要改这个文件 —— 那是应该改的地方。
 *
 * 处理器分三档
 * -----------
 *   已实现  : 4 条课表类规则，处理函数在 RuleEngine.ets
 *   恒为假  : 4 条窗口类 + 5 条天气类。鸿蒙侧没有「前台窗口」；天气要等 P11 接上
 *             联网数据。桌面版此时的行为是「找不到处理器 → 记日志 → false」，
 *             这里照抄那个结果，但用 support 显式标出来，别让读代码的人以为漏了实现。
 *   未注册  : 用户手改文件塞进来的陌生 id，或桌面版插件注册的规则。求值同样得到 false。
 * 三档在编辑器里显示成不同提示，避免用户对着一个恒假的规则反复调参数。
 *
 * 不用函数字段存 handler
 * ----------------------
 * 桌面版 RuleRegistryInfo.Handle 是个委托。这里换成 settingsKind 标签 + settingsOf
 * 里的分支：ArkTS 里「类字段是函数类型」虽然能过，但调用处要写强制类型转换，
 * 而这张表是纯数据，写成数据更清楚。新增规则要动的地方也只有 settingsOf 一处。
 */

import { JsonNode } from 'common_shared';
import {
  CurrentSubjectRuleSettings,
  CurrentWeatherRuleSettings,
  JsonObject,
  RainTimeRuleSettings,
  Rule,
  RuleIds,
  StringMatchingSettings,
  SunRiseSetRuleSettings,
  TimeStateRuleSettings,
  WindowStatusRuleSettings
} from 'common_shared';

/** 处理器实现状态。决定编辑器给它打什么标。 */
export enum RuleSupport {
  /** 求值器里有实现。 */
  Implemented = 0,
  /** 已注册但鸿蒙侧无对应物，求值恒为 false。 */
  Unsupported = 1,
  /** 用户配置里的陌生 id。求值恒为 false。 */
  Unknown = 2
}

/**
 * 规则设置的类型标签。
 *
 * 与桌面版那六个 SettingsType 一一对应（StringMatchingSettings 被四条规则共用，
 * 所以是 7 个标签对 6 个类型）。解码分支集中在 settingsOf。
 */
export enum RuleSettingsKind {
  /** 没有设置。 */
  None = 0,
  StringMatching = 1,
  TimeState = 2,
  CurrentSubject = 3,
  CurrentWeather = 4,
  RainTime = 5,
  SunRiseSet = 6,
  WindowStatus = 7
}

/** 一条规则的注册信息。对应桌面版 RuleRegistryInfo。 */
export class RuleInfo {
  id: string = '';
  /** 显示名。桌面版注册时给的中文名。 */
  name: string = '';
  /**
   * 桌面版是 Segoe Fluent 图标的码位（\uE215 之类）。鸿蒙侧没有那套字体，
   * 保留字段但不渲染：等 P10 做主题时再决定换成什么符号。
   */
  iconGlyph: string = '';
  support: RuleSupport = RuleSupport.Unsupported;
  settingsKind: RuleSettingsKind = RuleSettingsKind.None;
}

function entry(id: string, name: string, glyph: string, support: RuleSupport,
  kind: RuleSettingsKind): RuleInfo {
  const out: RuleInfo = new RuleInfo();
  out.id = id;
  out.name = name;
  out.iconGlyph = glyph;
  out.support = support;
  out.settingsKind = kind;
  return out;
}

/** 13 条内置规则，顺序照 App.Services.xaml.cs 的注册顺序。 */
const REGISTRY: RuleInfo[] = [
  entry(RuleIds.WINDOW_CLASS_NAME, '前台窗口类名', '', RuleSupport.Unsupported,
    RuleSettingsKind.StringMatching),
  entry(RuleIds.WINDOW_TEXT, '前台窗口标题', '', RuleSupport.Unsupported,
    RuleSettingsKind.StringMatching),
  entry(RuleIds.WINDOW_STATUS, '前台窗口状态是', '', RuleSupport.Unsupported,
    RuleSettingsKind.WindowStatus),
  entry(RuleIds.WINDOW_PROCESS_NAME, '前台窗口进程', '', RuleSupport.Unsupported,
    RuleSettingsKind.StringMatching),
  entry(RuleIds.LESSONS_CURRENT_SUBJECT, '科目是', '', RuleSupport.Implemented,
    RuleSettingsKind.CurrentSubject),
  entry(RuleIds.LESSONS_NEXT_SUBJECT, '下节课科目是', '', RuleSupport.Implemented,
    RuleSettingsKind.CurrentSubject),
  entry(RuleIds.LESSONS_PREVIOUS_SUBJECT, '上节课科目是', '', RuleSupport.Implemented,
    RuleSettingsKind.CurrentSubject),
  entry(RuleIds.LESSONS_TIME_STATE, '当前时间状态是', '', RuleSupport.Implemented,
    RuleSettingsKind.TimeState),
  entry(RuleIds.WEATHER_CURRENT, '当前天气是', '', RuleSupport.Unsupported,
    RuleSettingsKind.CurrentWeather),
  entry(RuleIds.WEATHER_TOMORROW, '明天天气是', '', RuleSupport.Unsupported,
    RuleSettingsKind.CurrentWeather),
  entry(RuleIds.WEATHER_ALERT, '存在气象预警', '', RuleSupport.Unsupported,
    RuleSettingsKind.StringMatching),
  entry(RuleIds.WEATHER_RAIN_TIME, '距离降水开始/结束还剩', '', RuleSupport.Unsupported,
    RuleSettingsKind.RainTime),
  entry(RuleIds.WEATHER_SUN_RISE_SET, '是否日出/日落', '', RuleSupport.Unsupported,
    RuleSettingsKind.SunRiseSet)
];

export class RuleCatalog {
  /**
   * 查一条规则的注册信息。未知 id 返回 undefined —— 对应桌面版
   * `if (!IRulesetService.Rules.TryGetValue(i.Id, out var rule))` 的失败分支。
   */
  static find(id: string): RuleInfo | undefined {
    for (const each of REGISTRY) {
      if (each.id === id) {
        return each;
      }
    }
    return undefined;
  }

  /** 全部内置规则，按注册顺序。 */
  static all(): RuleInfo[] {
    return REGISTRY;
  }

  /** 这条规则现在能不能算。编辑器用它决定要不要给设置控件。 */
  static supportOf(id: string): RuleSupport {
    const found: RuleInfo | undefined = RuleCatalog.find(id);
    return found === undefined ? RuleSupport.Unknown : found.support;
  }

  /**
   * 显示名。
   *
   * 未知 id 直接回显 id，与桌面版
   * `Name = string.IsNullOrEmpty(name) ? id : name` 同一个意图：让用户看得见
   * 自己填了些什么，而不是一个空白。
   */
  static displayNameOf(id: string): string {
    const found: RuleInfo | undefined = RuleCatalog.find(id);
    return found === undefined ? id : found.name;
  }

  /**
   * 把规则上的 Settings 解成强类型对象。
   *
   * 未知 id 返回 undefined（对应桌面版「没有 settingsType 就把原样传给 handler」
   * 的那条路，而所有 handler 都以 `settings is not X` 判否）。
   *
   * Settings 为 null 时按「空对象」解，等价于桌面版
   * `i.Settings ?? Activator.CreateInstance(settingsType)`：拿到的就是该类型的
   * 默认值，于是规则只会不成立，不会抛。
   */
  static settingsOf(rule: Rule): Object | undefined {
    const found: RuleInfo | undefined = RuleCatalog.find(rule.id);
    if (found === undefined) {
      return undefined;
    }
    // 自写判定函数不做类型收窄，所以这里要显式给一个 JsonNode 而不是 undefined。
    const raw: JsonNode = rule.settings === undefined ? new JsonObject() : rule.settings;
    if (found.settingsKind === RuleSettingsKind.StringMatching) {
      return StringMatchingSettings.parse(raw);
    }
    if (found.settingsKind === RuleSettingsKind.TimeState) {
      return TimeStateRuleSettings.parse(raw);
    }
    if (found.settingsKind === RuleSettingsKind.CurrentSubject) {
      return CurrentSubjectRuleSettings.parse(raw);
    }
    if (found.settingsKind === RuleSettingsKind.CurrentWeather) {
      return CurrentWeatherRuleSettings.parse(raw);
    }
    if (found.settingsKind === RuleSettingsKind.RainTime) {
      return RainTimeRuleSettings.parse(raw);
    }
    if (found.settingsKind === RuleSettingsKind.SunRiseSet) {
      return SunRiseSetRuleSettings.parse(raw);
    }
    if (found.settingsKind === RuleSettingsKind.WindowStatus) {
      return WindowStatusRuleSettings.parse(raw);
    }
    return undefined;
  }

  /** 新建一条该 id 的规则时该带什么设置。未知 id 返回 undefined。 */
  static defaultSettingsOf(id: string): Object | undefined {
    const found: RuleInfo | undefined = RuleCatalog.find(id);
    if (found === undefined) {
      return undefined;
    }
    if (found.settingsKind === RuleSettingsKind.StringMatching) {
      return new StringMatchingSettings();
    }
    if (found.settingsKind === RuleSettingsKind.TimeState) {
      return new TimeStateRuleSettings();
    }
    if (found.settingsKind === RuleSettingsKind.CurrentSubject) {
      return new CurrentSubjectRuleSettings();
    }
    if (found.settingsKind === RuleSettingsKind.CurrentWeather) {
      return new CurrentWeatherRuleSettings();
    }
    if (found.settingsKind === RuleSettingsKind.RainTime) {
      return new RainTimeRuleSettings();
    }
    if (found.settingsKind === RuleSettingsKind.SunRiseSet) {
      return new SunRiseSetRuleSettings();
    }
    if (found.settingsKind === RuleSettingsKind.WindowStatus) {
      return new WindowStatusRuleSettings();
    }
    return undefined;
  }
}
