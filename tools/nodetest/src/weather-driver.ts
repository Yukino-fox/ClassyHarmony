/*
 * 天气测试台（码表 / 模糊匹配 / 预警筛选 / 日出日落 / 倒计时文案 / 规则 / 简报）。
 *
 * 天气这一层的失败模式几乎全是「安静地错」：
 *
 *   1. 码表少一条或抄错一个字。表现是某个天气代码显示成「未知」，而「未知」
 *      本来就是一个合法文案 —— 没有任何东西会报错。
 *   2. 模糊匹配的展开表漏一条。表现是「当前天气是小雨」规则在某一种实际天气下
 *      不成立，用户只会觉得自己配错了。
 *   3. 预警去重取错了「最新」。表现是界面少一条预警，或者把旧预警压在新预警
 *      上面；两种都长得像正常数据。
 *   4. 倒计时的中点取整方向错。只有恰好落在 15 分钟整数倍上才看得出来
 *      （「~1.5h」写成「~1h」），而分钟级预报给的正是整分钟。
 *   5. 落盘的键名写成了 PascalCase。桌面版读自己的缓存时会整份读不出来，
 *      而本端读自己的缓存同样 —— 但两边的症状都是「天气永远是空的」，
 *      不会指到键名上。
 *
 * 所以下面每一条都对着桌面版源码或 `xiaomi_weather_status.json` 取答案，
 * 而不是对着本端实现「再算一遍看等不等」。
 *
 * 关于 `parseWeatherNumber` 的千分位：桌面版用的是 .NET 的
 * `double.TryParse(string, out double)`，那个重载允许千分位分隔符，本端刻意
 * 收窄成不认（理由写在 Weather.ets）。这里正面钉住这条收窄，免得将来有人
 * 以为是漏了。
 */

import { JsonReader } from '../../common_shared/src/main/ets/json/JsonReader';
import { JsonWriter } from '../../common_shared/src/main/ets/json/JsonWriter';
import { JsonNode, JsonObject } from '../../common_shared/src/main/ets/json/JsonNode';
import { DateTimeValue } from '../../common_shared/src/main/ets/json/DateTimeValue';
import {
  AqiInfo,
  RangedValue,
  ValueUnitPair,
  WeatherAlert,
  WeatherInfo,
  parseWeatherNumber
} from '../../common_shared/src/main/ets/models/Weather';
import {
  CurrentWeatherRuleSettings,
  RainTimeRuleSettings,
  RuleIds,
  StringMatchingSettings,
  SunRiseSetRuleSettings
} from '../../common_shared/src/main/ets/models/Ruleset';
import {
  WEATHER_CODE_TABLE,
  WEATHER_TEXT_UNKNOWN,
  expandWeatherCode,
  isUnknownWeatherCode,
  isWeatherCodeMatched,
  weatherTextByCode
} from '../../common_core/src/main/ets/weather/WeatherCodes';
import {
  aqiLevelName,
  filterWeatherAlerts,
  minutesToApproxTime,
  tryGetSunTimes,
  windDirectionDegrees
} from '../../common_core/src/main/ets/weather/WeatherLogic';
import {
  WeatherSnapshot,
  currentWeatherSatisfied,
  hasWeatherAlertSatisfied,
  rainTimeSatisfied,
  sunRiseSetSatisfied,
  tomorrowWeatherSatisfied,
  weatherRuleSatisfied
} from '../../common_core/src/main/ets/weather/WeatherRules';
import {
  WEATHER_MAIN_KIND_AQI,
  WEATHER_MAIN_KIND_CONDITION,
  WEATHER_MAIN_KIND_FEELS_LIKE,
  WEATHER_MAIN_KIND_HUMIDITY,
  WEATHER_MAIN_KIND_PRESSURE,
  WEATHER_MAIN_KIND_WIND,
  WeatherBrief,
  buildWeatherBrief
} from '../../common_core/src/main/ets/weather/WeatherBrief';
import { WeatherPayload } from '../../common_core/src/main/ets/components/ComponentPayloads';

let passed: number = 0;
const failures: string[] = [];

function check(name: string, condition: boolean, detail: string = ''): void {
  if (condition) {
    passed++;
  } else {
    failures.push(detail.length === 0 ? name : `${name} —— ${detail}`);
  }
}

function checkEqual(name: string, actual: string, expected: string): void {
  check(name, actual === expected, `实际「${actual}」，期望「${expected}」`);
}

function checkNum(name: string, actual: number, expected: number): void {
  check(name, actual === expected, `实际 ${actual}，期望 ${expected}`);
}

/** 解析一个时刻，失败时退化到最小值（测试里不该失败）。 */
function dt(text: string): DateTimeValue {
  const value: DateTimeValue | undefined = DateTimeValue.tryParse(text);
  return value === undefined ? DateTimeValue.minValue() : value;
}

/** 一个只有时间字段的天气，用来撞规则。 */
function weatherAt(hour: number, minute: number): DateTimeValue {
  return dt(`2026-10-01T${hour < 10 ? '0' : ''}${hour}:${minute < 10 ? '0' : ''}${minute}:00`);
}

function pair(value: string, unit: string): ValueUnitPair {
  const out: ValueUnitPair = new ValueUnitPair();
  out.value = value;
  out.unit = unit;
  return out;
}

/** 造一条预警。 */
function alert(type: string, pubTime: string, title: string = '',
  detail: string = ''): WeatherAlert {
  const out: WeatherAlert = new WeatherAlert();
  out.type = type;
  out.title = title;
  out.detail = detail;
  out.pubTime = dt(pubTime);
  return out;
}

// --------------------------------------------------------------- 码表

