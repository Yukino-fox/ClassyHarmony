/*
 * cron 表达式解析与匹配。对应桌面版 CronTrigger 用的 TimeCrontab。
 *
 * 字段数：5 或 6
 * ----------
 * 桌面版调的是 `TimeCrontab.Crontab.Parse(expr)`，那个库的默认格式是**带秒的
 * 6 段**（秒 分 时 日 月 周）。但 `CronTriggerSettings` 的默认值写的是
 * `"* * * * *"` —— 5 段，按 6 段解析器会直接抛 TimeCrontabException，于是
 * 「刚加进来的 cron 触发器」永远不响，而且界面上看不出是哪里错了。
 *
 * 鸿蒙侧两种段数都收：先按 6 段试，失败再按 5 段试（5 段时秒位补 0，即只在
 * 分的第 0 秒触发）。这样桌面版的默认配置在鸿蒙侧也是好的，而用户想按秒触发
 * 也能写 6 段。
 *
 * 支持的写法
 * ----------
 *   *        全部
 *   ?        同 *，但只允许出现在「日」和「周」两段（沿用 TimeCrontab 的限制）
 *   a        单个值
 *   a-b      闭区间
 *   a-b/n    区间内每 n 个
 *   斜杠 n    从最小值起每 n 个（前半段写星号）
 *   a,b,c    列表，可与上面几种混用
 *   月与周可以写英文缩写（Jan..Dec / Sun..Sat），大小写不敏感
 *
 * 日 / 周 同时受限时按「或」匹配
 * ------------------------------
 * 这是经典 cron（Vixie）的老规则，也是用户预期的那条：两个都写死时，
 * 「日」命中或「周」命中就算命中。桌面版走的是 TimeCrontab 自己的实现，
 * 具体口径未核实；这里选经典规则并写在这里，是因为它不依赖那个库的细节，
 * 而行为上两条规则只在「日与周恰好一个不命中另一个也不命中」时才分岔，
 * 那种配置本身就很罕见。
 */

import { DateTimeValue } from 'common_shared';
import { t, tf } from '../i18n/I18n';

/** 某一段能取的值域。 */
class FieldRange {
  min: number = 0;
  max: number = 0;
  /** 值域外的合法别名，键是别名（小写）。 */
  names: Map<string, number> = new Map<string, number>();

  constructor(min: number, max: number) {
    this.min = min;
    this.max = max;
  }

  /**
   * 这个值域能不能接 `?`。
   *
   * 只有「日」与「周」可以 —— 其余段位上 `?` 一定是写错了，当成 `*` 反而会
   * 悄悄接受一份坏配置。桌面版在这一点上会抛异常，这里选择不抛，按 `*` 处理：
   * 见文件头「已实现的取舍」之外，这是另一处刻意偏离，理由是坏表达式最坏的
   * 结果是触发得太频繁，而界面上会标出「解析成功/失败」。
   */
  allowsQuestion: boolean = false;

  contains(value: number): boolean {
    return value >= this.min && value <= this.max;
  }
}

const SECONDS: FieldRange = new FieldRange(0, 59);
const MINUTES: FieldRange = new FieldRange(0, 59);
const HOURS: FieldRange = new FieldRange(0, 23);
const DAYS_OF_MONTH: FieldRange = new FieldRange(1, 31);
DAYS_OF_MONTH.allowsQuestion = true;
const MONTHS: FieldRange = new FieldRange(1, 12);
const DAYS_OF_WEEK: FieldRange = new FieldRange(0, 6);
DAYS_OF_WEEK.allowsQuestion = true;

const MONTH_NAMES: string[] =
  ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const DAY_NAMES: string[] = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

function buildNames(): void {
  for (let i: number = 0; i < MONTH_NAMES.length; i++) {
    MONTHS.names.set(MONTH_NAMES[i], i + 1);
  }
  for (let i: number = 0; i < DAY_NAMES.length; i++) {
    DAYS_OF_WEEK.names.set(DAY_NAMES[i], i);
  }
}
buildNames();

