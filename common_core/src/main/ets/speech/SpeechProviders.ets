/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 语音提供方目录与选择。
 *
 * 这一层存在的意义：桌面版的语音提供方是插件（`[SpeechProviderInfo]` 特性 +
 * 依赖注入的按名解析），鸿蒙侧没有插件容器，用一张表代替。表在这里而不是
 * 在 entry，是为了让「同一个 settings.json 在两端都打得开」这件事可测：
 * 选择逻辑是纯函数，能拿一堆可用性组合去撞。
 *
 * 与桌面版的一处刻意分歧
 * --------------------
 * 桌面版解析不到提供方时给的是 BlankSpeechService —— 也就是**静默**，不发声
 * 也不提示。原因很实际：那边的默认值是 `classisland.speech.edgeTts`，而在
 * Linux / macOS 上 EdgeTTS 是可用插件，在 Windows 上系统 TTS 也可用，所以
 * 「解析不到」只可能是用户手改坏了配置，静默是合理的降级。
 *
 * 鸿蒙侧不同：EdgeTTS 需要复刻微软的 WebSocket 合成协议（含 Sec-MS-GEC
 * 令牌），本阶段没有移植；系统 TTS 则是平台自带、开箱可用。于是「照抄默认值
 * 就会永远没声音」——用户什么都没做错，只是那份配置是在桌面上写的。
 *
 * 所以这里多一跳：请求的提供方不可用时回退到系统 TTS（若系统 TTS 也不可用
 * 才静默），并把「发生了回退」显式返回给调用方，让设置页能把它写出来。静默
 * 是最后的兜底，而不是第一反应 —— 一个不发声的提醒和一个没有提醒，对用户来
 * 说是同一件事，不该由一个跨端同步过来的字符串来决定。
 */

/** 系统 TTS。桌面版对应 `classisland.speech.system`（Windows 的 System.Speech）。 */
export const SPEECH_PROVIDER_SYSTEM: string = 'classisland.speech.system';

/** EdgeTTS。桌面版对应 `classisland.speech.edgeTts`。本端未移植。 */
export const SPEECH_PROVIDER_EDGE_TTS: string = 'classisland.speech.edgeTts';

/** GPT-SoVITS。桌面版对应 `classisland.speech.gpt-sovits`，走自建服务器。 */
export const SPEECH_PROVIDER_GPT_SOVITS: string = 'classisland.speech.gpt-sovits';

/**
 * 默认提供方。
 *
 * 值与桌面版 Settings.cs 第 1847 行逐字一致。不要在鸿蒙侧改成本端的首选
 * （系统 TTS）：这个键是跨端读写的，改了之后用户在桌面上存的偏好会被覆盖掉，
 * 而这属于「两端默认值不同」里最难发现的一类 —— 用户只会觉得「桌面版上设好
 * 的语音，到手机上就变了」。回退交给 resolveSpeechProvider 做。
 */
export const DEFAULT_SPEECH_PROVIDER: string = SPEECH_PROVIDER_EDGE_TTS;

/** 音量的合法范围。桌面版 SpeechVolume 是 double，放给用户的是 0~1。 */
export const SPEECH_VOLUME_MIN: number = 0;
export const SPEECH_VOLUME_MAX: number = 1;

/** EdgeTTS 的默认音色。与桌面版同一常量，回退时才用得到。 */
export const DEFAULT_EDGE_TTS_VOICE: string = 'zh-CN-XiaoxiaoNeural';

/** 一个提供方的静态信息。 */
export interface SpeechProviderInfo {
  id: string;
  displayName: string;
  /**
   * 本端是否有实现。
   *
   * 与「此刻是否可用」不是一回事：系统 TTS 实现了，但设备上没有对应的语音
   * 能力时仍然发不出声。前者是编译期的事实（写死在这里），后者要看运行时，
   * 由 entry 侧按系统能力查询给出。
   *
   * 本阶段只有系统 TTS 是 `true`。另外两个各差一大块：
   *   - EdgeTTS 要复刻微软的 WebSocket 合成协议（含 Sec-MS-GEC 令牌，且随时
   *     可能被对方改）；
   *   - GPT-SoVITS 要 HTTP 取 WAV 再自己接音频渲染器播放。
   * 两者都不是「接一个 SDK」的量，且都无法在本机验证（前者依赖微软服务，
   * 后者依赖用户自建服务器）。写成 `true` 会让设置页把一个走不通的选项显示
   * 成正常，所以这里是 `false` —— 界面上会注明「本设备暂不支持」。
   */
  implemented: boolean;
  /** 缓存子目录名。与桌面版 Path.Combine(AppCacheFolderPath, X) 的 X 一致。 */
  cacheFolder: string;
  /** 缓存文件后缀，含点。桌面版 EdgeTTS 无后缀，GPT-SoVITS 是 .wav。 */
  cacheExtension: string;
}

/**
 * 全部提供方。
 *
 * 顺序即设置页里的展示顺序。把系统 TTS 放前面：它是本端唯一能用的，
 * 用户最可能选它，而这个列表是「循环切换」式的，排在前面意味着少点几下。
 */
