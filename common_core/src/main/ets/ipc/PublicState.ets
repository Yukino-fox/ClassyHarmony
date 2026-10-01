/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 跨设备共享的公开状态。
 *
 * 这是桌面版 `IPublicLessonsService` / `IPublicProfileService` 在鸿蒙上的
 * 可序列化子集。桌面版把整个 `ClassPlan` / `Profile` 对象图直接经 Protobuf
 * 管道丢给别的进程，本端刻意**不**那么做：
 *
 *   1. 分布式数据对象同步的是「属性」，逐条推全量对象图既慢又难收敛；
 *   2. 公开出去的东西越少越安全 —— 对方要的通常只是「现在上什么课、还有多久
 *      下课」，不是老师名、不是附件数据；
 *   3. 扁平字段（全是 string/number/boolean）在 ArkTS 与 DDO 两边都好传，
 *      嵌套对象在分布式数据对象里是深拷贝语义，改一个叶子会推整棵树。
 *
 * 字段一律 camelCase（与天气模型同一个约定）：这是我们自己定义的线上格式，
 * 不跟桌面版 settings.json 的 PascalCase 混。
 *
 * 编解码走项目自研的 JSON 内核，不引入第三方序列化，保证与本地存储同一套
 * 行为（尤其是数字的原始字面量保留）。
 */

import {
  JsonBoolean,
  JsonNode,
  JsonObject,
  JsonReader,
  JsonString,
  JsonValue,
  JsonWriter,
  ModelCodec,
  Profile
} from 'common_shared';
import { DateTimeValue } from 'common_shared';
import { TimeState } from 'common_shared';
import { LessonsSnapshot } from '../engine/LessonsSnapshot';
import { PublicNotifyIds } from './PublicProtocol';

/** 生成公开状态时携带的身份信息（core 不认识设备，由入口侧注入）。 */
export class PublicStateSource {
  /** 设备显示名，例如「HUAWEI Mate 60」。 */
  deviceName: string = '';
  /** 当前档案名。 */
  profileName: string = '';
}

/**
 * 公开的当前课表状态。
 *
 * 与 `LessonsSnapshot` 的差别：snapshot 是给规则求值用的完整快照（带科目
 * 引用、时间表对象、上一节课等），这里只保留「另一台设备要显示在屏幕上」的
 * 那几项，并且把对象都降成字符串 / 数字。
 */
export class PublicLessonState {
  deviceName: string = '';
  profileName: string = '';
  classPlanName: string = '';

  isClassPlanEnabled: boolean = false;
  isClassPlanLoaded: boolean = false;
  isLessonConfirmed: boolean = false;

  /** TimeState 数值：0 None / 1 OnClass / 2 PrepareOnClass / 3 Breaking / 4 AfterSchool。 */
  currentState: number = 0;

  currentSubjectName: string = '';
  nextClassSubjectName: string = '';

  /** 当前时间点起止，`HH:MM:SS`；无时间点时为 `00:00:00`。 */
  currentTimeLayoutStart: string = '';
  currentTimeLayoutEnd: string = '';

  /** 距上课 / 距下课剩余秒数。语义与桌面版 `IPublicLessonsService` 一致。 */
  onClassLeftSeconds: number = 0;
  onBreakingTimeLeftSeconds: number = 0;

  /**
   * 本份快照对应的状态迁移事件，取 `PublicNotifyIds` 里的值；没有迁移时空串。
   *
   * 单独带一个事件字段而不是让接收方比对上一份快照：接收方可能刚加入会话、
   * 根本没有「上一份」，靠比对永远收不到事件。
   */
  lastEvent: string = '';

