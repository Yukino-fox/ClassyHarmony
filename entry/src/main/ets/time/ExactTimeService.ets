/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 精确时间服务：编排 NTP 查询与时钟接入。
 *
 * 职责边界
 * --------
 * 本文件只做「什么时候查、查到之后喂给谁、设置变了怎么办」三件事：
 *   - 什么时候查：启动时一次，之后每 10 分钟一次（与桌面版同间隔）；
 *   - 喂给谁：ExactClock，它同时实现 AppClock，全应用共用这一个实例；
 *   - 设置变了：重读并重落。
 * 报文编解码、偏差公式、采纳判据、冻结、每日补偿算术全在 common_core，
 * 那里有 186 条用例在盯。这里一行算法都没有。
 *
 * 必须是进程内单例
 * --------------
 * AppServices 里 resolveClassTableViewModel / resolveScheduleEditorViewModel
 * 各自 new 了一个 SystemClock —— 那是「每次组装一份干净的」写法。校时服务
 * 不能跟着这么做：两份 ExactClock 各自跑 10 分钟定时器、各自发查询，偏差
 * 还会因为两次查询的往返不同而差几十毫秒，于是同一个界面上课表页和编辑页
 * 显示的时间不一样。所以这里用模块级实例，并且**替换掉**那两个 SystemClock
 * （见 AppServices）。
 *
 * 小组件不接
 * ----------
 * FormExtensionAbility 那份容器里仍然是 SystemClock。小组件的存活窗口是
 * 10 秒量级，校时是 10 分钟周期，两者对不上：它永远等不到一次有意义的同步，
 * 却要为这几十毫秒的准确度多发一次 UDP、并在沙箱里多留一个 socket。系统时间
 * 对一个 10 秒的卡片来说足够。
 *
 * 与桌面版三处刻意分歧
 * ------------------
 * 1. 系统时间跳变的阈值取 5 秒，桌面版 30 秒。桌面版那个判据算的是
 *    `|LastSystemTime - now| - elapsed > 30s`，只在系统钟**往回**跳时才可能
 *    成立，往前跳（更常见：NTP 一开、系统自动校了）永远测不出来。这里用
 *    单调时钟作第二根轴，两个方向都测得出，阈值取 5 秒是因为超过 5 秒的跳变
 *    一定会被用户看见。
 * 2. 反向保持 / 冻结的语义拆开了。桌面版只有「等一次重同步」一种恢复方式，
 *    且在 Sysc() 里用 nowBase 与 prev 比较来代替；这里把「小幅倒退 → 保持旧
 *    值、真实时间追上即恢复」与「系统钟被改 → 冻结、必须重同步」分成两件事。
 * 3. 每日补偿在基准日落到未来时钳到 0（见 DailyAutoAdjust.ets 文件头）。
 * 其余（间隔、默认值、落盘键名、TimeOffsetSeconds + DebugTimeOffsetSeconds
 * 的叠加顺序）都与桌面版一致。
 *
 * 网络这一段为什么不做退避重试
 * --------------------------
 * UDP 查询失败在移动网络下是常态（基站切换、NAT 超时）。10 分钟一次的固定
 * 间隔意味着一次失败只损失 10 分钟精度，用户看不见；而一旦做指数退避，退避
 * 的状态就得跨进程活下来（小组件运行时也要读），复杂度远超收益。桌面版也是
 * 固定间隔。失败只写 statusText，不弹提示。
 */

import { common } from '@kit.AbilityKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DateTimeValue } from 'common_shared';
import { t, tf } from 'common_core';
import { ExactClock, SyncOutcome, planDailyAutoAdjust } from 'common_core';

import { AppClock } from '../common/AppClock';
import {
  AppPreferences,
  DEFAULT_EXACT_TIME_SERVER,
  PrefKeys,
  TIME_OFFSET_LIMIT
} from '../common/AppPreferences';
import { NtpQueryResult, queryNtp } from './NtpClient';

const DOMAIN: number = 0x0000;
const TAG: string = 'ExactTime';

/** 同步周期。与桌面版 DispatcherTimer.Interval = 10 分钟一致。 */
const SYNC_INTERVAL_MS: number = 600000;

/** 两次同步之间的最短间隔，用于「切回前台时要不要立刻查一次」。 */
const MIN_FOREGROUND_RESYNC_MS: number = 60000;

/**
 * 取开机以来的毫秒数；取不到时返回 -1。
 *
 * 返回 -1 而不是 0：0 是一个合法取值（刚开机），拿它参与「基线 + 经过时间」
 * 的算术会算出一个落在开机时刻的值，看起来像「系统时间被拨回去了」。
 * ExactClock 见到负数就不做跳变检测。
 */
function readUptime(): number {
  try {
    return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'getUptime failed: %{public}s', `${err}`);
    return -1;
  }
}