function testWeatherCodes(): void {
  // 条数与首尾。40 条是从 xiaomi_weather_status.json 数出来的（0..35 + 53 + 301
  // + 302 + 99）。少一条通常是因为合并了两个范围或漏了 53。
  checkNum('码表 40 条', WEATHER_CODE_TABLE.length, 40);
  checkNum('第一条是 0', WEATHER_CODE_TABLE[0].code, 0);
  checkEqual('第一条是晴', WEATHER_CODE_TABLE[0].text, 'weather_code_0');
  checkNum('最后一条是 99', WEATHER_CODE_TABLE[39].code, 99);
  checkEqual('最后一条是未知', WEATHER_CODE_TABLE[39].text, 'weather_code_99');

  // 抽查几处容易抄错的。
  checkEqual('1 是多云', weatherTextByCode('1'), "多云");
  checkEqual('2 是阴', weatherTextByCode('2'), "阴");
  checkEqual('5 带冰雹', weatherTextByCode('5'), "雷阵雨并伴有冰雹");
  checkEqual('6 是雨夹雪', weatherTextByCode('6'), "雨夹雪");
  checkEqual('12 是特大暴雨', weatherTextByCode('12'), "特大暴雨");
  checkEqual('18 是雾', weatherTextByCode('18'), "雾");
  checkEqual('19 是冻雨', weatherTextByCode('19'), "冻雨");
  checkEqual('20 是沙尘暴', weatherTextByCode('20'), "沙尘暴");
  checkEqual('21 是中雨区间', weatherTextByCode('21'), "小雨-中雨");
  checkEqual('28 是暴雪区间', weatherTextByCode('28'), "大雪-暴雪");
  checkEqual('29 是浮尘', weatherTextByCode('29'), "浮尘");
  checkEqual('32 是飑', weatherTextByCode('32'), "飑");
  checkEqual('34 是弱高吹雪', weatherTextByCode('34'), "弱高吹雪");
  checkEqual('35 是轻雾', weatherTextByCode('35'), "轻雾");
  checkEqual('53 是霾', weatherTextByCode('53'), "霾");
  checkEqual('301 是雨', weatherTextByCode('301'), "雨");
  checkEqual('302 是雪', weatherTextByCode('302'), "雪");

  // 表内 99 命中与未命中给的是同一个文案，但「99」本身是命中。
  checkEqual('99 命中未知', weatherTextByCode('99'), "未知");
  checkEqual('不存在的代码给未知', weatherTextByCode('999'), WEATHER_TEXT_UNKNOWN);
  // 不做前导零归一化：桌面版是拿 int 的 ToString 去比，'01' 永远查不到。
  checkEqual('01 查不到', weatherTextByCode('01'), WEATHER_TEXT_UNKNOWN);
  checkEqual('空串查不到', weatherTextByCode(''), WEATHER_TEXT_UNKNOWN);

  check('99 是未知代码', isUnknownWeatherCode('99'));
  check('0 不是未知代码', !isUnknownWeatherCode('0'));
}

// --------------------------------------------------------------- 展开与匹配

function testExpandAndMatch(): void {
  const expansions: string[] = ['21', '22', '23', '24', '25', '26', '27', '28', '301', '302'];
  for (const code of expansions) {
    const expanded: string[] = expandWeatherCode(code);
    check(`展开 ${code} 含自身`, expanded.indexOf(code) >= 0);
    check(`展开 ${code} 不止一条`, expanded.length > 1);
    // 展开出的每个代码都必须是表里认识的具体天气 —— 出现「未知」说明抄错了
    // 一个不存在的代码（比如把 19 写成 191）。
    for (const item of expanded) {
      if (item === '99') {
        continue;
      }
      check(`展开 ${code} 的 ${item} 在表里`, weatherTextByCode(item) !== WEATHER_TEXT_UNKNOWN);
    }
  }

  // 八条区间是「两个相邻档 + 区间本身」。
  checkEqual('21 展开', expandWeatherCode('21').join(','), '7,8,21');
  checkEqual('28 展开', expandWeatherCode('28').join(','), '16,17,28');
  checkEqual(
    '301 展开',
    expandWeatherCode('301').join(','),
    '3,4,5,6,7,8,9,10,11,12,19,21,22,23,24,25,301'
  );
  checkEqual(
    '302 展开',
    expandWeatherCode('302').join(','),
    '6,13,14,15,16,17,26,27,28,34,302'
  );

  // 非区间代码原样返回单元素。
  checkEqual('0 不展开', expandWeatherCode('0').join(','), '0');
  checkEqual('99 不展开', expandWeatherCode('99').join(','), '99');
  checkEqual('陌生代码原样', expandWeatherCode('888').join(','), '888');

  // 相等即匹配，与展开表是否完整无关。
  check('原串相等即匹配', isWeatherCodeMatched('0', '0'));
  check('小雨 vs 小雨-中雨（模糊）', isWeatherCodeMatched('7', '21'));
  check('中雨-大雨含中雨', isWeatherCodeMatched('8', '22'));
  check('小雨-中雨含小雨', isWeatherCodeMatched('21', '7'));
  check('雨区间含冻雨', isWeatherCodeMatched('301', '19'));
  check('雪区间含弱高吹雪', isWeatherCodeMatched('302', '34'));
  // 雨区间与雪区间在「雨夹雪」（6）上交叠 —— 两边的展开表都含 6，所以它们
  // 互相匹配。别按字面想当然地以为「雨」与「雪」互斥。
  check('雨区间与雪区间在雨夹雪上交叠', isWeatherCodeMatched('301', '302'));
  check('雨区间含雨夹雪', isWeatherCodeMatched('301', '6'));
  check('晴与雨不匹配', !isWeatherCodeMatched('0', '7'));
  check('陌生代码只与自己相等', isWeatherCodeMatched('888', '888'));
  check('陌生代码与别的都不等', !isWeatherCodeMatched('888', '0'));
}

// --------------------------------------------------------------- 数字解析

