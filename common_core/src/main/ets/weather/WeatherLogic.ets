/*
 * 天气的纯计算：预警筛选、日出日落、降雨倒计时文案、风向角度。
 *
 * 为什么这些放在 core
 * ----------------
 * 它们全部是「给一批数据 → 出一个结果」，没有网络、没有文件、没有平台 API，
 * 所以能进 Node 测试台逐条撞边界。桌面版把这些逻辑埋在 `WeatherService` 里
 * （一个同时管着 IHostedService、HTTP、DispatcherTimer 的类），结果就是
 * 「预警去重对不对」这件事没有任何单测 —— 而它恰恰是最容易悄悄错的部分：
 * 去重错的症状是「少了一条预警」或者「同一条预警念两遍」，两种都不会报错。
 *
 * 除号在哪
 * ------
 * 天气的**取数**（HTTP、定位、5 分钟定时器）在 entry 的 WeatherService。
 * 这里只负责把取回来的 `WeatherInfo` 变成「界面要显示的那几个数」。
 */
import { t } from '../i18n/I18n';

import {
  DateTimeValue,
  WeatherAlert,
  WeatherInfo,
  parseWeatherNumber
} from 'common_shared';

/** 一对日出日落时刻。 */
export class SunTimes {
  sunrise: DateTimeValue = DateTimeValue.minValue();
  sunset: DateTimeValue = DateTimeValue.minValue();
}

/**
 * 排除 + 去重气象预警。对应桌面版 `QueryWeatherWithResultAsync` 里那两段。
 *
 * 步骤与顺序都不能换：
 *   1. 排除：`ExcludedWeatherAlerts` 里**非空白**的每一项，只要它是
 *      预警标题或详情的子串，这条预警就被丢掉。空串必须排除掉，否则
 *      空串是任何字符串的子串，会把所有预警清空 —— 桌面版那句
 *      `.Where(x => !string.IsNullOrWhiteSpace(x))` 就是干这个的。
 *   2. 去重：按 `type` 分组，每组只留 `pubTime` 最大的那条。
 *
 * 「只留最新的一条」的并列规则
 * --------------------------
 * .NET 的 `MaxBy` 在键相等时保留**先出现**的那一条（它只在
 * `comparison > 0` 时替换）。所以这里用严格大于比较：同一 type、同一 pubTime
 * 的两条，留列表里靠前的那条。这条规则不会在真实数据里触发（同一个
 * alertId 不会重复），但把「并列怎么办」写死成和桌面版一致，比留一个
 * 「取决于实现」的空档好。
 *
 * 输出顺序：按 type **首次出现**的顺序，与桌面版 `ToDictionary(...).Values`
 * 的顺序一致。这个顺序会决定界面上预警的排列，所以不能换成按 pubTime 排 ——
 * 那会让「刚发布的预警跳到最前」这种视觉变化在两端不一致。
 */
export function filterWeatherAlerts(alerts: WeatherAlert[], exclusions: string[]): WeatherAlert[] {
  const validExclusions: string[] = [];
  for (const exclusion of exclusions) {
    if (exclusion.trim().length > 0) {
      validExclusions.push(exclusion);
    }
  }

  const typeOrder: string[] = [];
  const bestByType: Map<string, WeatherAlert> = new Map<string, WeatherAlert>();
  for (const alert of alerts) {
    if (validExclusions.length > 0 && isExcluded(alert, validExclusions)) {
      continue;
    }
    const current: WeatherAlert | undefined = bestByType.get(alert.type);
    if (current === undefined) {
      typeOrder.push(alert.type);
      bestByType.set(alert.type, alert);
      continue;
    }
    if (alert.pubTime.toLocalMillis() > current.pubTime.toLocalMillis()) {
      bestByType.set(alert.type, alert);
    }
  }

  const out: WeatherAlert[] = [];
  for (const type of typeOrder) {
    const alert: WeatherAlert | undefined = bestByType.get(type);
    if (alert !== undefined) {
      out.push(alert);
    }
  }
  return out;
}

function isExcluded(alert: WeatherAlert, exclusions: string[]): boolean {
  for (const exclusion of exclusions) {
    if (alert.title.includes(exclusion) || alert.detail.includes(exclusion)) {
      return true;
    }
  }
  return false;
}