export class ExactTimeService implements AppClock {
  private readonly core: ExactClock = new ExactClock();
  private readonly prefs: AppPreferences;

  private enabled: boolean = true;
  private server: string = DEFAULT_EXACT_TIME_SERVER;
  /** 只含用户手动偏移，不含 DebugTimeOffsetSeconds（设置页要显示的就是它）。 */
  private manualOffsetSeconds: number = 0;
  private debugOffsetSeconds: number = 0;
  private autoAdjustEnabled: boolean = false;
  private autoAdjustSeconds: number = 0;

  private intervalId: number = -1;
  /** 上次发起同步的墙钟时刻，0 表示还没同步过。 */
  private lastSyncAt: number = 0;
  /** 一次同步正在进行（防止定时器与手动触发叠在一起）。 */
  private syncing: boolean = false;
  private syncStatus: string = t('ts_not_synced');

  constructor(context: common.Context) {
    this.prefs = new AppPreferences(context);
    this.readSettings();
  }

  // ------------------------------------------------------------ 取时间

  /**
   * 当前本地时间。这是全应用唯一的「现在」。
   *
   * 每次都重新取系统时间与开机时长，不缓存：这两者都是极廉价的系统调用，
   * 而缓存意味着「校时结果生效要等下一个缓存过期」，冻结解除时界面会晚
   * 最多一秒才恢复。
   */
  now(): DateTimeValue {
    return this.core.now(Date.now(), readUptime());
  }

  // ------------------------------------------------------------ 生命周期

  /**
   * 开始同步。幂等，可在 onForeground 里反复调。
   *
   * 每日补偿放在这里而不是构造函数里：构造函数只跑一次，而 onForeground
   * 每次切回前台都会重读一遍设置与补偿。之所以敢这么做，是因为补偿会无条件
   * 推进基准日到今天 —— 第二次进来时天数算出来是 0，天然幂等。若哪天改成
   * 「只有开关打开时才推进基准日」，这里就会每天重复补偿一次。
   */
  start(): void {
    this.readSettings();
    this.applyDailyAutoAdjust();
    if (!this.enabled) {
      this.stop();
      return;
    }
    if (this.intervalId < 0) {
      this.intervalId = setInterval((): void => {
        void this.syncQuietly();
      }, SYNC_INTERVAL_MS) as number;
    }
    void this.syncOnForeground();
  }

  /** 停掉定时器。已经停过是空操作。 */
  stop(): void {
    if (this.intervalId >= 0) {
      clearInterval(this.intervalId);
      this.intervalId = -1;
    }
  }

  /**
   * 切回前台时的同步决策。
   *
   * 不每次都查：用户在设置页和主界面之间来回切是常事，每次切回来都发一次
   * UDP 既费电又没意义 —— 上一次同步的结果最多才 10 分钟。留 1 分钟的宽限，
   * 连着切两次不会连着发两次包。
   */
  private async syncOnForeground(): Promise<void> {
    const since: number = Date.now() - this.lastSyncAt;
    if (this.lastSyncAt > 0 && since < MIN_FOREGROUND_RESYNC_MS) {
      return;
    }
    await this.syncQuietly();
  }

  // ------------------------------------------------------------ 同步

  /** 立即同步一次。设置页的「立即校时」按钮走这里。 */
  async syncNow(): Promise<void> {
    await this.doSync(true);
  }

  private async syncQuietly(): Promise<void> {
    await this.doSync(false);
  }

  /**
   * 跑一次查询并把结果交给 ExactClock。
   *
   * 永不抛异常，理由同 NtpClient：调用方是定时器与生命周期回调，抛出去
   * 只会变成没人看的未处理 Promise 拒绝。
   *
   * @param manual 是否用户主动触发。是的话失败原因要落到 statusText 上给
   *        人看；不是的话只记日志，避免定时器每 10 分钟改一次界面文案。
   */
  private async doSync(manual: boolean): Promise<void> {
    if (!this.enabled) {
      this.syncStatus = t('time_off_use_system');
      return;
    }
    if (this.syncing) {
      return;
    }
    this.syncing = true;
    this.lastSyncAt = Date.now();
    this.syncStatus = t('ts_syncing');
    try {
      const result: NtpQueryResult = await queryNtp(this.server);
      if (!result.ok || result.response === undefined) {
        this.syncStatus = tf('ts_sync_failed', result.detail);
        hilog.warn(DOMAIN, TAG, 'ntp query failed: %{public}s', result.detail);
        return;
      }
      this.applyResult(result);
    } catch (err) {
      this.syncStatus = tf('ts_sync_failed', `${err}`);
      hilog.error(DOMAIN, TAG, 'sync threw: %{public}s', `${err}`);
    } finally {
      this.syncing = false;
    }
  }