function testParseNumber(): void {
  checkNum('整数', parseWeatherNumber('42') ?? -1, 42);
  checkNum('负号', parseWeatherNumber('-3') ?? -1, -3);
  checkNum('正号', parseWeatherNumber('+3') ?? -1, 3);
  checkNum('小数', parseWeatherNumber('39.9') ?? -1, 39.9);
  checkNum('前导小数点', parseWeatherNumber('.5') ?? -1, 0.5);
  checkNum('尾随小数点', parseWeatherNumber('5.') ?? -1, 5);
  checkNum('科学计数', parseWeatherNumber('1e3') ?? -1, 1000);
  checkNum('负指数', parseWeatherNumber('1.5e-1') ?? -1, 0.15);
  checkNum('两侧空白可去', parseWeatherNumber('  7  ') ?? -1, 7);

  check('空串不认', parseWeatherNumber('') === undefined);
  check('空白不认', parseWeatherNumber('   ') === undefined);
  check('尾随字母不认', parseWeatherNumber('39.9abc') === undefined);
  // 这条是**刻意收窄**，不是抄错：桌面版的 .NET TryParse 认千分位（"1,234" → 1234），
  // 本端不认。理由见 Weather.ets。钉住它是为了不改回去。
  check('千分位刻意不认', parseWeatherNumber('1,234') === undefined);
  check('两个小数点不认', parseWeatherNumber('1.2.3') === undefined);
  check('孤立减号不认', parseWeatherNumber('-') === undefined);
  check('十六进制不认', parseWeatherNumber('0x10') === undefined);
  check('NaN 不认', parseWeatherNumber('NaN') === undefined);
  check('Infinity 不认', parseWeatherNumber('Infinity') === undefined);
}

// --------------------------------------------------------------- AQI 分档

function testAqiLevel(): void {
  const aqi: AqiInfo = new AqiInfo();
  // 桌面版 `case <= 50 → 1`，所以 0（含解析失败）落在第 1 档，不是 -1。
  checkNum('默认 0.0 落第 1 档', aqi.aqiLevel(), 1);
  const boundaries: number[] = [0, 1, 50, 51, 100, 101, 150, 151, 200, 201, 300, 301, 9999];
  const expected: number[] = [1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6];
  for (let i: number = 0; i < boundaries.length; i++) {
    aqi.aqi = `${boundaries[i]}`;
    checkNum(`AQI ${boundaries[i]} 落第 ${expected[i]} 档`, aqi.aqiLevel(), expected[i]);
  }
  aqi.aqi = 'abc';
  checkNum('AQI 解析失败落第 1 档', aqi.aqiLevel(), 1);
  aqi.aqi = '';
  checkNum('AQI 空串落第 1 档', aqi.aqiLevel(), 1);

  // 档位名（本端为无障碍/设置页新增，桌面版没有）。
  checkEqual('档位 1 优', aqiLevelName(1), '优');
  checkEqual('档位 2 良', aqiLevelName(2), '良');
  checkEqual('档位 3 轻度污染', aqiLevelName(3), '轻度污染');
  checkEqual('档位 4 中度污染', aqiLevelName(4), '中度污染');
  checkEqual('档位 5 重度污染', aqiLevelName(5), '重度污染');
  checkEqual('档位 6 严重污染', aqiLevelName(6), '严重污染');
}

// --------------------------------------------------------------- 降雨倒计时原始值

function rainOf(values: number[]): number {
  const info: WeatherInfo = new WeatherInfo();
  info.minutely.precipitation.value = values;
  return info.minutely.precipitation.rainRemainingMinutes();
}

function testRainRemaining(): void {
  checkNum('空列表给 0', rainOf([]), 0);
  checkNum('全 0 给 0', rainOf([0, 0, 0]), 0);
  // 现在没下、第 3 分钟开始下 → 正 3。
  checkNum('将来开始下雨', rainOf([0, 0, 0, 0.2]), 3);
  // 第一项就有雨，第 2 分钟停 → 负 2。
  checkNum('正在下，还有 2 分钟停', rainOf([0.5, 0.3, 0, 0]), -2);
  // 前后都有雨、中间停：取第一个 <= 0 的下标。
  checkNum('中间停', rainOf([0.5, 0, 0.3]), -1);
  // 第一项就有雨且整个窗口都不停 → 第二个循环返回第一个 > 0 的下标 0。
  // 与「说不清」同为 0，桌面版如此，照抄。
  checkNum('雨覆盖满窗口给 0', rainOf([0.5, 0.7]), 0);
  // 前导 0 之后的第一个非零是开始下雨的下标。
  checkNum('跳过多余的 0', rainOf([0, 0, 0, 0, 0, 1.0]), 5);
}

// --------------------------------------------------------------- 模糊时间文案

function testMinutesToApprox(): void {
  checkEqual('0 分钟', minutesToApproxTime(0), '0min');
  // 60 分钟以下不加 ~。
  checkEqual('1 分钟', minutesToApproxTime(1), '1min');
  checkEqual('30 分钟', minutesToApproxTime(30), '30min');
  checkEqual('59 分钟', minutesToApproxTime(59), '59min');
  checkEqual('负 30 分钟', minutesToApproxTime(-30), '-30min');
  // 60 起进小时档，半小时取整。
  checkEqual('60 分钟是一小时', minutesToApproxTime(60), '~1h');
  checkEqual('90 分钟', minutesToApproxTime(90), '~1.5h');
  checkEqual('97 分钟收成 1.5h', minutesToApproxTime(97), '~1.5h');
  checkEqual('75 分钟', minutesToApproxTime(75), '~1.5h');
  // 45 分钟还不到小时档（阈值是 60），所以是分钟档。
  checkEqual('45 分钟仍是分钟档', minutesToApproxTime(45), '45min');
  // 105 → 1.75h * 2 = 3.5 → 远离零取 4 → 2.0h。
  checkEqual('105 分钟', minutesToApproxTime(105), '~2h');
  // 135 → 2.25 * 2 = 4.5 → 5 → 2.5h。
  checkEqual('135 分钟', minutesToApproxTime(135), '~2.5h');
  // 负数的中点也要远离零：-90 → 1.5 → ~-1.5h。
  checkEqual('负 90 分钟', minutesToApproxTime(-90), '~-1.5h');
  checkEqual('负 97 分钟', minutesToApproxTime(-97), '~-1.5h');
  checkEqual('整小时不带小数', minutesToApproxTime(180), '~3h');
  checkEqual('210 分钟', minutesToApproxTime(210), '~3.5h');
}

// --------------------------------------------------------------- 风向

