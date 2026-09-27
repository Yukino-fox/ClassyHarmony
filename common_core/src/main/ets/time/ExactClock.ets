/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 精确时钟：在系统时间之上叠加 NTP 偏差与用户手动偏移，并防住两类回跳。
 *
 * 对应桌面版 Services/ExactTimeService.cs 的 GetCurrentLocalDateTime()。
 *
 * 两类回跳，性质不同
 * ----------------
 * 一、系统时间被改（用户手动校时、系统自动对时、NTP 守护进程）：
 *    检测到之后**冻结**，在重新同步完成之前一直返回冻结前的值。冻结的理由
 *    是：系统时间跳变的那一瞬间，课表高亮会整片翻掉（"刚才还在上的课突然
 *    变成没上"），而这个跳变对用户来说没有任何操作可以解释它。
 *
 * 二、刚同步完发现时间略微倒退（< 30 秒）：
 *    不冻结，而是**保持**在旧值上，等真实时间追上再继续。保持而不是冻结，
 *    是因为这种情况几乎总是网络延迟不对称造成的测量误差，几秒内自己就
 *    好了；而冻结要等下一次同步（最长 10 分钟）。
 *
 * 为什么用单调时钟
 * ----------------
 * 检测系统时间跳变，必须能区分「真的过了 10 分钟」与「系统钟被拨了 10
 * 分钟」。只读系统时间是区分不出来的 —— 拨钟之后两次读数的差值也跟着变。
 *
 * 桌面版用 Stopwatch 做这件事，但它的判据
 * |(上次系统时间 − 本次系统时间) − Stopwatch 经过时间| > 30s
 * 在时钟稳定时等于 2 × 实际间隔。也就是说这个判据在「两次调用相隔超过
 * 15 秒」时就会触发，与跳变无关 —— 靠每秒轮询一次才恰好不误发。这里改成
 * |本次系统时间 − (上次系统时间 + 单调经过时间)| > 阈值，判据里只有真正
 * 的偏差，调用间隔多长都不影响。
 *
 * 冻结解除后必须重建基线
 * ----------------------
 * 配对基线（系统时间 ↔ 单调时间）是在跳变发生*之前*记下的。冻结期间
 * now() 直接返回不再更新基线，于是解冻后的第一次 now() 会拿一个陈旧
 * 基线去比，算出的偏差仍然是整跳的那个量级，立刻又判定成跳变 —— 变成
 * 永久冻结。所以 applySync 在采纳同步时一并把基线重记到当前。
 *
 * 时间戳都是参数
 * --------------
 * now() 收系统时间与单调时间，applySync() 收四个 NTP 时间戳加当下的系统
 * 与单调读数。本模块因此不含任何平台调用，能在 Node 测试台里把每一处
 * 边界都钉死 —— 而这几个判据一旦错了，表现是「时间静悄悄地偏」，界面
 * 上完全看不出来。
 */

import { DateTimeValue } from 'common_shared';
import { NtpResponse, ntpDelayMillis, ntpOffsetMillis } from './NtpProtocol';

/**
 * 系统时间跳变的判定阈值（毫秒）。
 *
 * 取 5 秒而不是桌面版的 30 秒：手机的系统自动对时（NITZ）一旦生效就是
 * 几十秒级的跳变，而 5 秒足以滤掉网络时间同步本身的抖动。阈值太大则真正
 * 跳变时用户已经看到高亮乱跳了。
 */
export const SYSTEM_JUMP_THRESHOLD_MS: number = 5000;

/**
 * 同步后可接受的最大往返延迟（毫秒）。
 *
 * 偏差公式 ((T2−T1)+(T3−T4))/2 假定上下行延迟对称。延迟越大这个假定越
 * 不可靠，误差可能到秒级 —— 那还不如用系统时间。所以超过 5 秒的往返直接
 * 丢弃这次结果，等下一次同步。
 */
export const MAX_ACCEPTABLE_DELAY_MS: number = 5000;

/**
 * 同步后倒退多少以内算「测量误差，保持而不是冻结」（毫秒）。
 *
 * 与桌面版的 30 秒一致。这个量级上的倒退几乎不可能是真实的时间变化 ——
 * 真的倒退 30 秒意味着用户在调表，而用户调表会被上面那条系统跳变检测
 * 抓住（系统时间确实变了），走冻结而不是走这里。
 */
export const BACKWARD_HOLD_LIMIT_MS: number = 30000;