  /**
   * 把一次查询的结果落到时钟上。
   *
   * statusText 分三层，从具体到笼统，好让人知道下一步该做什么：
   *   - 冻结（系统钟被改）：必须重同步，等着就行；
   *   - 采纳成功：说清本机快还是慢、多少；
   *   - 兜底：ExactClock 自己给的原因（响应不合法、往返过大、负延迟）。
   */
  private applyResult(result: NtpQueryResult): void {
    if (result.response === undefined) {
      this.syncStatus = t('time_sync_bad_response');
      return;
    }
    const outcome: SyncOutcome = this.core.applySync(
      result.t1Millis, result.response, result.t4Millis, Date.now(), readUptime());
    if (outcome.accepted) {
      const offset: number = outcome.offsetMillis;
      this.syncStatus = outcome.offsetMillis >= 0
        ? tf('ts_behind_fixed', formatMillis(offset))
        : tf('ts_ahead_fixed', formatMillis(-offset));
    } else {
      this.syncStatus = tf('ts_rejected', this.core.statusText());
    }
    hilog.info(DOMAIN, TAG, 'sync: accepted=%{public}d offset=%{public}d delay=%{public}d',
      outcome.accepted ? 1 : 0, outcome.offsetMillis, outcome.delayMillis);
  }

  // ------------------------------------------------------------ 设置

  /**
   * 重读全部设置并落到 core。
   *
   * 分两处落是有意的：开关与偏移走 ExactClock（它决定 now() 的行为），
   * 服务器与补偿参数只留在这里（本进程内直接用）。分开放是为了让
   * ExactClock 不必知道服务器地址这种它用不上的东西。
   */
  private readSettings(): void {
    this.enabled = this.prefs.getBoolean(PrefKeys.EXACT_TIME_ENABLED, true);
    const server: string = this.prefs
      .getString(PrefKeys.EXACT_TIME_SERVER, DEFAULT_EXACT_TIME_SERVER)
      .trim();
    this.server = server.length === 0 ? DEFAULT_EXACT_TIME_SERVER : server;
    this.manualOffsetSeconds = clampOffset(
      this.prefs.getNumber(PrefKeys.TIME_OFFSET_SECONDS, 0));
    this.debugOffsetSeconds = clampOffset(
      this.prefs.getNumber(PrefKeys.DEBUG_TIME_OFFSET_SECONDS, 0));
    this.autoAdjustEnabled = this.prefs.getBoolean(PrefKeys.TIME_AUTO_ADJUST_ENABLED, false);
    this.autoAdjustSeconds = clampOffset(
      this.prefs.getNumber(PrefKeys.TIME_AUTO_ADJUST_SECONDS, 0));
    this.pushToCore();
  }

  /** 把开关与偏移交给 ExactClock。 */
  private pushToCore(): void {
    this.core.setEnabled(this.enabled);
    // 顺序与桌面版 GetCurrentLocalDateTime 一致：先 TimeOffsetSeconds，
    // 再 DebugTimeOffsetSeconds。两者可叠加也各自独立，加法满足交换律，
    // 但保顺序是为了让「读这段代码的人」不用去桌面版确认能不能换。
    this.core.setOffsetSeconds(this.manualOffsetSeconds + this.debugOffsetSeconds);
  }

  /**
   * 跑一次每日补偿并落盘。
   *
   * 幂等：补偿计划无条件把基准日推进到今天，所以第二次进来天数必然是 0。
   * 算术在 common_core 的 planDailyAutoAdjust 里（有 43 条用例），这里只负责
   * 读设置、落盘、把新偏移推给时钟。
   */
  private applyDailyAutoAdjust(): void {
    const baseline: string = this.prefs.getString(PrefKeys.LAST_TIME_ADJUST, '');
    const parsed: DateTimeValue | undefined = baseline.length === 0
      ? undefined : DateTimeValue.tryParse(baseline);
    const plan = planDailyAutoAdjust(
      this.autoAdjustEnabled, this.manualOffsetSeconds, this.autoAdjustSeconds,
      DateTimeValue.now(), parsed);
    if (plan.applied) {
      hilog.info(DOMAIN, TAG, 'daily auto adjust: +%{public}d days, offset=%{public}s',
        plan.days, `${plan.offsetSeconds}`);
      this.manualOffsetSeconds = plan.offsetSeconds;
      this.prefs.put(PrefKeys.TIME_OFFSET_SECONDS, plan.offsetSeconds);
    }
    if (plan.advanceBaseline) {
      this.prefs.put(PrefKeys.LAST_TIME_ADJUST, DateTimeValue.now().toString());
    }
    this.pushToCore();
  }

  // ------------------------------------------- 设置项写入（设置页调用）

