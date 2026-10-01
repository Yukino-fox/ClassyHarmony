/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 朗读服务：把「什么时候念、念什么、用哪个引擎」接起来。
 *
 * 职责边界
 * --------
 * 队列语义（跳过作废项、不重排、单消费者）全在 common_core 的 SpeechQueue，
 * 那边有 195 条用例在盯。这里只负责三件事：
 *   - 从设置里读出「开没开、用哪个提供方、音量多少」；
 *   - 驱动队列循环（core 只做决定，等待与 I/O 必须在这一层）；
 *   - 把「一条通知被展示了」这个事件翻译成一次入队。
 * 本文件没有一行算法。
 *
 * 必须是进程内单例
 * --------------
 * 队列、`playing` 标记、正在念的那一项，都是跨调用状态。做成多份的后果是
 * 同一句话被两个循环各念一遍（两段声音叠在一起），而且「清空队列」只能清掉
 * 自己那一份。所以走模块级实例，与 ExactTimeService 同一个路子。
 *
 * 与桌面版的一处刻意分歧：不清队列
 * ------------------------------
 * 桌面版在提醒播完时调 `SpeechService.ClearSpeechQueue()`（NotificationWorker
 * Service.cs:215）。它清得起，因为桌面版的提醒是「显示 5~10 秒然后消失」的
 * 遮罩/横幅，提醒没了语音也就没有意义了。
 *
 * 鸿蒙侧的通知是**发出去就留在通知栏**，没有「播完」这个时刻可以挂钩（要挂
 * 得监听通知被划掉，那需要一套常驻的监听服务，见 P11e）。既然挂不上，就干脆
 * 不清：队列是先进先出的，一句接一句念完，顺序与课表顺序一致。代价是一次性
 * 触发很多条时会堆积，但那本来就不该发生（提醒是每节课一次）。
 *
 * 音量
 * ----
 * 系统 TTS 没有逐条音量：`speak()` 的参数里没有音量，`AudioVolumeManager`
 * 那条路要 `ACCESS_NOTIFICATION_POLICY` 且自 API 9 起废弃。所以 `SpeechVolume`
 * 照常读、照常落盘（跨端一致性），但不作用于系统 TTS —— 设置页里如实写明
 * 「音量跟随系统媒体音量」。等 GPT-SoVITS 那边自己接音频渲染器时，音量才
 * 有处可用。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  DEFAULT_SPEECH_PROVIDER,
  SPEECH_PROVIDER_SYSTEM,
  SpeechItem,
  SpeechItemState,
  SpeechQueue,
  SpeechResolution,
  SpeechStep,
  SpeechStepKind,
  findSpeechProvider,
  implementedSpeechProviders,
  resolveSpeechProvider,
  shouldSpeakNotification,
  speechProviderName
} from 'common_core';
import { AppPreferences, PrefKeys, DEFAULT_SPEECH_ENABLED, DEFAULT_ALLOW_NOTIFICATION_SPEECH }
  from '../common/AppPreferences';
import { SystemSpeechService, isSystemSpeechSupported } from './SystemSpeechService';

const DOMAIN: number = 0x0000;
const TAG: string = 'SpeechService';

let instance: SpeechService | undefined = undefined;

/**
 * 取进程内唯一的朗读服务，首次调用时装配。
 *
 * @param context UIAbility 的 context。用它的 cacheDir 当合成音频的落点
 *        （将来接文件型提供方时用得上），也是 AppPreferences 的落点。
 */
export function resolveSpeechService(context: common.UIAbilityContext): SpeechService {
  if (instance !== undefined) {
    return instance;
  }
  instance = new SpeechService(context);
  return instance;
}

/** 丢掉单例。应用退出时调用（释放系统 TTS 引擎）。 */
export function shutdownSpeechService(): void {
  if (instance !== undefined) {
    instance.dispose();
    instance = undefined;
  }
}