/** 一次同步的结果。 */
export interface SyncOutcome {
  /** 是否采纳（false 表示延迟过大或时间戳非法）。 */
  accepted: boolean;
  /** 采纳时的偏差（毫秒），未采纳时为 0。 */
  offsetMillis: number;
  /** 往返延迟（毫秒），未采纳时也可能有值。 */
  delayMillis: number;
  /** 本次同步是否解除了冻结。 */
  releasedFreeze: boolean;
  /** 本次同步是否触发了反向跳保持。 */
  startedHold: boolean;
}

export class ExactClock {
  /** 是否使用 NTP。与桌面版 Settings.IsExactTimeEnabled 同名同义。 */
  private enabled: boolean = false;

  /** 用户手动偏移（秒）。与桌面版 Settings.TimeOffsetSeconds 同名。 */
  private offsetSeconds: number = 0;

  /** NTP 偏差（毫秒）。首次同步成功前为 0。 */
  private ntpOffset: number = 0;

  /** 是否已成功同步过一次。没同步过时 ntpOffset 无意义，用系统时间。 */
  private synced: boolean = false;

  /** 冻结中：检测到系统时间跳变，等外部重新同步。 */
  private frozen: boolean = false;
  private frozenReason: string = '';

  /** 上次返回的时刻（本地纪元毫秒，已含全部偏移）。 */
  private lastReturned: number = 0;

  /** 最近一次读到的系统时间。所有派生都从它算，不再去取真实时间。 */
  private lastSystem: number = 0;

  /** 「系统时间 ↔ 单调时间」的配对基线。valid 为假时下一次 now 重建。 */
  private baselineSystem: number = 0;
  private baselineUptime: number = 0;
  private baselineValid: boolean = false;

  /** 反向跳保持：保持在 holdingAt 之前，等真实时间追上。 */
  private holding: boolean = false;
  private holdingAt: number = 0;

  // ------------------------------------------------------------ 配置