  /**
   * 改总开关。
   *
   * 改动要立刻见效：开 → 立即查一次；关 → 停定时器并清掉已同步状态
   * （ExactClock.setEnabled(false) 会清偏差，用户关了就是不想被改时间）。
   */
  setEnabled(value: boolean): void {
    this.enabled = value;
    this.prefs.put(PrefKeys.EXACT_TIME_ENABLED, value);
    this.pushToCore();
    if (value) {
      this.start();
    } else {
      this.stop();
      this.syncStatus = t('time_off_use_system');
    }
  }

  /**
   * 改 NTP 服务器。
   *
   * 立刻查一次：换服务器这个动作本身就是「我现在就要准」的信号，等 10 分钟
   * 的话用户会以为没生效。
   */
  setServer(value: string): void {
    const trimmed: string = value.trim();
    this.server = trimmed.length === 0 ? DEFAULT_EXACT_TIME_SERVER : trimmed;
    this.prefs.put(PrefKeys.EXACT_TIME_SERVER, this.server);
    this.lastSyncAt = 0;
    void this.syncQuietly();
  }

  /** 改手动偏移（秒）。立即生效，不落 LastTimeAdjustDateTime。 */
  setOffsetSeconds(value: number): void {
    this.manualOffsetSeconds = clampOffset(value);
    this.prefs.put(PrefKeys.TIME_OFFSET_SECONDS, this.manualOffsetSeconds);
    this.pushToCore();
  }

  /** 改每日补偿开关。不立刻补：补多少由 start() 里的补偿计划按天数算。 */
  setAutoAdjustEnabled(value: boolean): void {
    this.autoAdjustEnabled = value;
    this.prefs.put(PrefKeys.TIME_AUTO_ADJUST_ENABLED, value);
  }

  /** 改每日补偿秒数。 */
  setAutoAdjustSeconds(value: number): void {
    this.autoAdjustSeconds = clampOffset(value);
    this.prefs.put(PrefKeys.TIME_AUTO_ADJUST_SECONDS, this.autoAdjustSeconds);
  }

  // ------------------------------------------------------------ 只读

  isEnabled(): boolean {
    return this.enabled;
  }

  currentServer(): string {
    return this.server;
  }

  currentOffsetSeconds(): number {
    return this.manualOffsetSeconds;
  }

  isAutoAdjustEnabled(): boolean {
    return this.autoAdjustEnabled;
  }

  currentAutoAdjustSeconds(): number {
    return this.autoAdjustSeconds;
  }

  /** 是否已拿到过一次可用的服务器时刻。 */
  isSynced(): boolean {
    return this.core.isSynced();
  }

  /** 本次同步相对服务器的偏差（毫秒）。未同步时为 0。 */
  offsetMillis(): number {
    return this.core.ntpOffsetMillis();
  }

  /**
   * 状态文案。
   *
   * 冻结信息优先于同步状态：冻结时 ExactClock 给出的原因才是用户需要看到的
   * （「系统时间被改了」比「3 分钟前同步成功」有用得多）。
   */
  statusText(): string {
    if (this.core.isFrozen()) {
      return tf('ts_status_last_sync', this.core.statusText(), this.syncStatus);
    }
    return this.syncStatus;
  }
}

let instance: ExactTimeService | undefined = undefined;

/** 取进程内唯一的校时服务，首次调用时装配。 */
export function resolveExactTimeService(context: common.Context): ExactTimeService {
  if (instance === undefined) {
    instance = new ExactTimeService(context);
  }
  return instance;
}

/** 只为「重置」用：丢掉当前实例，下次 resolve 会重新装配。 */
export function resetExactTimeService(): void {
  if (instance !== undefined) {
    instance.stop();
  }
  instance = undefined;
}

/** 偏移夹在 ±24 小时内。越界多半是设置被手改的，不夹的话显示会离谱。 */
function clampOffset(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  if (value > TIME_OFFSET_LIMIT) {
    return TIME_OFFSET_LIMIT;
  }
  if (value < -TIME_OFFSET_LIMIT) {
    return -TIME_OFFSET_LIMIT;
  }
  return value;
}

/**
 * 毫秒的显示口径。
 *
 * 一位小数就够了：NTP 在 4G 上本来就只有几十毫秒的抖动，显示到微秒是
 * 拿噪声当信号。超过一分钟才换算成分钟 —— 手机上「本机慢 0.3 秒」和
 * 「本机慢 12.4 分钟」是两种完全不同的故障（前者是网络抖动，后者是
 * 本机时钟被大幅拨过），不换算的话后者会被读成前者。
 */
function formatMillis(millis: number): string {
  if (Math.abs(millis) >= 60000) {
    return tf('ts_minutes', (millis / 60000).toFixed(1));
  }
  return tf('ts_seconds', (millis / 1000).toFixed(1));
}