export class SpeechService {
  private readonly prefs: AppPreferences;
  private readonly cacheDir: string;
  private readonly systemSpeech: SystemSpeechService = new SystemSpeechService();
  private readonly queue: SpeechQueue = new SpeechQueue();
  /** 单消费者守卫。见 pump() 的头注。 */
  private playing: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.prefs = new AppPreferences(context);
    this.cacheDir = context.cacheDir;
  }

  // ------------------------------------------------------------ 设置读取

  /** 全局开关。桌面版默认 true。 */
  isEnabled(): boolean {
    return this.prefs.getBoolean(PrefKeys.SPEECH_ENABLED, DEFAULT_SPEECH_ENABLED);
  }

  /** 「允许通知朗读」。桌面版默认 **false**，即朗读是 opt-in。 */
  allowNotificationSpeech(): boolean {
    return this.prefs.getBoolean(PrefKeys.ALLOW_NOTIFICATION_SPEECH,
      DEFAULT_ALLOW_NOTIFICATION_SPEECH);
  }

  /** 设置里选的提供方 id（可能是本端没有实现的）。 */
  selectedProviderId(): string {
    return this.prefs.getString(PrefKeys.SELECTED_SPEECH_PROVIDER, DEFAULT_SPEECH_PROVIDER);
  }

  /** 当前音色（系统 TTS 的 person）。 */
  systemPerson(): number {
    return this.systemSpeech.getPerson();
  }

  /** 换音色。立即作用于下一次朗读。 */
  setSystemPerson(person: number): void {
    this.systemSpeech.setPerson(person);
  }

  /**
   * 本刻可用的提供方。
   *
   * 两道筛：本端实现了（编译期事实，写在 core 的表里），且设备具备该能力
   * （运行时查询）。分开是因为两者的补救方式不同 —— 前者要写代码，后者要
   * 用户在系统里装语音包。
   */
  availableProviderIds(): string[] {
    const out: string[] = [];
    const implemented: string[] = implementedSpeechProviders();
    for (let i: number = 0; i < implemented.length; i++) {
      const id: string = implemented[i];
      if (id === SPEECH_PROVIDER_SYSTEM && !isSystemSpeechSupported()) {
        continue;
      }
      out.push(id);
    }
    return out;
  }

  /** 实际会用的提供方（含回退）。 */
  resolution(): SpeechResolution {
    return resolveSpeechProvider(this.selectedProviderId(), this.availableProviderIds());
  }

  /**
   * 一行状态文本，给设置页显示。
   *
   * 把「回退」说出来是有意的：用户在桌面上把提供方设成 EdgeTTS，同步过来之后
   * 鸿蒙侧用的是系统 TTS。不说的话，用户会以为 EdgeTTS 在鸿蒙上也能用，下次
   * 在手机上改音色自然也就不会生效，而他找不到原因。
   */
  statusText(): string {
    if (!this.isEnabled()) {
      return '语音已关闭';
    }
    const selected: string = this.selectedProviderId();
    const resolved: SpeechResolution = this.resolution();
    if (resolved.providerId.length === 0) {
      const info = findSpeechProvider(selected);
      if (info !== undefined && !info.implemented) {
        return `不可用：${info.displayName} 在本设备上尚未实现，且没有可回退的引擎`;
      }
      return `不可用：${speechProviderName(selected)} 在本设备上不可用`;
    }
    const name: string = speechProviderName(resolved.providerId);
    if (!resolved.fellBack) {
      return `当前：${name}`;
    }
    return `当前：${name}（所选的 ${speechProviderName(selected)} 在本设备上不可用，已回退）`;
  }

  // ------------------------------------------------------------ 入队

  /**
   * 入队一段要念的文本。不做任何开关判断 —— 判断在 notifyShown / 调用方。
   *
   * 提供方不可用时静默丢弃：这不是错误，是这台设备没有语音能力。丢在入队处
   * 而不是等到播放时，是为了不让队列里堆着一串永远不会被念的项（那样
   * `statusText` 与实际行为会对不上）。
   */
  enqueue(text: string): void {
    if (text.trim().length === 0) {
      return;
    }
    const resolved: SpeechResolution = this.resolution();
    if (resolved.providerId.length === 0) {
      hilog.debug(DOMAIN, TAG, 'no provider available, dropping speech');
      return;
    }
    // 系统 TTS 直接发声，没有中间文件，所以入队就是「已就绪」。文件型提供方
    // （EdgeTTS / GPT-SoVITS）在这里算缓存路径并标成未就绪，由 pump 的 Wait
    // 分支去合成 —— 那两条路径尚未实现，见 SpeechProviders 的 implemented。
    const item: SpeechItem = this.queue.enqueue(text, '', true);
    hilog.info(DOMAIN, TAG, 'enqueued speech id=%{public}d len=%{public}d',
      item.id, text.length);
    void this.pump();
  }

  /**
   * 一条通知被展示时的入口。
   *
   * 三个开关的与，与桌面版 NotificationWorkerService.cs:178 完全一致：
   * 全局开关（用户明确说了要不要说话）、内容自己的开关（这一条通知是否允许
   * 朗读）、以及「允许通知朗读」总开关（桌面版默认关）。
   */
  notifyShown(contentSpeechEnabled: boolean, speechText: string): void {
    if (!shouldSpeakNotification(this.isEnabled(), contentSpeechEnabled,
      this.allowNotificationSpeech())) {
      return;
    }
    this.enqueue(speechText);
  }

  // ------------------------------------------------------------ 队列控制

  /** 清空队列并停止当前朗读。 */
  clearQueue(): void {
    this.queue.cancelAll();
    this.systemSpeech.stop();
  }

  /** 队列里还有几项（含正在念的）。 */
  pendingCount(): number {
    return this.queue.size();
  }

  isSpeaking(): boolean {
    return this.systemSpeech.isSpeaking();
  }

  /**
   * 立即念一句，不等队列。给设置页的「试听」用。
   *
   * 不看全局开关：用户正在试听，就是要听 —— 让他先打开开关再试听，只会让
   * 「试听没反应」变成一个需要解释的状态。但仍受提供方可用性约束，不可能
   * 靠试听绕过「这台设备没有语音引擎」这个事实。
   *
   * @returns 空串表示成功，否则是失败原因。
   */
  async trySpeakNow(text: string): Promise<string> {
    const resolved: SpeechResolution = this.resolution();
    if (resolved.providerId.length === 0) {
      return '本设备没有可用的语音引擎';
    }
    this.systemSpeech.resetAvailability();
    const outcome = await this.systemSpeech.speak(text);
    return outcome.ok ? '' : outcome.detail;
  }

  /** 释放引擎。应用退出时调用。 */
  dispose(): void {
    this.clearQueue();
    this.systemSpeech.shutdown();
  }

  // ------------------------------------------------------------ 队列循环

  /**
   * 队列的单消费者循环。
   *
   * `playing` 是重入守卫：`enqueue` 每次都调 pump，但同一时刻只能有一个循环
   * 在跑。没有它的话，两条通知同时到达会各自起一个循环，两边都从 `advance()`
   * 拿到队首那一项，于是同一句话被念两遍、且第二遍拿的是同一个 id。
   *
   * 循环体只做三件事：拿决定、执行决定、了结那一项。所有排序/跳过/取消的
   * 判断都在 core 的 `advance()` 里。
   */
  private async pump(): Promise<void> {
    if (this.playing) {
      return;
    }
    this.playing = true;
    try {
      for (;;) {
        const step: SpeechStep = this.queue.advance();
        if (step.kind === SpeechStepKind.Idle) {
          break;
        }
        const item: SpeechItem | undefined = step.item;
        if (item === undefined) {
          break;
        }
        if (step.kind === SpeechStepKind.Wait) {
          // 文件型提供方的合成阶段。系统 TTS 永远不会走到这里（入队即就绪），
          // 但队列的形状要留住 —— 接 GPT-SoVITS 时只需填这个分支。
          const ready: boolean = await this.ensureReady(item);
          this.queue.markState(item.id, ready ? SpeechItemState.Ready : SpeechItemState.Failed);
          continue;
        }
        await this.playOne(item);
        this.queue.complete(item.id);
      }
    } finally {
      this.playing = false;
    }
    /*
     * 收尾再确认一次。
     *
     * 上面的循环判定 Idle 之后、`playing` 置回 false 之前，有一小段窗口：那时
     * 若有人入队，`enqueue` 里的 `pump()` 看到 `playing === true` 会直接返回。
     * 不补这一下，那一项就永远躺在队列里，直到下次有人入队才被顺带念出来 ——
     * 表现为「提醒偶尔慢一拍 / 不响」。
     */
    if (!this.queue.isEmpty()) {
      void this.pump();
    }
  }

  /**
   * 保证音频已就绪（文件型提供方的合成阶段）。
   *
   * 现在是 `true`：系统 TTS 不需要中间文件。留成方法而不是直接写 `true`，
   * 是为了让将来加提供方时改动落在一个明确的位置，而不是在循环体里加分支。
   */
  private async ensureReady(item: SpeechItem): Promise<boolean> {
    return true;
  }

  /**
   * 念一项。
   *
   * 无论成功失败都把那一项了结掉（由调用方 `complete`）：一次失败的朗读不该
   * 让队列停在原地。失败只记日志 —— 语音是增强能力，它坏了不该影响课表。
   */
  private async playOne(item: SpeechItem): Promise<void> {
    const outcome = await this.systemSpeech.speak(item.text);
    if (!outcome.ok) {
      hilog.warn(DOMAIN, TAG, 'speak failed id=%{public}d: %{public}s',
        item.id, outcome.detail);
    }
  }
}
