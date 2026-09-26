/*
 * 模型编解码共用工具。
 *
 * 桌面版里 AttachedObjects 出现在 5 个 AttachableSettingsObject 子类上，
 * 类型均为 Dictionary<Guid, object?>，键为 Guid、值为任意裸 JSON（含 null）。
 * 这里以 JsonNode 原样承载，读入写出都不解释其内容，从而保证插件写入的
 * 私有数据在往返中逐字节保持不变。
 */

import { Guid } from '../json/Guid';
import { DateTimeValue } from '../json/DateTimeValue';
import { JsonArray, JsonNode, JsonNull, JsonNumber, JsonObject, JsonString } from '../json/JsonNode';
import { JsonValue } from '../json/JsonValue';
import { KeyedMap } from '../collections/KeyedMap';

export class ModelCodec {
  // ---- AttachedObjects ------------------------------------------------

  /** 读取 AttachedObjects。原样保留节点树，不解释内部结构。 */
  static readAttachedObjects(parent: JsonObject): KeyedMap<JsonNode> {
    const out: KeyedMap<JsonNode> = new KeyedMap<JsonNode>();
    const node: JsonObject | undefined = JsonValue.asObject(parent.tryGet('AttachedObjects'));
    if (node === undefined) {
      return out;
    }
    // 键统一归一为小写 D 格式，与 Guid 字典键的写出规则一致
    for (const member of node.entries()) {
      const normalized: string | undefined = ModelCodec.normalizeGuidKey(member.name);
      if (normalized !== undefined) {
        out.set(normalized, member.value);
      }
    }
    return out;
  }

  static writeAttachedObjects(source: KeyedMap<JsonNode>): JsonObject {
    const out: JsonObject = new JsonObject();
    source.forEach((value: JsonNode, key: string) => {
      out.set(key, value);
    });
    return out;
  }

  // ---- Guid 键字典 ----------------------------------------------------

  /** 读取 Dictionary<Guid, V>。键归一为小写 D 格式。 */
  static readGuidMap<V>(parent: JsonObject, fieldName: string,
    readValue: (node: JsonNode) => V): KeyedMap<V> {
    const out: KeyedMap<V> = new KeyedMap<V>();
    const node: JsonObject | undefined = JsonValue.asObject(parent.tryGet(fieldName));
    if (node === undefined) {
      return out;
    }
    for (const member of node.entries()) {
      const normalized: string | undefined = ModelCodec.normalizeGuidKey(member.name);
      if (normalized !== undefined) {
        out.set(normalized, readValue(member.value));
      }
    }
    return out;
  }

  static writeGuidMap<V>(source: KeyedMap<V>,
    writeValue: (value: V) => JsonNode): JsonObject {
    const out: JsonObject = new JsonObject();
    source.forEach((value: V, key: string) => {
      out.set(key, writeValue(value));
    });
    return out;
  }

  /**
   * DateTime 键字典（OrderedSchedules）。
   *
   * 键在读入时即规范化：桌面版的键类型是 DateTime，查找一律用 `someDate.Date`
   * （即当天 00:00:00），所以手写的 "2026-9-8"、"2026-09-08T00:00:00.0000000"
   * 在桌面版都能命中，统一成规范 ISO 字面量后才能在本实现里同样命中。
   * 解析不了的键原样保留。
   */
  static readDateKeyMap<V>(parent: JsonObject, fieldName: string,
    readValue: (node: JsonNode) => V): KeyedMap<V> {
    const out: KeyedMap<V> = new KeyedMap<V>();
    const node: JsonObject | undefined = JsonValue.asObject(parent.tryGet(fieldName));
    if (node === undefined) {
      return out;
    }
    for (const member of node.entries()) {
      const parsed: DateTimeValue | undefined = DateTimeValue.tryParse(member.name);
      out.set(parsed === undefined ? member.name : parsed.toString(), readValue(member.value));
    }
    return out;
  }

  /**
   * DateTime 键字典写出。
   *
   * 桌面版此处是 Dictionary<DateTime, _>，System.Text.Json 会把键规范化成
   * ISO 字面量，所以手写的 "2026-9-8T00:00:00" 存盘后会变成
   * "2026-09-08T00:00:00"。这里对能解析的键做同样规范化。
   *
   * 解析不了的键原样写出：桌面版在反序列化阶段就会直接抛异常，而档案是
   * 纯数据，宁可保留原文也不要静默把它改写成 0001-01-01。
   */
  static writeDateKeyMap<V>(source: KeyedMap<V>,
    writeValue: (value: V) => JsonNode): JsonObject {
    const out: JsonObject = new JsonObject();
    source.forEach((value: V, key: string) => {
      const parsed: DateTimeValue | undefined = DateTimeValue.tryParse(key);
      out.set(parsed === undefined ? key : parsed.toString(), writeValue(value));
    });
    return out;
  }

