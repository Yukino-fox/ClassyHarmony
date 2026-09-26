/*
 * DateTime。
 *
 * 桌面版由 System.Text.Json 内置 DateTimeConverter 处理，Kind 为 Unspecified 时
 * 写出 ISO 8601 扩展格式：
 *
 *     yyyy-MM-ddTHH:mm:ss[.fffffff]
 *
 * 小数部分固定 7 位（100 纳秒刻度），且仅在非零时才出现。
 * 证据：源项目 examples/example.json 中为 "2024-05-25T08:00:00"，无小数部分。
 *
 * 这里以「日历分量」而非「纪元毫秒」作为存储，原因是课表里的 DateTime
 * （TempClassPlanSetupTime / OverlaySetupTime / OrderedSchedules 的键）语义是
 * 墙上时钟：Kind=Unspecified，不带时区。若折算成纪元毫秒就必须引入一个隐式时区，
 * 而设备时区会变，往返就不再稳定。
 *
 * 关于时区后缀：ClassIsland 自身从不写出后缀。读入时若遇到 Z 或 ±hh:mm，
 * 本实现保留墙上时钟分量并丢弃偏移（不折算到 UTC），因为课表日期一旦被折算
 * 就可能整体偏移一天，属于静默的数据变更。此为有意取舍，已记录待复核。
 */

const MS_PER_SECOND: number = 1000;
const MS_PER_MINUTE: number = 60000;
const MS_PER_HOUR: number = 3600000;
const MS_PER_DAY: number = 86400000;

export class DateTimeValue {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
  /** 100 纳秒刻度的小数部分，0–9999999。 */
  fraction: number;

  constructor(year: number, month: number, day: number,
    hour: number, minute: number, second: number, fraction: number = 0) {
    this.year = year;
    this.month = month;
    this.day = day;
    this.hour = hour;
    this.minute = minute;
    this.second = second;
    this.fraction = Math.trunc(fraction);
  }

  /** DateTime.MinValue（0001-01-01T00:00:00），对应 C# default(DateTime)。 */
  static minValue(): DateTimeValue {
    return new DateTimeValue(1, 1, 1, 0, 0, 0, 0);
  }

  /** 当前本地时间。 */
  static now(): DateTimeValue {
    return DateTimeValue.fromDate(new Date());
  }

  /** 由 JS Date 的本地日历分量构造。 */
  static fromDate(date: Date): DateTimeValue {
    return new DateTimeValue(
      date.getFullYear(),
      date.getMonth() + 1,
      date.getDate(),
      date.getHours(),
      date.getMinutes(),
      date.getSeconds(),
      date.getMilliseconds() * 10000
    );
  }

  /** 折算为本地纪元毫秒，用于比较与算术。 */
  toLocalMillis(): number {
    return Date.UTC(this.year, this.month - 1, this.day,
      this.hour, this.minute, this.second, Math.floor(this.fraction / 10000)) -
      this.localTimezoneOffsetMillis(this.year, this.month - 1, this.day);
  }

  private localTimezoneOffsetMillis(y: number, m: number, d: number): number {
    const probe: Date = new Date(y, m, d, 12, 0, 0, 0);
    return -probe.getTimezoneOffset() * MS_PER_MINUTE;
  }

  /**
   * 规范字面量，等价于 System.Text.Json 的 DateTime 写出。
   * 年份固定四位；小数部分非零时补足 7 位。
   */
  toString(): string {
    let out: string = `${DateTimeValue.pad(this.year, 4)}-${DateTimeValue.pad(this.month, 2)}-${DateTimeValue.pad(this.day, 2)}` +
      `T${DateTimeValue.pad(this.hour, 2)}:${DateTimeValue.pad(this.minute, 2)}:${DateTimeValue.pad(this.second, 2)}`;
    if (this.fraction !== 0) {
      out += `.${DateTimeValue.padLeft(this.fraction.toString(), 7, '0')}`;
    }
    return out;
  }

  /** 仅日期部分，用于卡片、日程等按天聚合的场景。 */
  toDateString(): string {
    return `${DateTimeValue.pad(this.year, 4)}-${DateTimeValue.pad(this.month, 2)}-${DateTimeValue.pad(this.day, 2)}`;
  }

  /** 星期几：0=周日 … 6=周六。 */
  dayOfWeek(): number {
    return new Date(this.year, this.month - 1, this.day).getDay();
  }

  /**
   * 与 C# TimeOnly.ToTimeSpan() 对齐：当天已过的秒数。
   * 课程时段比较大量依赖这个量。
   */
  timeOfDaySeconds(): number {
    return this.hour * 3600 + this.minute * 60 + this.second;
  }

