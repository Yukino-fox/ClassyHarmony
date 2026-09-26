/*
 * 课表中的一节课。对应 ClassIsland.Shared/Models/Profile/ClassInfo.cs
 *
 * 序列化顺序：SubjectId, IsChangedClass, IsEnabled, AttachedObjects, IsActive
 *
 * 被 [JsonIgnore] 排除：Index、CurrentTimeLayout、CurrentTimeLayoutItem、IsEmpty。
 * 前两者是运行期由父课表回填的引用，不落盘；Index 由数组下标隐含。
 */

import { Guid } from '../json/Guid';
import { JsonBoolean, JsonNode, JsonObject } from '../json/JsonNode';
import { KeyedMap } from '../collections/KeyedMap';
import { ModelCodec } from './ModelCodec';

export class ClassInfo {
  /** 学科 ID。 */
  subjectId: Guid = Guid.empty();

  /** 是否为临时换课课程。 */
  isChangedClass: boolean = false;

  isEnabled: boolean = true;

  attachedObjects: KeyedMap<JsonNode> = new KeyedMap<JsonNode>();

  isActive: boolean = false;

  /** 运行期字段，不落盘：课程在课表 Classes 数组中的下标。 */
  index: number = 0;

  constructor() {
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('SubjectId', ModelCodec.guidNode(this.subjectId));
    out.set('IsChangedClass', new JsonBoolean(this.isChangedClass));
    out.set('IsEnabled', new JsonBoolean(this.isEnabled));
    out.set('AttachedObjects', ModelCodec.writeAttachedObjects(this.attachedObjects));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): ClassInfo {
    const out: ClassInfo = new ClassInfo();
    out.subjectId = ModelCodec.guid(node, 'SubjectId');
    out.isChangedClass = ModelCodec.bool(node, 'IsChangedClass', false);
    out.isEnabled = ModelCodec.bool(node, 'IsEnabled', true);
    out.attachedObjects = ModelCodec.readAttachedObjects(node);
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }

  /** 是否为空课（无学科）。运行期判定，不落盘。 */
  isEmpty(): boolean {
    return this.subjectId.isEmpty();
  }
}