function testWindDirection(): void {
  checkNum('来向 0 → 180', windDirectionDegrees('0'), 180);
  checkNum('来向 180 → 0', windDirectionDegrees('180'), 0);
  checkNum('来向 90 → 270', windDirectionDegrees('90'), 270);
  checkNum('来向 270 → 90', windDirectionDegrees('270'), 90);
  checkNum('来向 360 → 180', windDirectionDegrees('360'), 180);
  checkNum('来向 350 → 170', windDirectionDegrees('350'), 170);
  // 解析失败给 0（表示不旋转），不是 180。
  checkNum('文字解析失败给 0', windDirectionDegrees('东'), 0);
  checkNum('空串给 0', windDirectionDegrees(''), 0);
  checkNum('小数也对', windDirectionDegrees('10.5'), 190.5);
}

// --------------------------------------------------------------- 预警筛选

function testFilterAlerts(): void {
  // 空排除、空列表。
  checkNum('空列表', filterWeatherAlerts([], []).length, 0);

  const rain: WeatherAlert = alert('暴雨', '2026-10-01T10:00:00', '暴雨蓝色预警', '详情');
  const hot: WeatherAlert = alert('高温', '2026-10-01T09:00:00', '高温黄色预警', '详情');

  // 空白排除项必须被忽略，否则空串是任何字符串的子串，会把预警全清掉。
  checkNum('空白排除项不生效', filterWeatherAlerts([rain, hot], ['', '   ']).length, 2);
  // 命中标题。
  checkNum('按标题排除', filterWeatherAlerts([rain, hot], ['高温']).length, 1);
  // 命中详情也要排除（桌面版是 Title 或 Detail 的子串）。
  const detailOnly: WeatherAlert = alert('大雾', '2026-10-01T08:00:00', '大雾预警', '能见度低，注意高温');
  checkNum('按详情排除', filterWeatherAlerts([detailOnly], ['高温']).length, 0);
  checkNum('不相干的排除项不动它', filterWeatherAlerts([detailOnly], ['台风']).length, 1);

  // 去重：同 type 取 pubTime 最大的。
  const older: WeatherAlert = alert('暴雨', '2026-10-01T08:00:00', '旧');
  const newer: WeatherAlert = alert('暴雨', '2026-10-01T12:00:00', '新');
  const deduped: WeatherAlert[] = filterWeatherAlerts([older, newer], []);
  checkNum('按 type 去重', deduped.length, 1);
  checkEqual('去重留最新的', deduped[0].title, '新');
  // 顺序颠倒也要留下 pubTime 大的那一条。
  const reversed: WeatherAlert[] = filterWeatherAlerts([newer, older], []);
  checkEqual('顺序颠倒也留最新', reversed[0].title, '新');

  // 并列时留**先出现**的那条（对应 .NET MaxBy 的严格大于比较）。
  const tieA: WeatherAlert = alert('暴雨', '2026-10-01T10:00:00', '先');
  const tieB: WeatherAlert = alert('暴雨', '2026-10-01T10:00:00', '后');
  checkEqual('并列留先出现', filterWeatherAlerts([tieA, tieB], [])[0].title, '先');

  // 输出顺序按 type 首次出现，而不是按 pubTime —— 这决定界面上的排列。
  const out: WeatherAlert[] = filterWeatherAlerts([rain, hot], []);
  checkEqual('顺序按首次出现 1', out[0].type, '暴雨');
  checkEqual('顺序按首次出现 2', out[1].type, '高温');

  // 默认图标判定。
  const defaultIcon: WeatherAlert = alert('暴雨', '2026-10-01T10:00:00');
  defaultIcon.images.set('icon', 'http://f5.market.xiaomi.com/download/Weather/0ac110d2ee20a454ab44f5df30f9fa6ff650e0b72/a.webp');
  checkNum('默认图标判为 1', defaultIcon.isDefaultIcon(), 1);
  const customIcon: WeatherAlert = alert('暴雨', '2026-10-01T10:00:00');
  customIcon.images.set('icon', 'http://example.com/a.webp');
  checkNum('自定义图标判为 0', customIcon.isDefaultIcon(), 0);
  const noIcon: WeatherAlert = alert('暴雨', '2026-10-01T10:00:00');
  checkNum('缺图标键返回 0 而不是抛', noIcon.isDefaultIcon(), 0);
}

// --------------------------------------------------------------- 日出日落

function sunriseItem(from: string, to: string): RangedValue {
  const out: RangedValue = new RangedValue();
  out.from = from;
  out.to = to;
  return out;
}

function testSunTimes(): void {
  const info: WeatherInfo = new WeatherInfo();
  info.forecastDaily.sunRiseSet.value = [
    sunriseItem('2026-10-01 05:56:00', '2026-10-01 18:10:00'),
    sunriseItem('2026-10-02 05:57:00', '2026-10-02 18:09:00')
  ];

  const today = tryGetSunTimes(info, dt('2026-10-01T12:00:00'));
  check('今天能取到', today !== undefined);
  if (today !== undefined) {
    checkEqual('今天的日出', today.sunrise.toString(), '2026-10-01T05:56:00');
    checkEqual('今天的日落', today.sunset.toString(), '2026-10-01T18:10:00');
  }

  const tomorrow = tryGetSunTimes(info, dt('2026-10-02T00:30:00'));
  check('次日能取到', tomorrow !== undefined);
  if (tomorrow !== undefined) {
    checkEqual('次日的日出', tomorrow.sunrise.toString(), '2026-10-02T05:57:00');
  }

  // 第三天没有数据。
  check('没有当天数据返回 undefined', tryGetSunTimes(info, dt('2026-10-03T12:00:00')) === undefined);

  // `||` 的宽松：日出在前一天、日落在今天，也算今天那一组。
  const crossMidnight: WeatherInfo = new WeatherInfo();
  crossMidnight.forecastDaily.sunRiseSet.value = [
    sunriseItem('2026-09-30 23:50:00', '2026-10-01 18:10:00')
  ];
  check('日落落在今天也能取到', tryGetSunTimes(crossMidnight, dt('2026-10-01T12:00:00')) !== undefined);

  // 解析失败的那一条要跳过，继续找下一条。
  const bad: WeatherInfo = new WeatherInfo();
  bad.forecastDaily.sunRiseSet.value = [
    sunriseItem('', '2026-10-01 18:10:00'),
    sunriseItem('2026-10-01 05:56:00', '2026-10-01 18:10:00')
  ];
  const afterBad = tryGetSunTimes(bad, dt('2026-10-01T12:00:00'));
  check('跳过解析失败的条目', afterBad !== undefined);
  if (afterBad !== undefined) {
    checkEqual('跳过坏的取到好的', afterBad.sunrise.toString(), '2026-10-01T05:56:00');
  }

  // 全空。
  check('空列表返回 undefined', tryGetSunTimes(new WeatherInfo(), dt('2026-10-01T12:00:00')) === undefined);
}

