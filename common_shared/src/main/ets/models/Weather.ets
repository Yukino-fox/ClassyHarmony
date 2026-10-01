/*
 * 天气模型。对应 ClassIsland.Core/Models/Weather 下的 17 个类。
 *
 * 为什么这个文件的键名是 camelCase，而别的模型是 PascalCase
 * ------------------------------------------------------
 * 别的模型（Settings / Profile / ClassPlan）落盘时走 System.Text.Json 的默认
 * options，没有命名策略，所以键名就是 C# 属性名（PascalCase）。天气这一族是
 * 例外：每个字段上都有 `[JsonPropertyName("camelCase")]`，因为这套类型**同时
 * 是小米天气 API 的响应模型**，属性名得按对端的格式来。
 *
 * 所以同一个 `WeatherInfo` 有两种用途：
 *   1. 解析 `weatherapi.market.xiaomi.com` 的响应；
 *   2. 桌面版把它整个存进 settings.json 的 `LastWeatherInfo`。
 * 两处的键名都是 camelCase，因此这里只有一个 codec 需要维护 —— 这也是为什么
 * 它放在 common_shared 而不是 entry：它是**跨端读写**的格式。
 *
 * 本端把缓存存在 weather.json（不是 settings.json）
 * ----------------------------------------------
 * 桌面版把最近一次天气整个塞进 settings.json 的 `LastWeatherInfo`，由
 * SettingsService 统一序列化。本端不这么做，理由见 entry 的 WeatherStore：
 * 每 5 分钟一次的刷新会把整份设置文件重写一遍，而设置文件还同时被设置页、
 * 自动化行动、小组件读写 —— 为一个纯缓存把它变成高频写目标不划算。
 *
 * 代价：`LastWeatherInfo` 在 settings.json 里会停在我们不动的那个旧值上。
 * AppPreferences 的写入是「读全文、改键、写回」，未知键原样保留，所以桌面版
 * 写过的缓存不会被抹掉（只是不再更新），下次桌面版启动会自己刷新。
 *
 * 故意比桌面版宽容的两处
 * --------------------
 *   - `aqi`：桌面版声明为 string，若对端给了数字会在反序列化时抛。这里
 *     字符串和数字都收（数字取字面量）。天气是缓存，一次解析失败不该让整块
 *     面板变空。
 *   - `alerts[].images`：桌面版的 `IsDefaultIcon` 用字典索引器取 `icon`，
 *     键不存在会抛 KeyNotFoundException。这里缺键返回 0（不是默认图标），
 *     与「取不到图标就按自定义图标处理」的意图一致。
 * 二者都只在**对端给了意外形状**时才走到，正常数据下与桌面版逐字同结果。
 *
 * 数字字段
 * ------
 * hourly 的 temperature/weather 在 C# 里是 `List<int>`，minutely 的 value 是
 * `List<double>`。两者在 ArkTS 里都是 number[]，区别只在写出时用 ofInt 还是
 * of，所以分了 IntListStatus / DoubleListStatus 两个类。这不是冗余：合成一个
 * 类会让 minutely 的 0.5 有被截成 0 的风险。
 */

import { KeyedMap } from '../collections/KeyedMap';
import { DateTimeValue } from '../json/DateTimeValue';
import { JsonNode, JsonObject, JsonString } from '../json/JsonNode';
import { JsonValue } from '../json/JsonValue';
import { ModelCodec } from './ModelCodec';

/** 天气代码缺失时的默认值。桌面版 `CurrentWeather.Weather` 的初始值。 */
export const WEATHER_CODE_UNKNOWN: string = '99';

/** `WeatherInfo.alerts[].images` 里默认图标所在的那个键。 */
const ALERT_ICON_KEY: string = 'icon';