  // ---- 标量 ----------------------------------------------------------

  static guidNode(value: Guid): JsonNode {
    return new JsonString(value.toString());
  }

  /** 可空 Guid：undefined 写 null。 */
  static nullableGuidNode(value: Guid | undefined): JsonNode {
    return value === undefined ? new JsonNull() : new JsonString(value.toString());
  }

  static dateTimeNode(value: DateTimeValue): JsonNode {
    return new JsonString(value.toString());
  }

  static readDateTime(parent: JsonObject, fieldName: string): DateTimeValue {
    const node: JsonNode | undefined = parent.tryGet(fieldName);
    if (node instanceof JsonString) {
      return DateTimeValue.parseOrMin(node.value);
    }
    return DateTimeValue.minValue();
  }

  static readNullableGuid(parent: JsonObject, fieldName: string): Guid | undefined {
    return JsonValue.asNullableGuid(parent.tryGet(fieldName));
  }

  static string(parent: JsonObject, fieldName: string, fallback: string): string {
    return JsonValue.asString(parent.tryGet(fieldName), fallback);
  }

  static bool(parent: JsonObject, fieldName: string, fallback: boolean): boolean {
    return JsonValue.asBoolean(parent.tryGet(fieldName), fallback);
  }

  static int(parent: JsonObject, fieldName: string, fallback: number): number {
    return JsonValue.asInt(parent.tryGet(fieldName), fallback);
  }

  /** 整数字段写出节点。统一走此处，避免各处直接构造 JsonNumber 时格式走样。 */
  static intNode(value: number): JsonNode {
    return JsonNumber.ofInt(value);
  }

  static guid(parent: JsonObject, fieldName: string): Guid {
    return JsonValue.asGuid(parent.tryGet(fieldName));
  }

  /**
   * 带默认值的 Guid 读取。
   * 字段缺失时桌面版会保留构造函数里的初始值（如 ClassPlan.AssociatedGroup
   * 默认 DefaultGroupGuid），因此回退值必须显式给出，不能一律退到 Guid.Empty。
   */
  static guidOr(parent: JsonObject, fieldName: string, fallback: Guid): Guid {
    const node: JsonNode | undefined = parent.tryGet(fieldName);
    if (node === undefined) {
      return fallback;
    }
    return JsonValue.asGuid(node);
  }

  // ---- 数组 ----------------------------------------------------------

  static readArray<V>(parent: JsonObject, fieldName: string, readValue: (node: JsonNode) => V): V[] {
    const out: V[] = [];
    const node: JsonArray | undefined = JsonValue.asArray(parent.tryGet(fieldName));
    if (node === undefined) {
      return out;
    }
    const items: JsonNode[] = node.values();
    for (let i: number = 0; i < items.length; i++) {
      out.push(readValue(items[i]));
    }
    return out;
  }

  static writeArray<V>(values: V[], writeValue: (value: V) => JsonNode): JsonArray {
    const out: JsonArray = new JsonArray();
    for (const value of values) {
      out.push(writeValue(value));
    }
    return out;
  }

  // ---- 内部 ----------------------------------------------------------

  /**
   * Guid 字典键归一。键允许写成 Guid 的 N/D/B/P 形式，
   * 输出统一为小写 D，与 Guid.ToString() 一致。
   */
  private static normalizeGuidKey(key: string): string | undefined {
    const parsed: Guid | undefined = Guid.tryParse(key);
    return parsed === undefined ? undefined : parsed.toString();
  }

  /** 把任意 JSON 节点深拷贝一份（供 AttachedObjects 隔离外部修改）。 */
  static cloneNode(node: JsonNode): JsonNode {
    if (node instanceof JsonObject) {
      const out: JsonObject = new JsonObject();
      for (const member of node.entries()) {
        out.set(member.name, ModelCodec.cloneNode(member.value));
      }
      return out;
    }
    if (node instanceof JsonArray) {
      const out: JsonArray = new JsonArray();
      const items: JsonNode[] = node.values();
      for (const item of items) {
        out.push(ModelCodec.cloneNode(item));
      }
      return out;
    }
    return node;
  }
}