  addSeconds(seconds: number): DateTimeValue {
    return DateTimeValue.fromLocalMillis(this.toLocalMillis() + seconds * MS_PER_SECOND);
  }

  addDays(days: number): DateTimeValue {
    return DateTimeValue.fromLocalMillis(this.toLocalMillis() + days * MS_PER_DAY);
  }

  static fromLocalMillis(millis: number): DateTimeValue {
    return DateTimeValue.fromDate(new Date(millis));
  }

  /**
   * 解析 ISO 8601 形式。非法返回 undefined。
   * 容忍 'T' 或空格分隔、缺省秒、1–7 位小数、尾部时区后缀。
   */
  static tryParse(text: string): DateTimeValue | undefined {
    if (text === null || text === undefined) {
      return undefined;
    }
    const raw: string = text.trim();
    if (raw.length < 8) {
      return undefined;
    }

    let body: string = raw;
    // 丢弃时区后缀（保留墙上时钟，见文件头说明）
    const zIndex: number = body.indexOf('Z');
    if (zIndex === body.length - 1) {
      body = body.substring(0, zIndex);
    } else {
      const offsetMatch: number = DateTimeValue.findOffsetStart(body);
      if (offsetMatch > 0) {
        body = body.substring(0, offsetMatch);
      }
    }

    const sepIndex: number = body.indexOf('T') >= 0 ? body.indexOf('T') : body.indexOf(' ');
    const datePart: string = sepIndex >= 0 ? body.substring(0, sepIndex) : body;
    const timePart: string = sepIndex >= 0 ? body.substring(sepIndex + 1) : '';

    const dateSegments: string[] = datePart.split('-');
    if (dateSegments.length !== 3) {
      return undefined;
    }
    const year: number = Number(dateSegments[0]);
    const month: number = Number(dateSegments[1]);
    const day: number = Number(dateSegments[2]);
    if (Number.isNaN(year) || Number.isNaN(month) || Number.isNaN(day)) {
      return undefined;
    }
    if (month < 1 || month > 12 || day < 1 || day > 31) {
      return undefined;
    }

    let hour: number = 0;
    let minute: number = 0;
    let second: number = 0;
    let fraction: number = 0;
    if (timePart.length > 0) {
      let timeBody: string = timePart;
      const fracIndex: number = timeBody.indexOf('.');
      if (fracIndex >= 0) {
        const fracText: string = timeBody.substring(fracIndex + 1);
        timeBody = timeBody.substring(0, fracIndex);
        if (fracText.length === 0 || fracText.length > 7) {
          return undefined;
        }
        for (let i: number = 0; i < fracText.length; i++) {
          const c: string = fracText.charAt(i);
          if (c < '0' || c > '9') {
            return undefined;
          }
        }
        fraction = Number(fracText) * Math.pow(10, 7 - fracText.length);
      }
      const timeSegments: string[] = timeBody.split(':');
      if (timeSegments.length < 1 || timeSegments.length > 3) {
        return undefined;
      }
      hour = Number(timeSegments[0]);
      if (timeSegments.length >= 2) {
        minute = Number(timeSegments[1]);
      }
      if (timeSegments.length >= 3) {
        second = Number(timeSegments[2]);
      }
      if (Number.isNaN(hour) || Number.isNaN(minute) || Number.isNaN(second)) {
        return undefined;
      }
    }

    return new DateTimeValue(year, month, day, hour, minute, second, fraction);
  }

  /** 解析失败时回退到 DateTime.MinValue，便于反序列化容错。 */
  static parseOrMin(text: string): DateTimeValue {
    const parsed: DateTimeValue | undefined = DateTimeValue.tryParse(text);
    return parsed === undefined ? DateTimeValue.minValue() : parsed;
  }

  /** 定位 ±hh:mm / ±hhmm 形式的时区后缀起点。 */
  private static findOffsetStart(body: string): number {
    // 时间部分形如 hh:mm:ss，后缀的 +/- 必然出现在 11 字符之后
    for (let i: number = 10; i < body.length; i++) {
      const c: string = body.charAt(i);
      if (c === '+' || c === '-') {
        return i;
      }
    }
    return -1;
  }

  equals(other: DateTimeValue | undefined): boolean {
    if (other === undefined) {
      return false;
    }
    return this.toString() === other.toString();
  }

  private static pad(value: number, width: number): string {
    return DateTimeValue.padLeft(value.toString(), width, '0');
  }

  private static padLeft(text: string, length: number, filler: string): string {
    let out: string = text;
    while (out.length < length) {
      out = filler + out;
    }
    return out;
  }
}