/**
 * 严格数字。对应 .NET 的 `double.TryParse(text, out var r)`（默认样式）。
 *
 * 不用 `Number.parseFloat`：它会把 `"39.9abc"` 读成 `39.9`，而 .NET 的
 * TryParse 因为「整串必须消费完」会返回 false。数值字段一律严格 —— 一个读不懂
 * 的数值应该退回默认值，而不是被悄悄截成半个数。
 *
 * 与 .NET 的一处刻意收窄：**不认千分位分隔符**。
 * 桌面版那个重载用的是 `NumberStyles.Float | AllowThousands`，所以
 * `"1,234"` 在它那边解析成 1234；这里返回 undefined。
 * 收窄的理由：会喂进这个函数的只有小米接口的 `aqi` 与风向角度，两者都是
 * 无分隔的裸数字串；支持分隔符只会让「手改坏的缓存」多一种被接受的形状，
 * 而本端本来就该把读不懂的缓存退回默认值。
 * 记在这里是为了**将来若有人拿桌面版同一串输入对比时不会以为这是 bug** ——
 * 真实数据下两者逐字同结果。
 */
export function parseWeatherNumber(text: string): number | undefined {
  const trimmed: string = text.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  if (!/^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$/.test(trimmed)) {
    return undefined;
  }
  const value: number = Number(trimmed);
  return Number.isNaN(value) ? undefined : value;
}

/**
 * 四个小米默认预警图标的 URL。
 *
 * 桌面版用 C# 的 `is ... or ...` 模式匹配。这张表的作用是判断「这条预警用的是
 * 默认图标还是自定义图标」—— 组件上用默认图标时按等级着色，自定义图标时原样
 * 显示，不给它染色（染色会把别人画的图变成一团色块）。
 */
const DEFAULT_ALERT_ICON_URLS: string[] = [
  'http://f5.market.xiaomi.com/download/Weather/0ac110d2ee20a454ab44f5df30f9fa6ff650e0b72/a.webp', // 蓝色
  'http://f4.market.mi-img.com/download/Weather/072013febeb1944da85649e5e547ec5a8284816a/a.webp', // 黄色
  'http://f5.market.xiaomi.com/download/Weather/06db501333e6d4075a3364a66cdf23ba5733111b3/a.webp', // 橙色
  'http://f3.market.xiaomi.com/download/Weather/03e3e096d3d9e485fa33bbf833fc3b3c96c23d014/a.webp' // 红色
];

/** 「值 + 单位」。桌面上重写了 ToString()，界面上直接用。 */
export class ValueUnitPair {
  value: string = '';
  unit: string = '';

  /** 对应桌面版 `ValueUnitPair.ToString()`。 */
  toString(): string {
    return `${this.value}${this.unit}`;
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('value', new JsonString(this.value));
    out.set('unit', new JsonString(this.unit));
    return out;
  }

  static parse(node: JsonNode): ValueUnitPair {
    const out: ValueUnitPair = new ValueUnitPair();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.value = ModelCodec.string(obj, 'value', '');
    out.unit = ModelCodec.string(obj, 'unit', '');
    return out;
  }
}

/** 风向 + 风速。 */
export class WindInfo {
  direction: ValueUnitPair = new ValueUnitPair();
  speed: ValueUnitPair = new ValueUnitPair();

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('direction', this.direction.toJson());
    out.set('speed', this.speed.toJson());
    return out;
  }

  static parse(node: JsonNode): WindInfo {
    const out: WindInfo = new WindInfo();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    const direction: JsonNode | undefined = obj.tryGet('direction');
    if (direction !== undefined) {
      out.direction = ValueUnitPair.parse(direction);
    }
    const speed: JsonNode | undefined = obj.tryGet('speed');
    if (speed !== undefined) {
      out.speed = ValueUnitPair.parse(speed);
    }
    return out;
  }
}