// --------------------------------------------------------------- 模型往返

/** 一份贴近小米接口形状的完整响应。字段用 camelCase（对端与桌面版缓存都是）。 */
const FIXTURE: string = `{
  "current": {
    "feelsLike": { "value": "26", "unit": "\u00b0C" },
    "humidity": { "value": "45", "unit": "%" },
    "pressure": { "value": "1013", "unit": "hPa" },
    "temperature": { "value": "25", "unit": "\u00b0C" },
    "visibility": { "value": "20", "unit": "km" },
    "weather": "0",
    "pubTime": "2026-10-01T12:00:00",
    "wind": {
      "direction": { "value": "90", "unit": "\u00b0" },
      "speed": { "value": "3", "unit": "\u7ea7" }
    }
  },
  "alerts": [
    {
      "locationKey": "weathercn:101010100",
      "alertId": "a1",
      "pubTime": "2026-10-01T10:00:00",
      "title": "\u5317\u4eac\u5e02\u6c14\u8c61\u53f0\u53d1\u5e03\u66b4\u96e8\u84dd\u8272\u9884\u8b66",
      "type": "\u66b4\u96e8",
      "level": "\u84dd\u8272",
      "detail": "\u8be6\u60c5\u4e00",
      "images": { "icon": "http://f5.market.xiaomi.com/download/Weather/0ac110d2ee20a454ab44f5df30f9fa6ff650e0b72/a.webp" }
    }
  ],
  "updateTime": 1759291200000,
  "forecastDaily": {
    "precipitationProbability": { "value": ["10", "20", "30"] },
    "temperature": { "value": [{ "from": "18", "to": "26" }, { "from": "17", "to": "25" }] },
    "weather": { "value": [{ "from": "0", "to": "2" }, { "from": "21", "to": "8" }] },
    "sunRiseSet": { "value": [{ "from": "2026-10-01 05:56:00", "to": "2026-10-01 18:10:00" }] }
  },
  "forecastHourly": {
    "temperature": { "value": [25, 26, 27] },
    "weather": { "value": [0, 1, 2] }
  },
  "minutely": { "precipitation": { "value": [0, 0.1, 0.5, 0.2, 0, 0] } },
  "aqi": { "aqi": "42" }
}`;

function testModelRoundTrip(): void {
  const info: WeatherInfo = WeatherInfo.parse(JsonReader.parse(FIXTURE));

  checkNum('天气代码', Number(info.current.weather), 0);
  checkEqual('温度值', info.current.temperature.value, '25');
  checkEqual('温度单位', info.current.temperature.unit, '°C');
  checkEqual('体感', info.current.feelsLike.value, '26');
  checkEqual('湿度', info.current.humidity.value, '45');
  checkEqual('气压', info.current.pressure.value, '1013');
  checkEqual('风力', info.current.wind.speed.value, '3');
  checkEqual('风向', info.current.wind.direction.value, '90');
  checkEqual('发布时间', info.current.pubTime.toString(), '2026-10-01T12:00:00');
  checkNum('更新时间', info.updateTime, 1759291200000);
  check('有数据', info.hasData());
  checkNum('AQI', Number(info.aqi.aqi), 42);
  checkNum('AQI 档位', info.aqi.aqiLevel(), 1);
  checkNum('预警条数', info.alerts.length, 1);
  checkEqual('预警类型', info.alerts[0].type, '暴雨');
  checkEqual('预警等级', info.alerts[0].level, '蓝色');
  checkNum('默认图标', info.alerts[0].isDefaultIcon(), 1);
  checkEqual('明天天气 from', info.forecastDaily.weather.value[1].from, '21');
  checkEqual('明天天气 to', info.forecastDaily.weather.value[1].to, '8');
  checkEqual('今日降水概率', info.forecastDaily.precipitationProbability.value[0], '10');
  checkNum('逐小时温度', info.forecastHourly.temperature.value[0], 25);
  checkNum('逐小时天气', info.forecastHourly.weather.value[2], 2);
  checkNum('分钟降水长度', info.minutely.precipitation.value.length, 6);
  checkNum('分钟降水 0.5 没被截断', info.minutely.precipitation.value[2], 0.5);
  checkNum('分钟降水余值', info.minutely.precipitation.rainRemainingMinutes(), 1);

  // 顶层键名必须是 camelCase 且恰好这 7 个。写成 PascalCase 的话桌面版读不出、
  // 本端也读不出，症状是「天气永远是空的」。
  const root: JsonObject | undefined = JsonReader.parse(JsonWriter.writeCompact(info.toJson())) as JsonObject;
  const names: string[] = [];
  for (const member of root.entries()) {
    names.push(member.name);
  }
  checkEqual('顶层键名', names.join(','),
    'current,alerts,updateTime,forecastDaily,forecastHourly,minutely,aqi');

  // 二次往返必须逐字节相同（数字字面量、字符串都没漂移）。
  const once: string = JsonWriter.writeCompact(info.toJson());
  const twice: string = JsonWriter.writeCompact(WeatherInfo.parse(JsonReader.parse(once)).toJson());
  checkEqual('往返幂等', twice, once);
  // 缩进写出里也不能出现 PascalCase。
  const indented: string = JsonWriter.writeIndented(info.toJson());
  check('缩进里有 forecastDaily', indented.indexOf('"forecastDaily"') >= 0);
  check('缩进里没有 ForecastDaily', indented.indexOf('"ForecastDaily"') < 0);

  // 空对象解析出一个「没有数据」的天气，而不是抛。
  const empty: WeatherInfo = WeatherInfo.parse(JsonReader.parse('{}'));
  check('空对象无数据', !empty.hasData());
  checkEqual('空对象天气代码是 99', empty.current.weather, '99');
  checkNum('空对象 AQI 档位 1', empty.aqi.aqiLevel(), 1);
  checkNum('空对象倒计时 0', empty.minutely.precipitation.rainRemainingMinutes(), 0);
  check('非对象也不抛', !WeatherInfo.parse(JsonReader.parse('[]')).hasData());

  // aqi 给数字也要收（桌面版声明 string，给数字会抛；本端刻意放宽）。
  const numericAqi: WeatherInfo = WeatherInfo.parse(JsonReader.parse('{"aqi":{"aqi":123}}'));
  checkEqual('数字 AQI 取字面量', numericAqi.aqi.aqi, '123');
  checkNum('数字 AQI 档位', numericAqi.aqi.aqiLevel(), 3);
  // 浮点字面量保留原样。
  checkEqual('小数 AQI 字面量', WeatherInfo.parse(JsonReader.parse('{"aqi":{"aqi":42.5}}')).aqi.aqi, '42.5');
}

