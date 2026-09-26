/*
 * 颜色值。对齐 Avalonia Color 与桌面版的 ColorHexJsonConverter。
 *
 * 字面量格式是 #RRGGBBAA（透明度在**末尾**）
 * ------------------------------------------------
 * 这不是常见的 CSS 顺序，容易想当然写成 #AARRGGBB。依据是桌面版的转换器：
 *
 *   ColorHexJsonConverter.Write
 *     → ColorToHexConverter.ToHexString(value, AlphaComponentPosition.Trailing, true)
 *
 * Avalonia 的 ToHexString 在 Trailing 下拼的是 {R:X2}{G:X2}{B:X2}{A:X2}，
 * 所以 DefaultGroupGuid 之外最常出现的 ForegroundColor 默认值
 * Colors.DodgerBlue（#1E90FF，全不透明）落盘成 "#1E90FFFF"，不是 "#FF1E90FF"。
 * 写反了的话桌面版读回来会把不透明红当透明度，整个面板背景变黑红 —— 而 JSON
 * 本身完全合法，只有真机上看颜色才发现得了。
 *
 * 数字一律大写十六进制两位：X2 格式化，位数不足补 0。
 *
 * 桌面版还接受对象形式 {"A":..,"R":..,"G":..,"B":..}，那个也读。
 *
 * 与 ArkUI 的颜色字符串不是一回事
 * -------------------------------
 * ArkUI 的 '#AARRGGBB' 把透明度放在**开头**。所以 toArkUi() 单独换一次字节序，
 * 别拿 toString() 直接喂给 .fontColor()：#1E90FFFF 在 ArkUI 里是「几乎全透明
 * 的深红」，不报错、不警告，只是看不见。
 */

export class ColorValue {
  a: number;
  r: number;
  g: number;
  b: number;

  constructor(a: number, r: number, g: number, b: number) {
    this.a = ColorValue.byte(a);
    this.r = ColorValue.byte(r);
    this.g = ColorValue.byte(g);
    this.b = ColorValue.byte(b);
  }

  /** Colors.DodgerBlue，MainWindowLineSettings.ForegroundColor 的默认值。 */
  static dodgerBlue(): ColorValue {
    return new ColorValue(255, 0x1e, 0x90, 0xff);
  }

  /** Colors.Black，MainWindowLineSettings.BackgroundColor 的默认值。 */
  static black(): ColorValue {
    return new ColorValue(255, 0, 0, 0);
  }

  /** 纯白全不透明，TextComponentSettings.FontColor 的默认值。 */
  static white(): ColorValue {
    return new ColorValue(255, 255, 255, 255);
  }

  /** 纯红全不透明，CountDownComponentSettings.FontColor 的默认值。 */
  static red(): ColorValue {
    return new ColorValue(255, 255, 0, 0);
  }

  /**
   * default(Color)，即全 0。桌面版解析失败时落到它（`?? default`）。
   *
   * 全透明黑：不是「黑色」，是不可见。拿它当解析失败的回退值看起来很怪，
   * 但那是桌面版的实际行为 —— 换成一个好看的回退色反而会让「颜色写坏了」
   * 这件事在界面上完全看不出来。
   */
  static transparent(): ColorValue {
    return new ColorValue(0, 0, 0, 0);
  }

  /**
   * 解析桌面版的颜色字面量。
   *
   * 容忍：#RRGGBBAA（8 位）、#RRGGBB（6 位，补 A=FF）、大小写混写、
   * 无 `#` 前缀。读不出来返回 undefined，由调用方决定回退。
   */
  static tryParse(text: string): ColorValue | undefined {
    let body: string = text.trim();
    if (body.startsWith('#')) {
      body = body.substring(1);
    }
    if (body.length === 8) {
      const r: number = ColorValue.hex(body, 0);
      const g: number = ColorValue.hex(body, 2);
      const b: number = ColorValue.hex(body, 4);
      const a: number = ColorValue.hex(body, 6);
      return new ColorValue(a, r, g, b);
    }
    if (body.length === 6) {
      return new ColorValue(255,
        ColorValue.hex(body, 0), ColorValue.hex(body, 2), ColorValue.hex(body, 4));
    }
    return undefined;
  }

  /** 落盘字面量：`#RRGGBBAA`，大写。 */
  toString(): string {
    return `#${ColorValue.pair(this.r)}${ColorValue.pair(this.g)}` +
      `${ColorValue.pair(this.b)}${ColorValue.pair(this.a)}`;
  }

  /**
   * ArkUI 颜色字符串：`#AARRGGBB`，透明度在开头。
   *
   * 与 toString() 的差别只在这里，值本身一样。
   */
  toArkUi(): string {
    return `#${ColorValue.pair(this.a)}${ColorValue.pair(this.r)}` +
      `${ColorValue.pair(this.g)}${ColorValue.pair(this.b)}`;
  }

  equals(other: ColorValue | undefined): boolean {
    return other !== undefined && other.a === this.a && other.r === this.r &&
      other.g === this.g && other.b === this.b;
  }

  private static pair(value: number): string {
    const hex: string = value.toString(16).toUpperCase();
    return hex.length < 2 ? `0${hex}` : hex;
  }

  private static hex(body: string, offset: number): number {
    const slice: string = body.substring(offset, offset + 2);
    const value: number = parseInt(slice, 16);
    return Number.isNaN(value) ? 0 : value;
  }

  private static byte(value: number): number {
    if (!Number.isFinite(value)) {
      return 0;
    }
    const rounded: number = Math.round(value);
    return rounded < 0 ? 0 : (rounded > 255 ? 255 : rounded);
  }
}