/**
 * 找今天的日出日落。对应桌面版 `WeatherService.TryGetSunTimes`。
 *
 * 桌面版用 `sr.Date == now.Date || ss.Date == now.Date` 认「这是今天那一组」。
 * 用 `||` 而不是 `&&` 是一个刻意的宽松：跨零点前后（比如 23:59 查到的
 * 那组日出是明天、日落是今天）也能认出来。照抄。
 *
 * 取不到返回 undefined，调用方（日出日落规则）据此判 false —— 与桌面版
 * 「解析失败继续找下一条、找不到返回 false」一致。
 */
export function tryGetSunTimes(info: WeatherInfo, now: DateTimeValue): SunTimes | undefined {
  const today: DateTimeValue = now.dateOnly();
  for (const item of info.forecastDaily.sunRiseSet.value) {
    const sunrise: DateTimeValue | undefined = DateTimeValue.tryParse(item.from);
    if (sunrise === undefined) {
      continue;
    }
    const sunset: DateTimeValue | undefined = DateTimeValue.tryParse(item.to);
    if (sunset === undefined) {
      continue;
    }
    if (sunrise.dateOnly().equals(today) || sunset.dateOnly().equals(today)) {
      const out: SunTimes = new SunTimes();
      out.sunrise = sunrise;
      out.sunset = sunset;
      return out;
    }
  }
  return undefined;
}

/**
 * 「已过 / 还剩多少分钟」的模糊化文案。对应桌面版
 * `MinutesToApproxTimeConverter`。
 *
 * 三档：
 *   |n| == 0        → `0min`
 *   |n| >= 60       → `~1.5h`（半小时取整，注意是 `AwayFromZero`：
 *                      -1.5h 变成 `~-1.5h`，不是 `~-1h` 或 `~-2h`）
 *   其它            → `-30min` / `30min`（这一档**不**加 `~`）
 *
 * 大于等于 60 分钟时不显示精确分钟，是刻意的：分钟级预报的有效期就是两小时，
 * 报「~97min」比报「~1.5h」既长又假精确。
 */
export function minutesToApproxTime(minutes: number): string {
  const isNegative: boolean = minutes < 0;
  const absMinutes: number = Math.abs(minutes);
  if (absMinutes === 0) {
    return '0min';
  }
  const approxPrefix: string = isNegative ? '~-' : '~';
  if (absMinutes >= 60) {
    const hours: number = absMinutes / 60.0;
    const rounded: number = roundAwayFromZero(hours * 2.0) / 2.0;
    const text: string = Math.abs(rounded % 1.0) < 1e-9
      ? `${Math.trunc(rounded)}`
      : rounded.toFixed(1);
    return `${approxPrefix}${text}h`;
  }
  const exactPrefix: string = isNegative ? '-' : '';
  return `${exactPrefix}${absMinutes}min`;
}

/**
 * 四舍五入、中点远离零。对应 .NET `Math.Round(x, MidpointRounding.AwayFromZero)`。
 *
 * 不用 `Math.round`：JS 的 `Math.round(-2.5)` 是 -2（向 +∞），.NET 的
 * AwayFromZero 给 -3。这里的中点只可能出现在 `hours * 2` 上（即 15 分钟的
 * 整数倍），是真实会走到的路径，不是理论边界。
 */
function roundAwayFromZero(value: number): number {
  return value >= 0 ? Math.floor(value + 0.5) : Math.ceil(value - 0.5);
}

/**
 * 风向文字转角度。对应桌面版 `WindDirectionConverter.Convert`。
 *
 * 小米给的是**风的来向**的度数，而箭头图标画的是指向，所以转成
 * 「来向 + 180」再对 360 取模。
 *
 * 解析不出来给 0 —— 注意 0 在图标上不是「正北」，而是「不旋转」，即
 * 保持图标默认朝向。屏幕上看不出「解析失败」与「正北风」的区别；
 * 桌面版同样如此，这里不改。
 */
export function windDirectionDegrees(directionText: string): number {
  const parsed: number | undefined = parseWeatherNumber(directionText);
  if (parsed === undefined) {
    return 0;
  }
  return (parsed + 180.0) % 360.0;
}

/**
 * AQI 的档位名。桌面版没有这个函数（它只把数字按档位染色），
 * 本端用它给无障碍朗读与设置页提供中文描述。
 */
export function aqiLevelName(level: number): string {
  if (level <= 1) {
    return t('aqi_excellent');
  }
  if (level === 2) {
    return t('aqi_good');
  }
  if (level === 3) {
    return t('aqi_light');
  }
  if (level === 4) {
    return t('aqi_moderate');
  }
  if (level === 5) {
    return t('aqi_heavy');
  }
  return t('aqi_severe');
}
