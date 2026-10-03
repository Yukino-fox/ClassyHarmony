/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 跨设备状态同步（entry 侧）。
 *
 * 对应桌面版的 `ClassIsland.Shared.IPC`。桌面版用命名管道 + Protobuf 让同一台
 * 机器上的其它进程查询课表状态；鸿蒙上那些同伴（Launcher / 托盘工具 / 桌面
 * 悬浮窗）都不存在，所以这里把「跨进程」重新定义成「跨设备」：
 *
 *   - 主动发布：通过 `distributedDataObject` 把公开课表状态同步给超级终端里
 *     加入同一会话的其它设备；
 *   - 被动查询：外部应用用 Want 显式匹配本应用（见 `PublicQueryService`）。
 *
 * 两条路径共用同一份 `PublicLessonState`（core 里，有 83 条用例在盯），本文件
 * 只负责把 core 的纯数据接到系统的分布式数据对象上。
 *
 * 必须是进程内单例
 * --------------
 * 发布节流状态、远端快照、会话对象都是跨调用状态：设置页读的和每秒 tick 写的
 * 必须是同一份，各自建一份会出现「设置页显示已连接但状态从来没推出去」这种
 * 最难查的不一致。走模块级实例，与 ExactTimeService / WeatherService 同一个
 * 路子。
 *
 * 为什么默认关、且全程 try/catch 兜底
 * ---------------------------------
 * `distributedDataObject` 需要 `ohos.permission.DISTRIBUTED_DATASYNC`（用户授权），
 * 还要设备在同一超级终端里。任何一步失败（权限被拒、没有可信设备、系统版本
 * 不支持）都不该影响主功能 —— 课表本身完全不需要它。所以这里把「能不能用」
 * 和「用户开没开」分开：开了但系统不给，界面上给一句原因，主流程照常。
 *
 * 已知限制（刻意记在这里，不假装不存在）
 * ------------------------------------
 * 同一会话里多台设备都会发布，`distributedDataObject` 是「最后写入者生效」，
 * 没有冲突合并。当前用途是「把一台设备的状态展示到另一台」，不是双向编辑，
 * 所以不做 CRDT。真要做双向编辑得换成带版本号的合并策略。
 */

import { distributedDataObject } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { t, tf } from 'common_core';
import {
  DISTRIBUTED_SESSION_ID_MAX_LENGTH,
  PublicLessonState,
  PublicStateSource,
  buildPublicLessonState,
  isPublicStateStale,
  isValidDistributedSessionId,
  normalizeDistributedSessionId
} from 'common_core';
import { LessonsSnapshot } from 'common_core';
import { DateTimeValue, Profile } from 'common_shared';
import {
  AppPreferences,
  DEFAULT_DISTRIBUTED_SESSION_ID,
  DEFAULT_DISTRIBUTED_SYNC_ENABLED,
  PrefKeys
} from '../common/AppPreferences';

const DOMAIN: number = 0x0000;
const TAG: string = 'DistributedState';

/** 内容没变时也至少隔这么久重推一次（让刚加入的设备尽快拿到当前值）。 */
const REPUBLISH_INTERVAL_MS: number = 30000;

/** 远端快照超过这么久没更新就不再采信。 */
const STALE_AFTER_SECONDS: number = 120;

/**
 * 分布式数据对象上的扁平字段。
 *
 * 必须全是 string / number / boolean —— 分布式数据对象对嵌套对象是深拷贝
 * 语义，改一个叶子会推整棵树；扁平字段在 ArkTS 与 DDO 两边都好传。
 *
 * 用 interface 而不是 class：`distributedDataObject.create` 收的是源对象，
 * 对象字面量在 ArkTS 里只有目标类型是 interface / 具名类时才合法。
 */
interface DistributedStateFields {
  deviceName: string;
  profileName: string;
  classPlanName: string;
  isClassPlanEnabled: boolean;
  isClassPlanLoaded: boolean;
  isLessonConfirmed: boolean;
  currentState: number;
  currentSubjectName: string;
  nextClassSubjectName: string;
  currentTimeLayoutStart: string;
  currentTimeLayoutEnd: string;
  onClassLeftSeconds: number;
  onBreakingTimeLeftSeconds: number;
  lastEvent: string;
  updatedAt: number;
}

/** 空字段（源对象的初值）。 */
function emptyFields(): DistributedStateFields {
  const out: DistributedStateFields = {
    deviceName: '',
    profileName: '',
    classPlanName: '',
    isClassPlanEnabled: false,
    isClassPlanLoaded: false,
    isLessonConfirmed: false,
    currentState: 0,
    currentSubjectName: '',
    nextClassSubjectName: '',
    currentTimeLayoutStart: '',
    currentTimeLayoutEnd: '',
    onClassLeftSeconds: 0,
    onBreakingTimeLeftSeconds: 0,
    lastEvent: '',
    updatedAt: 0
  };
  return out;
}

