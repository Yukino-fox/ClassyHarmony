/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 系统 TTS：CoreSpeechKit 的封装。
 *
 * 模块名
 * ------
 * 计划书里写的是 `@kit.SpeechToolKit`，**这个模块不存在**。SDK 里能用的只有两个：
 *   - `@kit.CoreSpeechKit`（HMS，re-export `@hms.ai.textToSpeech`）—— 本文件用这个；
 *   - `@kit.SpeechKit`（面向语音识别/语音朗读的另一套，接口形状不同）。
 * 另外 `sdk/default/openharmony/ets/api/` 下的 47 个 kit 里没有任何 TTS。
 * 所以 TTS 是**系统自带能力**，不是 OpenHarmony 基础能力 —— 设备上没有对应的
 * 系统能力时 `canIUse` 返回 false，调用方要按「不发声」处理而不是崩掉。
 *
 * 与桌面版的关系
 * ------------
 * 桌面版的 `classisland.speech.system` 是 Windows 的 System.Speech.Synthesis，
 * 这边是鸿蒙的 CoreSpeechKit，两者的共同点只有「用系统自带的语音引擎」。
 * 苹果那边是 AVSpeechSynthesizer，Windows 是 SAPI —— 这一类提供方本来就是
 * 「各平台各有一份」，所以这里不追求与桌面版的行为逐条对齐。
 *
 * 为什么不接 onData 自己放
 * ----------------------
 * `SpeakListener.onData` 是存在的（可选，给了原始音频流），接上它就能自己
 * 接音频渲染器、从而控制音量。不这么做，因为这会把「播放」这件本来由系统
 * 负责的事搬到应用里：要处理重采样、音频焦点、后台播放、与来电/其它应用的
 * 争抢 —— 每一条都比「音量不可调」严重。代价是音量只能跟随系统媒体音量，
 * 设置页里如实写明这一点。
 *
 * 引擎的创建与回收
 * --------------
 * `createEngine` 是异步的，且**最多只能存在三个实例**（全设备范围内）。所以：
 *   - 惰性创建，第一次要说话时才建，避免「用户从没开过语音却在启动阶段占了
 *     一个实例名额」；
 *   - 同一时刻只有一个创建在飞（`creating` 记住那个 Promise），并发调用不会
 *     各建一个；
 *   - `person`（音色）变了要把旧引擎 shutdown 掉再重建 —— 音色是创建参数，
 *     改不了；不重建的话设置页上改音色要等下次冷启动才生效。
 *
 * 后台播放
 * -------
 * 创建参数里带了 `isBackStage: true`。不带的默认行为是「退到后台就停」，而
 * 课前一分钟提醒恰恰最可能发生在应用不在前台的时候 —— 那正是它该起作用的时候。
 */

import { textToSpeech } from '@kit.CoreSpeechKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'SystemSpeech';

/**
 * 系统能力名。从 `@hms.ai.textToSpeech.d.ts` 的 `@syscap` 抄来。
 *
 * 拼错一个字符返回的就是 false，表现是「TTS 永远静默」且没有任何报错 ——
 * 所以这个字符串不要手打第二遍。
 */
const TTS_SYSCAP: string = 'SystemCapability.AI.TextToSpeech';

/** 引擎语言。中文用 `zh-CN`（`zh_CN` 也认，但推荐写法是前者）。 */
const ENGINE_LANGUAGE: string = 'zh-CN';

/**
 * 引擎模式。文档写的是「0 在线模式，当前不支持；1 离线模式，支持」。
 *
 * 取 1。在线模式既然不支持，取 0 的表现是创建失败或退化成离线 —— 与其猜，
 * 不如直接用文档说支持的那个。
 */
const ENGINE_OFFLINE: number = 1;

/** 女声（凌晓山），推荐值，无需额外下载。 */
export const PERSON_FEMALE: number = 13;
/** 男声（凌飞哲），需要下载语音包。 */
export const PERSON_MALE: number = 21;

/**
 * 单次朗读的看门狗基准（毫秒）。
 *
 * 为什么要有看门狗：`speak()` 是「没返回值、靠回调告诉你完了」的接口。回调
 * 不来（引擎内部卡死、被系统回收）时，等待方会永远挂着，而朗读服务是一个
 * 串行队列 —— 队首永远挂着就意味着**整个语音功能从此不再出声**，且没有任何
 * 报错。宁可把一次朗读判失败、丢进队列的跳过逻辑，也不要让队列永久卡住。
 *
 * 基准 30 秒 + 每字 0.5 秒，上限 5 分钟。一条课前提醒（二十来个字）大概 40 秒
 * 的额度，正常朗读只要几秒，够宽松。
 */
const WATCHDOG_BASE_MS: number = 30000;
const WATCHDOG_PER_CHAR_MS: number = 500;
const WATCHDOG_MAX_MS: number = 300000;

/** 单条文本的长度上限。文档写的是 10000 字。 */
const MAX_TEXT_LENGTH: number = 10000;

