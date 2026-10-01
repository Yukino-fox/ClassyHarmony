/*
 * 天气简报组件的渲染数据。
 *
 * 为什么单独一个文件而不是塞进 PanelBuilder
 * -----------------------------------
 * `PanelNode` 里给天气留了一组专属字段（主信息、AQI、预警列表、降雨倒计时）。
 * 把它们怎么算出来的逻辑放在这里，`PanelModel.ets` 只负责「调一下、填进去」，
 * 于是这个文件可以在 Node 测试台里拿一份构造好的 WeatherInfo 直接撞 ——
 * 而「预警要不要显示」「降雨倒计时用模糊还是精确」这类判断，最容易出错的
 * 恰恰是边界（0 值、列表为空、开关为假），不去逐条撞一遍不放心。
 *
 * 与桌面版的一处刻意分歧：图标换成文字
 * --------------------------------
 * 桌面版的天气组件用图标字体（Lucide / Fluent Design / SF Symbols 三选一，
 * 由 Settings.WeatherIconId 决定）画天气、风向箭头、AQI、气压、体感、雨。
 * 那三套图标都有各自的字体文件或符号表，本端没有移植（HAR 里没有那些字形，
 * ArkUI 也没有对应的图标组件）。所以：
 *   - 「主信息」一律带上中文标签或天气文字，而不是只画图标 + 数值。
 *     例如 kind=0 在桌面版是「[天气图标] 26°C」，这里是「晴 26°C」；
 *     kind=3 在桌面版是「[AQI图标] 42」，这里是「AQI 42」。
 *   - 预警项一律显示类型文字，不显示图标（桌面版的图标来自一个 http 的
 *     .webp 链接，既要放行明文 HTTP 又不保证加载成功，不值得）。
 * 代价：`MainWeatherInfoKind` / `AlertsTitleShowMode` 这两个设置在视觉上
 * 没有桌面版那么明显（kind 仍能切换显示哪一项，只是每项都带标签）。这一点
 * 写进了设置页的说明里，没有藏起来。
 */

import { WeatherInfo, ValueUnitPair } from 'common_shared';
import { WeatherPayload } from '../components/ComponentPayloads';
import { minutesToApproxTime } from './WeatherLogic';
import { weatherTextByCode } from './WeatherCodes';

/** 一条要显示的预警。 */
export class WeatherAlertBrief {
  /** 预警类型，例如「暴雨」。界面这一栏显示它。 */
  type: string = '';
  /** 标题。桌面版在 tooltip / 完整形态里显示；本端留作备用。 */
  title: string = '';
  /** 预警等级，对端给的字符串原样保留。 */
  level: string = '';
  /** 图标 URL。本端不加载，保留它是为了将来接上图标时不用再动 core。 */
  iconUrl: string = '';
  /**
   * 是否为小米的默认图标。
   *
   * 桌面版用它决定「按等级着色」还是「原样显示自定义图标」。本端显示的是
   * 文字，所以暂时只作为数据保留。
   */
  isDefaultIcon: boolean = false;
}

/** 天气简报组件要显示的全部内容。 */
export class WeatherBrief {
  /**
   * 主信息文字。`ShowMainWeatherInfo` 为假（或没有数据）时是空串。
   *
   * 空串表示「这一项不显示」，而不是「显示空字符串」，界面据此跳过。
   */
  mainText: string = '';
  /**
   * 主信息种类 0..5，与 `WeatherComponentSettings.MainWeatherInfoKind` 同值：
   * 0 天气、1 湿度、2 风、3 AQI、4 气压、5 体感。
   *
   * 界面用它决定「这一行要不要换色」（只有 AQI 会按档位换色）。
   */
  mainKind: number = 0;
  /** AQI 档位 1..6。只有 mainKind === 3 时有意义，界面据此取色。 */
  aqiLevel: number = 0;
  /** 要显示的预警，最多就是数据里有的条数。 */
  alerts: WeatherAlertBrief[] = [];
  /** 降雨倒计时。空串表示不显示。 */
  rainText: string = '';
}

/** 主信息种类的取值。用常量而不是裸数字，免得 0..5 的含义散落在各处。 */
export const WEATHER_MAIN_KIND_CONDITION: number = 0;
export const WEATHER_MAIN_KIND_HUMIDITY: number = 1;
export const WEATHER_MAIN_KIND_WIND: number = 2;
export const WEATHER_MAIN_KIND_AQI: number = 3;
export const WEATHER_MAIN_KIND_PRESSURE: number = 4;
export const WEATHER_MAIN_KIND_FEELS_LIKE: number = 5;