/** 实时天气。 */
export class CurrentWeather {
  feelsLike: ValueUnitPair = new ValueUnitPair();
  humidity: ValueUnitPair = new ValueUnitPair();
  pressure: ValueUnitPair = new ValueUnitPair();
  temperature: ValueUnitPair = new ValueUnitPair();
  visibility: ValueUnitPair = new ValueUnitPair();
  /** 天气代码（字符串形式的整数），见 WeatherCodes.weatherTextByCode。 */
  weather: string = WEATHER_CODE_UNKNOWN;
  pubTime: DateTimeValue = DateTimeValue.minValue();
  wind: WindInfo = new WindInfo();

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('feelsLike', this.feelsLike.toJson());
    out.set('humidity', this.humidity.toJson());
    out.set('pressure', this.pressure.toJson());
    out.set('temperature', this.temperature.toJson());
    out.set('visibility', this.visibility.toJson());
    out.set('weather', new JsonString(this.weather));
    out.set('pubTime', ModelCodec.dateTimeNode(this.pubTime));
    out.set('wind', this.wind.toJson());
    return out;
  }

  static parse(node: JsonNode): CurrentWeather {
    const out: CurrentWeather = new CurrentWeather();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    const feelsLike: JsonNode | undefined = obj.tryGet('feelsLike');
    if (feelsLike !== undefined) {
      out.feelsLike = ValueUnitPair.parse(feelsLike);
    }
    const humidity: JsonNode | undefined = obj.tryGet('humidity');
    if (humidity !== undefined) {
      out.humidity = ValueUnitPair.parse(humidity);
    }
    const pressure: JsonNode | undefined = obj.tryGet('pressure');
    if (pressure !== undefined) {
      out.pressure = ValueUnitPair.parse(pressure);
    }
    const temperature: JsonNode | undefined = obj.tryGet('temperature');
    if (temperature !== undefined) {
      out.temperature = ValueUnitPair.parse(temperature);
    }
    const visibility: JsonNode | undefined = obj.tryGet('visibility');
    if (visibility !== undefined) {
      out.visibility = ValueUnitPair.parse(visibility);
    }
    out.weather = ModelCodec.string(obj, 'weather', WEATHER_CODE_UNKNOWN);
    out.pubTime = ModelCodec.readDateTime(obj, 'pubTime');
    const wind: JsonNode | undefined = obj.tryGet('wind');
    if (wind !== undefined) {
      out.wind = WindInfo.parse(wind);
    }
    return out;
  }
}

/**
 * 一个区间。
 *
 * 日预报里 `temperature` / `weather` / `sunRiseSet` 的元素都是它，字段都是
 * 字符串：`weather` 的 from/to 是天气代码，`sunRiseSet` 的 from/to 是时刻
 * （`yyyy-MM-dd HH:mm:ss`），`temperature` 的是温度数值的字符串形式。
 */
export class RangedValue {
  from: string = '';
  to: string = '';

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('from', new JsonString(this.from));
    out.set('to', new JsonString(this.to));
    return out;
  }

  static parse(node: JsonNode): RangedValue {
    const out: RangedValue = new RangedValue();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.from = ModelCodec.string(obj, 'from', '');
    out.to = ModelCodec.string(obj, 'to', '');
    return out;
  }
}

/** `StatusValueBase<List<string>>`。日降水概率。 */
export class StringListStatus {
  value: string[] = [];

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('value', ModelCodec.writeArray(this.value, (v: string) => new JsonString(v)));
    return out;
  }

  static parse(node: JsonNode): StringListStatus {
    const out: StringListStatus = new StringListStatus();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.value = ModelCodec.readArray(obj, 'value', (n: JsonNode) => JsonValue.asString(n, ''));
    return out;
  }
}

/** `StatusValueBase<List<RangedValue>>`。日温度 / 日天气 / 日出日落。 */
export class RangedListStatus {
  value: RangedValue[] = [];

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('value', ModelCodec.writeArray(this.value, (v: RangedValue) => v.toJson()));
    return out;
  }

  static parse(node: JsonNode): RangedListStatus {
    const out: RangedListStatus = new RangedListStatus();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.value = ModelCodec.readArray(obj, 'value', (n: JsonNode) => RangedValue.parse(n));
    return out;
  }
}

