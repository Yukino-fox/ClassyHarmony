/*
 * TimeSpan。
 *
 * 桌面版由 System.Text.Json 内置 TimeSpanConverter 处理（.NET 7 起随 8.0.5 生效），
 * 写出使用 Utf8Formatter 的 "c" 常量格式：
 *
 *     [-][d.]hh:mm:ss[.fffffff]
 *
 * 精确语义（字节级往返的前提）：
 * 1. 天数为 0 时省略 d. 前缀；非 0 时输出 d. 且 d 可为多位。
 * 2. hh 恒为两位且落在 00–23（天数已先行剥离）。
 * 3. 小数部分为 100 纳秒刻度（.NET tick），恒为 7 位，为 0 时整段省略。
 * 4. 负号作用于整体：-1.02:03:04 表示 -(1天2时3分4秒)，而非 -1天+2时3分4秒。
 * 5. 上限长度 26 字符（-dddddddd.hh:mm:ss.fffffff）。
 *
 * 读入端按官方 schema pattern 解析：^-?(\d+\.)?\d{2}:\d{2}:\d{2}(\.\d{1,7})?$
 * 并额外容忍小时不足两位等非规范写法——读入宽松、写出严格，
 * 保证手改过的配置文件仍能导入，而本模块写出的文件与桌面版逐字节一致。
 */

/** 一天的 tick 数。 */
const TICKS_PER_DAY: number = 864000000000;
/** 一小时的 tick 数。 */
const TICKS_PER_HOUR: number = 36000000000;
/** 一分钟的 tick 数。 */
const TICKS_PER_MINUTE: number = 600000000;
/** 一秒的 tick 数。 */
const TICKS_PER_SECOND: number = 10000000;

/**
 * tick 上限。Number.MAX_SAFE_INTEGER 为 9007199254740991（约 2.5 亿天），
 * 远大于 TimeSpan.MaxValue 的 9.2e18 tick，故实际无法用 number 精确表示
 * TimeSpan 的完整取值域。此处把可用范围限定在安全整数内（约 250 天），
 * 对时间表场景绰绰有余；解析越界值时钳制并保持时间部分可预测。
 */
const MAX_SAFE_TICKS: number = 9007199254740991;

export class TimeSpanValue {
  /** 总 tick 数（100 纳秒），可负。 */
  private ticks: number;

  private constructor(ticks: number) {
    this.ticks = ticks;
  }

  /** 零值。 */
  static zero(): TimeSpanValue {
    return new TimeSpanValue(0);
  }

  /** 由 tick 数构造。 */
  static fromTicks(ticks: number): TimeSpanValue {
    return new TimeSpanValue(Math.trunc(ticks));
  }

  /** 由小时构造。 */
  static fromHours(hours: number): TimeSpanValue {
    return new TimeSpanValue(Math.round(hours * TICKS_PER_HOUR));
  }

  /** 由分钟构造。 */
  static fromMinutes(minutes: number): TimeSpanValue {
    return new TimeSpanValue(Math.round(minutes * TICKS_PER_MINUTE));
  }

  /** 由「时:分」构造，分钟可超出 60。 */
  static fromHoursMinutes(hours: number, minutes: number): TimeSpanValue {
    return new TimeSpanValue(hours * TICKS_PER_HOUR + minutes * TICKS_PER_MINUTE);
  }

  /** 总 tick 数。 */
  getTicks(): number {
    return this.ticks;
  }

  /** 是否为零。 */
  isZero(): boolean {
    return this.ticks === 0;
  }

  /** 是否为负。 */
  isNegative(): boolean {
    return this.ticks < 0;
  }

  /** 毫秒部分。 */
  milliseconds(): number {
    return Math.floor(Math.abs(this.ticks) % TICKS_PER_SECOND / 10000);
  }

  /** 加减。 */
  add(other: TimeSpanValue): TimeSpanValue {
    return new TimeSpanValue(this.ticks + other.ticks);
  }

  subtract(other: TimeSpanValue): TimeSpanValue {
    return new TimeSpanValue(this.ticks - other.ticks);
  }

  equals(other: TimeSpanValue | undefined): boolean {
    if (other === undefined) {
      return false;
    }
    return this.ticks === other.getTicks();
  }

  /**
   * 规范字面量，等价于 Utf8Formatter.TryFormat(value, 'c')。
   */
  toString(): string {
    const negative: boolean = this.ticks < 0;
    // 取绝对值：-(2^53) 边界无实际意义，此处用 tick 级取反即可。
    let rest: number = negative ? -this.ticks : this.ticks;

    const days: number = Math.floor(rest / TICKS_PER_DAY);
    rest = rest - days * TICKS_PER_DAY;
    const hours: number = Math.floor(rest / TICKS_PER_HOUR);
    rest = rest - hours * TICKS_PER_HOUR;
    const minutes: number = Math.floor(rest / TICKS_PER_MINUTE);
    rest = rest - minutes * TICKS_PER_MINUTE;
    const seconds: number = Math.floor(rest / TICKS_PER_SECOND);
    const fraction: number = rest - seconds * TICKS_PER_SECOND;

    let out: string = negative ? '-' : '';
    if (days !== 0) {
      out += `${days}.`;
    }
    out += `${TimeSpanValue.pad2(hours)}:${TimeSpanValue.pad2(minutes)}:${TimeSpanValue.pad2(seconds)}`;
    if (fraction !== 0) {
      out += `.${TimeSpanValue.padLeft(fraction.toString(), 7, '0')}`;
    }
    return out;
  }

