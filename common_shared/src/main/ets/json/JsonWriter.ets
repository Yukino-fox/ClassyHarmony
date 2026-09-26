/*
 * JSON 写出器。
 *
 * 字符串转义规则严格复刻 System.Text.Json 的默认 JavaScriptEncoder，
 * 这是字节级往返的隐性前提：
 * - 仅 Basic Latin (U+0000–U+007E) 可原样输出，其余一律 \uXXXX（大写十六进制）。
 * - 即使在 Basic Latin 内，HTML 敏感字符 & ' + < > ` 仍被转义（默认编码器为防 XSS）。
 * - 控制字符使用 \b \t \n \f \r 短形式，其余用 \u00XX。
 * 证据：源项目 ClassIsland/Assets/default-subjects.json 中 "语文" 被写作 "语文"。
 */

import { JsonArray, JsonBoolean, JsonNode, JsonNull, JsonNumber, JsonObject, JsonString, JsonWriterFormat } from './JsonNode';

export class JsonWriter {
  private indentSize: number;
  private newline: string;

  /**
   * @param indentSize 0 表示压缩输出，对齐 ConfigureFileHelper.SaveConfig 的 writeIndented=false 默认值。
   */
  constructor(indentSize: number = 0, newline: string = '\n') {
    this.indentSize = indentSize;
    this.newline = newline;
  }

  static write(node: JsonNode, indentSize: number = 0): string {
    return new JsonWriter(indentSize).writeNode(node);
  }

  /** 压缩输出，等价于 writeIndented=false。 */
  static writeCompact(node: JsonNode): string {
    return new JsonWriter(0).writeNode(node);
  }

  /** 缩进输出，等价于 writeIndented=true（2 空格缩进，与 System.Text.Json 默认一致）。 */
  static writeIndented(node: JsonNode): string {
    return new JsonWriter(2).writeNode(node);
  }

  private writeNode(node: JsonNode): string {
    const parts: string[] = [];
    this.writeInto(node, parts, 0);
    return parts.join('');
  }

  private writeInto(node: JsonNode, parts: string[], depth: number): void {
    if (node instanceof JsonObject) {
      this.writeObject(node, parts, depth);
    } else if (node instanceof JsonArray) {
      this.writeArray(node, parts, depth);
    } else if (node instanceof JsonString) {
      parts.push(this.quote(node.value));
    } else if (node instanceof JsonNumber) {
      parts.push(node.raw);
    } else if (node instanceof JsonBoolean) {
      parts.push(node.value ? 'true' : 'false');
    } else if (node instanceof JsonNull) {
      parts.push('null');
    } else {
      // 理论不可达：节点类型封闭。保底输出 null 以免产生非法 JSON。
      parts.push('null');
    }
  }

  private writeObject(obj: JsonObject, parts: string[], depth: number): void {
    if (obj.count === 0) {
      parts.push('{}');
      return;
    }
    const pretty: boolean = this.indentSize > 0;
    parts.push('{');
    const inner: number = depth + 1;
    for (const member of obj.entries()) {
      if (pretty) {
        parts.push(this.newline);
        this.pushIndent(parts, inner);
      } else if (parts.length > 0 && parts[parts.length - 1] !== '{') {
        parts.push(',');
      }
      parts.push(this.quote(member.name));
      parts.push(':');
      if (pretty) {
        parts.push(' ');
      }
      this.writeInto(member.value, parts, inner);
    }
    if (pretty) {
      parts.push(this.newline);
      this.pushIndent(parts, depth);
    }
    parts.push('}');
  }

  private writeArray(arr: JsonArray, parts: string[], depth: number): void {
    if (arr.count === 0) {
      parts.push('[]');
      return;
    }
    const pretty: boolean = this.indentSize > 0;
    parts.push('[');
    const inner: number = depth + 1;
    const items: JsonNode[] = arr.values();
    for (let i: number = 0; i < items.length; i++) {
      if (i > 0) {
        parts.push(',');
      }
      if (pretty) {
        parts.push(this.newline);
        this.pushIndent(parts, inner);
      }
      this.writeInto(items[i], parts, inner);
    }
    if (pretty) {
      parts.push(this.newline);
      this.pushIndent(parts, depth);
    }
    parts.push(']');
  }

  private pushIndent(parts: string[], depth: number): void {
    for (let i: number = 0; i < depth; i++) {
      parts.push(' '.repeat(this.indentSize));
    }
  }

  /**
   * 按 System.Text.Json 默认编码器转义并加引号。
   */
  private quote(value: string): string {
    let out: string = '"';
    for (let i: number = 0; i < value.length; i++) {
      const code: number = value.charCodeAt(i);
      switch (code) {
        case 0x22:
          out += '\\"';
          continue;
        case 0x5C:
          out += '\\\\';
          continue;
        case 0x08:
          out += '\\b';
          continue;
        case 0x09:
          out += '\\t';
          continue;
        case 0x0A:
          out += '\\n';
          continue;
        case 0x0C:
          out += '\\f';
          continue;
        case 0x0D:
          out += '\\r';
          continue;
        default:
          break;
      }
      if (code < 0x20 || code >= 0x7F) {
        out += this.escapeCodeUnit(code);
        continue;
      }
      // Basic Latin 内仍需转义的 HTML 敏感字符
      if (code === 0x26 || code === 0x27 || code === 0x2B || code === 0x3C || code === 0x3E || code === 0x60) {
        out += this.escapeCodeUnit(code);
        continue;
      }
      out += value.charAt(i);
    }
    return `${out}"`;
  }

  private escapeCodeUnit(code: number): string {
    const hex: string = code.toString(16).toUpperCase();
    if (hex.length >= 4) {
      return `\\u${hex}`;
    }
    return `\\u000${hex}`;
  }
}
