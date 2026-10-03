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
import { TIME_TYPE_CLASS, TimeLayoutItem } from './TimeLayoutItem';
import { t } from '../i18n/I18n';

export class TimeLayout {
  /** 是否为叠加时间表。 */
  isOverlay: boolean = false;

  /** 叠加来源；非叠加时为 null。 */
  overlaySourceId: Guid | undefined = undefined;

  name: string = t('sh_default_layout');

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
   * 课程时段（TimeType==0）列表。
   *
   * ClassPlan.Classes[i] 与 classTimePoints()[i] 一一对应，这个下标映射是
   * 课表引擎的地基：GetClassIndex、ValidTimeLayoutItems、OverwriteAllClassPlanSubject
   * 全部建立在它之上。
   */
  classTimePoints(): TimeLayoutItem[] {
    const out: TimeLayoutItem[] = [];
    for (const item of this.layouts) {
      if (item.timeType === TIME_TYPE_CLASS) {
        out.push(item);
      }
    }
    return out;
  }

  /**
   * 会显示在课表网格里的时间点（上课 / 课间 / 分割线），保持原顺序。
   *
   * 行动（TimeType==3）不在其中——它只在自动化与提醒链路里生效。
   */
  displayTimePoints(): TimeLayoutItem[] {
    const out: TimeLayoutItem[] = [];
    for (const item of this.layouts) {
      if (item.isDisplayable()) {
        out.push(item);
      }
    }
    return out;
  }

  /**
   * 课程时段下标表：长度与 layouts 相同，每项是该位置在
   * classTimePoints() 中的下标，非课程时段为 -1。
   *
   * 一次遍历同时得到 classTimePoints / displayTimePoints / classIndexOf
   * 所需的信息，避免在 50ms 一次的课表轮询里反复线性扫描。
   */
  classSlotIndexes(): number[] {
    const out: number[] = [];
    let slot: number = 0;
    for (const item of this.layouts) {
      if (item.timeType === TIME_TYPE_CLASS) {
        out.push(slot);
        slot++;
      } else {
        out.push(-1);
      }
    }
    return out;
  }

  /**
   * layouts 下标 -> 课程时段下标。越界或非课程时段返回 -1。
   * 对应 LessonsService.GetClassIndex。
   */
  classIndexOf(layoutIndex: number): number {
    if (layoutIndex < 0 || layoutIndex >= this.layouts.length) {
      return -1;
    }
    return this.classSlotIndexes()[layoutIndex];
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
    out.name = ModelCodec.string(node, 'Name', t('sh_default_layout'));
    out.layouts = ModelCodec.readArray(node, 'Layouts', (item: JsonNode) => {
      return TimeLayoutItem.fromJson(JsonValue.asObject(item) ?? new JsonObject());
    });
    out.attachedObjects = ModelCodec.readAttachedObjects(node);
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }
}
