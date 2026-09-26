/*
 * 档案（课表数据的根）。对应 ClassIsland.Shared/Models/Profile/Profile.cs
 *
 * 序列化顺序：
 *   Name, TimeLayouts, ClassPlans, Subjects, IsOverlayClassPlanEnabled,
 *   OverlayClassPlanId, TempClassPlanId, TempClassPlanSetupTime,
 *   ClassPlanGroups, SelectedClassPlanGroupId, TempClassPlanGroupId,
 *   TempClassPlanGroupExpireTime, IsTempClassPlanGroupEnabled,
 *   TempClassPlanGroupType, Id, OrderedSchedules, IsActive
 *
 * 键的类型：
 * - TimeLayouts / ClassPlans / Subjects / ClassPlanGroups 为 Guid 键，序列化为
 *   「Guid 小写 D 格式 -> 值」的对象。
 * - OrderedSchedules 为 DateTime 键，序列化为「ISO 8601 字符串 -> 值」的对象，
 *   且查找依赖字符串精确匹配，故键文本按原样保留。
 *
 * 被 [JsonIgnore] 排除：EditingSubjects（编辑态副本）、HasOverlayClassPlan（派生值）。
 *
 * 反序列化后必须调用 bindReferences() 回填 ClassPlan -> TimeLayout 的运行期引用，
 * 对应桌面版 Profile.RefreshTimeLayouts()。
 */

import { TempClassPlanGroupType } from '../enums/TempClassPlanGroupType';
import { DateTimeValue } from '../json/DateTimeValue';
import { Guid } from '../json/Guid';
import { JsonBoolean, JsonNode, JsonObject, JsonString } from '../json/JsonNode';
import { JsonReader } from '../json/JsonReader';
import { JsonValue } from '../json/JsonValue';
import { JsonWriter } from '../json/JsonWriter';
import { KeyedMap } from '../collections/KeyedMap';
import { ModelCodec } from './ModelCodec';
import { ClassPlan } from './ClassPlan';
import { ClassPlanGroup } from './ClassPlanGroup';
import { OrderedSchedule } from './OrderedSchedule';
import { Subject } from './Subject';
import { TimeLayout } from './TimeLayout';

export class Profile {
  name: string = '';

  timeLayouts: KeyedMap<TimeLayout> = new KeyedMap<TimeLayout>();
  classPlans: KeyedMap<ClassPlan> = new KeyedMap<ClassPlan>();
  subjects: KeyedMap<Subject> = new KeyedMap<Subject>();

  isOverlayClassPlanEnabled: boolean = false;
  /** 叠加班表模式下当前使用的课表。 */
  overlayClassPlanId: Guid | undefined = undefined;

  /** 临时课表（调课 / 考试）。 */
  tempClassPlanId: Guid | undefined = undefined;
  tempClassPlanSetupTime: DateTimeValue = DateTimeValue.now();

  classPlanGroups: KeyedMap<ClassPlanGroup> = new KeyedMap<ClassPlanGroup>();
  selectedClassPlanGroupId: Guid = ClassPlanGroup.defaultGroupGuid();

  tempClassPlanGroupId: Guid | undefined = undefined;
  tempClassPlanGroupExpireTime: DateTimeValue = DateTimeValue.now();
  isTempClassPlanGroupEnabled: boolean = false;
  tempClassPlanGroupType: number = TempClassPlanGroupType.Inherit;

  id: Guid = Guid.newGuid();

  /** 指定日期的课表安排，键为 DateTime 的 ISO 字面量。 */
  orderedSchedules: KeyedMap<OrderedSchedule> = new KeyedMap<OrderedSchedule>();

  isActive: boolean = false;

  // ---- 运行期状态，不落盘 ----

  /** 编辑态学科副本（对应 [JsonIgnore] EditingSubjects）。 */
  editingSubjects: Subject[] = [];

  constructor() {
  }

  /** 是否处于叠加班表模式（对应只读属性 HasOverlayClassPlan）。 */
  hasOverlayClassPlan(): boolean {
    return this.isOverlayClassPlanEnabled;
  }

  /**
   * 回填 ClassPlan -> TimeLayout 运行期引用，并重置各课表的失效标记。
   * 对应桌面版 Profile.RefreshTimeLayouts()，反序列化后必须调用。
   */
  bindReferences(): void {
    this.classPlans.forEach((plan: ClassPlan) => {
      plan.bindTimeLayout(this.timeLayouts.tryGet(plan.timeLayoutId.toString()));
      plan.lastTimeLayoutCount = -1;
    });
    // 课表内课程下标是运行期派生值，按数组顺序回填
    this.classPlans.forEach((plan: ClassPlan) => {
      for (let i: number = 0; i < plan.classes.length; i++) {
        plan.classes[i].index = i;
      }
    });
  }

  // ---- 便捷查询 ----

  tryGetClassPlan(guid: Guid): ClassPlan | undefined {
    return this.classPlans.tryGet(guid.toString());
  }

  tryGetSubject(guid: Guid): Subject | undefined {
    return this.subjects.tryGet(guid.toString());
  }