/** `StatusValueBase<List<int>>`。逐小时温度 / 天气代码。 */
export class IntListStatus {
  value: number[] = [];

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('value', ModelCodec.writeArray(this.value, (v: number) => ModelCodec.intNode(v)));
    return out;
  }

  static parse(node: JsonNode): IntListStatus {
    const out: IntListStatus = new IntListStatus();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.value = ModelCodec.readArray(obj, 'value', (n: JsonNode) => JsonValue.asInt(n, 0));
    return out;
  }
}

/** `StatusValueBase<List<double>>`。分钟级降水。 */
export class DoubleListStatus {
  value: number[] = [];

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('value', ModelCodec.writeArray(this.value, (v: number) => ModelCodec.doubleNode(v)));
    return out;
  }

  static parse(node: JsonNode): DoubleListStatus {
    const out: DoubleListStatus = new DoubleListStatus();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.value = ModelCodec.readArray(obj, 'value', (n: JsonNode) => JsonValue.asNumber(n, 0));
    return out;
  }
}

/** 逐日预报。 */
export class ForecastDaily {
  precipitationProbability: StringListStatus = new StringListStatus();
  temperature: RangedListStatus = new RangedListStatus();
  weather: RangedListStatus = new RangedListStatus();
  sunRiseSet: RangedListStatus = new RangedListStatus();

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('precipitationProbability', this.precipitationProbability.toJson());
    out.set('temperature', this.temperature.toJson());
    out.set('weather', this.weather.toJson());
    out.set('sunRiseSet', this.sunRiseSet.toJson());
    return out;
  }

  static parse(node: JsonNode): ForecastDaily {
    const out: ForecastDaily = new ForecastDaily();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    const precipitationProbability: JsonNode | undefined = obj.tryGet('precipitationProbability');
    if (precipitationProbability !== undefined) {
      out.precipitationProbability = StringListStatus.parse(precipitationProbability);
    }
    const temperature: JsonNode | undefined = obj.tryGet('temperature');
    if (temperature !== undefined) {
      out.temperature = RangedListStatus.parse(temperature);
    }
    const weather: JsonNode | undefined = obj.tryGet('weather');
    if (weather !== undefined) {
      out.weather = RangedListStatus.parse(weather);
    }
    const sunRiseSet: JsonNode | undefined = obj.tryGet('sunRiseSet');
    if (sunRiseSet !== undefined) {
      out.sunRiseSet = RangedListStatus.parse(sunRiseSet);
    }
    return out;
  }
}

/** 逐小时预报。 */
export class ForecastHourly {
  temperature: IntListStatus = new IntListStatus();
  weather: IntListStatus = new IntListStatus();

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('temperature', this.temperature.toJson());
    out.set('weather', this.weather.toJson());
    return out;
  }

  static parse(node: JsonNode): ForecastHourly {
    const out: ForecastHourly = new ForecastHourly();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    const temperature: JsonNode | undefined = obj.tryGet('temperature');
    if (temperature !== undefined) {
      out.temperature = IntListStatus.parse(temperature);
    }
    const weather: JsonNode | undefined = obj.tryGet('weather');
    if (weather !== undefined) {
      out.weather = IntListStatus.parse(weather);
    }
    return out;
  }
}

/**
 * 分钟级降水。
 *
 * `value` 是未来两小时逐分钟的降水量，下标即「多少分钟后」。
 */
export class MinutelyPrecipitation {
  value: number[] = [];

  /**
   * 对应桌面版 `MinutelyPrecipitation.RainRemainingMinutes`。
   *
   * 三种结果，语义不同，不能合成一个「还有多久下雨」：
   *   负数：正在下雨，`-n` 表示还有 n 分钟停。
   *   正数：现在没下，n 分钟后开始下。
   *   零  ：列表为空、两小时内都不下、或列表被雨覆盖满（第一项就 > 0 且找不到
   *         任何 <= 0 的项时，第二个循环会返回 0）——「说不清」统一归零。
   * 桌面版就是这样，照抄：调用方（RainTime 规则）用
   * `(IsRemainingTime ? -1 : 1) * rainRemainingMinutes > 0` 来挑方向，
   * 零值被两个方向同时排除，落到「不成立」。
   */
  rainRemainingMinutes(): number {
    const values: number[] = this.value;
    if (values.length <= 0) {
      return 0;
    }
    if (values[0] > 0) {
      for (let i: number = 0; i < values.length; i++) {
        if (values[i] <= 0) {
          return -i;
        }
      }
    }
    for (let i: number = 0; i < values.length; i++) {
      if (values[i] > 0) {
        return i;
      }
    }
    return 0;
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('value', ModelCodec.writeArray(this.value, (v: number) => ModelCodec.doubleNode(v)));
    return out;
  }

