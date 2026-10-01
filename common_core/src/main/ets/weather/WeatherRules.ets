/*
 * 五条天气规则的判定。对应桌面版 `WeatherService` 里那五个
 * `RegisterRuleHandler` 注册的处理器。
 *
 * 为什么要一个 WeatherSnapshot 而不是直接读盘
 * -----------------------------------
 * 桌面版处理器读的是 `Settings.LastWeatherInfo` 与一个进程内布尔
 * `IsWeatherRefreshed`。前者是全局可变状态，后者更麻烦 —— 它不在 Settings 里，
 * 所以**不落盘**，重启之后是 false，直到本轮第一次查询成功才变 true。
 *
 * 这个区别在界面上看得见：应用刚启动、首次查询还没回来的那几秒，
 * 天气类规则一律判 false。本端照抄（快照的 isRefreshed 同样只在
 * 一次成功查询之后才置位），因为「刚启动时面板按哪套规则显示」是一个
 * 用户能观察到的行为，两端不一致会很难解释。
 *
 * isRefreshed 与「有没有数据」是两件事
 * ---------------------------------
 * 缓存从 weather.json 读回来之后，**显示**用的数据是有的（天气组件照常显示
 * 上次的温度），但规则仍然判 false。所以这个快照同时带着 info（可能来自缓存）
 * 和 isRefreshed（只反映本轮查询），规则各自决定要看哪个。桌面版就是这个
 * 形状：组件绑 Settings.LastWeatherInfo，规则额外看 IsWeatherRefreshed。
 */

import {
  CurrentWeatherRuleSettings,
  RainTimeRuleSettings,
  StringMatchingSettings,
  SunRiseSetRuleSettings,
  WeatherInfo,
  DateTimeValue,
  RuleIds
} from 'common_shared';
import {
  tryGetSunTimes,
  SunTimes
} from './WeatherLogic';
import { isWeatherCodeMatched } from './WeatherCodes';

/**
 * 一次天气快照。
 *
 * 由 entry 的 WeatherService 在每次刷新后整份替换掉再交给规则求值，
 * 求值过程本身不改它 —— 与 RuleEngine 的「纯函数 + 返回轨迹」同一条纪律。
 */
export class WeatherSnapshot {
  /**
   * 本次进程内是否成功取到过天气。对应桌面版 `WeatherService.IsWeatherRefreshed`。
   *
   * 注意它**不**因为「从缓存读到了数据」而变 true。
   */
  isRefreshed: boolean = false;
  /** 最近一次的天气。可能来自缓存，也可能是空对象。 */
  info: WeatherInfo = new WeatherInfo();

  /** 便捷构造：未知（没有天气服务时用）。规则全判 false。 */
  static unknown(): WeatherSnapshot {
    return new WeatherSnapshot();
  }
}

/** 「当前天气是」。对应 `CurrentWeatherRuleHandler`。 */
export function currentWeatherSatisfied(settings: CurrentWeatherRuleSettings,
  snapshot: WeatherSnapshot): boolean {
  if (!snapshot.isRefreshed) {
    return false;
  }
  const actual: string = snapshot.info.current.weather;
  const target: string = `${settings.weatherId}`;
  if (settings.isFuzzyMatch) {
    return isWeatherCodeMatched(actual, target);
  }
  return target === actual;
}

/**
 * 「明天天气是」。对应 `TomorrowWeatherRuleHandler`。
 *
 * 日预报的 `weather.value[1]` 是**明天**（下标 0 是今天）。取不到第二天直接
 * 判 false，不做「拿最后一天凑数」的兜底 —— 那会让「明天」在下拉菜单里
 * 名不副实。桌面版同样直接 false。
 */
export function tomorrowWeatherSatisfied(settings: CurrentWeatherRuleSettings,
  snapshot: WeatherSnapshot): boolean {
  if (!snapshot.isRefreshed) {
    return false;
  }
  const values = snapshot.info.forecastDaily.weather.value;
  if (values.length <= 1) {
    return false;
  }
  const tomorrow = values[1];
  const target: string = `${settings.weatherId}`;
  if (settings.isFuzzyMatch) {
    return isWeatherCodeMatched(tomorrow.from, target) || isWeatherCodeMatched(tomorrow.to, target);
  }
  return tomorrow.from === target || tomorrow.to === target;
}

/**
 * 「存在气象预警」。对应 `HasAlertRuleHandler`。
 *
 * 只匹配**标题**，不匹配详情。桌面版如此（`settings.IsMatching(x.Title)`）。
 * 匹配详情会让「预警详情里提到『暴雨』」的任意一条高温预警也命中，
 * 这是刻意没做的。
 */
