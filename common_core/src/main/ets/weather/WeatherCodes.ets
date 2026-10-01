/*
 * 天气代码表与模糊匹配。
 *
 * 表从哪来
 * --------
 * 桌面版把这张表当资源文件放在 `Assets/XiaomiWeather/xiaomi_weather_status.json`
 * （40 条，1188 字节），启动时读进 `WeatherStatusList`。本端**内联成常量**：
 *   - 1KB 的表不值得为它引一条资源加载路径，何况 common_core 是 HAR，
 *     读 rawfile 要绕一趟 entry；
 *   - 内联之后整张表是纯函数的一部分，能进 Node 测试台逐条断言 ——
 *     资源文件在测试台里读不到。
 * 数据逐条抄自那份 JSON，顺序不变。
 *
 * 为什么查找是按「代码转成的字符串」而不是数字
 * ----------------------------------------
 * 桌面版 `GetWeatherTextByCode(string code)` 里做的是
 * `i.Code.ToString() == code` —— 拿 int 的十进制表示去和一个字符串比。
 * 传进来的 code 来自 `CurrentWeather.Weather`（JSON 里就是字符串），
 * 所以「01」和「1」在桌面版是两条不同的查询：前者查不到，返回「未知」。
 * 照抄，不做归一化。会传进奇怪字符串的地方是用户手改的设置文件，
 * 那种输入本来就该按「查不到」处理，而不是被悄悄修好。
 *
 * 模糊匹配的语义
 * ------------
 * `ExpandWeatherCode` 把小米的「区间天气代码」摊成一堆具体代码：
 *   21（小雨-中雨）→ 7 小雨、8 中雨、21
 *   301（雨）→ 3..12 里所有下雨的 + 19 冻雨 + 21..25 + 301
 * 于是「当前天气是 小雨」（7）在模糊匹配下能被「小雨-中雨」（21）满足，
 * 反过来也一样（因为两边各自展开后都含 7）。精确匹配则要求两个字符串相等。
 */

import { WEATHER_CODE_UNKNOWN } from 'common_shared';

/** 表里的一条。 */
export interface WeatherCodeEntry {
  code: number;
  text: string;
}

/** 查不到时的文案。桌面版字面量。 */
export const WEATHER_TEXT_UNKNOWN: string = '未知';

/**
 * 40 条天气代码。顺序与 `xiaomi_weather_status.json` 一致。
 *
 * 注意 99「未知」**在表里**，所以 `weatherTextByCode('99')` 返回「未知」——
 * 与查不到时的兜底文案恰好同字，但来路不同：一个是表命中，一个是表未命中。
 * 这不是冗余，而是照抄：桌面版同样两条路都通向「未知」。
 */
export const WEATHER_CODE_TABLE: WeatherCodeEntry[] = [
  { code: 0, text: '晴' },
  { code: 1, text: '多云' },
  { code: 2, text: '阴' },
  { code: 3, text: '阵雨' },
  { code: 4, text: '雷阵雨' },
  { code: 5, text: '雷阵雨并伴有冰雹' },
  { code: 6, text: '雨夹雪' },
  { code: 7, text: '小雨' },
  { code: 8, text: '中雨' },
  { code: 9, text: '大雨' },
  { code: 10, text: '暴雨' },
  { code: 11, text: '大暴雨' },
  { code: 12, text: '特大暴雨' },
  { code: 13, text: '阵雪' },
  { code: 14, text: '小雪' },
  { code: 15, text: '中雪' },
  { code: 16, text: '大雪' },
  { code: 17, text: '暴雪' },
  { code: 18, text: '雾' },
  { code: 19, text: '冻雨' },
  { code: 20, text: '沙尘暴' },
  { code: 21, text: '小雨-中雨' },
  { code: 22, text: '中雨-大雨' },
  { code: 23, text: '大雨-暴雨' },
  { code: 24, text: '暴雨-大暴雨' },
  { code: 25, text: '大暴雨-特大暴雨' },
  { code: 26, text: '小雪-中雪' },
  { code: 27, text: '中雪-大雪' },
  { code: 28, text: '大雪-暴雪' },
  { code: 29, text: '浮尘' },
  { code: 30, text: '扬沙' },
  { code: 31, text: '强沙尘暴' },
  { code: 32, text: '飑' },
  { code: 33, text: '龙卷风' },
  { code: 34, text: '弱高吹雪' },
  { code: 35, text: '轻雾' },
  { code: 53, text: '霾' },
  { code: 301, text: '雨' },
  { code: 302, text: '雪' },
  { code: 99, text: '未知' }
];