  /** 生成时刻（Unix 毫秒）。接收方用它判新鲜度。 */
  updatedAt: number = 0;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('deviceName', new JsonString(this.deviceName));
    out.set('profileName', new JsonString(this.profileName));
    out.set('classPlanName', new JsonString(this.classPlanName));
    out.set('isClassPlanEnabled', new JsonBoolean(this.isClassPlanEnabled));
    out.set('isClassPlanLoaded', new JsonBoolean(this.isClassPlanLoaded));
    out.set('isLessonConfirmed', new JsonBoolean(this.isLessonConfirmed));
    out.set('currentState', ModelCodec.intNode(this.currentState));
    out.set('currentSubjectName', new JsonString(this.currentSubjectName));
    out.set('nextClassSubjectName', new JsonString(this.nextClassSubjectName));
    out.set('currentTimeLayoutStart', new JsonString(this.currentTimeLayoutStart));
    out.set('currentTimeLayoutEnd', new JsonString(this.currentTimeLayoutEnd));
    out.set('onClassLeftSeconds', ModelCodec.intNode(this.onClassLeftSeconds));
    out.set('onBreakingTimeLeftSeconds', ModelCodec.intNode(this.onBreakingTimeLeftSeconds));
    out.set('lastEvent', new JsonString(this.lastEvent));
    out.set('updatedAt', ModelCodec.doubleNode(this.updatedAt));
    return out;
  }

  static parse(node: JsonNode): PublicLessonState {
    const out: PublicLessonState = new PublicLessonState();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.deviceName = ModelCodec.string(obj, 'deviceName', '');
    out.profileName = ModelCodec.string(obj, 'profileName', '');
    out.classPlanName = ModelCodec.string(obj, 'classPlanName', '');
    out.isClassPlanEnabled = ModelCodec.bool(obj, 'isClassPlanEnabled', false);
    out.isClassPlanLoaded = ModelCodec.bool(obj, 'isClassPlanLoaded', false);
    out.isLessonConfirmed = ModelCodec.bool(obj, 'isLessonConfirmed', false);
    out.currentState = ModelCodec.int(obj, 'currentState', 0);
    out.currentSubjectName = ModelCodec.string(obj, 'currentSubjectName', '');
    out.nextClassSubjectName = ModelCodec.string(obj, 'nextClassSubjectName', '');
    out.currentTimeLayoutStart = ModelCodec.string(obj, 'currentTimeLayoutStart', '');
    out.currentTimeLayoutEnd = ModelCodec.string(obj, 'currentTimeLayoutEnd', '');
    out.onClassLeftSeconds = ModelCodec.int(obj, 'onClassLeftSeconds', 0);
    out.onBreakingTimeLeftSeconds = ModelCodec.int(obj, 'onBreakingTimeLeftSeconds', 0);
    out.lastEvent = ModelCodec.string(obj, 'lastEvent', '');
    out.updatedAt = ModelCodec.number(obj, 'updatedAt', 0);
    return out;
  }

  /**
   * 内容键：忽略 `updatedAt` 与 `lastEvent`，只比较「画在屏幕上会不一样」的
   * 部分。发布节流用它判断「这一秒有没有必要再推一次」。
   */
  contentKey(): string {
    return `${this.currentState}|${this.currentSubjectName}|${this.nextClassSubjectName}`
      + `|${this.currentTimeLayoutStart}|${this.currentTimeLayoutEnd}`
      + `|${this.onClassLeftSeconds}|${this.onBreakingTimeLeftSeconds}`
      + `|${this.classPlanName}|${this.isClassPlanLoaded ? 1 : 0}`;
  }
}

/**
 * 公开的档案摘要。
 *
 * 只给计数与课表名列表，不给课表内容 —— 摘要的用途是「另一台设备列出这台
 * 设备上有什么课表」，需要内容时再单独取（那是后续能力，当前不做）。
 */
export class PublicProfileBrief {
  deviceName: string = '';
  profileName: string = '';
  classPlanCount: number = 0;
  subjectCount: number = 0;
  timeLayoutCount: number = 0;
  classPlanNames: string[] = [];
  updatedAt: number = 0;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('deviceName', new JsonString(this.deviceName));
    out.set('profileName', new JsonString(this.profileName));
    out.set('classPlanCount', ModelCodec.intNode(this.classPlanCount));
    out.set('subjectCount', ModelCodec.intNode(this.subjectCount));
    out.set('timeLayoutCount', ModelCodec.intNode(this.timeLayoutCount));
    out.set('classPlanNames',
      ModelCodec.writeArray(this.classPlanNames, (value: string) => new JsonString(value)));
    out.set('updatedAt', ModelCodec.doubleNode(this.updatedAt));
    return out;
  }

  static parse(node: JsonNode): PublicProfileBrief {
    const out: PublicProfileBrief = new PublicProfileBrief();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.deviceName = ModelCodec.string(obj, 'deviceName', '');
    out.profileName = ModelCodec.string(obj, 'profileName', '');
    out.classPlanCount = ModelCodec.int(obj, 'classPlanCount', 0);
    out.subjectCount = ModelCodec.int(obj, 'subjectCount', 0);
    out.timeLayoutCount = ModelCodec.int(obj, 'timeLayoutCount', 0);
    out.classPlanNames = ModelCodec.readArray(obj, 'classPlanNames',
      (item: JsonNode) => JsonValue.asString(item, ''));
    out.updatedAt = ModelCodec.number(obj, 'updatedAt', 0);
    return out;
  }
}