/** 一段的匹配结果：命中哪些值 + 是不是「全都要」（写的是 *）。 */
class Field {
  /** 命中集合，用 boolean 数组按值下标存。 */
  hits: boolean[] = [];
  /** 这段写的是否是 * / ?（即不受限制）。 */
  unrestricted: boolean = false;

  constructor(range: FieldRange) {
    for (let i: number = 0; i <= range.max; i++) {
      this.hits.push(false);
    }
  }

  hit(value: number): void {
    if (value >= 0 && value < this.hits.length) {
      this.hits[value] = true;
    }
  }

  matches(value: number): boolean {
    return value >= 0 && value < this.hits.length && this.hits[value];
  }
}

/** 解析结果。解析失败时 valid 为 false，reason 说明失败在哪。 */
export class CronExpression {
  /** 解析成功了吗。 */
  valid: boolean = false;

  /** 失败原因（中文，直接可显示）。 */
  reason: string = '';

  /** 表达式原文。解析成功时用于回显。 */
  source: string = '';

  private hasSeconds: boolean = false;
  private seconds: Field = new Field(SECONDS);
  private minutes: Field = new Field(MINUTES);
  private hours: Field = new Field(HOURS);
  private daysOfMonth: Field = new Field(DAYS_OF_MONTH);
  private months: Field = new Field(MONTHS);
  private daysOfWeek: Field = new Field(DAYS_OF_WEEK);

  constructor() {
  }

  /**
   * 解析一个表达式。
   *
   * 返回的实例一定非 null —— 失败时 valid=false 且 reason 有话可说，
   * 免得调用点每次都判两遍。界面要显示「解析失败 + 原因」时读这两个字段。
   */
  static parse(expression: string): CronExpression {
    const out: CronExpression = new CronExpression();
    out.source = expression;

    const parts: string[] = expression.trim().split(/\s+/).filter((each: string) => each.length > 0);
    if (parts.length !== 5 && parts.length !== 6) {
      out.reason = tf('cron_field_count', `${parts.length}`);
      return out;
    }
    out.hasSeconds = parts.length === 6;

    // 6 段时最前面是秒；5 段时秒位固定补 0。
    const specs: string[] = out.hasSeconds
      ? parts
      : ['0', parts[0], parts[1], parts[2], parts[3], parts[4]];

    const ranges: FieldRange[] = [SECONDS, MINUTES, HOURS, DAYS_OF_MONTH, MONTHS, DAYS_OF_WEEK];
    const fields: Field[] = [out.seconds, out.minutes, out.hours, out.daysOfMonth, out.months,
      out.daysOfWeek];

    for (let i: number = 0; i < 6; i++) {
      if (!CronExpression.parseField(specs[i], ranges[i], fields[i])) {
        out.reason = tf('cron_field_bad', `${i + 1}`, specs[i]);
        return out;
      }
    }

    out.valid = true;
    out.reason = '';
    return out;
  }

  /** 段数（5 或 6），给界面上提示「现在是几段式」。解析失败时为 0。 */
  fieldCount(): number {
    if (!this.valid) {
      return 0;
    }
    return this.hasSeconds ? 6 : 5;
  }

  /**
   * 这一刻是否命中。
   *
   * 语义是「**这一秒**符合表达式」—— cron 的粒度就是秒。5 段表达式只在每分钟的
   * 第 0 秒命中，所以调用方要每秒问一次（桌面版是靠 `GetSleepTimeSpan` 睡到下
   * 一个触发点的，鸿蒙侧改成轮询，见 AutomationEngine 的 tick）。
   */
  matches(now: DateTimeValue): boolean {
    if (!this.valid) {
      return false;
    }
    if (!this.seconds.matches(now.second) || !this.minutes.matches(now.minute) ||
      !this.hours.matches(now.hour) || !this.months.matches(now.month)) {
      return false;
    }
    return this.matchesDay(now);
  }