/** 对应桌面版 `IWeatherService.GetWeatherTextByCode`。 */
export function weatherTextByCode(code: string): string {
  for (const entry of WEATHER_CODE_TABLE) {
    if (`${entry.code}` === code) {
      return entry.text;
    }
  }
  return WEATHER_TEXT_UNKNOWN;
}

/**
 * 对应桌面版 `WeatherService.ExpandWeatherCode`。
 *
 * 八条特例，其余原样返回单元素数组。用 `Map<string, string[]>` 而不是
 * switch：这张表将来若有增补，改数据比改控制流省事；而且它能被测试直接
 * 遍历（「表里每个键展开后都包含自己」是一条很值的断言，见 driver）。
 *
 * 返回的数组**不可被调用方修改**——它可能是从表里直接取出的那一份。
 * 调用方（isWeatherCodeMatched）只读，不复制。
 */
const WEATHER_CODE_EXPANSIONS: Map<string, string[]> = new Map<string, string[]>([
  ['21', ['7', '8', '21']],
  ['22', ['8', '9', '22']],
  ['23', ['9', '10', '23']],
  ['24', ['10', '11', '24']],
  ['25', ['11', '12', '25']],
  ['26', ['14', '15', '26']],
  ['27', ['15', '16', '27']],
  ['28', ['16', '17', '28']],
  ['301', ['3', '4', '5', '6', '7', '8', '9', '10', '11', '12', '19', '21', '22', '23', '24', '25', '301']],
  ['302', ['6', '13', '14', '15', '16', '17', '26', '27', '28', '34', '302']]
]);

export function expandWeatherCode(code: string): string[] {
  const expanded: string[] | undefined = WEATHER_CODE_EXPANSIONS.get(code);
  if (expanded !== undefined) {
    return expanded;
  }
  return [code];
}

/**
 * 两个天气代码在模糊语义下是否算同一类。
 *
 * 先比原串（相等直接成立），再比展开后的交集 —— 与桌面版
 * `actualCodes.Overlaps(targetCodes)` 的顺序一致。
 *
 * 原串相等那一步不能省。展开只覆盖八个区间代码，像 '0'（晴）这样的代码展开
 * 后就是 `['0']`，两边相等时靠交集也能命中；但如果有人把这一步去掉、只保留
 * 交集，当展开表被改坏（比如漏了一条）时行为会静默变化 —— 而「相等即匹配」
 * 是这张表无论如何都该保住的性质，让它独立成一步比依赖展开表完整更稳。
 */
export function isWeatherCodeMatched(actualWeatherCode: string, targetWeatherCode: string): boolean {
  if (actualWeatherCode === targetWeatherCode) {
    return true;
  }
  const actualCodes: string[] = expandWeatherCode(actualWeatherCode);
  const targetCodes: string[] = expandWeatherCode(targetWeatherCode);
  for (const actual of actualCodes) {
    for (const target of targetCodes) {
      if (actual === target) {
        return true;
      }
    }
  }
  return false;
}

/** 未知代码的便捷判断，给界面用来决定「要不要显示问号」。 */
export function isUnknownWeatherCode(code: string): boolean {
  return code === WEATHER_CODE_UNKNOWN;
}
