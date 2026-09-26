/*
 * 手写 JSON 解析器。
 *
 * 不用 JSON.parse 的原因见 JsonNode.ets 顶部说明，核心是：
 * 保留数字原始字面量 + 完全类型化（无 any / unknown）+ 严格遵循 RFC 8259。
 */

import { JsonArray, JsonBoolean, JsonNode, JsonNull, JsonNumber, JsonObject, JsonString } from './JsonNode';

export class JsonParseError extends Error {
  constructor(message: string, position: number) {
    super(`${message}（位置 ${position}）`);
    this.name = 'JsonParseError';
  }
}

export class JsonReader {
  private text: string;
  private pos: number;

  private constructor(text: string) {
    this.text = text;
    this.pos = 0;
  }

  /** 解析一段 JSON 文本。 */
  static parse(text: string): JsonNode {
    const reader: JsonReader = new JsonReader(text);
    reader.skipWhitespace();
    const node: JsonNode = reader.readValue();
    reader.skipWhitespace();
    if (reader.pos !== reader.text.length) {
      throw new JsonParseError('JSON 根值之后存在多余内容', reader.pos);
    }
    return node;
  }

  private skipWhitespace(): void {
    while (this.pos < this.text.length) {
      const c: string = this.text.charAt(this.pos);
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
        this.pos++;
      } else {
        break;
      }
    }
  }

  private peek(): string {
    if (this.pos >= this.text.length) {
      throw new JsonParseError('内容意外结束', this.pos);
    }
    return this.text.charAt(this.pos);
  }

  private expect(ch: string): void {
    if (this.peek() !== ch) {
      throw new JsonParseError(`期望 '${ch}'`, this.pos);
    }
    this.pos++;
  }

  private readValue(): JsonNode {
    const c: string = this.peek();
    if (c === '{') {
      return this.readObject();
    }
    if (c === '[') {
      return this.readArray();
    }
    if (c === '"') {
      return new JsonString(this.readString());
    }
    if (c === 't') {
      this.readLiteral('true');
      return new JsonBoolean(true);
    }
    if (c === 'f') {
      this.readLiteral('false');
      return new JsonBoolean(false);
    }
    if (c === 'n') {
      this.readLiteral('null');
      return new JsonNull();
    }
    return this.readNumber();
  }

  private readLiteral(literal: string): void {
    if (this.text.substr(this.pos, literal.length) !== literal) {
      throw new JsonParseError(`非法字面量，期望 '${literal}'`, this.pos);
    }
    this.pos += literal.length;
  }

  private readObject(): JsonObject {
    this.expect('{');
    const obj: JsonObject = new JsonObject();
    this.skipWhitespace();
    if (this.peek() === '}') {
      this.pos++;
      return obj;
    }
    while (true) {
      this.skipWhitespace();
      const key: string = this.readString();
      this.skipWhitespace();
      this.expect(':');
      this.skipWhitespace();
      obj.set(key, this.readValue());
      this.skipWhitespace();
      const c: string = this.peek();
      if (c === ',') {
        this.pos++;
        continue;
      }
      if (c === '}') {
        this.pos++;
        return obj;
      }
      throw new JsonParseError('对象中期望 \',\' 或 \'}\'', this.pos);
    }
  }

  private readArray(): JsonArray {
    this.expect('[');
    const arr: JsonArray = new JsonArray();
    this.skipWhitespace();
    if (this.peek() === ']') {
      this.pos++;
      return arr;
    }
    while (true) {
      this.skipWhitespace();
      arr.push(this.readValue());
      this.skipWhitespace();
      const c: string = this.peek();
      if (c === ',') {
        this.pos++;
        continue;
      }
      if (c === ']') {
        this.pos++;
        return arr;
      }
      throw new JsonParseError('数组中期望 \',\' 或 \']\'', this.pos);
    }
  }

  private readString(): string {
    this.expect('"');
    let out: string = '';
    while (true) {
      if (this.pos >= this.text.length) {
        throw new JsonParseError('字符串未闭合', this.pos);
      }
      const c: string = this.text.charAt(this.pos);
      if (c === '"') {
        this.pos++;
        return out;
      }
      if (c === '\\') {
        this.pos++;
        out += this.readEscape();
        continue;
      }
      if (c < ' ') {
        throw new JsonParseError('字符串中出现未转义的控制字符', this.pos);
      }
      out += c;
      this.pos++;
    }
  }

  private readEscape(): string {
    const c: string = this.peek();
    this.pos++;
    switch (c) {
      case '"':
        return '"';
      case '\\':
        return '\\';
      case '/':
        return '/';
      case 'b':
        return '\b';
      case 'f':
        return '\f';
      case 'n':
        return '\n';
      case 'r':
        return '\r';
      case 't':
        return '\t';
      case 'u':
        return this.readUnicodeEscape();
      default:
        throw new JsonParseError(`非法转义序列 '\\${c}'`, this.pos - 1);
    }
  }

  private readUnicodeEscape(): string {
    if (this.pos + 4 > this.text.length) {
      throw new JsonParseError('\\u 转义长度不足', this.pos);
    }
    const hex: string = this.text.substr(this.pos, 4);
    const code: number = parseInt(hex, 16);
    if (Number.isNaN(code)) {
      throw new JsonParseError(`\\u 转义非法：'${hex}'`, this.pos);
    }
    this.pos += 4;
    return String.fromCharCode(code);
  }

  /**
   * 读取数字并保留原始字面量。
   *
   * JSON 语法要求形如 -?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?
   * 这里先按语法扫描出字面量，再交给 Number 解析，避免先转浮点丢精度。
   */
  private readNumber(): JsonNumber {
    const start: number = this.pos;
    if (this.pos < this.text.length && this.text.charAt(this.pos) === '-') {
      this.pos++;
    }
    const intStart: number = this.pos;
    while (this.pos < this.text.length && this.isDigit(this.text.charAt(this.pos))) {
      this.pos++;
    }
    if (this.pos === intStart) {
      throw new JsonParseError('数字缺少整数部分', start);
    }
    if (this.text.charAt(intStart) === '0' && this.pos - intStart > 1) {
      throw new JsonParseError('数字存在前导零', intStart);
    }
    if (this.pos < this.text.length && this.text.charAt(this.pos) === '.') {
      this.pos++;
      const fracStart: number = this.pos;
      while (this.pos < this.text.length && this.isDigit(this.text.charAt(this.pos))) {
        this.pos++;
      }
      if (this.pos === fracStart) {
        throw new JsonParseError('数字缺少小数部分', this.pos);
      }
    }
    if (this.pos < this.text.length) {
      const e: string = this.text.charAt(this.pos);
      if (e === 'e' || e === 'E') {
        this.pos++;
        if (this.pos < this.text.length) {
          const sign: string = this.text.charAt(this.pos);
          if (sign === '+' || sign === '-') {
            this.pos++;
          }
        }
        const expStart: number = this.pos;
        while (this.pos < this.text.length && this.isDigit(this.text.charAt(this.pos))) {
          this.pos++;
        }
        if (this.pos === expStart) {
          throw new JsonParseError('数字指数部分非法', this.pos);
        }
      }
    }
    const raw: string = this.text.substring(start, this.pos);
    const value: number = Number(raw);
    if (Number.isNaN(value)) {
      throw new JsonParseError(`数字无法解析：'${raw}'`, start);
    }
    return new JsonNumber(raw, value);
  }

  private isDigit(c: string): boolean {
    return c >= '0' && c <= '9';
  }
}