  static parse(node: JsonNode): MinutelyPrecipitation {
    const out: MinutelyPrecipitation = new MinutelyPrecipitation();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.value = ModelCodec.readArray(obj, 'value', (n: JsonNode) => JsonValue.asNumber(n, 0));
    return out;
  }
}

/** 分钟级预报包。 */
export class Minutely {
  precipitation: MinutelyPrecipitation = new MinutelyPrecipitation();

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('precipitation', this.precipitation.toJson());
    return out;
  }

  static parse(node: JsonNode): Minutely {
    const out: Minutely = new Minutely();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    const precipitation: JsonNode | undefined = obj.tryGet('precipitation');
    if (precipitation !== undefined) {
      out.precipitation = MinutelyPrecipitation.parse(precipitation);
    }
    return out;
  }
}

/** 空气质量。 */
export class AqiInfo {
  /**
   * AQI 值。**字符串**，桌面版如此声明。
   *
   * 对端在正常数据里给的是字符串（`"aqi": "42"`），但本端解析时也接受数字
   * （取字面量），理由见文件头。
   */
  aqi: string = '0.0';

  /**
   * 对应桌面版 `AqiInfo.AqiLevel` 的六档分级。
   *
   * 用 `<= 50` 起步而不是 `< 50`：桌面版 `switch` 第一条是 `case <= 50`，
   * 所以解析出来的 0（含解析失败）落在第 1 档，不是 -1。`default` 分支在
   * 这个 switch 里**永远走不到** —— double 的所有取值都被前六条覆盖 ——
   * 照抄那个 -1 的写法只会让读代码的人以为存在第七种情况。
   */
  aqiLevel(): number {
    const parsed: number | undefined = parseWeatherNumber(this.aqi);
    const aqi: number = parsed === undefined ? 0 : parsed;
    if (aqi <= 50) {
      return 1;
    }
    if (aqi <= 100) {
      return 2;
    }
    if (aqi <= 150) {
      return 3;
    }
    if (aqi <= 200) {
      return 4;
    }
    if (aqi <= 300) {
      return 5;
    }
    return 6;
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('aqi', new JsonString(this.aqi));
    return out;
  }

  static parse(node: JsonNode): AqiInfo {
    const out: AqiInfo = new AqiInfo();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    const raw: JsonNode | undefined = obj.tryGet('aqi');
    if (raw === undefined) {
      return out;
    }
    // 用 JsonValue 的宽松读取，不在模型里写 instanceof。
    // JsonNode 的各个子类与 JsonValue 定义在一起，判定放在那边才永远判得对。
    out.aqi = JsonValue.asStringLoose(raw, out.aqi);
    return out;
  }
}

/** 一条气象预警。 */
export class WeatherAlert {
  locationKey: string = '';
  alertId: string = '';
  pubTime: DateTimeValue = DateTimeValue.minValue();
  title: string = '';
  /** 预警类型。去重按它分组（同一类只留最新的一条）。 */
  type: string = '';
  level: string = '';
  detail: string = '';
  images: KeyedMap<string> = new KeyedMap<string>();

