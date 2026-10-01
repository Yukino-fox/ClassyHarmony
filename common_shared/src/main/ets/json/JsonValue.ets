/*
 * 节点取值辅助。
 *
 * 桌面版读取时字段缺失会退回 C# 默认值（Guid.Empty / 0 / false / 空串 / null），
 * 这里以「读不到即默认值」为统一语义，避免各处重复判空。
 */

import { JsonArray, JsonBoolean, JsonNode, JsonNull, JsonNumber, JsonObject, JsonString } from './JsonNode';
import { Guid } from './Guid';

export class JsonValue {
  /** 取出对象节点；不是对象（或缺失）时返回 undefined。 */
  static asObject(node: JsonNode | undefined): JsonObject | undefined {
    if (node instanceof JsonObject) {
      return node;
    }
    return undefined;
  }

  /** 取出数组节点。 */
  static asArray(node: JsonNode | undefined): JsonArray | undefined {
    if (node instanceof JsonArray) {
      return node;
    }
    return undefined;
  }

  /** 取出字符串；非字符串返回 fallback。 */
  static asString(node: JsonNode | undefined, fallback: string = ''): string {
    if (node instanceof JsonString) {
      return node.value;
    }
    return fallback;
  }

  /**
   * 宽松取字符串：字符串取原值，数字取**原始字面量**，其它返回 fallback。
   *
   * 只给「对端形状不确定」的字段用（目前只有天气的 aqi：桌面版声明成 string，
   * 但那份声明的来源是一个我们无法在此核对的第三方接口）。取原始字面量而不是
   * 数值再格式化，是为了让 `"0.0"` 这类已经写好的字符串形态在往返里不走样。
   *
   * 不用在别处：严格是默认口径，宽松是例外，例外多了就等于没有类型。
   */
  static asStringLoose(node: JsonNode | undefined, fallback: string = ''): string {
    if (node instanceof JsonString) {
      return node.value;
    }
    if (node instanceof JsonNumber) {
      return node.raw;
    }
    return fallback;
  }

  /**
   * 取出布尔。
   * 桌面版对 bool 的读取是严格类型化的，字符串 "true" 会导致 JsonException；
   * 这里保持严格（返回 fallback），不做宽松解析，以免掩盖配置损坏。
   */
  static asBoolean(node: JsonNode | undefined, fallback: boolean = false): boolean {
    if (node instanceof JsonBoolean) {
      return node.value;
    }
    return fallback;
  }

  /** 取出整数。非数值或含小数点时返回 fallback。 */
  static asInt(node: JsonNode | undefined, fallback: number = 0): number {
    if (node instanceof JsonNumber) {
      if (Number.isInteger(node.value)) {
        return node.value;
      }
      return fallback;
    }
    return fallback;
  }

  /** 取出浮点数。非数值时返回 fallback。 */
  static asNumber(node: JsonNode | undefined, fallback: number = 0): number {
    if (node instanceof JsonNumber) {
      return node.value;
    }
    return fallback;
  }

  /** 取出枚举（以整数存储）。 */
  static asEnum(node: JsonNode | undefined, fallback: number): number {
    if (node instanceof JsonNumber) {
      return Math.trunc(node.value);
    }
    return fallback;
  }

  /**
   * 取出 Guid。空串或空白按 Guid.Empty 处理，
   * 复刻 GuidEmptyFallbackConverter.Read 的行为。
   */
  static asGuid(node: JsonNode | undefined): Guid {
    if (node instanceof JsonString) {
      return Guid.parseOrEmpty(node.value);
    }
    return Guid.empty();
  }

  /** 取出可空 Guid。JSON null 或缺失返回 undefined。 */
  static asNullableGuid(node: JsonNode | undefined): Guid | undefined {
    if (node === undefined || node instanceof JsonNull) {
      return undefined;
    }
    if (node instanceof JsonString) {
      return Guid.parseOrEmpty(node.value);
    }
    return undefined;
  }

  /** 是否为显式 null。 */
  static isNull(node: JsonNode | undefined): boolean {
    return node === undefined || node instanceof JsonNull;
  }
}
