/*
 * Guid。
 *
 * 桌面版序列化规则（来自 GuidEmptyFallbackConverter）：
 * - 写出：value.ToString()，即 "D" 规范格式——32 位小写十六进制 + 4 个连字符。
 * - 读入：空白或空串 → Guid.Empty；否则 Guid.Parse。
 *
 * Guid.Parse 接受 N / D / B / P 四种格式，这里读入端一并容忍，
 * 但写出端始终归一为小写 "D"，与桌面版一致。
 */

const EMPTY_CANONICAL: string = '00000000-0000-0000-0000-000000000000';

export class Guid {
  /** 归一后的 "D" 格式小写字符串。 */
  private value: string;

  private constructor(canonical: string) {
    this.value = canonical;
  }

  /** Guid.Empty。 */
  static empty(): Guid {
    return new Guid(EMPTY_CANONICAL);
  }

  /** 由已有 "D" 格式字符串构造，不做校验（供反序列化热路径使用）。 */
  static fromCanonical(canonical: string): Guid {
    return new Guid(canonical);
  }

  /**
   * 解析字符串，失败或为空白时返回 Guid.Empty。
   * 对应 GuidEmptyFallbackConverter.Read。
   */
  static parseOrEmpty(text: string): Guid {
    if (text === null || text === undefined) {
      return Guid.empty();
    }
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      return Guid.empty();
    }
    const normalized: string | undefined = Guid.normalize(trimmed);
    if (normalized === undefined) {
      return Guid.empty();
    }
    return new Guid(normalized);
  }

  /** 严格解析，失败返回 undefined。 */
  static tryParse(text: string): Guid | undefined {
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      return undefined;
    }
    const normalized: string | undefined = Guid.normalize(trimmed);
    if (normalized === undefined) {
      return undefined;
    }
    return new Guid(normalized);
  }

  /**
   * 把 N / D / B / P 任一格式归一为小写 "D"。
   * 非法返回 undefined。
   */
  private static normalize(text: string): string | undefined {
    let hex: string = '';
    if (text.length === 38 && text.charAt(0) === '{' && text.charAt(37) === '}') {
      hex = text.substring(1, 37); // B
    } else if (text.length === 38 && text.charAt(0) === '(' && text.charAt(37) === ')') {
      hex = text.substring(1, 37); // P
    } else if (text.length === 36) {
      hex = text; // D，需校验连字符位置
    } else if (text.length === 32) {
      hex = text; // N
    } else {
      return undefined;
    }

    hex = hex.toLowerCase();
    for (let i: number = 0; i < hex.length; i++) {
      const c: string = hex.charAt(i);
      const isHex: boolean = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
      const isSeparator: boolean = c === '-' && (i === 8 || i === 13 || i === 18 || i === 23);
      if (!isHex && !isSeparator) {
        return undefined;
      }
    }
    if (hex.length === 36) {
      return hex;
    }
    // N 格式：按 8-4-4-4-12 插入连字符
    return `${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}`;
  }

  /** 生成新的非空 Guid（v4）。 */
  static newGuid(): Guid {
    const hex: string = '0123456789abcdef';
    let out: string = '';
    for (let i: number = 0; i < 36; i++) {
      if (i === 8 || i === 13 || i === 18 || i === 23) {
        out += '-';
        continue;
      }
      if (i === 12) {
        out += '4'; // version
        continue;
      }
      if (i === 16) {
        out += hex.charAt((Math.random() * 4) | 0 + 8); // variant
        continue;
      }
      out += hex.charAt((Math.random() * 16) | 0);
    }
    return new Guid(out);
  }

  /** 是否为 Guid.Empty。 */
  isEmpty(): boolean {
    return this.value === EMPTY_CANONICAL;
  }

  /** 写出用字面量，等价于 C# value.ToString()。 */
  toString(): string {
    return this.value;
  }

  equals(other: Guid | undefined): boolean {
    if (other === undefined) {
      return false;
    }
    return this.value === other.value;
  }
}

/** 供 Map 键使用的包装，避免对象身份导致去重失败。 */
export class GuidKey {
  private key: string;

  constructor(guid: Guid) {
    this.key = guid.toString();
  }

  get value(): string {
    return this.key;
  }
}
