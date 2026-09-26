/*
 * 课表。对应 ClassIsland.Shared/Models/Profile/ClassPlan.cs
 *
 * 序列化顺序：
 *   TimeLayoutId, TimeRule, Classes, Name, IsOverlay, OverlaySourceId,
 *   OverlaySetupTime, IsEnabled, AssociatedGroup, AttachedObjects, IsActive
 *
 * 被 [JsonIgnore] 排除：ValidTimeLayoutItems、TimeLayout、IsActivated；
 * TimeLayouts / ClassPlans 是 internal 反向引用，同样不落盘。
 *
 * 默认值两处易错：
 * - Name 默认 "新课表"（不是空串）
 * - AssociatedGroup 默认 ClassPlanGroup.DefaultGroupGuid（不是 Guid.Empty）
 * - OverlaySetupTime 默认 DateTime.Now（不是 MinValue）
 */

import { DateTimeValue } from '../json/DateTimeValue';
import { Guid } from '../json/Guid';
import { JsonBoolean, JsonNode, JsonNull, JsonObject, JsonString } from '../json/JsonNode';
import { JsonValue } from '../json/JsonValue';
import { KeyedMap } from '../collections/KeyedMap';
import { ModelCodec } from './ModelCodec';
import { ClassInfo } from './ClassInfo';
import { ClassPlanGroup } from './ClassPlanGroup';
import { TimeLayout } from './TimeLayout';
import { TimeLayoutItem } from './TimeLayoutItem';
import { TimeRule } from './TimeRule';

export class ClassPlan {
  timeLayoutId: Guid = Guid.empty();

  /** 时间规则（星期几 / 单双周）。 */
  timeRule: TimeRule = new TimeRule();

  classes: ClassInfo[] = [];

  name: string = '新课表';

  isOverlay: boolean = false;

  /** 叠加来源课表。 */
  overlaySourceId: Guid | undefined = undefined;

  /** 叠加方案的建立时间。 */
  overlaySetupTime: DateTimeValue = DateTimeValue.now();

  isEnabled: boolean = true;

  /** 所属课表组。 */
  associatedGroup: Guid = ClassPlanGroup.defaultGroupGuid();

  attachedObjects: KeyedMap<JsonNode> = new KeyedMap<JsonNode>();

  isActive: boolean = false;

  // ---- 运行期状态，不落盘 ----

  /** 当前是否生效。 */
  isActivated: boolean = false;

  /**
   * 关联的时间表。由 Profile 在反序列化后回填（对应 C# 的 internal TimeLayouts
   * 反向引用 + TimeLayout 计算属性），不落盘。
   */
  private timeLayout: TimeLayout | undefined = undefined;

  /** 上次计算时的时间点数量，用于失效重算判断。 */
  lastTimeLayoutCount: number = -1;

  constructor() {
  }

  /** 绑定所属时间表。由 Profile 在装载后调用。 */
  bindTimeLayout(layout: TimeLayout | undefined): void {
    this.timeLayout = layout;
  }

  /** 取所属时间表。 */
  resolveTimeLayout(): TimeLayout | undefined {
    return this.timeLayout;
  }

  /**
   * 课间时间点被过滤后的列表（对应 C# ValidTimeLayoutItems）。
   * 课程 Classes[i] 对应 validLayouts()[i]。
   */
  validTimeLayoutItems(): TimeLayoutItem[] {
    if (this.timeLayout === undefined) {
      return [];
    }
    return this.timeLayout.validLayouts();
  }

  /** 取第 index 节课对应的时间点；越界返回 TimeLayoutItem.empty()。 */
  currentTimeLayoutItem(index: number): TimeLayoutItem {
    const valid: TimeLayoutItem[] = this.validTimeLayoutItems();
    if (index < 0 || index >= valid.length) {
      return TimeLayoutItem.empty();
    }
    return valid[index];
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('TimeLayoutId', ModelCodec.guidNode(this.timeLayoutId));
    out.set('TimeRule', this.timeRule.toJson());
    out.set('Classes', ModelCodec.writeArray(this.classes, (item: ClassInfo) => item.toJson()));
    out.set('Name', new JsonString(this.name));
    out.set('IsOverlay', new JsonBoolean(this.isOverlay));
    if (this.overlaySourceId === undefined) {
      out.set('OverlaySourceId', new JsonNull());
    } else {
      out.set('OverlaySourceId', new JsonString(this.overlaySourceId.toString()));
    }
    out.set('OverlaySetupTime', ModelCodec.dateTimeNode(this.overlaySetupTime));
    out.set('IsEnabled', new JsonBoolean(this.isEnabled));
    out.set('AssociatedGroup', ModelCodec.guidNode(this.associatedGroup));
    out.set('AttachedObjects', ModelCodec.writeAttachedObjects(this.attachedObjects));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): ClassPlan {
    const out: ClassPlan = new ClassPlan();
    out.timeLayoutId = ModelCodec.guid(node, 'TimeLayoutId');
    out.timeRule = TimeRule.fromJson(JsonValue.asObject(node.tryGet('TimeRule')) ?? new JsonObject());
    out.classes = ModelCodec.readArray(node, 'Classes', (item: JsonNode) => {
      return ClassInfo.fromJson(JsonValue.asObject(item) ?? new JsonObject());
    });
    out.name = ModelCodec.string(node, 'Name', '新课表');
    out.isOverlay = ModelCodec.bool(node, 'IsOverlay', false);
    out.overlaySourceId = ModelCodec.readNullableGuid(node, 'OverlaySourceId');
    out.overlaySetupTime = ModelCodec.readDateTime(node, 'OverlaySetupTime');
    out.isEnabled = ModelCodec.bool(node, 'IsEnabled', true);
    out.associatedGroup = ModelCodec.guidOr(node, 'AssociatedGroup', ClassPlanGroup.defaultGroupGuid());
    out.attachedObjects = ModelCodec.readAttachedObjects(node);
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }
}