export function hasWeatherAlertSatisfied(settings: StringMatchingSettings,
  snapshot: WeatherSnapshot): boolean {
  if (!snapshot.isRefreshed) {
    return false;
  }
  for (const alert of snapshot.info.alerts) {
    if (settings.isMatching(alert.title)) {
      return true;
    }
  }
  return false;
}

/**
 * 「距离降水开始 / 结束还剩」。对应 `RainTimeRuleHandler`。
 *
 * `rainRemainingMinutes` 的符号定义了方向：负数是「正在下、还有 n 分钟停」，
 * 正数是「n 分钟后开始下」。`isRemainingTime` 为真时取负号那一档
 * （还剩多久停），为假时取正号那一档（多久后开始）。
 *
 * 这里**没有** isRefreshed 判断，是照抄：没有数据时 minutely 的列表为空，
 * rainRemainingMinutes 返回 0，`0 > 0` 为假，结果一样。加一个判断只是
 * 多一条永远走不到的短路。
 */
export function rainTimeSatisfied(settings: RainTimeRuleSettings,
  snapshot: WeatherSnapshot): boolean {
  const remaining: number = snapshot.info.minutely.precipitation.rainRemainingMinutes();
  const baseTime: number = (settings.isRemainingTime ? -1.0 : 1.0) * remaining;
  return baseTime > 0 && baseTime <= settings.rainTimeMinutes;
}

/**
 * 「是否日出 / 日落」。对应 `SunRiseSetRuleHandler`。
 *
 * `isSunset` 为真时判「现在是夜里」（日落后 或 日出前），为假时判「白天」。
 * 两个条件都是**左闭右开**的小心写法：日出那一刻算白天，日落那一刻算夜里，
 * 不会出现某一秒两边都成立或都不成立。
 *
 * 注意 `SunRiseSetRuleSettings.TimeMinutes` 这个字段桌面版**从来没读过** ——
 * 它在编辑器里有输入框、会落盘，但处理器不看它。本端照抄（不读），
 * 否则「同一份配置两端行为不同」。字段本身仍读写，以保住往返。
 */
export function sunRiseSetSatisfied(settings: SunRiseSetRuleSettings,
  snapshot: WeatherSnapshot, now: DateTimeValue): boolean {
  if (!snapshot.isRefreshed) {
    return false;
  }
  const sun: SunTimes | undefined = tryGetSunTimes(snapshot.info, now);
  if (sun === undefined) {
    return false;
  }
  const nowMillis: number = now.toLocalMillis();
  const riseMillis: number = sun.sunrise.toLocalMillis();
  const setMillis: number = sun.sunset.toLocalMillis();
  if (settings.isSunset) {
    return nowMillis >= setMillis || nowMillis < riseMillis;
  }
  return nowMillis >= riseMillis && nowMillis < setMillis;
}

/**
 * 按 id 分派。RuleEngine 只调这一个入口。
 *
 * 快照为 undefined（天气服务还没起来）时全判 false，与「未刷新」同结果，
 * 也保证面板与规则编辑器在天气模块缺失时行为不变。
 *
 * 传入的 settings 类型是 Object，因为 RuleEngine 的处理器签名是统一的；
 * 各分支自己做类型收窄，判错就返回 false —— 对应桌面版 `if (o is not X) return false`。
 */
export function weatherRuleSatisfied(id: string, settings: Object,
  snapshot: WeatherSnapshot | undefined, now: DateTimeValue): boolean {
  if (snapshot === undefined) {
    return false;
  }
  // 用类型断言而不是 instanceof 收窄。理由有二：
  //   1. settings 由 RuleCatalog.settingsOf 按注册表里的 settingsKind 解出来，
  //      类型是那张表保证的，再判一次是多余的；
  //   2. core 侧的类型从 'common_shared' 这个入口进来，而对象可能由别处按深路径
  //      构造 —— 两个模块实例的类用 instanceof 比永远为假，症状是「所有天气规则
  //      恒不成立」且不报错。
  // 现有 RuleEngine.handle 处理 TimeStateRuleSettings 用的就是同一套写法。
  if (id === RuleIds.WEATHER_CURRENT) {
    return currentWeatherSatisfied(settings as CurrentWeatherRuleSettings, snapshot);
  }
  if (id === RuleIds.WEATHER_TOMORROW) {
    return tomorrowWeatherSatisfied(settings as CurrentWeatherRuleSettings, snapshot);
  }
  if (id === RuleIds.WEATHER_ALERT) {
    return hasWeatherAlertSatisfied(settings as StringMatchingSettings, snapshot);
  }
  if (id === RuleIds.WEATHER_RAIN_TIME) {
    return rainTimeSatisfied(settings as RainTimeRuleSettings, snapshot);
  }
  if (id === RuleIds.WEATHER_SUN_RISE_SET) {
    return sunRiseSetSatisfied(settings as SunRiseSetRuleSettings, snapshot, now);
  }
  return false;
}