export class DistributedStateService {
  private readonly context: common.UIAbilityContext;
  private readonly prefs: AppPreferences;

  /** 本机显示名，构造时算一次（设备名不会中途变）。 */
  private readonly deviceName: string;

  private enabled: boolean = false;
  private sessionId: string = '';
  private started: boolean = false;

  /** 系统不给用（权限被拒 / 创建失败）时的原因，空串表示没出错。 */
  private failure: string = '';

  private object: distributedDataObject.DataObject | undefined = undefined;
  private fields: DistributedStateFields | undefined = undefined;

  private lastStateKey: string = '';
  private lastPublishedAt: number = 0;

  private remote: PublicLessonState | undefined = undefined;
  private readonly online: Set<string> = new Set<string>();

  constructor(context: common.Context) {
    this.context = context as common.UIAbilityContext;
    this.prefs = new AppPreferences(this.context);
    this.deviceName = DistributedStateService.resolveDeviceName();
    this.reload();
  }

  // ------------------------------------------------------------ 配置

  /** 重新读一遍开关与会话 ID（设置页改完、或从后台回来时调）。 */
  reload(): void {
    this.enabled = this.prefs.getBoolean(PrefKeys.DISTRIBUTED_SYNC_ENABLED,
      DEFAULT_DISTRIBUTED_SYNC_ENABLED);
    const raw: string = this.prefs.getString(PrefKeys.DISTRIBUTED_SESSION_ID,
      DEFAULT_DISTRIBUTED_SESSION_ID);
    this.sessionId = normalizeDistributedSessionId(raw, '');
  }

  /** 用户开没开同步。 */
  isEnabled(): boolean {
    return this.enabled;
  }

  /** 当前会话 ID；没生成过时是空串。 */
  currentSessionId(): string {
    return this.sessionId;
  }

  /** 本机显示名。 */
  currentDeviceName(): string {
    return this.deviceName;
  }

  /**
   * 设置页改开关。
   *
   * 开了之后立刻尝试建会话；关掉时退出会话并清掉对象。写盘先于启停：即使
   * 系统这一秒不给用，下次启动仍会按用户的意图重试。
   */
  setEnabled(value: boolean): void {
    this.enabled = value;
    this.prefs.put(PrefKeys.DISTRIBUTED_SYNC_ENABLED, value);
    if (value) {
      this.start();
    } else {
      this.stop();
    }
  }

  /**
   * 把会话 ID 换成用户输入的那个（已规范化）。
   *
   * 返回规范化后的值，设置页拿它回填输入框 —— 用户看的必须是最终生效的那个，
   * 否则会以为自己填的没生效。
   */
  setSessionId(raw: string): string {
    const normalized: string = normalizeDistributedSessionId(raw, '');
    this.sessionId = normalized;
    this.prefs.put(PrefKeys.DISTRIBUTED_SESSION_ID, normalized);
    if (this.started) {
      this.stop();
      this.start();
    }
    return normalized;
  }

  /** 生成一个会话 ID 并落盘（用户不想自己起名字时用）。 */
  generateSessionId(): string {
    let id: string = '';
    try {
      id = normalizeDistributedSessionId(distributedDataObject.genSessionId(), '');
    } catch (error) {
      id = '';
    }
    if (id.length === 0) {
      // 系统生成失败时的兜底：时间戳只含数字，一定合法。
      id = `classisland${Date.now()}`;
      id = normalizeDistributedSessionId(id, 'classisland');
    }
    // 再截一次，防时间戳与随机串拼起来超长（正常不会）。
    if (id.length > DISTRIBUTED_SESSION_ID_MAX_LENGTH) {
      id = id.substring(0, DISTRIBUTED_SESSION_ID_MAX_LENGTH);
    }
    this.sessionId = id;
    this.prefs.put(PrefKeys.DISTRIBUTED_SESSION_ID, id);
    if (this.started) {
      this.stop();
      this.start();
    }
    return id;
  }

  // ------------------------------------------------------------ 启停