export const SPEECH_PROVIDERS: SpeechProviderInfo[] = [
  {
    id: SPEECH_PROVIDER_SYSTEM,
    displayName: '系统 TTS',
    implemented: true,
    cacheFolder: 'SystemTTS',
    cacheExtension: ''
  },
  {
    id: SPEECH_PROVIDER_GPT_SOVITS,
    displayName: 'GPT-SoVITS',
    implemented: false,
    cacheFolder: 'GPTSoVITS',
    cacheExtension: '.wav'
  },
  {
    id: SPEECH_PROVIDER_EDGE_TTS,
    displayName: 'EdgeTTS',
    implemented: false,
    cacheFolder: 'EdgeTTS',
    cacheExtension: ''
  }
];

/** 按 id 查提供方信息。查不到返回 undefined —— 允许配置文件里留着别的插件 id。 */
export function findSpeechProvider(id: string): SpeechProviderInfo | undefined {
  for (let i: number = 0; i < SPEECH_PROVIDERS.length; i++) {
    if (SPEECH_PROVIDERS[i].id === id) {
      return SPEECH_PROVIDERS[i];
    }
  }
  return undefined;
}

/** 提供方的显示名。查不到时原样返回 id，好让用户看到是哪个字符串没解析出来。 */
export function speechProviderName(id: string): string {
  const found: SpeechProviderInfo | undefined = findSpeechProvider(id);
  return found === undefined ? id : found.displayName;
}

/** 解析结果。 */
export interface SpeechResolution {
  /** 最终使用的提供方 id。为空串表示只能静默。 */
  providerId: string;
  /** 请求的那个是否被换掉了。设置页据此提示用户。 */
  fellBack: boolean;
}

/**
 * 从「请求的提供方」与「本刻可用的提供方」算出实际要用的那个。
 *
 * 三分支：
 *   1. 请求的可用 → 用它，不回退；
 *   2. 请求的不可用，但系统 TTS 可用 → 回退到系统 TTS，标记 fellBack；
 *   3. 都不可用 → 空串，静默。
 *
 * 只回退到系统 TTS，不回退到其它实现：系统 TTS 是平台自带的兜底，语义上
 * 「能出声」比「用哪个引擎出声」重要。若哪天本端实现了 EdgeTTS 而用户选的
 * 是它，那条路径走的是分支 1，与这里无关。
 */
export function resolveSpeechProvider(requested: string,
  availableIds: string[]): SpeechResolution {
  if (contains(availableIds, requested)) {
    return { providerId: requested, fellBack: false };
  }
  if (contains(availableIds, SPEECH_PROVIDER_SYSTEM)) {
    return { providerId: SPEECH_PROVIDER_SYSTEM, fellBack: requested.length > 0 };
  }
  return { providerId: '', fellBack: false };
}

/**
 * 本端实现了哪些提供方。entry 侧再按运行时能力筛一道。
 *
 * 单独列出来是为了让「实现的」与「可用的」两张集合能分开测：设置页要用前者
 * 显示灰掉的项目（说明为什么不能用），用后者做实际解析。
 */
export function implementedSpeechProviders(): string[] {
  const out: string[] = [];
  for (let i: number = 0; i < SPEECH_PROVIDERS.length; i++) {
    if (SPEECH_PROVIDERS[i].implemented) {
      out.push(SPEECH_PROVIDERS[i].id);
    }
  }
  return out;
}

/**
 * 一条通知该不该朗读。
 *
 * 三个开关是与的关系，与桌面版 NotificationWorkerService.cs:178 完全一致：
 *
 *     settings.IsSpeechEnabled && content.IsSpeechEnabled && AllowNotificationSpeech
 *
 * 三个都有必要，缺一条都会出事：
 *   - 全局关：用户明确说了「别说话」；
 *   - 内容关：这一条通知自己标记了不需要朗读（比如纯静默的提示）；
 *   - 通知朗读总开关：桌面版默认为 **false**，也就是说语音朗读是 opt-in 的。
 *     少判这一条，用户的默认配置会突然开始出声 —— 这是本项目里唯一一处
 *     「默认静默」被打破就会立刻惊到用户的开关。
 */
export function shouldSpeakNotification(globalSpeechEnabled: boolean,
  contentSpeechEnabled: boolean, allowNotificationSpeech: boolean): boolean {
  return globalSpeechEnabled && contentSpeechEnabled && allowNotificationSpeech;
}

/** 音量夹到合法区间。与桌面版不同：那边不夹，setVolume 出错只在日志里。 */
export function clampSpeechVolume(value: number): number {
  if (!Number.isFinite(value)) {
    return SPEECH_VOLUME_MAX;
  }
  if (value < SPEECH_VOLUME_MIN) {
    return SPEECH_VOLUME_MIN;
  }
  if (value > SPEECH_VOLUME_MAX) {
    return SPEECH_VOLUME_MAX;
  }
  return value;
}

function contains(list: string[], value: string): boolean {
  for (let i: number = 0; i < list.length; i++) {
    if (list[i] === value) {
      return true;
    }
  }
  return false;
}