  tryGetTimeLayout(guid: Guid): TimeLayout | undefined {
    return this.timeLayouts.tryGet(guid.toString());
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Name', new JsonString(this.name));
    out.set('TimeLayouts', ModelCodec.writeGuidMap(this.timeLayouts, (v: TimeLayout) => v.toJson()));
    out.set('ClassPlans', ModelCodec.writeGuidMap(this.classPlans, (v: ClassPlan) => v.toJson()));
    out.set('Subjects', ModelCodec.writeGuidMap(this.subjects, (v: Subject) => v.toJson()));
    out.set('IsOverlayClassPlanEnabled', new JsonBoolean(this.isOverlayClassPlanEnabled));
    out.set('OverlayClassPlanId', ModelCodec.nullableGuidNode(this.overlayClassPlanId));
    out.set('TempClassPlanId', ModelCodec.nullableGuidNode(this.tempClassPlanId));
    out.set('TempClassPlanSetupTime', ModelCodec.dateTimeNode(this.tempClassPlanSetupTime));
    out.set('ClassPlanGroups', ModelCodec.writeGuidMap(this.classPlanGroups, (v: ClassPlanGroup) => v.toJson()));
    out.set('SelectedClassPlanGroupId', ModelCodec.guidNode(this.selectedClassPlanGroupId));
    out.set('TempClassPlanGroupId', ModelCodec.nullableGuidNode(this.tempClassPlanGroupId));
    out.set('TempClassPlanGroupExpireTime', ModelCodec.dateTimeNode(this.tempClassPlanGroupExpireTime));
    out.set('IsTempClassPlanGroupEnabled', new JsonBoolean(this.isTempClassPlanGroupEnabled));
    out.set('TempClassPlanGroupType', ModelCodec.intNode(this.tempClassPlanGroupType));
    out.set('Id', ModelCodec.guidNode(this.id));
    out.set('OrderedSchedules', ModelCodec.writeGuidMap(this.orderedSchedules, (v: OrderedSchedule) => v.toJson()));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): Profile {
    const out: Profile = new Profile();
    out.name = ModelCodec.string(node, 'Name', '');
    out.timeLayouts = ModelCodec.readGuidMap(node, 'TimeLayouts', (item: JsonNode) => {
      return TimeLayout.fromJson(JsonValue.asObject(item) ?? new JsonObject());
    });
    out.classPlans = ModelCodec.readGuidMap(node, 'ClassPlans', (item: JsonNode) => {
      return ClassPlan.fromJson(JsonValue.asObject(item) ?? new JsonObject());
    });
    out.subjects = ModelCodec.readGuidMap(node, 'Subjects', (item: JsonNode) => {
      return Subject.fromJson(JsonValue.asObject(item) ?? new JsonObject());
    });
    out.isOverlayClassPlanEnabled = ModelCodec.bool(node, 'IsOverlayClassPlanEnabled', false);
    out.overlayClassPlanId = ModelCodec.readNullableGuid(node, 'OverlayClassPlanId');
    out.tempClassPlanId = ModelCodec.readNullableGuid(node, 'TempClassPlanId');
    out.tempClassPlanSetupTime = ModelCodec.readDateTime(node, 'TempClassPlanSetupTime');
    out.classPlanGroups = ModelCodec.readGuidMap(node, 'ClassPlanGroups', (item: JsonNode) => {
      return ClassPlanGroup.fromJson(JsonValue.asObject(item) ?? new JsonObject());
    });
    out.selectedClassPlanGroupId = ModelCodec.guidOr(node, 'SelectedClassPlanGroupId',
      ClassPlanGroup.defaultGroupGuid());
    out.tempClassPlanGroupId = ModelCodec.readNullableGuid(node, 'TempClassPlanGroupId');
    out.tempClassPlanGroupExpireTime = ModelCodec.readDateTime(node, 'TempClassPlanGroupExpireTime');
    out.isTempClassPlanGroupEnabled = ModelCodec.bool(node, 'IsTempClassPlanGroupEnabled', false);
    out.tempClassPlanGroupType = ModelCodec.int(node, 'TempClassPlanGroupType', TempClassPlanGroupType.Inherit);
    out.id = ModelCodec.guid(node, 'Id');
    out.orderedSchedules = ModelCodec.readDateKeyMap(node, 'OrderedSchedules', (item: JsonNode) => {
      return OrderedSchedule.fromJson(JsonValue.asObject(item) ?? new JsonObject());
    });
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    out.bindReferences();
    return out;
  }

  /**
   * 从 JSON 文本装载。
   * @throws 根值不是对象时抛出，交由调用方决定是回退到默认档案还是提示用户。
   */
  static parse(text: string): Profile {
    const node: JsonNode = JsonReader.parse(text);
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      throw new Error('档案 JSON 根值不是对象');
    }
    return Profile.fromJson(obj);
  }

  /** 序列化为 JSON 文本。indentSize=0 为压缩输出，对齐桌面版 SaveConfig 默认。 */
  static stringify(profile: Profile, indentSize: number = 0): string {
    return JsonWriter.write(profile.toJson(), indentSize);
  }
}