  /**
   * 进入同步。幂等。
   *
   * 先 reload：从后台回来时用户可能刚在设置页改过会话 ID，不重读就会一直用
   * 老的。`enabled` 为假时不建对象 —— 默认关的那条路径一次系统调用都不发。
   */
  start(): void {
    if (this.started) {
      return;
    }
    this.reload();
    if (!this.enabled) {
      return;
    }
    this.started = true;
    this.failure = '';

    const id: string = this.ensureSessionId();
    if (!isValidDistributedSessionId(id)) {
      this.failure = t('ddo_bad_session_id');
      return;
    }

    try {
      const source: DistributedStateFields = emptyFields();
      const created: distributedDataObject.DataObject =
        distributedDataObject.create(this.context, source);
      this.object = created;
      // create 返回的就是要读写的那个对象；先当 object 再向下转型 ——
      // DataObject 接口只声明了方法，没有字段，直接转会被判「类型不重叠」。
      const createdAsObject: object = created;
      this.fields = createdAsObject as DistributedStateFields;

      created.on('change', (sessionId: string, changed: string[]) => {
        this.handleChange(changed);
      });
      created.on('status', (sessionId: string, networkId: string,
        status: 'online' | 'offline') => {
        this.handleStatus(networkId, status);
      });

      created.setSessionId(id).then(() => {
        hilog.info(DOMAIN, TAG, 'joined session %{public}s', id);
      }).catch((error: Error) => {
        this.failure = tf('ddo_join_failed', error.message);
        hilog.warn(DOMAIN, TAG, 'setSessionId failed: %{public}s', this.failure);
      });
    } catch (error) {
      this.failure = tf('ddo_sync_unavailable', `${error}`);
      this.object = undefined;
      this.fields = undefined;
      hilog.warn(DOMAIN, TAG, 'create distributed object failed: %{public}s', this.failure);
    }
  }