  /**
   * 是否使用小米的默认图标。
   *
   * 桌面版用字典索引器 `Images["icon"]`，缺键会抛。这里缺键返回 0。
   * 返回值是 0/1 而不是 boolean，与桌面版一致（它绑定到 XAML 的一个 int）；
   * 本端没有 XAML，但保留这个形状免得 read 代码的人以为可以 `if (x)`——
   * ArkTS 里 0 是假、1 是真，恰好也能用，但语义是「等级标志」不是「真假」。
   */
  isDefaultIcon(): number {
    const url: string = this.images.getOrDefault(ALERT_ICON_KEY, '');
    for (const candidate of DEFAULT_ALERT_ICON_URLS) {
      if (url === candidate) {
        return 1;
      }
    }
    return 0;
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('locationKey', new JsonString(this.locationKey));
    out.set('alertId', new JsonString(this.alertId));
    out.set('pubTime', ModelCodec.dateTimeNode(this.pubTime));
    out.set('title', new JsonString(this.title));
    out.set('type', new JsonString(this.type));
    out.set('level', new JsonString(this.level));
    out.set('detail', new JsonString(this.detail));
    const images: JsonObject = new JsonObject();
    this.images.forEach((value: string, key: string) => {
      images.set(key, new JsonString(value));
    });
    out.set('images', images);
    return out;
  }

  static parse(node: JsonNode): WeatherAlert {
    const out: WeatherAlert = new WeatherAlert();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.locationKey = ModelCodec.string(obj, 'locationKey', '');
    out.alertId = ModelCodec.string(obj, 'alertId', '');
    out.pubTime = ModelCodec.readDateTime(obj, 'pubTime');
    out.title = ModelCodec.string(obj, 'title', '');
    out.type = ModelCodec.string(obj, 'type', '');
    out.level = ModelCodec.string(obj, 'level', '');
    out.detail = ModelCodec.string(obj, 'detail', '');
    const images: JsonObject | undefined = JsonValue.asObject(obj.tryGet('images'));
    if (images !== undefined) {
      for (const member of images.entries()) {
        // 非字符串的值直接丢，空串也丢：图标 URL 为空与没有图标是同一件事，
        // 而留下一个空键会让 isDefaultIcon 的查找多一次无意义的命中。
        const text: string = JsonValue.asString(member.value, '');
        if (text.length > 0) {
          out.images.set(member.name, text);
        }
      }
    }
    return out;
  }
}

/** 一次完整天气。既是 API 响应，也是缓存的本体。 */
export class WeatherInfo {
  current: CurrentWeather = new CurrentWeather();
  alerts: WeatherAlert[] = [];
  /** 更新时间，Unix 毫秒。 */
  updateTime: number = 0;
  forecastDaily: ForecastDaily = new ForecastDaily();
  forecastHourly: ForecastHourly = new ForecastHourly();
  minutely: Minutely = new Minutely();
  aqi: AqiInfo = new AqiInfo();

  /** 对应桌面版 `WeatherInfo.UpdateTime`（`[JsonIgnore]`，由 Unix 毫秒转换）。 */
  updateTimeValue(): DateTimeValue {
    return DateTimeValue.fromLocalMillis(this.updateTime);
  }

  /**
   * 是否真的载入了天气数据。
   *
   * 判据是更新时刻：默认值 0 对应桌面版 `new WeatherInfo()` 的初始状态 ——
   * 那种状态下 `Current.Weather` 是「99」（未知）、各个 ValueUnitPair 都是
   * 空串，界面上会画出一串「空 空格 空」。真实数据一定带一个非零的
   * `updateTime`（小米接口每次响应都有）。
   *
   * 放一个方法而不是让调用方各自判 `updateTime > 0`：这个判断会出现在
   * 组件渲染、设置页状态、自动化行动三处，散开写迟早有一处漏判、
   * 表现为界面上多出一块空白。
   */
  hasData(): boolean {
    return this.updateTime > 0;
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('current', this.current.toJson());
    out.set('alerts', ModelCodec.writeArray(this.alerts, (v: WeatherAlert) => v.toJson()));
    out.set('updateTime', ModelCodec.doubleNode(this.updateTime));
    out.set('forecastDaily', this.forecastDaily.toJson());
    out.set('forecastHourly', this.forecastHourly.toJson());
    out.set('minutely', this.minutely.toJson());
    out.set('aqi', this.aqi.toJson());
    return out;
  }