/** 一次朗读的结果。 */
export interface SpeakOutcome {
  ok: boolean;
  /** 失败原因（给日志与设置页的「试听」用），成功时为空串。 */
  detail: string;
}

/**
 * 设备是否具备系统 TTS 能力。
 *
 * `canIUse` 是同步的，不抛异常。用单独的函数而不是把它藏在类里：调用方
 * （SpeechService 的可用性列表、设置页的灰显）需要在**不创建引擎**的前提下
 * 知道这件事 —— 创建一个引擎只为了问一句「你能不能说话」会占掉三个实例名额
 * 之一。
 */
export function isSystemSpeechSupported(): boolean {
  try {
    return canIUse(TTS_SYSCAP);
  } catch {
    return false;
  }
}

export class SystemSpeechService {
  private engine: textToSpeech.TextToSpeechEngine | undefined = undefined;
  private creating: Promise<textToSpeech.TextToSpeechEngine | undefined> | undefined = undefined;
  /** 当前音色。变了要重建引擎。 */
  private person: number = PERSON_FEMALE;

  /** 正在等结果的那次朗读的 requestId；空串表示没有。 */
  private pendingId: string = '';
  private pendingResolve: ((outcome: SpeakOutcome) => void) | undefined = undefined;
  private watchdog: number | undefined = undefined;
  private counter: number = 0;

  /** 已经因为连不上/建不起来而放弃过，不再每次朗读都重试一遍。 */
  private engineUnavailable: boolean = false;