  /** 退出同步。幂等。 */
  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.lastStateKey = '';
    this.lastPublishedAt = 0;
    this.remote = undefined;
    this.online.clear();
    if (this.object !== undefined) {
      try {
        this.object.off('change');
        this.object.off('status');
        // 空串 = 退出会话（API 的约定），不是「设一个叫空的会话」。
        this.object.setSessionId('').catch((error: Error) => {
          hilog.warn(DOMAIN, TAG, 'leave session failed: %{public}s', error.message);
        });
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'stop failed: %{public}s', `${error}`);
      }
    }
    this.object = undefined;
    this.fields = undefined;
  }

  // ------------------------------------------------------------ 发布

  /**
   * 发布一次当前快照。每秒被 tick 调用一次，内部按内容 + 时间节流。
   *
   * 节流两档：
   *   - 内容没变，且距上次发布不到 `REPUBLISH_INTERVAL_MS` → 跳过；
   *   - 内容变了 → 立刻发（倒计时每秒都在变，所以实际上每秒都会发，
   *     但「课间休息时屏幕上一分钟没动」的场景下就不会空推）。
   */
  publish(snapshot: LessonsSnapshot, profile: Profile): void {
    if (!this.started || this.fields === undefined) {
      return;
    }
    const source: PublicStateSource = new PublicStateSource();
    source.deviceName = this.deviceName;
    source.profileName = profile.name;
    const state: PublicLessonState = buildPublicLessonState(snapshot, source,
      DateTimeValue.now());

    const key: string = state.contentKey();
    const nowMillis: number = Date.now();
    if (key === this.lastStateKey && (nowMillis - this.lastPublishedAt) < REPUBLISH_INTERVAL_MS) {
      return;
    }
    this.lastStateKey = key;
    this.lastPublishedAt = nowMillis;

    const fields: DistributedStateFields = this.fields;
    fields.deviceName = state.deviceName;
    fields.profileName = state.profileName;
    fields.classPlanName = state.classPlanName;
    fields.isClassPlanEnabled = state.isClassPlanEnabled;
    fields.isClassPlanLoaded = state.isClassPlanLoaded;
    fields.isLessonConfirmed = state.isLessonConfirmed;
    fields.currentState = state.currentState;
    fields.currentSubjectName = state.currentSubjectName;
    fields.nextClassSubjectName = state.nextClassSubjectName;
    fields.currentTimeLayoutStart = state.currentTimeLayoutStart;
    fields.currentTimeLayoutEnd = state.currentTimeLayoutEnd;
    fields.onClassLeftSeconds = state.onClassLeftSeconds;
    fields.onBreakingTimeLeftSeconds = state.onBreakingTimeLeftSeconds;
    fields.lastEvent = state.lastEvent;
    fields.updatedAt = state.updatedAt;
  }

  // ------------------------------------------------------------ 远端

  /** 最近一次收到的远端快照；超过新鲜期或从没收到时返回 undefined。 */
  remoteState(): PublicLessonState | undefined {
    const state: PublicLessonState | undefined = this.remote;
    if (state === undefined) {
      return undefined;
    }
    if (isPublicStateStale(state.updatedAt, DateTimeValue.now(), STALE_AFTER_SECONDS)) {
      return undefined;
    }
    return state;
  }

  /** 界面上显示的一行状态。 */
  statusText(): string {
    if (!this.enabled) {
      return t('ddo_off');
    }
    if (this.failure.length > 0) {
      return this.failure;
    }
    if (!this.started) {
      return t('ddo_enabled_waiting');
    }
    if (this.sessionId.length === 0) {
      return t('ddo_no_session');
    }
    const parts: string[] = [];
    parts.push(tf('ddo_session_line', this.sessionId));
    parts.push(this.online.size > 0 ? tf('ddo_peers_online', `${this.online.size}`) : t('ddo_no_peers'));
    const remote: PublicLessonState | undefined = this.remoteState();
    if (remote !== undefined) {
      parts.push(tf('ddo_last_from', remote.deviceName.length > 0 ? remote.deviceName : t('ddo_unknown_device')));
    }
    return parts.join(' · ');
  }

  // ------------------------------------------------------------ 内部

  private ensureSessionId(): string {
    if (isValidDistributedSessionId(this.sessionId)) {
      return this.sessionId;
    }
    let id: string = '';
    try {
      id = normalizeDistributedSessionId(distributedDataObject.genSessionId(), '');
    } catch (error) {
      id = '';
    }
    if (id.length === 0) {
      id = normalizeDistributedSessionId(`classisland${Date.now()}`, 'classisland');
    }
    this.sessionId = id;
    this.prefs.put(PrefKeys.DISTRIBUTED_SESSION_ID, id);
    return id;
  }

  private handleChange(changed: string[]): void {
    const fields: DistributedStateFields | undefined = this.fields;
    if (fields === undefined) {
      return;
    }
    const state: PublicLessonState = new PublicLessonState();
    state.deviceName = fields.deviceName;
    state.profileName = fields.profileName;
    state.classPlanName = fields.classPlanName;
    state.isClassPlanEnabled = fields.isClassPlanEnabled;
    state.isClassPlanLoaded = fields.isClassPlanLoaded;
    state.isLessonConfirmed = fields.isLessonConfirmed;
    state.currentState = fields.currentState;
    state.currentSubjectName = fields.currentSubjectName;
    state.nextClassSubjectName = fields.nextClassSubjectName;
    state.currentTimeLayoutStart = fields.currentTimeLayoutStart;
    state.currentTimeLayoutEnd = fields.currentTimeLayoutEnd;
    state.onClassLeftSeconds = fields.onClassLeftSeconds;
    state.onBreakingTimeLeftSeconds = fields.onBreakingTimeLeftSeconds;
    state.lastEvent = fields.lastEvent;
    state.updatedAt = fields.updatedAt;
    if (state.updatedAt <= 0) {
      return;
    }
    this.remote = state;
    hilog.info(DOMAIN, TAG, 'remote change: %{public}d fields from %{public}s',
      changed.length, state.deviceName);
  }

  private handleStatus(networkId: string, status: string): void {
    if (status === 'online') {
      this.online.add(networkId);
    } else {
      this.online.delete(networkId);
    }
    hilog.info(DOMAIN, TAG, 'peer %{public}s is %{public}s', networkId, status);
  }

  /** 设备显示名：品牌 + 市场名，取不到就退到产品型号。 */
  private static resolveDeviceName(): string {
    let brand: string = '';
    let market: string = '';
    let model: string = '';
    try {
      brand = deviceInfo.brand;
      market = deviceInfo.marketName;
      model = deviceInfo.productModel;
    } catch (error) {
      brand = '';
    }
    const combined: string = `${brand} ${market}`.trim();
    if (combined.length > 0) {
      return combined;
    }
    return model.length > 0 ? model : t('ddo_default_model');
  }
}

// ------------------------------------------------------------ 单例

let instance: DistributedStateService | undefined = undefined;

/**
 * 取进程内唯一的跨设备服务，没有就建一个。
 *
 * 与 ExactTimeService / WeatherService 同一个路子：模块级实例，不走 DI 容器 ——
 * 生命周期跟着 Ability（前台启、后台停），放 DI 里反而要额外管启停。
 */
export function resolveDistributedStateService(
  context: common.Context): DistributedStateService {
  if (instance === undefined) {
    instance = new DistributedStateService(context);
  }
  return instance;
}

/** 丢掉单例（进程要退了，或测试要重来）。 */
export function resetDistributedStateService(): void {
  if (instance !== undefined) {
    instance.stop();
    instance = undefined;
  }
}