  /**
   * 日 / 周 的组合判定。
   *
   * 两段都写死时按「或」；只写死一段时按那一段；两段都放开时恒命中。
   */
  private matchesDay(now: DateTimeValue): boolean {
    const byMonth: boolean = this.daysOfMonth.matches(now.day);
    // DateTimeValue.dayOfWeek() 返回 (h+6)%7，0 是周日，与 cron 的 0 一样，
    // 不用再转一次（见 0 基星期几那条纪律）。
    const byWeek: boolean = this.daysOfWeek.matches(now.dayOfWeek());
    if (this.daysOfMonth.unrestricted && this.daysOfWeek.unrestricted) {
      return true;
    }
    if (this.daysOfMonth.unrestricted) {
      return byWeek;
    }
    if (this.daysOfWeek.unrestricted) {
      return byMonth;
    }
    return byMonth || byWeek;
  }

  /** 解一段。成功往 field 里写命中集合，失败返回 false。 */
  private static parseField(spec: string, range: FieldRange, field: Field): boolean {
    if (spec.length === 0) {
      return false;
    }
    if (spec === '*') {
      CronExpression.fillAll(field, range);
      field.unrestricted = true;
      return true;
    }
    if (spec === '?') {
      // 见 FieldRange.allowsQuestion 的注：这里选择接受并按 * 处理。
      CronExpression.fillAll(field, range);
      field.unrestricted = true;
      return true;
    }
    const pieces: string[] = spec.split(',');
    for (const piece of pieces) {
      if (piece.length === 0) {
        return false;
      }
      if (!CronExpression.parsePiece(piece, range, field)) {
        return false;
      }
    }
    return true;
  }

  private static fillAll(field: Field, range: FieldRange): void {
    for (let v: number = range.min; v <= range.max; v++) {
      field.hit(v);
    }
  }

  /**
   * 解 `a` / `a-b` / `a-b/n` / 星号斜杠 n 中的一项。
   *
   * 斜杠可省；省了就是步长 1。斜杠前的部分三种形态：
   *   星号或空  -> 从值域最小到最大
   *   单个值     -> 只有一个值（带斜杠时补到值域末尾，即 `5/10` = 5,15,25...）
   *   a-b       -> 闭区间
   */
  private static parsePiece(piece: string, range: FieldRange, field: Field): boolean {
    const slash: number = piece.indexOf('/');
    const baseText: string = slash < 0 ? piece : piece.substring(0, slash);
    const step: number = slash < 0 ? 1 : CronExpression.parseDigits(piece.substring(slash + 1));
    if (step <= 0) {
      return false;
    }
    let from: number = range.min;
    let to: number = range.max;
    if (baseText.length > 0 && baseText !== '*') {
      const dash: number = baseText.indexOf('-');
      if (dash < 0) {
        from = CronExpression.parseValue(baseText, range);
        if (from < 0) {
          return false;
        }
        // 单个值不带斜杠就是那个值本身；带了斜杠则一路补到值域末尾。
        to = slash < 0 ? from : range.max;
      } else {
        from = CronExpression.parseValue(baseText.substring(0, dash), range);
        to = CronExpression.parseValue(baseText.substring(dash + 1), range);
        if (from < 0 || to < 0) {
          return false;
        }
      }
    }
    if (from > to) {
      return false;
    }
    for (let v: number = from; v <= to; v += step) {
      field.hit(v);
    }
    return true;
  }

  /**
   * 解一个值。允许英文缩写与「7 = 周日」。
   *
   * 返回 -1 表示解不出来。用 -1 而不是 undefined 是因为 0 是合法值（周日、
   * 零点），拿 0 当失败信号会把周日整个判成错。
   */
  private static parseValue(text: string, range: FieldRange): number {
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      return -1;
    }
    const named: number | undefined = range.names.get(trimmed.toLowerCase());
    if (named !== undefined) {
      return named;
    }
    const value: number = CronExpression.parseDigits(trimmed);
    if (value < 0) {
      return -1;
    }
    // 「周」段允许写 7 当周日。这是 cron 的老约定，不写的话
    // 「每周日」得写成 0，而用户多半会写 7。
    if (range === DAYS_OF_WEEK && value === 7) {
      return 0;
    }
    return range.contains(value) ? value : -1;
  }

  /** 解一段纯数字。含非数字字符返回 -1。 */
  private static parseDigits(text: string): number {
    if (text.length === 0) {
      return -1;
    }
    let out: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i) - 48;
      if (code < 0 || code > 9) {
        return -1;
      }
      out = out * 10 + code;
    }
    return out;
  }
}