// --------------------------------------------------------------- 五条规则

function refreshedSnapshot(info: WeatherInfo): WeatherSnapshot {
  const out: WeatherSnapshot = new WeatherSnapshot();
  out.isRefreshed = true;
  out.info = info;
  return out;
}

function testRules(): void {
  const info: WeatherInfo = WeatherInfo.parse(JsonReader.parse(FIXTURE));
  // 明天（下标 1）的天气是 21（小雨-中雨），from 21 / to 8。
  const snapshot: WeatherSnapshot = refreshedSnapshot(info);

  // ---- 当前天气 ----
  const current: CurrentWeatherRuleSettings = new CurrentWeatherRuleSettings();
  current.weatherId = 0;
  check('当前天气精确匹配', currentWeatherSatisfied(current, snapshot));
  current.weatherId = 1;
  check('当前天气不匹配', !currentWeatherSatisfied(current, snapshot));
  // 模糊：当前是 0（晴），目标是 7（小雨）→ 不匹配。
  current.weatherId = 7;
  current.isFuzzyMatch = true;
  check('晴天不是小雨（模糊）', !currentWeatherSatisfied(current, snapshot));
  // 换个当前天气：小雨-中雨（21）满足目标 7。
  const fuzzyInfo: WeatherInfo = WeatherInfo.parse(JsonReader.parse(FIXTURE));
  fuzzyInfo.current.weather = '21';
  const fuzzySnap: WeatherSnapshot = refreshedSnapshot(fuzzyInfo);
  current.weatherId = 7;
  current.isFuzzyMatch = true;
  check('小雨-中雨满足小雨（模糊）', currentWeatherSatisfied(current, fuzzySnap));
  current.isFuzzyMatch = false;
  check('精确匹配下 21 不等于 7', !currentWeatherSatisfied(current, fuzzySnap));
  current.weatherId = 21;
  check('精确匹配下 21 等于 21', currentWeatherSatisfied(current, fuzzySnap));

  // 未刷新 → 一律 false，哪怕数据齐全。
  const cold: WeatherSnapshot = new WeatherSnapshot();
  cold.info = info;
  current.weatherId = 0;
  current.isFuzzyMatch = false;
  check('未刷新时当前天气规则为假', !currentWeatherSatisfied(current, cold));

  // ---- 明天天气 ----
  const tomorrow: CurrentWeatherRuleSettings = new CurrentWeatherRuleSettings();
  tomorrow.weatherId = 21;
  check('明天精确 from', tomorrowWeatherSatisfied(tomorrow, snapshot));
  tomorrow.weatherId = 8;
  check('明天精确 to', tomorrowWeatherSatisfied(tomorrow, snapshot));
  tomorrow.weatherId = 9;
  check('明天不匹配', !tomorrowWeatherSatisfied(tomorrow, snapshot));
  tomorrow.weatherId = 7;
  tomorrow.isFuzzyMatch = true;
  check('明天模糊：21 含 7', tomorrowWeatherSatisfied(tomorrow, snapshot));
  // 只有一天预报时判 false。
  const oneDay: WeatherInfo = WeatherInfo.parse(JsonReader.parse(FIXTURE));
  oneDay.forecastDaily.weather.value = [sunriseItem('0', '2')];
  const oneDaySnap: WeatherSnapshot = refreshedSnapshot(oneDay);
  tomorrow.isFuzzyMatch = false;
  tomorrow.weatherId = 0;
  check('只有一天预报时明天规则为假', !tomorrowWeatherSatisfied(tomorrow, oneDaySnap));
  check('未刷新时明天规则为假', !tomorrowWeatherSatisfied(tomorrow, cold));

  // ---- 气象预警 ----
  // 非正则时 `IsMatching` 是**整串相等**（桌面版 `str == Text`），不是「包含」。
  const matching: StringMatchingSettings = new StringMatchingSettings();
  matching.text = '暴雨';
  check('预警：子串不算匹配', !hasWeatherAlertSatisfied(matching, snapshot));
  matching.text = '北京市气象台发布暴雨蓝色预警';
  check('预警：整串匹配', hasWeatherAlertSatisfied(matching, snapshot));
  // 正则才是「在串里找」。
  matching.useRegex = true;
  matching.text = '暴雨';
  check('预警：正则子串匹配', hasWeatherAlertSatisfied(matching, snapshot));
  matching.text = '高温';
  check('预警：正则不匹配', !hasWeatherAlertSatisfied(matching, snapshot));
  // 只匹配标题，不匹配详情。
  const detailAlert: WeatherInfo = WeatherInfo.parse(JsonReader.parse(FIXTURE));
  detailAlert.alerts[0].title = '大风蓝色预警';
  detailAlert.alerts[0].detail = '请注意暴雨';
  const detailSnap: WeatherSnapshot = refreshedSnapshot(detailAlert);
  matching.text = '暴雨';
  check('预警不看详情', !hasWeatherAlertSatisfied(matching, detailSnap));
  matching.useRegex = false;
  check('未刷新时预警规则为假', !hasWeatherAlertSatisfied(matching, cold));

  // ---- 降水倒计时 ----
  // minutely = [0, 0.1, 0.5, 0.2, 0, 0] → RainRemainingMinutes = 1（1 分钟后开始）。
  const rain: RainTimeRuleSettings = new RainTimeRuleSettings();
  rain.isRemainingTime = false;
  rain.rainTimeMinutes = 60;
  check('1 分钟后开始下雨，阈值 60 成立', rainTimeSatisfied(rain, snapshot));
  rain.rainTimeMinutes = 1;
  check('阈值 1 也成立（闭区间）', rainTimeSatisfied(rain, snapshot));
  rain.rainTimeMinutes = 0.5;
  check('阈值 0.5 不成立', !rainTimeSatisfied(rain, snapshot));
  // isRemainingTime=true 时取负数那一档，现在没在下雨 → 不成立。
  rain.rainTimeMinutes = 60;
  rain.isRemainingTime = true;
  check('还剩模式：现在没下雨不成立', !rainTimeSatisfied(rain, snapshot));
  // 正在下雨的数据。
  const raining: WeatherInfo = WeatherInfo.parse(JsonReader.parse(FIXTURE));
  raining.minutely.precipitation.value = [0.5, 0.3, 0, 0];
  const rainingSnap: WeatherSnapshot = refreshedSnapshot(raining);
  check('还剩模式：2 分钟后停成立', rainTimeSatisfied(rain, rainingSnap));
  rain.isRemainingTime = false;
  check('开始模式：正在下不算「将要下」', !rainTimeSatisfied(rain, rainingSnap));
  // 这条规则**不**看 isRefreshed（照抄桌面版）。
  // 这条规则**不**看 isRefreshed：数据在（哪怕是缓存里的）就照常求值，
  // 所以未刷新的快照上它照样可能为真。照抄桌面版。
  check('未刷新时降水规则照样求值', rainTimeSatisfied(rain, cold));

  // ---- 日出日落 ----
  const sun: SunRiseSetRuleSettings = new SunRiseSetRuleSettings();
  // 夹具的日出/日落落在 2026-10-01。
  sun.isSunset = false;
  check('正午是白天', sunRiseSetSatisfied(sun, snapshot, weatherAt(12, 0)));
  sun.isSunset = true;
  check('正午不是夜里', !sunRiseSetSatisfied(sun, snapshot, weatherAt(12, 0)));
  sun.isSunset = false;
  // 日出那一刻算白天（左闭）。
  check('日出那一刻算白天', sunRiseSetSatisfied(sun, snapshot, dt('2026-10-01T05:56:00')));
  // 日出前一秒算夜里。
  check('日出前一秒不算白天', !sunRiseSetSatisfied(sun, snapshot, dt('2026-10-01T05:55:59')));
  // 日落那一刻算夜里（右开）。
  sun.isSunset = true;
  check('日落那一刻算夜里', sunRiseSetSatisfied(sun, snapshot, dt('2026-10-01T18:10:00')));
  sun.isSunset = false;
  check('日落那一刻不算白天', !sunRiseSetSatisfied(sun, snapshot, dt('2026-10-01T18:10:00')));
  // 深夜：夜里成立。
  sun.isSunset = true;
  check('深夜算夜里', sunRiseSetSatisfied(sun, snapshot, dt('2026-10-01T23:00:00')));
  sun.isSunset = false;
  check('深夜不算白天', !sunRiseSetSatisfied(sun, snapshot, dt('2026-10-01T23:00:00')));
  // 找不到当天数据 → false。
  const noSun: WeatherInfo = WeatherInfo.parse(JsonReader.parse(FIXTURE));
  noSun.forecastDaily.sunRiseSet.value = [];
  const noSunSnap: WeatherSnapshot = refreshedSnapshot(noSun);
  check('没有日出数据时为假', !sunRiseSetSatisfied(sun, noSunSnap, weatherAt(12, 0)));
  check('未刷新时日出规则为假', !sunRiseSetSatisfied(sun, cold, weatherAt(12, 0)));

  // ---- 分派器 ----
  // tomorrow 在前一段被改成了 weatherId=0（用来看「只有一天预报」那条），
  // 这里要重新对准夹具里明天的 21。
  tomorrow.weatherId = 21;
  tomorrow.isFuzzyMatch = false;
  check('分派：当前天气', weatherRuleSatisfied(RuleIds.WEATHER_CURRENT, current, snapshot, weatherAt(12, 0)));
  check('分派：未知 id 为假', !weatherRuleSatisfied('classisland.weather.nope', current, snapshot, weatherAt(12, 0)));
  check('分派：快照 undefined 全为假',
    !weatherRuleSatisfied(RuleIds.WEATHER_CURRENT, current, undefined, weatherAt(12, 0)));
  check('分派：明天', weatherRuleSatisfied(RuleIds.WEATHER_TOMORROW, tomorrow, snapshot, weatherAt(12, 0)));
  // matching 在前一段末尾被复位成「不匹配」状态，这里再对准一次。
  matching.useRegex = true;
  matching.text = '暴雨';
  check('分派：预警', weatherRuleSatisfied(RuleIds.WEATHER_ALERT, matching, snapshot, weatherAt(12, 0)));
  check('分派：降水', weatherRuleSatisfied(RuleIds.WEATHER_RAIN_TIME, rain, snapshot, weatherAt(12, 0)));
  const sunSettings: SunRiseSetRuleSettings = new SunRiseSetRuleSettings();
  sunSettings.isSunset = false;
  check('分派：日出日落',
    weatherRuleSatisfied(RuleIds.WEATHER_SUN_RISE_SET, sunSettings, snapshot, weatherAt(12, 0)));
  // 没有降水时「将要下雨」不成立。
  const dryInfo: WeatherInfo = WeatherInfo.parse(JsonReader.parse(FIXTURE));
  dryInfo.minutely.precipitation.value = [0, 0, 0];
  const rainStart: RainTimeRuleSettings = new RainTimeRuleSettings();
  rainStart.isRemainingTime = false;
  rainStart.rainTimeMinutes = 60;
  check('无降水时不是「将要下雨」', !rainTimeSatisfied(rainStart, refreshedSnapshot(dryInfo)));
}