  /**
   * 解析 TimeSpan 字面量。非法返回 undefined。
   * 容忍形如 "8:00"、"1.2:03:04"、"0:00:00.5" 的宽松写法。
   */
  static tryParse(text: string): TimeSpanValue | undefined {
    if (text === null || text === undefined) {
      return undefined;
    }
    const raw: string = text.trim();
    if (raw.length === 0) {
      return undefined;
    }

    let body: string = raw;
    let negative: boolean = false;
    if (body.charAt(0) === '-') {
      negative = true;
      body = body.substring(1);
    } else if (body.charAt(0) === '+') {
      body = body.substring(1);
    }
    if (body.length === 0) {
      return undefined;
    }

    // 分离天数：形如 "1.02:03:04" 的 "1."。
    // 不能简单取第一个点——"00:00:00.5" 的点属于小数秒而非天数。
    // 判据是位置：天数分隔点必然出现在第一个冒号之前，小数点必然在其后。
    let days: number = 0;
    let timePart: string = body;
    const firstColon: number = body.indexOf(':');
    const dayDotIndex: number = firstColon > 0 ? body.lastIndexOf('.', firstColon) : -1;
    if (dayDotIndex > 0) {
      const dayPart: string = body.substring(0, dayDotIndex);
      timePart = body.substring(dayDotIndex + 1);
      if (!TimeSpanValue.isAllDigits(dayPart) || dayPart.length === 0) {
        return undefined;
      }
      days = Number(dayPart);
    }

    // 分离小数秒
    let fraction: number = 0;
    const timeDotIndex: number = timePart.indexOf('.');
    if (timeDotIndex >= 0) {
      const fracPart: string = timePart.substring(timeDotIndex + 1);
      timePart = timePart.substring(0, timeDotIndex);
      if (fracPart.length === 0 || fracPart.length > 7 || !TimeSpanValue.isAllDigits(fracPart)) {
        return undefined;
      }
      fraction = Number(fracPart) * Math.pow(10, 7 - fracPart.length);
    }

    // 桌面版写出恒为 hh:mm:ss 三段；这里额外容忍省略秒的 "8:00" 写法，
    // 因为课表 JSON 常被用户手工编辑，读入宽松可避免整份档案导入失败。
    const segments: string[] = timePart.split(':');
    if (segments.length < 2 || segments.length > 3) {
      return undefined;
    }
    const hours: number | undefined = TimeSpanValue.toNumber(segments[0]);
    const minutes: number | undefined = TimeSpanValue.toNumber(segments[1]);
    const seconds: number | undefined =
      segments.length === 3 ? TimeSpanValue.toNumber(segments[2]) : 0;
    if (hours === undefined || minutes === undefined || seconds === undefined) {
      return undefined;
    }
    if (minutes > 59 || seconds > 59) {
      return undefined;
    }

    const total: number = (days * TICKS_PER_DAY) +
      (hours * TICKS_PER_HOUR) +
      (minutes * TICKS_PER_MINUTE) +
      (seconds * TICKS_PER_SECOND) +
      fraction;
    if (!Number.isFinite(total) || Math.abs(total) > MAX_SAFE_TICKS) {
      return undefined;
    }
    return new TimeSpanValue(negative ? -total : total);
  }

  /** 解析失败时回退到零值，便于反序列化容错。 */
  static parseOrZero(text: string): TimeSpanValue {
    const parsed: TimeSpanValue | undefined = TimeSpanValue.tryParse(text);
    return parsed === undefined ? TimeSpanValue.zero() : parsed;
  }

  private static toNumber(segment: string): number | undefined {
    if (segment.length === 0 || !TimeSpanValue.isAllDigits(segment)) {
      return undefined;
    }
    return Number(segment);
  }

  private static isAllDigits(text: string): boolean {
    for (let i: number = 0; i < text.length; i++) {
      const c: string = text.charAt(i);
      if (c < '0' || c > '9') {
        return false;
      }
    }
    return text.length > 0;
  }

  private static pad2(value: number): string {
    return TimeSpanValue.padLeft(value.toString(), 2, '0');
  }

  private static padLeft(text: string, length: number, filler: string): string {
    let out: string = text;
    while (out.length < length) {
      out = filler + out;
    }
    return out;
  }
}
