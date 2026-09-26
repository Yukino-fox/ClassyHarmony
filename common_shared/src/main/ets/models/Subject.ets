/*
 * 学科。对应 ClassIsland.Shared/Models/Profile/Subject.cs
 *
 * 序列化顺序：Name, Initial, TeacherName, IsOutDoor, AttachedObjects, IsActive
 * （后两项分别来自基类 AttachableSettingsObject 与 ObservableRecipient）
 */

import { JsonBoolean, JsonNode, JsonObject, JsonString } from '../json/JsonNode';
import { JsonValue } from '../json/JsonValue';
import { KeyedMap } from '../collections/KeyedMap';
import { ModelCodec } from './ModelCodec';

export class Subject {
  name: string = '';
  /** 简称，用于紧凑展示。 */
  initial: string = '';
  teacherName: string = '';
  isOutDoor: boolean = false;
  /** 插件附加数据，原样透传。 */
  attachedObjects: KeyedMap<JsonNode> = new KeyedMap<JsonNode>();
  isActive: boolean = false;

  constructor() {
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Name', new JsonString(this.name));
    out.set('Initial', new JsonString(this.initial));
    out.set('TeacherName', new JsonString(this.teacherName));
    out.set('IsOutDoor', new JsonBoolean(this.isOutDoor));
    out.set('AttachedObjects', ModelCodec.writeAttachedObjects(this.attachedObjects));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): Subject {
    const out: Subject = new Subject();
    out.name = ModelCodec.string(node, 'Name', '');
    out.initial = ModelCodec.string(node, 'Initial', '');
    out.teacherName = ModelCodec.string(node, 'TeacherName', '');
    out.isOutDoor = ModelCodec.bool(node, 'IsOutDoor', false);
    out.attachedObjects = ModelCodec.readAttachedObjects(node);
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }

  /** 无学科时的占位（对应桌面版 Subject.Empty）。 */
  static empty(): Subject {
    return new Subject();
  }
}