// --------------------------------------------------------------- 简报

function testBrief(): void {
  const info: WeatherInfo = WeatherInfo.parse(JsonReader.parse(FIXTURE));

  const payload: WeatherPayload = new WeatherPayload();
  const brief: WeatherBrief = buildWeatherBrief(payload, info);
  checkEqual('默认主信息：晴 + 温度', brief.mainText, '晴 25°C');
  checkNum('默认主信息种类', brief.mainKind, WEATHER_MAIN_KIND_CONDITION);
  checkNum('AQI 档位带上', brief.aqiLevel, 1);
  checkNum('预警带出', brief.alerts.length, 1);
  checkEqual('预警类型文字', brief.alerts[0].type, '暴雨');
  check('预警图标标记', brief.alerts[0].isDefaultIcon);
  // minutely = [0, 0.1, ...] → 1 分钟 → 1min。默认模糊开启，但 1 分钟走分钟档。
  checkEqual('降雨倒计时', brief.rainText, '1min');

  // 主信息切换。
  payload.mainWeatherInfoKind = WEATHER_MAIN_KIND_HUMIDITY;
  checkEqual('湿度', buildWeatherBrief(payload, info).mainText, '湿度 45%');
  payload.mainWeatherInfoKind = WEATHER_MAIN_KIND_WIND;
  checkEqual('风向风速', buildWeatherBrief(payload, info).mainText, '90 3级');
  payload.mainWeatherInfoKind = WEATHER_MAIN_KIND_AQI;
  checkEqual('AQI', buildWeatherBrief(payload, info).mainText, 'AQI 42');
  payload.mainWeatherInfoKind = WEATHER_MAIN_KIND_PRESSURE;
  checkEqual('气压', buildWeatherBrief(payload, info).mainText, '气压 1013hPa');
  payload.mainWeatherInfoKind = WEATHER_MAIN_KIND_FEELS_LIKE;
  checkEqual('体感', buildWeatherBrief(payload, info).mainText, '体感 26°C');
  // 陌生 kind 落回天气 + 温度。
  payload.mainWeatherInfoKind = 99;
  checkEqual('陌生 kind 回落', buildWeatherBrief(payload, info).mainText, '晴 25°C');
  payload.mainWeatherInfoKind = WEATHER_MAIN_KIND_CONDITION;

  // 开关。
  payload.showMainWeatherInfo = false;
  const noMain: WeatherBrief = buildWeatherBrief(payload, info);
  checkEqual('关掉主信息', noMain.mainText, '');
  payload.showMainWeatherInfo = true;
  payload.showAlerts = false;
  checkNum('关掉预警', buildWeatherBrief(payload, info).alerts.length, 0);
  payload.showAlerts = true;
  payload.showRainTime = false;
  checkEqual('关掉降雨', buildWeatherBrief(payload, info).rainText, '');
  payload.showRainTime = true;

  // 模糊开关：97 分钟 → 1.5h / 97min。
  const longRain: WeatherInfo = WeatherInfo.parse(JsonReader.parse(FIXTURE));
  const values: number[] = [];
  for (let i: number = 0; i < 120; i++) {
    values.push(0);
  }
  values[97] = 0.5;
  longRain.minutely.precipitation.value = values;
  payload.isFuzzyLongRainCountdownEnabled = true;
  checkEqual('模糊开启 97min → 1.5h', buildWeatherBrief(payload, longRain).rainText, '~1.5h');
  payload.isFuzzyLongRainCountdownEnabled = false;
  checkEqual('模糊关闭显示原始分钟', buildWeatherBrief(payload, longRain).rainText, '97min');

  // 说不清（0）时不显示。
  const dry: WeatherInfo = WeatherInfo.parse(JsonReader.parse(FIXTURE));
  dry.minutely.precipitation.value = [0, 0, 0];
  checkEqual('不下雨时不显示倒计时', buildWeatherBrief(payload, dry).rainText, '');

  // 没有数据时给空简报，不抛。
  const empty: WeatherBrief = buildWeatherBrief(payload, undefined);
  checkEqual('undefined 主信息为空', empty.mainText, '');
  checkNum('undefined 没有预警', empty.alerts.length, 0);
  checkEqual('undefined 没有降雨', empty.rainText, '');

  // 数值为空时不显示光秃秃的单位。
  const blank: WeatherInfo = WeatherInfo.parse(JsonReader.parse(FIXTURE));
  blank.current.temperature.value = '';
  checkEqual('温度值为空时只留天气文字', buildWeatherBrief(payload, blank).mainText.trim(), "晴");
}

