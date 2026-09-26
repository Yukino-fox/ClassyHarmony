/*
 * 模型深拷贝。对应 ClassIsland.Shared/Helpers/ConfigureFileHelper.DuplicateJson
 *
 * 桌面版的临时层课表、临时层时间表都是这样复制的：
 *
 *     var json = JsonSerializer.Serialize(o);
 *     return JsonSerializer.Deserialize<T>(json)!;
 *
 * 即「序列化 -> 反序列化」。之所以不用逐字段克隆，是因为模型上挂着
 * AttachedObjects（插件写入的任意 JSON），逐字段复制必然漏字段，
 * 一旦漏掉就是静默丢用户配置。这里照搬同一条路径，行为与桌面版一致。
 *
 * 代价是走了一次文本化。对临时层这种一次性、低频操作完全可接受。
 */

import { JsonNode, JsonObject } from '../json/JsonNode';
import { JsonReader } from '../json/JsonReader';
import { JsonValue } from '../json/JsonValue';
import { JsonWriter } from '../json/JsonWriter';

export class ModelCloner {
  /**
   * 经 JSON 往返深拷贝一个模型。
   *
   * toJson / fromJson 用调用方传入，避免在这里维护一张模型注册表——
   * 注册表在 ArkTS 里既无类型收益，又会和新模型脱节。
   */
  static duplicate<T>(source: T, toJson: (value: T) => JsonObject,
    fromJson: (node: JsonObject) => T): T {
    const text: string = JsonWriter.writeCompact(toJson(source));
    const node: JsonObject = ModelCloner.asObject(JsonReader.parse(text));
    return fromJson(node);
  }

  /**
   * toJson 的返回类型已是 JsonObject，走到这里只可能是有人把上面改坏了。
   * 抛错比静默造一个空对象更容易定位——后者会把错误推迟到几十行之后。
   */
  private static asObject(node: JsonNode): JsonObject {
    const asObj: JsonObject | undefined = JsonValue.asObject(node);
    if (asObj === undefined) {
      throw new Error('ModelCloner: 序列化结果不是 JSON 对象');
    }
    return asObj;
  }
}