  /**
   * 回调。只建一次并在引擎创建后 setListener。
   *
   * 注意 `onStart` 什么都不做：它只报告采样率/位深之类的播放参数，我们没有
   * 用到的地方。留空实现而不是省掉 —— `onStart` 是必填成员。
   */
  private readonly listener: textToSpeech.SpeakListener = {
    onStart: (requestId: string, response: textToSpeech.StartResponse): void => {
      hilog.debug(DOMAIN, TAG, 'speak start %{public}s', requestId);
    },
    onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
      this.finish(requestId, { ok: true, detail: '' });
    },
    onStop: (requestId: string, response: textToSpeech.StopResponse): void => {
      this.finish(requestId, { ok: false, detail: '已停止' });
    },
    onError: (requestId: string, errorCode: number, errorMessage: string): void => {
      this.finish(requestId, { ok: false, detail: `${errorCode} ${errorMessage}` });
    }
  };

  /** 当前音色。 */
  getPerson(): number {
    return this.person;
  }

  /**
   * 换音色。音色是引擎的创建参数，改不了，所以要丢掉旧引擎。
   *
   * 丢掉之后不立刻重建：下一次 `speak` 会惰性重建。立刻重建的话，用户在设置页
   * 上把音色从 13 拖到 21 又拖回 13，就会白建两个引擎（名额一共三个）。
   */
  setPerson(person: number): void {
    if (person === this.person) {
      return;
    }
    this.person = person;
    this.shutdownEngine();
    this.engineUnavailable = false;
  }

  /**
   * 朗读一段文本，等它播完。
   *
   * 永不抛异常：所有失败都收进返回值的 `detail`。理由是调用方是一个队列循环，
   * 一次失败只该让这一项被跳过，不该把整个循环打断 —— 一个异常穿出去会让
   * 队列永久停在 `playing` 状态（见 SpeechService 的 pump）。
   */
  async speak(text: string): Promise<SpeakOutcome> {
    const trimmed: string = text.length > MAX_TEXT_LENGTH
      ? text.substring(0, MAX_TEXT_LENGTH) : text;
    // 空文本直接当成功：引擎会以「文本为空」报错（1002300001），而「没什么
    // 可念的」本来就该是静默的成功，不该在日志里留下一条错误。
    if (trimmed.trim().length === 0) {
      return { ok: true, detail: '' };
    }
    if (this.engineUnavailable) {
      return { ok: false, detail: '系统语音引擎不可用' };
    }

    const engine: textToSpeech.TextToSpeechEngine | undefined = await this.ensureEngine();
    if (engine === undefined) {
      return { ok: false, detail: '系统语音引擎创建失败' };
    }

    const requestId: string = `classy${this.counter++}`;
    return new Promise<SpeakOutcome>((resolve: (outcome: SpeakOutcome) => void) => {
      this.pendingId = requestId;
      this.pendingResolve = resolve;
      this.watchdog = setTimeout((): void => {
        // 超时：先真的停一下引擎，再判失败。只判失败不停的话，引擎还在念，
        // 下一项又调 speak()，两段声音会叠在一起。
        hilog.warn(DOMAIN, TAG, 'speak watchdog fired %{public}s', requestId);
        this.stopEngine();
        this.finish(requestId, { ok: false, detail: '朗读超时' });
      }, this.watchdogFor(trimmed));

      try {
        const params: textToSpeech.SpeakParams = { requestId: requestId };
        engine.speak(trimmed, params);
      } catch (err) {
        // 同步抛出（401 参数错 / 1002300001 文本为空或过长）。这里只可能是
        // 前几项已经排除掉的情形，以及引擎已经处于坏状态。收进 detail。
        this.finish(requestId, { ok: false, detail: `${err}` });
      }
    });
  }

  /**
   * 停止当前朗读。
   *
   * 主动把等待方叫醒，而不是等引擎的 `onStop` 回调：那个回调不保证会来
   * （比如引擎已经处于异常状态），而不来的后果是队列永久卡在队首。回调真
   * 来了也安全 —— `finish` 按 requestId 过滤，第二次是个空操作。
   */
  stop(): void {
    const id: string = this.pendingId;
    this.stopEngine();
    if (id.length > 0) {
      this.finish(id, { ok: false, detail: '已停止' });
    }
  }

  /** 是否正在朗读。 */
  isSpeaking(): boolean {
    return this.pendingId.length > 0;
  }

  /**
   * 释放引擎。应用退出时调用。
   *
   * 不释放的话引擎占着一个实例名额（全设备三个），而且后台播放会让进程
   * 晚一点才能被回收。
   */
  shutdown(): void {
    this.stop();
    this.shutdownEngine();
  }

  // ------------------------------------------------------------ 内部

  private watchdogFor(text: string): number {
    const budget: number = WATCHDOG_BASE_MS + text.length * WATCHDOG_PER_CHAR_MS;
    return budget > WATCHDOG_MAX_MS ? WATCHDOG_MAX_MS : budget;
  }

  private finish(requestId: string, outcome: SpeakOutcome): void {
    // 过期的回调：requestId 已经换了一轮（超时后又被 stop，或新的朗读已经开始）。
    if (this.pendingId !== requestId) {
      return;
    }
    this.pendingId = '';
    if (this.watchdog !== undefined) {
      clearTimeout(this.watchdog);
      this.watchdog = undefined;
    }
    const resolve: ((outcome: SpeakOutcome) => void) | undefined = this.pendingResolve;
    this.pendingResolve = undefined;
    if (resolve !== undefined) {
      resolve(outcome);
    }
  }

  /**
   * 建引擎（如果还没有）。
   *
   * 失败之后置 `engineUnavailable`，之后不再重试。重试的代价是每次朗读都做
   * 一次几十毫秒的异步创建再失败，而成功率为零 —— 设备的能力不会在使用中途
   * 长出来。真长出来了（用户装了语音包）由设置页的「试听」按钮触发
   * `resetAvailability()`。
   */
  private async ensureEngine(): Promise<textToSpeech.TextToSpeechEngine | undefined> {
    if (this.engine !== undefined) {
      return this.engine;
    }
    if (!isSystemSpeechSupported()) {
      this.engineUnavailable = true;
      return undefined;
    }
    if (this.creating !== undefined) {
      return this.creating;
    }
    this.creating = this.createEngine();
    const engine: textToSpeech.TextToSpeechEngine | undefined = await this.creating;
    this.creating = undefined;
    return engine;
  }

  private async createEngine(): Promise<textToSpeech.TextToSpeechEngine | undefined> {
    try {
      const extra: Record<string, Object> = {};
      // 退到后台继续念。课前提醒最可能在应用不在前台时触发。
      extra['isBackStage'] = true;
      const params: textToSpeech.CreateEngineParams = {
        language: ENGINE_LANGUAGE,
        person: this.person,
        online: ENGINE_OFFLINE,
        extraParams: extra
      };
      const engine: textToSpeech.TextToSpeechEngine = await textToSpeech.createEngine(params);
      engine.setListener(this.listener);
      this.engine = engine;
      this.engineUnavailable = false;
      hilog.info(DOMAIN, TAG, 'engine created, person=%{public}d', this.person);
      return engine;
    } catch (err) {
      // 1002300002 语言不支持 / 1002300003 音色不支持 / 1002300005 创建失败。
      // 三种都不该让应用崩：语音是一个增强能力，没有它课表照常工作。
      hilog.error(DOMAIN, TAG, 'createEngine failed: %{public}s', `${err}`);
      this.engineUnavailable = true;
      return undefined;
    }
  }

  private stopEngine(): void {
    if (this.engine === undefined) {
      return;
    }
    try {
      this.engine.stop();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'engine.stop failed: %{public}s', `${err}`);
    }
  }

  private shutdownEngine(): void {
    if (this.engine === undefined) {
      return;
    }
    try {
      this.engine.shutdown();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'engine.shutdown failed: %{public}s', `${err}`);
    }
    this.engine = undefined;
  }

  /**
   * 清掉「引擎不可用」的判断，让它下次重新试一遍。
   *
   * 只给设置页的「试听」用：用户在系统设置里装了语音包之后，需要一个不用
   * 重启应用的入口让它生效。
   */
  resetAvailability(): void {
    this.engineUnavailable = false;
    this.shutdownEngine();
  }
}
