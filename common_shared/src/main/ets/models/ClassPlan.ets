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
import { t } from '../i18n/I18n';

export class ClassPlan {
  timeLayoutId: Guid = Guid.empty();

  /** 时间规则（星期几 / 单双周）。 */
  timeRule: TimeRule = new TimeRule();

  classes: ClassInfo[] = [];

  name: string = t('sh_default_plan');

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
   * 需要显示的时间点（对应 C# ValidTimeLayoutItems）。
   *
   * 算法照搬桌面版的双遍扫描，语义是「课程被停用时，连带它前后的
   * 课间与分割线一起消失」：
   * - 正向扫：非课程时间点继承它**前面**最近一个课程时间点的启用状态
   * - 反向扫：非课程时间点继承它**后面**最近一个课程时间点的启用状态
   * 任一遍判定为停用即移除。
   *
   * 两遍的初始状态都是「启用」，所以排在所有课程之前/之后的课间与分割线
   * 不会被误删——这与桌面版一致。
   *
   * 与 classTimePoints() 是两个不同的列表：前者含课间/分割线且已按启用状态
   * 过滤，后者只有课程时段且不过滤。Classes[i] 始终对应 classTimePoints()[i]，
   * 不是本列表。
   */
  validTimeLayoutItems(): TimeLayoutItem[] {
    const layout: TimeLayout | undefined = this.timeLayout;
    if (layout === undefined) {
      return [];
    }
    const slots: number[] = layout.classSlotIndexes();
    const display: TimeLayoutItem[] = [];
    const displaySlot: number[] = [];
    for (let i: number = 0; i < layout.layouts.length; i++) {
      const item: TimeLayoutItem = layout.layouts[i];
      if (item.isDisplayable()) {
        display.push(item);
        displaySlot.push(slots[i]);
      }
    }

    const keep: boolean[] = [];
    for (let i: number = 0; i < display.length; i++) {
      keep.push(true);
    }
    const classCount: number = this.classes.length;
    const enabledAt = (slot: number): boolean => {
      if (slot < 0 || slot >= classCount) {
        return false;
      }
      return this.classes[slot].isEnabled;
    };

    let carried: boolean = true;
    for (let i: number = 0; i < display.length; i++) {
      const slot: number = displaySlot[i];
      if (slot >= 0) {
        carried = enabledAt(slot);
      }
      if (!carried) {
        keep[i] = false;
      }
    }
    carried = true;
    for (let i: number = display.length - 1; i >= 0; i--) {
      const slot: number = displaySlot[i];
      if (slot >= 0) {
        carried = enabledAt(slot);
      }
      if (!carried) {
        keep[i] = false;
      }
    }

    const out: TimeLayoutItem[] = [];
    for (let i: number = 0; i < display.length; i++) {
      if (keep[i]) {
        out.push(display[i]);
      }
    }
    return out;
  }

  /**
   * 第 index 节课对应的时间点；越界返回 TimeLayoutItem.empty()。
   * 对应 ClassInfo.CurrentTimeLayoutItem。
   */
  currentTimeLayoutItem(index: number): TimeLayoutItem {
    const layout: TimeLayout | undefined = this.timeLayout;
    if (layout === undefined) {
      return TimeLayoutItem.empty();
    }
    const points: TimeLayoutItem[] = layout.classTimePoints();
    if (index < 0 || index >= points.length) {
      return TimeLayoutItem.empty();
    }
    return points[index];
  }

  /**
   * layouts 下标 -> 课程时段下标；越界或非课程时段返回 -1。
   * 对应 LessonsService.GetClassIndex / TimeLayout.GetClassIndex。
   */
  getClassIndex(layoutIndex: number): number {
    const layout: TimeLayout | undefined = this.timeLayout;
    if (layout === undefined) {
      return -1;
    }
    return layout.classIndexOf(layoutIndex);
  }

  /**
   * 使 Classes 的长度与课程时段数对齐，并回填下标与默认科目。
   * 对应 ClassPlan.RefreshClassesList。
   *
   * 桌面版靠一串 PropertyChanged 事件维持此不变量，ArkTS 侧改为显式调用——
   * 纯函数式推导比维持事件订阅更不容易失配，也更符合「无跨实例可变单例」
   * 的可重入约束。调用时机：档案装载后、时间点增删改后。
   */
  refreshClassesList(): void {
    const layout: TimeLayout | undefined = this.timeLayout;
    if (layout === undefined) {
      return;
    }
    const points: TimeLayoutItem[] = layout.classTimePoints();
    while (this.classes.length < points.length) {
      this.classes.push(new ClassInfo());
    }
    while (this.classes.length > points.length) {
      this.classes.pop();
    }
    for (let i: number = 0; i < this.classes.length; i++) {
      const info: ClassInfo = this.classes[i];
      info.index = i;
      const fallback: Guid = points[i].defaultClassId;
      if (info.subjectId.isEmpty() && !fallback.isEmpty()) {
        info.subjectId = fallback;
      }
    }
    this.lastTimeLayoutCount = layout.layouts.length;
  }

  /**
   * 标记与叠加来源课表不同的课程（换课标记）。
   * 对应 ClassPlan.RefreshIsChangedClass，source 由调用方从档案中解析。
   */
  refreshIsChangedClass(source: ClassPlan | undefined): void {
    if (source === undefined || this.classes.length !== source.classes.length) {
      for (const info of this.classes) {
        info.isChangedClass = false;
      }
      return;
    }
    for (let i: number = 0; i < this.classes.length; i++) {
      const info: ClassInfo = this.classes[i];
      if (i >= source.classes.length) {
        info.isChangedClass = false;
      } else {
        info.isChangedClass = !info.subjectId.equals(source.classes[i].subjectId);
      }
    }
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
    out.name = ModelCodec.string(node, 'Name', t('sh_default_plan'));
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