  static parse(node: JsonNode): WeatherInfo {
    const out: WeatherInfo = new WeatherInfo();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    const current: JsonNode | undefined = obj.tryGet('current');
    if (current !== undefined) {
      out.current = CurrentWeather.parse(current);
    }
    out.alerts = ModelCodec.readArray(obj, 'alerts', (n: JsonNode) => WeatherAlert.parse(n));
    out.updateTime = ModelCodec.number(obj, 'updateTime', 0);
    const forecastDaily: JsonNode | undefined = obj.tryGet('forecastDaily');
    if (forecastDaily !== undefined) {
      out.forecastDaily = ForecastDaily.parse(forecastDaily);
    }
    const forecastHourly: JsonNode | undefined = obj.tryGet('forecastHourly');
    if (forecastHourly !== undefined) {
      out.forecastHourly = ForecastHourly.parse(forecastHourly);
    }
    const minutely: JsonNode | undefined = obj.tryGet('minutely');
    if (minutely !== undefined) {
      out.minutely = Minutely.parse(minutely);
    }
    const aqi: JsonNode | undefined = obj.tryGet('aqi');
    if (aqi !== undefined) {
      out.aqi = AqiInfo.parse(aqi);
    }
    return out;
  }
}

/**
 * 城市检索结果。
 *
 * 注意桌面版源码里 Latitude / Longitude 两个属性的**文档注释是互换的**
 * （`Latitude` 被注释成「经度」、`Longitude` 被注释成「纬度」）。真正的对应
 * 关系看 `[JsonPropertyName]`：`Latitude` ↔ `"latitude"`，`Longitude` ↔
 * `"longitude"` —— 没有错。这里照实际字段名走，别照注释。
 *
 * 这一族只在「搜城市」时用，不进 settings.json，所以按 camelCase 存也无所谓；
 * 统一成 camelCase 是为了与同文件其它类一致。
 */
export class CityInfo {
  name: string = '';
  affiliation: string = '';
  locationKey: string = '';
  /** 数值以**字符串**给出，例如 `"39.9042"`。 */
  latitude: string = '';
  longitude: string = '';
  /** 查询状态。0 表示成功。 */
  status: number = -1;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('name', new JsonString(this.name));
    out.set('affiliation', new JsonString(this.affiliation));
    out.set('locationKey', new JsonString(this.locationKey));
    out.set('latitude', new JsonString(this.latitude));
    out.set('longitude', new JsonString(this.longitude));
    out.set('status', ModelCodec.intNode(this.status));
    return out;
  }

  static parse(node: JsonNode): CityInfo {
    const out: CityInfo = new CityInfo();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.name = ModelCodec.string(obj, 'name', '');
    out.affiliation = ModelCodec.string(obj, 'affiliation', '');
    out.locationKey = ModelCodec.string(obj, 'locationKey', '');
    out.latitude = ModelCodec.string(obj, 'latitude', '');
    out.longitude = ModelCodec.string(obj, 'longitude', '');
    out.status = ModelCodec.int(obj, 'status', -1);
    return out;
  }
}

/**
 * 城市选择列表里的一项。
 *
 * 桌面版这个类**没有** JsonPropertyName，所以它落盘是 PascalCase。但它从不
 * 落盘（只在城市选择器里当列表项），所以这里不提供 toJson。
 */
export class City {
  name: string = '';
  cityId: string = '';
}

/** 天气查询结果。对应桌面版 `WeatherQueryResult`。 */
export class WeatherQueryResult {
  isSuccess: boolean = false;
  errorMessage: string = '';
  /** 是否因为经纬度精度降级才定到城市。 */
  isPrecisionDegraded: boolean = false;
  /** 实际用到的精度（小数位）。只在 isPrecisionDegraded 时有意义。 */
  degradedPrecision: number = 4;
}
