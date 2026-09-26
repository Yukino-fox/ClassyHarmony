/*
 * 学科。对应 ClassIsland.Shared/Models/Profile/Subject.cs
 *
 * 序列化顺序：Name, Initial, TeacherName, IsOutDoor, AttachedObjects, IsActive
 * （后两项分别来自基类 AttachableSettingsObject 与 ObservableRecipient）
 *
 * 两个必须照搬的怪癖：
 *
 * 1. Name 的 setter 会在 Initial 为空时用 Name 首字回填 Initial。
 *    桌面版是 C# 属性 setter，System.Text.Json 反序列化时先写 Name 再写
 *    Initial，所以「JSON 里没有 Initial」时落盘会出现自动回填出来的简称。
 *    这里用 get/set 访问器复刻，若改成裸字段就会在往返中丢掉这个简称。
 *
 * 2. Fallback / Empty / Breaking 三个静态科目是桌面版的可变单例。
 *    LessonsService 在课间休息时直接改写 Breaking.Name，会把状态泄漏到
 *    后续所有读取。按可重入约束（无跨实例可变单例），这里改为每次新建，
 *    观感一致但不留残留。
 */

import { JsonBoolean, JsonNode, JsonObject, JsonString } from '../json/JsonNode';
import { JsonValue } from '../json/JsonValue';
import { KeyedMap } from '../collections/KeyedMap';
import { ModelCodec } from './ModelCodec';

export class Subject {
  private nameValue: string = '';

  /** 简称，用于紧凑展示。为空时由 name 回填首字。 */
  initial: string = '';
  teacherName: string = '';
  isOutDoor: boolean = false;
  /** 插件附加数据，原样透传。 */
  attachedObjects: KeyedMap<JsonNode> = new KeyedMap<JsonNode>();
  isActive: boolean = false;

  constructor() {
  }

  get name(): string {
    return this.nameValue;
  }

  set name(value: string) {
    this.nameValue = value;
    if (this.initial.length === 0 && value.trim().length > 0) {
      this.initial = value.substring(0, 1);
    }
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Name', new JsonString(this.nameValue));
    out.set('Initial', new JsonString(this.initial));
    out.set('TeacherName', new JsonString(this.teacherName));
    out.set('IsOutDoor', new JsonBoolean(this.isOutDoor));
    out.set('AttachedObjects', ModelCodec.writeAttachedObjects(this.attachedObjects));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static fromJson(node: JsonObject): Subject {
    const out: Subject = new Subject();
    // 先写 name 以触发 Initial 回填，再用 JSON 里的 Initial 覆盖。
    // 桌面版 STJ 按 JSON 中的出现顺序赋属性，效果与此一致。
    out.name = ModelCodec.string(node, 'Name', '');
    if (node.tryGet('Initial') !== undefined) {
      out.initial = ModelCodec.string(node, 'Initial', '');
    }
    out.teacherName = ModelCodec.string(node, 'TeacherName', '');
    out.isOutDoor = ModelCodec.bool(node, 'IsOutDoor', false);
    out.attachedObjects = ModelCodec.readAttachedObjects(node);
    out.isActive = ModelCodec.bool(node, 'IsActive', false);
    return out;
  }

  /**
   * 任课老师的姓氏。未填教师名时返回空串。
   * 对应 Subject.GetFirstName()。
   */
  firstTeacherSurname(): string {
    if (this.teacherName.trim().length === 0) {
      return '';
    }
    const isChinese: boolean = Subject.containsChinese(this.teacherName);
    if (isChinese) {
      if (this.teacherName.length >= 2) {
        const pair: string = this.teacherName.substring(0, 2);
        if (Subject.COMPOUND_SURNAMES.indexOf(pair) >= 0) {
          return pair;
        }
      }
      return this.teacherName.substring(0, 1);
    }
    // 英文名取最后一个空格分段
    const parts: string[] = this.teacherName.split(' ').filter((part: string) => part.length > 0);
    return parts.length > 1 ? parts[parts.length - 1] : this.teacherName;
  }

  /** 无学科时的占位（对应桌面版 Subject.Fallback，简称 "?"）。 */
  static fallback(): Subject {
    const out: Subject = new Subject();
    out.initial = '?';
    out.nameValue = '???';
    return out;
  }

  /** 空白科目（对应桌面版 Subject.Empty）。 */
  static empty(): Subject {
    return new Subject();
  }

  /**
   * 课间休息占位（对应桌面版 Subject.Breaking）。
   * 桌面版每个进程只有一个实例并被就地改写 Name，这里每次新建以免状态外泄；
   * 简称恒为「休」——桌面版因为 Initial 非空，setter 不会覆盖它。
   */
  static breaking(displayName: string): Subject {
    const out: Subject = new Subject();
    out.initial = '休';
    out.nameValue = displayName;
    return out;
  }

  private static containsChinese(text: string): boolean {
    for (let i: number = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code >= 0x4E00 && code <= 0x9FA5) {
        return true;
      }
    }
    return false;
  }

  /** 复姓表。命中则整体作为姓氏。 */
  private static readonly COMPOUND_SURNAMES: string[] = [
    '万俟', '司马', '上官', '欧阳', '夏侯', '诸葛', '闻人', '东方', '赫连', '皇甫',
    '尉迟', '公羊', '澹台', '公冶', '宗政', '濮阳', '淳于', '单于', '太叔', '申屠',
    '公孙', '仲孙', '轩辕', '令狐', '钟离', '宇文', '长孙', '慕容', '鲜于', '闾丘',
    '司徒', '司空', '亓官', '司寇', '子车', '颛孙', '端木', '巫马', '公西', '漆雕',
    '乐正', '壤驷', '公良', '拓跋', '夹谷', '宰父', '谷梁', '段干', '百里', '东郭',
    '南门', '呼延', '羊舌', '微生', '梁丘', '左丘', '东门', '西门', '南宫', '第五'
  ];
}
