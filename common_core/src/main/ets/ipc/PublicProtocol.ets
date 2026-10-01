/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 跨设备 / 外部调用的公开协议常量。
 *
 * 对应桌面版的 `ClassIsland.Shared.IPC`：
 *   - `IpcRoutedNotifyIds`  → `PublicNotifyIds`
 *   - IPC 方法调用           → Want 显式匹配（`PublicWantActions` + `PublicWantKeys`）
 *   - 命名管道 / 多实例互斥   → 分布式数据对象（`distributedDataObject`）
 *
 * 桌面版的 IPC 只在同一台机器的多个进程之间用（`IpcClient.PipeName` 那条命名
 * 管道）。鸿蒙应用是单进程模型：`UIAbility` 与 `FormExtensionAbility` 各自
 * 一个进程，而已知的同伴（Launcher、托盘工具、桌面悬浮窗）在鸿蒙上都不存在。
 * 所以这里把「跨进程」重新定义成「跨设备」：
 *
 *   - 同一份公开课表状态通过分布式数据对象同步给超级终端里的其它设备；
 *   - 同时保留一个 Want 入口，让外部应用能显式匹配并只读查询当前状态。
 *
 * 两条路径共用同一份 `PublicLessonState`（见 `PublicState.ets`），所以协议
 * 常量集中放在这个文件里，避免两边各写一套字符串。
 */

/**
 * 对应桌面版 `IpcRoutedNotifyIds`。
 *
 * 桌面版用它把「上课 / 课间 / 放学 / 状态变化」四类事件推给订阅进程。本端
 * 没有常驻订阅者，这四个 ID 保留下来有两个用途：
 *   1. 分布式数据对象在状态迁移时把对应 ID 写进 `lastEvent` 字段，接收方据此
 *      决定要不要弹提醒（而不是每秒解析整个快照）；
 *   2. 将来若接入 Want 广播，事件名已经定死，不用再改一遍。
 */
export class PublicNotifyIds {
  static readonly ON_CLASS: string = 'classisland.lessonsService.onClass';
  static readonly ON_BREAKING_TIME: string = 'classisland.lessonsService.onBreakingTime';
  static readonly ON_AFTER_SCHOOL: string = 'classisland.lessonsService.onAfterSchool';
  static readonly CURRENT_TIME_STATE_CHANGED: string =
    'classisland.lessonsService.currentTimeStateChanged';

  /** 不在上面四个里的其它状态（例如加载完成）。 */
  static readonly NONE: string = '';
}

/** 外部应用用 Want 显式匹配本应用时使用的 action。 */
export class PublicWantActions {
  /** 查询当前课表状态（返回 `PublicLessonState` 的紧凑 JSON）。 */
  static readonly QUERY_LESSON_STATE: string = 'classisland.tech.action.QUERY_LESSON_STATE';
  /** 查询档案摘要（返回 `PublicProfileBrief` 的紧凑 JSON）。 */
  static readonly QUERY_PROFILE_BRIEF: string = 'classisland.tech.action.QUERY_PROFILE_BRIEF';
}

/** Want 的入参 / 回参键。 */
export class PublicWantKeys {
  /** 布尔：本次查询是否成功。 */
  static readonly RESULT_OK: string = 'classisland.tech.result.ok';
  /** 字符串：成功时的紧凑 JSON。 */
  static readonly RESULT_JSON: string = 'classisland.tech.result.json';
  /** 字符串：失败时的中文原因，可直接显示。 */
  static readonly RESULT_MESSAGE: string = 'classisland.tech.result.message';
}

/**
 * `distributedDataObject.setSessionId` 对会话 ID 的约束：
 * 只允许字母、数字、下划线，最长 128 字节。
 */
export const DISTRIBUTED_SESSION_ID_MAX_LENGTH: number = 128;

/** 单字节是否为会话 ID 允许的字符。 */
function isSessionIdChar(code: number): boolean {
  const isDigit: boolean = code >= 48 && code <= 57; // 0-9
  const isUpper: boolean = code >= 65 && code <= 90; // A-Z
  const isLower: boolean = code >= 97 && code <= 122; // a-z
  const isUnderscore: boolean = code === 95; // _
  return isDigit || isUpper || isLower || isUnderscore;
}

/** 丢掉非法字符并按上限截断。 */
function sanitizeSessionId(raw: string): string {
  let out: string = '';
  for (let i: number = 0; i < raw.length; i++) {
    if (isSessionIdChar(raw.charCodeAt(i))) {
      out += raw.charAt(i);
    }
  }
  if (out.length > DISTRIBUTED_SESSION_ID_MAX_LENGTH) {
    out = out.substring(0, DISTRIBUTED_SESSION_ID_MAX_LENGTH);
  }
  return out;
}

/**
 * 规范化一个会话 ID；清洗后为空则退回落值。
 *
 * 为什么是「丢掉非法字符」而不是「替换成下划线」：用户很可能从别处拷一个带
 * 连字符的 UUID 过来（`3f2504e0-4f89-...`），而系统只收字母/数字/下划线。
 * 替换的话 `a-b` 与 `a_b` 会规范成同一个 ID，两个不同的输入连到同一个会话，
 * 用户完全看不出为什么；丢掉非法字符至少符合直觉。落值同样会被清洗。
 */
export function normalizeDistributedSessionId(raw: string, fallback: string): string {
  const cleaned: string = sanitizeSessionId(raw);
  if (cleaned.length > 0) {
    return cleaned;
  }
  return sanitizeSessionId(fallback);
}

/**
 * 是否符合系统对 sessionId 的约束。
 *
 * 空串**不算**合法：在 API 里空串表示「退出会话」，把它当成合法值会让
 * 「还没生成过会话 ID」与「主动退出了会话」两种情况长得一样。
 */
export function isValidDistributedSessionId(raw: string): boolean {
  if (raw.length === 0 || raw.length > DISTRIBUTED_SESSION_ID_MAX_LENGTH) {
    return false;
  }
  for (let i: number = 0; i < raw.length; i++) {
    if (!isSessionIdChar(raw.charCodeAt(i))) {
      return false;
    }
  }
  return true;
}