  setEnabled(value: boolean): void {
    if (this.enabled === value) {
      return;
    }
    this.enabled = value;
    // 关掉之后偏差不再有意义：留着会让用户在「关闭精确时间」之后仍然看到
    // 被修正过的时间，而那不是他关掉之后预期的行为。
    if (!value) {
      this.ntpOffset = 0;
      this.synced = false;
      this.holding = false;
    }
    // 基准也重建：启用状态变了之后偏差来源换了，旧的配对基线不再可比。
    this.baselineValid = false;
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  setOffsetSeconds(value: number): void {
    this.offsetSeconds = isFinite(value) ? value : 0;
  }

  offsetSecondsValue(): number {
    return this.offsetSeconds;
  }

  /** 当前生效的 NTP 偏差（毫秒）。没同步过为 0。 */
  ntpOffsetMillis(): number {
    return this.ntpOffset;
  }

  isSynced(): boolean {
    return this.synced;
  }

  isFrozen(): boolean {
    return this.frozen;
  }

  /** 供界面显示的一句状态说明。 */
  statusText(): string {
    if (this.frozen) {
      return '检测到系统时间变化，正在重新校时';
    }
    if (!this.enabled) {
      return '未启用精确时间，使用系统时间';
    }
    if (!this.synced) {
      return '尚未同步时间';
    }
    const seconds: string = (Math.round(this.ntpOffset / 100) / 10).toString();
    return this.ntpOffset >= 0
      ? `已校时，本机慢 ${seconds} 秒`
      : `已校时，本机快 ${Math.abs(Number(seconds))} 秒`;
  }

  // ------------------------------------------------------------ 同步

  /**
   * 采纳一次 NTP 测量。
   *
   * @param t1Millis 我们发出请求的本地纪元毫秒
   * @param response 已通过 parseNtpResponse 校验的响应
   * @param t4Millis 我们收到响应的本地纪元毫秒
   * @param systemMillis 收到响应这一刻的系统时间读数
   * @param uptimeMillis 同一刻的单调时间读数，-1 表示拿不到
   */
  applySync(t1Millis: number, response: NtpResponse, t4Millis: number,
    systemMillis: number, uptimeMillis: number): SyncOutcome {
    const delay: number = ntpDelayMillis(t1Millis, response, t4Millis);
    // 延迟为负说明本地时钟在请求期间往回走过，测量无效。
    const usable: boolean = isFinite(delay) && delay >= 0 && delay <= MAX_ACCEPTABLE_DELAY_MS;
    const offset: number = usable ? ntpOffsetMillis(t1Millis, response, t4Millis) : 0;
    if (!usable || !isFinite(offset)) {
      return { accepted: false, offsetMillis: 0, delayMillis: delay,
        releasedFreeze: false, startedHold: false };
    }

    this.lastSystem = systemMillis;
    this.rebuildBaseline(systemMillis, uptimeMillis);

    const previous: number = this.lastReturned;
    this.ntpOffset = offset;
    this.synced = true;

    // 同步完成即解除冻结 —— 冻结存在的全部意义就是「等一次重新同步」。
    const released: boolean = this.frozen;
    this.frozen = false;
    this.frozenReason = '';

    // 反向跳保持：同步把时间往回拉了一点（小误差），保持住不倒退。
    this.holding = false;
    const base: number = this.baseMillis();
    if (previous > 0 && base < previous && (previous - base) <= BACKWARD_HOLD_LIMIT_MS) {
      this.holding = true;
      this.holdingAt = previous;
    }

    return { accepted: true, offsetMillis: offset, delayMillis: delay,
      releasedFreeze: released, startedHold: this.holding };
  }

  // ------------------------------------------------------------ 取时间

  /**
   * 当前时刻。
   *
   * @param systemMillis 系统时间（Date.now()）
   * @param uptimeMillis 单调时间（systemDateTime.getUptime(STARTUP)）。
   *        传 -1 表示拿不到，此时不做跳变检测。
   */
  now(systemMillis: number, uptimeMillis: number): DateTimeValue {
    this.lastSystem = systemMillis;

    if (this.frozen) {
      return DateTimeValue.fromLocalMillis(this.lastReturned);
    }
    if (this.enabled && this.detectSystemJump(systemMillis, uptimeMillis)) {
      return DateTimeValue.fromLocalMillis(this.lastReturned);
    }

    const base: number = this.baseMillis();

    // 反向跳保持：真实时间追上 holdingAt 之前一直保持。
    if (this.holding) {
      if (base < this.holdingAt) {
        return DateTimeValue.fromLocalMillis(this.lastReturned);
      }
      this.holding = false;
    }

    this.lastReturned = base + Math.round(this.offsetSeconds * 1000);
    return DateTimeValue.fromLocalMillis(this.lastReturned);
  }

  /**
   * 无手动偏移、无防护的裸基准时刻。
   *
   * 系统时间 + NTP 偏差（没同步过或没启用就只是系统时间）。手动偏移不加
   * 在这里 —— 那是用户的表达偏好，不是「现在几点」。
   */
  private baseMillis(): number {
    if (this.enabled && this.synced) {
      return this.lastSystem + this.ntpOffset;
    }
    return this.lastSystem;
  }

  /**
   * 系统时间跳变检测。返回 true 表示刚检测到跳变并转入冻结。
   *
   * 判据：本次系统时间与「上次系统时间 + 单调经过时间」之差超过阈值。
   * 拿不到单调时间（uptimeMillis < 0）时不判 —— 把「检测手段不可用」
   * 当成「检测到跳变」会让时钟在某些设备上永久冻结。
   */
  private detectSystemJump(systemMillis: number, uptimeMillis: number): boolean {
    // 本次拿不到单调时钟就不判，并把基线作废。
    //
    // 作废是必须的：留着旧基线，下次单调时钟一恢复就会拿它跟一个跨越了
    // 整段「无单调」期间的读数去比，差值里混进了真实流逝的时间，必然超阈值
    // —— 于是第一次恢复就误判成跳变。反过来若把 -1 写进基线（下面第二个
    // 分支之外的情形），expected 会算成天文数字，同样立刻误判。
    if (uptimeMillis < 0) {
      this.baselineValid = false;
      return false;
    }
    if (!this.baselineValid) {
      this.rebuildBaseline(systemMillis, uptimeMillis);
      return false;
    }
    const expected: number = this.baselineSystem + (uptimeMillis - this.baselineUptime);
    const drift: number = systemMillis - expected;
    this.baselineSystem = systemMillis;
    this.baselineUptime = uptimeMillis;
    if (Math.abs(drift) > SYSTEM_JUMP_THRESHOLD_MS) {
      this.frozen = true;
      this.frozenReason = '系统时间被修改';
      return true;
    }
    return false;
  }

  /** 记录当前配对基线。uptime < 0 时标记为无效，下次 now 重建。 */
  private rebuildBaseline(systemMillis: number, uptimeMillis: number): void {
    this.baselineSystem = systemMillis;
    this.baselineUptime = uptimeMillis;
    this.baselineValid = uptimeMillis >= 0;
  }

  // ------------------------------------------------------------ 测试与预览

  /** 直接设定 NTP 偏差，跳过网络。测试与「手动校时」用。 */
  forceOffsetMillis(value: number): void {
    this.ntpOffset = value;
    this.synced = true;
  }

  /** 解除冻结（例如外部已重新同步但偏差没变化）。 */
  releaseFreeze(): void {
    this.frozen = false;
    this.frozenReason = '';
    this.baselineValid = false;
  }
}