/** 把 TimeState 迁移映射成事件 ID。没有迁移返回空串。 */
export function eventIdForTransition(target: TimeState | undefined): string {
  if (target === undefined) {
    return PublicNotifyIds.NONE;
  }
  if (target === TimeState.OnClass) {
    return PublicNotifyIds.ON_CLASS;
  }
  if (target === TimeState.Breaking) {
    return PublicNotifyIds.ON_BREAKING_TIME;
  }
  if (target === TimeState.AfterSchool) {
    return PublicNotifyIds.ON_AFTER_SCHOOL;
  }
  return PublicNotifyIds.CURRENT_TIME_STATE_CHANGED;
}

/** 从课表快照合成公开状态。纯函数，不读盘、不看时钟以外的东西。 */
export function buildPublicLessonState(snapshot: LessonsSnapshot, source: PublicStateSource,
  now: DateTimeValue): PublicLessonState {
  const out: PublicLessonState = new PublicLessonState();
  out.deviceName = source.deviceName;
  out.profileName = source.profileName;

  const plan = snapshot.currentClassPlan;
  out.classPlanName = plan === undefined ? '' : plan.name;

  out.isClassPlanEnabled = snapshot.isClassPlanEnabled;
  out.isClassPlanLoaded = snapshot.isClassPlanLoaded;
  out.isLessonConfirmed = snapshot.isLessonConfirmed;
  out.currentState = snapshot.state;

  out.currentSubjectName = snapshot.currentSubject.name;
  out.nextClassSubjectName = snapshot.nextClassSubject.name;
  out.currentTimeLayoutStart = snapshot.currentTimeLayoutItem.startTime.toString();
  out.currentTimeLayoutEnd = snapshot.currentTimeLayoutItem.endTime.toString();
  out.onClassLeftSeconds = snapshot.onClassLeftTime.toSeconds();
  out.onBreakingTimeLeftSeconds = snapshot.onBreakingTimeLeftTime.toSeconds();

  out.lastEvent = eventIdForTransition(snapshot.transitionTo);
  out.updatedAt = now.toLocalMillis();
  return out;
}

/** 从档案合成公开摘要。 */
export function buildPublicProfileBrief(profile: Profile, source: PublicStateSource,
  now: DateTimeValue): PublicProfileBrief {
  const out: PublicProfileBrief = new PublicProfileBrief();
  out.deviceName = source.deviceName;
  out.profileName = source.profileName.length > 0 ? source.profileName : profile.name;
  out.classPlanCount = profile.classPlans.size;
  out.subjectCount = profile.subjects.size;
  out.timeLayoutCount = profile.timeLayouts.size;
  const names: string[] = [];
  profile.classPlans.forEach((plan) => {
    names.push(plan.name);
  });
  out.classPlanNames = names;
  out.updatedAt = now.toLocalMillis();
  return out;
}

/**
 * 远端快照是否已过期。
 *
 * `updatedAt` 为 0 一律算过期：那是「从没发布过」的默认值。时钟回拨导致的
 * 负年龄不算过期（接收方的时间可能比发布方慢），与天气那边的口径一致。
 */
export function isPublicStateStale(updatedAt: number, now: DateTimeValue,
  maxAgeSeconds: number): boolean {
  if (updatedAt <= 0) {
    return true;
  }
  const ageMillis: number = now.toLocalMillis() - updatedAt;
  return ageMillis > maxAgeSeconds * 1000;
}

/** 公开状态的紧凑 JSON 编解码。 */
export class PublicStateCodec {
  static encodeLessonState(state: PublicLessonState): string {
    return JsonWriter.writeCompact(state.toJson());
  }

  static decodeLessonState(text: string): PublicLessonState | undefined {
    try {
      const node: JsonNode = JsonReader.parse(text);
      if (JsonValue.asObject(node) === undefined) {
        return undefined;
      }
      return PublicLessonState.parse(node);
    } catch (error) {
      return undefined;
    }
  }

  static encodeProfileBrief(brief: PublicProfileBrief): string {
    return JsonWriter.writeCompact(brief.toJson());
  }

  static decodeProfileBrief(text: string): PublicProfileBrief | undefined {
    try {
      const node: JsonNode = JsonReader.parse(text);
      if (JsonValue.asObject(node) === undefined) {
        return undefined;
      }
      return PublicProfileBrief.parse(node);
    } catch (error) {
      return undefined;
    }
  }
}