/**
 * 把一份天气与一份组件设置折成界面要画的东西。
 *
 * 没有数据（info 为 undefined，或从没取过且缓存为空）时返回一个空 brief：
 * 界面会什么都不画。桌面版此时画的是初始值（`Weather = "99"`、各 ValueUnitPair
 * 都是空串），也就是一个空的「未知 °」——比不画更难看。这里选择不画，
 * 并在面板层给一句「天气数据还没取到」的提示（见 PanelBuilder）。
 */
export function buildWeatherBrief(payload: WeatherPayload,
  info: WeatherInfo | undefined): WeatherBrief {
  const brief: WeatherBrief = new WeatherBrief();
  if (info === undefined) {
    return brief;
  }

  brief.mainKind = payload.mainWeatherInfoKind;
  brief.aqiLevel = info.aqi.aqiLevel();
  if (payload.showMainWeatherInfo) {
    brief.mainText = mainTextOf(payload.mainWeatherInfoKind, info);
  }
  if (payload.showRainTime) {
    brief.rainText = rainTextOf(payload, info);
  }
  if (payload.showAlerts) {
    for (const alert of info.alerts) {
      const item: WeatherAlertBrief = new WeatherAlertBrief();
      item.type = alert.type;
      item.title = alert.title;
      item.level = alert.level;
      item.iconUrl = alert.images.getOrDefault('icon', '');
      item.isDefaultIcon = alert.isDefaultIcon() === 1;
      brief.alerts.push(item);
    }
  }
  return brief;
}

function mainTextOf(kind: number, info: WeatherInfo): string {
  if (kind === WEATHER_MAIN_KIND_HUMIDITY) {
    return `湿度 ${pairText(info.current.humidity)}`;
  }
  if (kind === WEATHER_MAIN_KIND_WIND) {
    // 桌面版画一个按风向旋转的箭头 + 风速。没有箭头，就把风向文字放前面 ——
    // 比只留一个风速数值信息量大，而且「东风 3级」本来就是人读风向的方式。
    const direction: string = info.current.wind.direction.value;
    const speed: string = pairText(info.current.wind.speed);
    if (direction.length === 0) {
      return speed;
    }
    return `${direction} ${speed}`;
  }
  if (kind === WEATHER_MAIN_KIND_AQI) {
    return `AQI ${info.aqi.aqi}`;
  }
  if (kind === WEATHER_MAIN_KIND_PRESSURE) {
    return `气压 ${pairText(info.current.pressure)}`;
  }
  if (kind === WEATHER_MAIN_KIND_FEELS_LIKE) {
    return `体感 ${pairText(info.current.feelsLike)}`;
  }
  // 默认走「天气 + 温度」。未知的 kind 值（用户手改文件塞进来的）也落这里，
  // 与桌面版「所有 kind 都不等时没有任何 Border 可见」不同 —— 本端至少显示
  // 最常用的那一项，好过整块空白。
  return `${weatherTextByCode(info.current.weather)} ${pairText(info.current.temperature)}`;
}

/** 「值 + 单位」。两者都空时返回空串，免得界面上出现一个孤零零的单位。 */
function pairText(pair: ValueUnitPair): string {
  // 数值为空时返回空串，不返回光秃秃的单位。桌面版会照画那个单位
  // （初始值下界面上就是「°」），但那是绑定的默认形状，不是刻意的；
  // 这里按「没有数值就等于没有这一项」处理。
  if (pair.value.length === 0) {
    return '';
  }
  return pair.toString();
}

/**
 * 降雨倒计时。
 *
 * `RainRemainingMinutes` 为 0 时不显示 —— 0 的含义是「说不清」（没数据 /
 * 两小时内不下 / 雨覆盖满整个列表），不是一个真实的倒计时。桌面版用
 * `!!RainRemainingMinutes` 做同一个判断。
 *
 * `IsFuzzyLongRainCountdownEnabled` 决定要不要把「97min」写成「~1.5h」。
 * 关掉时按桌面版的 `{0}min` 格式输出原始整数，**负数也照实显示**
 * （`-30min` 表示雨还有 30 分钟停）。
 */
function rainTextOf(payload: WeatherPayload, info: WeatherInfo): string {
  const remaining: number = info.minutely.precipitation.rainRemainingMinutes();
  if (remaining === 0) {
    return '';
  }
  if (payload.isFuzzyLongRainCountdownEnabled) {
    return minutesToApproxTime(remaining);
  }
  return `${remaining}min`;
}
