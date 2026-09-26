/*
 * 时间表。对应 ClassIsland.Shared/Models/Profile/TimeLayout.cs
 *
 * 序列化顺序：IsOverlay, OverlaySourceId, Name, Layouts, AttachedObjects, IsActive
 *
 * 重要：IsActivated 与 IsActivatedManually 都是 [JsonIgnore]——「哪张时间表当前生效」
 * 不落盘，而是每次启动由 Profile 的激活规则重新推导。桌面版如此，本实现照搬，
 * 切勿把它们写进 JSON（写进去桌面版会忽略，且会污染手写配置）。
 */

import { Guid } from '../json/Guid';
import { JsonBoolean, JsonNode, JsonNull, JsonObject, JsonString } from '../json/JsonNode';
import { JsonValue } from '../json/JsonValue';
import { KeyedMap } from '../collections/KeyedMap';
import { ModelCodec } from './ModelCodec';
import { TIME_TYPE_BREAK, TimeLayoutItem } from './TimeLayoutItem';

export class TimeLayout {
  /** 是否为叠加时间表。 */
  isOverlay: boolean = false;

  /** 叠加来源；非叠加时为 null。 */
  overlaySourceId: Guid | undefined = undefined;

  name: string = '新时间表';

  /** 时间点列表。 */
  layouts: TimeLayoutItem[] = [];

  attachedObjects: KeyedMap<JsonNode> = new KeyedMap<JsonNode>();

  isActive: boolean = false;

  // ---- 运行期状态，不落盘 ----

  /** 当前是否生效。启动时由 Profile 重新推导。 */
  isActivated: boolean = false;

  /** 生效状态是否被用户手动指定。 */
  isActivatedManually: boolean = false;

  constructor() {
  }

  /**
   * 课间时间点被过滤后的列表，即所有 TimeType != 0 的时间点。
   * 课程与时间点的对应靠下标，ClassInfo.CurrentTimeLayoutItem 依赖它。
   */
  validLayouts(): TimeLayoutItem[] {
    const out: TimeLayoutItem[] = [];
    for (const item of this.layouts) {
      if (item.timeType !== TIME_TYPE_BREAK) {
        out.push(item);
      }
    }
    return out;
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('IsOverlay', new JsonBoolean(this.isOverlay));
    if (this.overlaySourceId === undefined) {
      out.set('OverlaySourceId', new JsonNull());
    } else {
      out.set('OverlaySourceId', new JsonString(this.overlaySourceId.toString()));
    }
    out.set('Name', new JsonString(this.name));
    out.set('Layouts', ModelCodec.writeArray(this.layouts, (item: TimeLayoutItem) => item.toJson()));
    out.set('AttachedObjects', ModelCodec.writeAttachedObjects(this.attachedObjects));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): TimeLayout {
    const out: TimeLayout = new TimeLayout();
    out.isOverlay = ModelCodec.bool(node, 'IsOverlay', false);
    out.overlaySourceId = ModelCodec.readNullableGuid(node, 'OverlaySourceId');
    out.name = ModelCodec.string(node, 'Name', '新时间表');
    out.layouts = ModelCodec.readArray(node, 'Layouts', (item: JsonNode) => {
      return TimeLayoutItem.fromJson(JsonValue.asObject(item) ?? new JsonObject());
    });
    out.attachedObjects = ModelCodec.readAttachedObjects(node);
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }
}