// --------------------------------------------------------------- 快照

function testSnapshot(): void {
  const unknown: WeatherSnapshot = WeatherSnapshot.unknown();
  check('默认未刷新', !unknown.isRefreshed);
  check('默认没有数据', !unknown.info.hasData());
  // 未知快照下五条规则恒假。
  const current: CurrentWeatherRuleSettings = new CurrentWeatherRuleSettings();
  check('未知快照下当前天气为假', !currentWeatherSatisfied(current, unknown));
  check('未知快照下明天为假', !tomorrowWeatherSatisfied(current, unknown));
  const matching: StringMatchingSettings = new StringMatchingSettings();
  check('未知快照下预警为假', !hasWeatherAlertSatisfied(matching, unknown));
  const rain: RainTimeRuleSettings = new RainTimeRuleSettings();
  check('未知快照下降水为假', !rainTimeSatisfied(rain, unknown));
  const sun: SunRiseSetRuleSettings = new SunRiseSetRuleSettings();
  check('未知快照下日出为假', !sunRiseSetSatisfied(sun, unknown, weatherAt(12, 0)));
}

// --------------------------------------------------------------- 主入口

testWeatherCodes();
testExpandAndMatch();
testParseNumber();
testAqiLevel();
testRainRemaining();
testMinutesToApprox();
testWindDirection();
testFilterAlerts();
testSunTimes();
testModelRoundTrip();
testRules();
testBrief();
testSnapshot();

if (failures.length > 0) {
  console.log(`天气：${failures.length} 项失败（共 ${passed + failures.length} 项）`);
  for (const failure of failures) {
    console.log(`  ✗ ${failure}`);
  }
  process.exit(1);
}
console.log(`天气：${passed} 项全部通过`);
