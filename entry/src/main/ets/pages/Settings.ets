/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 设置页。
 *
 * 为什么把值镜像到 @Local 而不是直接在 build 里读 AppPreferences
 * ------------------------------------------------------------
 * AppPreferences 是「读盘」的，每次 getXxx 都是一次 readTextSync + JSON.parse。
 * 在 build 里直接读有两个问题：一是 build 会被重跑很多次（任何依赖变化都触发），
 * 一次重跑几十次读盘；二是写完之后没有可观测的变化通知 —— 改的是磁盘上的文件，
 * 那个对象本身没变，得靠额外机制才让控件刷新。
 *
 * 所以：aboutToAppear 读一次填进 @Local，改的时候同时写盘和改 @Local。
 * 这与 Index.ets 里 grid / banner 的做法一致。
 *
 * 为什么只用 ListItem 不用 ListItemGroup
 * -------------------------------------
 * ListItemGroup 的 header 只收 CustomBuilder，收不了字符串
 * （`{header: 'x'}` 编译不过），而为一屏标题给每个分组都写一个 @Builder 不划算。
 * 所以用一条浅底色的 ListItem 只放标题文字，没有交互。分组标题在这里唯一的作用
 * 是让人扫一眼定位，浅底色加粗已经做到了。
 *
 * 箭头用 '›' 字符而不是图片
 * ----------------------
 * 为一个箭头引入 png 不划算：它在深色主题下还要另备一张（图片不跟随文字颜色），
 * 而字符天然跟随 fontColor。
 *
 * 取值都是「点一下循环」而不是选择器
 * ------------------------------
 * 每一项的可选值都是已知的少量枚举，循环比弹选择器少一次界面往返，也不会让
 * 用户在一个临时列表里找「浅色」两个字。代价是看不到「全部有哪些值」，对这几项
 * 来说不构成问题。
 */

import { t } from 'common_core';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AppPreferences,
  DEFAULT_AUTO_REFRESH_WEATHER_LOCATION,
  DEFAULT_BACKGROUND_KEEP_ALIVE,
  DEFAULT_CITY_ID,
  DEFAULT_CITY_NAME,
  DEFAULT_DISTRIBUTED_SESSION_ID,
  DEFAULT_DISTRIBUTED_SYNC_ENABLED,
  DEFAULT_NO_TLS_WEATHER_REQUESTS,
  DEFAULT_SYSTEM_SPEECH_PERSON,
  DEFAULT_WEATHER_ICON_ID,
  DEFAULT_WEATHER_LOCATION_SOURCE,
  DefaultPage,
  PrefKeys,
  ThemeMode
} from '../common/AppPreferences';
import { UiFeedback } from '../common/UiFeedback';
import { ThemeService } from '../common/ThemeService';
import { CONTENT_MAX_WIDTH } from '../components/ContentWidth';
import { EditorTextField } from '../components/EditorWidgets';
import { ExactTimeService, resolveExactTimeService } from '../time/ExactTimeService';
import { SpeechService, resolveSpeechService } from '../speech/SpeechService';
import { PERSON_FEMALE, PERSON_MALE } from '../speech/SystemSpeechService';
import { SPEECH_PROVIDER_SYSTEM, SPEECH_PROVIDERS, SpeechProviderInfo,
  findSpeechProvider } from 'common_core';
import { WeatherService, resolveWeatherService } from '../weather/WeatherService';
import {
  DistributedStateService,
  resolveDistributedStateService
} from '../ipc/DistributedStateService';
import {
  BackgroundTaskService,
  resolveBackgroundTaskService
} from '../background/BackgroundTaskService';
import { describe, ProfileTransfer } from '../data/ProfileTransfer';
import { PluginListRow } from '../plugin/PluginListRow';
import { PluginPackageImporter, pickPluginFile } from '../plugin/PluginPackageImporter';
import { PluginLoadIssue, PluginService, resolvePluginService } from '../plugin/PluginService';

const DOMAIN: number = 0x0000;
const TAG: string = 'Settings';

/** 字体缩放的档位。循环切换用，不给滑块 —— 见 cycleFontScale 的注释。 */
const FONT_SCALE_STEPS: number[] = [0.8, 0.9, 1.0, 1.1, 1.3, 1.6];

/** 提前量的档位（秒）。 */
const ADVANCE_STEPS: number[] = [0, 60, 300, 600];

/** 提醒提前量的合法范围。 */
const ADVANCE_MAX_SECONDS: number = 3600;

/*
 * 手动偏移的档位（秒）。
 *
 * 负值排在正值前面且 0 在中间：偏移是「往哪边拨」的一个双向量，把 0 放在
 * 列表中间并让循环从它开始，点到 0 时不用先滚过所有负档。
 */
const OFFSET_STEPS: number[] = [-60, -30, -10, -5, -1, 0, 1, 5, 10, 30, 60];

/*
 * 每日补偿的档位（秒/天）。
 *
 * 不含负档：补偿的语义是「本机每天慢 X 秒，补回来」，负数在界面上读起来
 * 是「每天快 X 秒，要往回拨」—— 那不是用户会主动想要的事，需要的话用手动
 * 偏移即可。想要每天回拨的用户请把符号反着想。
 */
const AUTO_ADJUST_STEPS: number[] = [0, 0.5, 1, 2, 5, 10, 30, 60];

@Entry
@ComponentV2
struct SettingsPage {
  @Local ready: boolean = false;

  // 界面
  @Local theme: number = ThemeMode.System;
  @Local fontScale: number = 1.0;
  @Local defaultPage: number = DefaultPage.Schedule;

  // 课表
  @Local showWeekNum: boolean = true;
  @Local showFreeTime: boolean = true;
  @Local conflictDetection: boolean = true;
  @Local autoSelectCurrentWeek: boolean = true;

  // 课前提醒
  @Local reminderEnabled: boolean = true;
  @Local advanceIndoor: number = 60;
  @Local advanceOutdoor: number = 600;
  @Local reminderMode: number = -1;

  // 自动化
  @Local automationEnabled: boolean = true;
  @Local automationConfig: string = 'Default';

  // 精确时间
  @Local exactTimeEnabled: boolean = true;
  @Local exactTimeServer: string = 'ntp.aliyun.com';
  @Local timeOffsetSeconds: number = 0;
  @Local timeAutoAdjustEnabled: boolean = false;
  @Local timeAutoAdjustSeconds: number = 0;
  /** NTP 服务器的编辑框是否展开。默认收起，保持设置列表行长一致。 */
  @Local editingServer: boolean = false;
  /** 同步状态文案。校时服务是异步的，这里存一份快照供界面显示。 */
  @Local syncStatus: string = '';
  /** 正在校时。用来把按钮置灰、避免连点发出多个查询。 */
  @Local syncing: boolean = false;

  // 语音朗读
  @Local speechEnabled: boolean = true;
  @Local allowNotificationSpeech: boolean = false;
  /** 设置里选的提供方 id。可能是本设备没有实现的（跨端同步来的）。 */
  @Local speechProviderId: string = '';
  /** 系统 TTS 的音色（13 女 / 21 男）。 */
  @Local systemPerson: number = DEFAULT_SYSTEM_SPEECH_PERSON;
  /** 状态文案：实际用哪个引擎、有没有回退、为什么不可用。 */
  @Local speechStatus: string = '';
  /** 正在试听。用来把按钮置灰，并让按钮文字变成进行时。 */
  @Local testingSpeech: boolean = false;

  // 天气
  /** 城市 id（形如 weathercn:101010100）。跨端读写的键。 */
  @Local cityId: string = DEFAULT_CITY_ID;
  /** 城市显示名。 */
  @Local cityName: string = DEFAULT_CITY_NAME;
  /** 定位来源：0 按城市 id / 1 自动定位。 */
  @Local weatherLocationSource: number = DEFAULT_WEATHER_LOCATION_SOURCE;
  @Local autoRefreshWeatherLocation: boolean = DEFAULT_AUTO_REFRESH_WEATHER_LOCATION;
  @Local noTlsWeatherRequests: boolean = DEFAULT_NO_TLS_WEATHER_REQUESTS;
  @Local weatherIconId: string = DEFAULT_WEATHER_ICON_ID;
  /** 排除的预警。界面上用一个「、」连接的字符串表示，落盘是数组。 */
  @Local excludedAlertsText: string = '';
  /** 城市编辑区是否展开。 */
  @Local editingCity: boolean = false;
  /** 排除预警编辑区是否展开。 */
  @Local editingExclusions: boolean = false;
  /** 天气状态文案。 */
  @Local weatherStatus: string = '';
  /** 正在刷新天气。 */
  @Local refreshingWeather: boolean = false;

  // 跨设备
  /** 是否开启跨设备公开状态同步。 */
  @Local distributedEnabled: boolean = DEFAULT_DISTRIBUTED_SYNC_ENABLED;
  /** 会话 ID。空串表示还没生成过。 */
  @Local distributedSessionId: string = DEFAULT_DISTRIBUTED_SESSION_ID;
  /** 本机显示名（只读，给用户认机器的）。 */
  @Local distributedDeviceName: string = '';
  /** 会话 ID 的编辑区是否展开。 */
  @Local editingSessionId: boolean = false;
  /** 同步状态文案。 */
  @Local distributedStatus: string = '';

  // 后台保活
  /** 是否申请长时任务。 */
  @Local backgroundKeepAlive: boolean = DEFAULT_BACKGROUND_KEEP_ALIVE;
  /** 保活状态文案（申请中 / 运行中 / 申请失败原因）。 */
  @Local backgroundKeepAliveStatus: string = '';

  // 诊断
  @Local debugLog: boolean = false;
  @Local performanceOverlay: boolean = false;

  /*
   * 扩展分组（P12）。
   *
   * 行数组整体替换，不逐行改：PluginRecord 是进程级静态状态，而「哪几条被跳过、
   * 为什么」只有重新问一次 ExtensionRegistry 才知道。逐行改的话，改完那一行与
   * 注册表里的记录就可能对不上，而那种不一致在界面上看不出来（名字还在、
   * 开关还在，只是条目数不对）。
   */
  @Local pluginRows: PluginListRow[] = [];
  @Local pluginSummary: string = '';
  @Local importing: boolean = false;
  /** 最近一次导入没成功的原因。空串表示没有。 */
  @Local pluginImportError: string = '';

  /** 不加装饰器：持有它的字段不需要可观测，AppPreferences 本身是纯读写器。 */
  private prefs: AppPreferences | undefined = undefined;

  /**
   * 换配色要用 UIAbilityContext。
   *
   * 存下来而不是每次现取：getHostContext() 在 ArkUI 里是拿宿主 context，
   * 拿到的对象在整个 Ability 生命周期内是同一个，存下来省掉一处类型断言，
   * 也让「换配色」这个动作不必关心 context 从哪来。
   */
  private host: common.UIAbilityContext | undefined = undefined;

  aboutToAppear(): void {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as
      common.UIAbilityContext;
    this.host = context;
    this.prefs = new AppPreferences(context);
    this.reload();
    this.ready = true;
  }

  /** 从盘上重读一遍，填满所有 @Local。 */
  private reload(): void {
    const prefs: AppPreferences | undefined = this.prefs;
    if (prefs === undefined) {
      return;
    }
    this.theme = prefs.theme();
    this.fontScale = prefs.fontScale();
    this.defaultPage = prefs.defaultPage();

    this.showWeekNum = prefs.getBoolean(PrefKeys.SHOW_WEEK_NUM, true);
    this.showFreeTime = prefs.getBoolean(PrefKeys.SHOW_FREE_TIME, true);
    this.conflictDetection = prefs.getBoolean(PrefKeys.CONFLICT_DETECTION, true);
    this.autoSelectCurrentWeek = prefs.getBoolean(PrefKeys.AUTO_SELECT_CURRENT_WEEK, true);

    this.reminderEnabled = prefs.getBoolean(PrefKeys.REMINDER_ENABLED, true);
    this.advanceIndoor = AppPreferences.clampInt(
      prefs.getNumber(PrefKeys.REMINDER_ADVANCE_INDOOR, 60), 0, ADVANCE_MAX_SECONDS);
    this.advanceOutdoor = AppPreferences.clampInt(
      prefs.getNumber(PrefKeys.REMINDER_ADVANCE_OUTDOOR, 600), 0, ADVANCE_MAX_SECONDS);
    this.reminderMode = prefs.getNumber(PrefKeys.REMINDER_MODE, -1);

    this.automationEnabled = prefs.getBoolean(PrefKeys.AUTOMATION_ENABLED, true);
    this.automationConfig = prefs.getString(PrefKeys.AUTOMATION_CONFIG, 'Default');

    // 校时的几项从服务读，不从 prefs 读。服务是它们的唯一持有者（偏移会被
    // 每日补偿就地改掉，服务器会被空串回落成默认值），直接读盘会拿到一个
    // 与「实际在用的」不一样的值 —— 界面上写着 A、跑起来是 B 这种最难查。
    const exact: ExactTimeService | undefined = this.exactService();
    if (exact !== undefined) {
      this.exactTimeEnabled = exact.isEnabled();
      this.exactTimeServer = exact.currentServer();
      this.timeOffsetSeconds = exact.currentOffsetSeconds();
      this.timeAutoAdjustEnabled = exact.isAutoAdjustEnabled();
      this.timeAutoAdjustSeconds = exact.currentAutoAdjustSeconds();
      this.syncStatus = exact.statusText();
    }

    // 语音同样从服务读。服务是「实际会用哪个引擎」的判断者：设置里写着
    // EdgeTTS 而实际用的是回退后的系统 TTS，直接读盘会显示成 EdgeTTS ——
    // 用户会以为配置生效了，然后在手机上改音色改不动、也找不到原因。
    const speech: SpeechService | undefined = this.speechService();
    if (speech !== undefined) {
      this.speechEnabled = speech.isEnabled();
      this.allowNotificationSpeech = speech.allowNotificationSpeech();
      this.speechProviderId = speech.selectedProviderId();
      this.systemPerson = speech.systemPerson();
      this.speechStatus = speech.statusText();
    }

    // 天气的几个标量直接读盘。城市 id / 名称在「自动定位」命中后会被服务就地
    // 改写，所以这里读盘拿到的就是服务刚写下的那份；状态文案则直接问服务要。
    this.cityId = prefs.getString(PrefKeys.CITY_ID, DEFAULT_CITY_ID);
    this.cityName = prefs.getString(PrefKeys.CITY_NAME, DEFAULT_CITY_NAME);
    this.weatherLocationSource = prefs.getNumber(PrefKeys.WEATHER_LOCATION_SOURCE,
      DEFAULT_WEATHER_LOCATION_SOURCE);
    this.autoRefreshWeatherLocation = prefs.getBoolean(PrefKeys.AUTO_REFRESH_WEATHER_LOCATION,
      DEFAULT_AUTO_REFRESH_WEATHER_LOCATION);
    this.noTlsWeatherRequests = prefs.getBoolean(PrefKeys.NO_TLS_WEATHER_REQUESTS,
      DEFAULT_NO_TLS_WEATHER_REQUESTS);
    this.weatherIconId = prefs.getString(PrefKeys.WEATHER_ICON_ID, DEFAULT_WEATHER_ICON_ID);
    this.excludedAlertsText = prefs.getStringArray(PrefKeys.EXCLUDED_WEATHER_ALERTS).join('、');
    this.weatherStatus = this.weatherService()?.statusText() ?? '天气服务未启动';

    // 跨设备：开关与会话 ID 直接读盘（服务是它们的写入者，读了就是最新的），
    // 设备名与状态问服务要 —— 设备名来自系统、状态取决于入会话成没成。
    this.distributedEnabled = prefs.getBoolean(PrefKeys.DISTRIBUTED_SYNC_ENABLED,
      DEFAULT_DISTRIBUTED_SYNC_ENABLED);
    this.distributedSessionId = prefs.getString(PrefKeys.DISTRIBUTED_SESSION_ID,
      DEFAULT_DISTRIBUTED_SESSION_ID);
    const distributed: DistributedStateService | undefined = this.distributedService();
    if (distributed !== undefined) {
      this.distributedDeviceName = distributed.currentDeviceName();
      this.distributedStatus = distributed.statusText();
    }

    // 后台保活：开关读盘，状态问服务要。服务是异步申请长时任务的，刚进
    // 设置页时可能还停在「未启动」，用户拨一下开关才会变成运行中 / 失败原因。
    this.backgroundKeepAlive = prefs.getBoolean(PrefKeys.BACKGROUND_KEEP_ALIVE,
      DEFAULT_BACKGROUND_KEEP_ALIVE);

    this.reloadPlugins();
    const background: BackgroundTaskService | undefined = this.backgroundService();
    if (background !== undefined) {
      this.backgroundKeepAliveStatus = background.statusText();
    }

    this.debugLog = prefs.getBoolean(PrefKeys.DEBUG_LOG, false);
    this.performanceOverlay = prefs.getBoolean(PrefKeys.PERFORMANCE_OVERLAY, false);
  }

  // ------------------------------------------------------------ 写

  private writeBool(key: string, value: boolean): void {
    this.prefs?.put(key, value);
  }

  private writeNumber(key: string, value: number): void {
    this.prefs?.put(key, value);
  }

  // ------------------------------------------------------------ 取值展示

  private themeLabel(): string {
    if (this.theme === ThemeMode.Light) {
      return '浅色';
    }
    if (this.theme === ThemeMode.Dark) {
      return '深色';
    }
    return '跟随系统';
  }

  private defaultPageLabel(): string {
    if (this.defaultPage === DefaultPage.Editor) {
      return '编辑页';
    }
    if (this.defaultPage === DefaultPage.Panel) {
      return '信息面板';
    }
    if (this.defaultPage === DefaultPage.Automation) {
      return '自动化';
    }
    return '课表页';
  }

  private fontScaleLabel(): string {
    return `${Math.round(this.fontScale * 100)}%`;
  }

  private advanceLabel(seconds: number): string {
    if (seconds <= 0) {
      return t('settings_at_class_moment');
    }
    if (seconds < 60) {
      return `${seconds} 秒`;
    }
    return `${Math.round(seconds / 60)} 分钟`;
  }

  private reminderModeLabel(): string {
    if (this.reminderMode === 0) {
      return t('settings_per_class');
    }
    if (this.reminderMode === 1) {
      return t('settings_folded');
    }
    return t('settings_auto');
  }

  // ------------------------------------------------------------ 交互

  /**
   * 切主题：写盘 + 立刻生效。
   *
   * 立刻生效而不是「下次启动生效」：配色是那种「不立刻看到就以为自己没改
   * 成功」的东西，而生效成本只是改一个窗口属性。
   *
   * 顺序是先落盘再切：万一 setColorMode 失败，盘上已经是新值，用户下次
   * 进来会看到生效；反过来先切后落盘，中间崩了就出现「屏幕上变了但重进
   * 又变回去」的更糟状态。
   */
  private cycleTheme(): void {
    this.theme = (this.theme + 1) % 3;
    this.writeNumber(PrefKeys.THEME, this.theme);
    if (this.host !== undefined) {
      ThemeService.apply(this.host, this.theme);
    }
  }

  private cycleDefaultPage(): void {
    this.defaultPage = (this.defaultPage + 1) % 4;
    this.writeNumber(PrefKeys.DEFAULT_PAGE, this.defaultPage);
  }

  /**
   * 字体缩放按档位循环，不给滑块。
   *
   * 连续滑块每帧都要写盘，而帧间隔短到能让 rename 连续做十几次；档位循环只在
   * 点一下时写一次。代价是调不到 1.25 这种中间值 —— 对正文字号来说六个档位已经
   * 够用，真要连续值可以放到设置页之外的独立入口。
   */
  private cycleFontScale(): void {
    let next: number = FONT_SCALE_STEPS[FONT_SCALE_STEPS.length - 1];
    for (let i: number = 0; i < FONT_SCALE_STEPS.length; i++) {
      if (FONT_SCALE_STEPS[i] > this.fontScale) {
        next = FONT_SCALE_STEPS[i];
        break;
      }
    }
    this.fontScale = next;
    this.writeNumber(PrefKeys.FONT_SCALE, next);
    UiFeedback.toast(this.getUIContext(), `字体缩放 ${Math.round(next * 100)}%`);
  }

  private cycleAdvanceIndoor(): void {
    this.advanceIndoor = this.nextAdvance(this.advanceIndoor);
    this.writeNumber(PrefKeys.REMINDER_ADVANCE_INDOOR, this.advanceIndoor);
  }

  private cycleAdvanceOutdoor(): void {
    this.advanceOutdoor = this.nextAdvance(this.advanceOutdoor);
    this.writeNumber(PrefKeys.REMINDER_ADVANCE_OUTDOOR, this.advanceOutdoor);
  }

  /** 在四档之间往后走一档，到顶后回到第一档。 */
  private nextAdvance(current: number): number {
    for (let i: number = 0; i < ADVANCE_STEPS.length; i++) {
      if (ADVANCE_STEPS[i] > current) {
        return ADVANCE_STEPS[i];
      }
    }
    return ADVANCE_STEPS[0];
  }

  private cycleReminderMode(): void {
    // -1（自动）→ 0（精确）→ 1（折叠）→ -1
    if (this.reminderMode === -1) {
      this.reminderMode = 0;
    } else if (this.reminderMode === 0) {
      this.reminderMode = 1;
    } else {
      this.reminderMode = -1;
    }
    this.writeNumber(PrefKeys.REMINDER_MODE, this.reminderMode);
  }

  /**
   * 取校时服务。
   *
   * host 还没赋值时返回 undefined 而不是抛 —— aboutToAppear 里赋值顺序是
   * 先 host 后 reload，但 reload 也被 resetAll 调，而 resetAll 是用户点的，
   * 理论上不该有 undefined；返回 undefined 只是让「拿不到就跳过这一段」
   * 成为可能，而不是崩掉整个设置页。
   */
  private exactService(): ExactTimeService | undefined {
    if (this.host === undefined) {
      return undefined;
    }
    return resolveExactTimeService(this.host);
  }

  // ------------------------------------------------------------ 语音朗读

  private speechService(): SpeechService | undefined {
    if (this.host === undefined) {
      return undefined;
    }
    return resolveSpeechService(this.host);
  }

  /**
   * 全局开关。
   *
   * 不调服务的 start/stop：朗读服务没有定时器，引擎是惰性创建的，开关只影响
   * 「下一次要不要念」。所以写盘 + 重算状态文案就够。
   */
  private toggleSpeech(on: boolean): void {
    this.speechEnabled = on;
    this.writeBool(PrefKeys.SPEECH_ENABLED, on);
    this.refreshSpeechStatus();
  }

  /**
   * 「允许通知朗读」。
   *
   * 桌面版这一项的默认值是 **false**，也就是「装好了不会自己说话」。这里保持
   * 同样的默认值：朗读是 opt-in，因为一个会突然出声的应用比一个安静的应用
   * 更让人反感，尤其在教室里。
   */
  private toggleAllowNotificationSpeech(on: boolean): void {
    this.allowNotificationSpeech = on;
    this.writeBool(PrefKeys.ALLOW_NOTIFICATION_SPEECH, on);
    this.refreshSpeechStatus();
  }

  /**
   * 换提供方。在**全部**提供方里循环，包括本设备没有实现的。
   *
   * 为什么不跳过没实现的：这个键是跨端读写的。用户在桌面上选的是 EdgeTTS，
   * 同步过来之后设置页要能把那件事显示出来（而不是显示成「系统 TTS」让他
   * 以为选的就是系统 TTS）；也要能选回系统 TTS。让没实现的选项在列表里出现
   * 并注明「本设备暂不支持」，比把它藏起来诚实。
   */
  private cycleSpeechProvider(): void {
    const next: string = SettingsPage.nextProvider(this.speechProviderId);
    this.speechProviderId = next;
    this.prefs?.put(PrefKeys.SELECTED_SPEECH_PROVIDER, next);
    this.refreshSpeechStatus();
  }

  private static nextProvider(current: string): string {
    for (let i: number = 0; i < SPEECH_PROVIDERS.length; i++) {
      if (SPEECH_PROVIDERS[i].id === current) {
        return SPEECH_PROVIDERS[(i + 1) % SPEECH_PROVIDERS.length].id;
      }
    }
    return SPEECH_PROVIDERS[0].id;
  }

  private cycleSystemPerson(): void {
    const next: number = this.systemPerson === PERSON_FEMALE ? PERSON_MALE : PERSON_FEMALE;
    this.systemPerson = next;
    this.writeNumber(PrefKeys.SYSTEM_SPEECH_PERSON, next);
    // 音色是引擎的创建参数，改不了 —— 服务会丢掉旧引擎，下次朗读重建。
    this.speechService()?.setSystemPerson(next);
    this.refreshSpeechStatus();
  }

  private refreshSpeechStatus(): void {
    this.speechStatus = this.speechService()?.statusText() ?? '';
  }

  /**
   * 试听。
   *
   * 用一句真话而不是「测试测试」：念出来的是应用以后真会念的那类句子（语速、
   * 停顿、多音字都在），用户听完就能判断要不要留着。代价是这一句得手工维护，
   * 但只有一句。
   */
  private async testSpeak(): Promise<void> {
    const speech: SpeechService | undefined = this.speechService();
    if (speech === undefined || this.testingSpeech) {
      return;
    }
    this.testingSpeech = true;
    try {
      const failure: string = await speech.trySpeakNow(t('settings_speech_sample'));
      UiFeedback.toast(this.getUIContext(),
        failure.length === 0 ? t('settings_test_sent') : `${t('settings_test_failed')}：${failure}`);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'testSpeak threw: %{public}s', `${err}`);
    }
    this.testingSpeech = false;
    this.refreshSpeechStatus();
  }

  private speechProviderLabel(): string {
    const info: SpeechProviderInfo | undefined = findSpeechProvider(this.speechProviderId);
    if (info === undefined) {
      return this.speechProviderId;
    }
    if (!info.implemented) {
      return `${info.displayName}（本设备暂不支持）`;
    }
    return info.displayName;
  }

  private personLabel(): string {
    return this.systemPerson === PERSON_MALE ? '男声' : '女声';
  }

  // ------------------------------------------------------------ 天气

  private weatherService(): WeatherService | undefined {
    if (this.host === undefined) {
      return undefined;
    }
    return resolveWeatherService(this.host);
  }

  private weatherLocationLabel(): string {
    return this.weatherLocationSource === 1 ? '自动定位' : '按城市 id';
  }

  /**
   * 换定位方式。
   *
   * 两个档位都不是「立刻生效」的：切到自动定位要等下一次刷新真去问系统要坐标，
   * 切回城市 id 要等下一次刷新用 CityId 查。所以这里只写盘 + 改文案，不触发
   * 刷新 —— 用户点「立即刷新」才是「现在就按新方式取一次」的意思。
   */
  private cycleWeatherLocationSource(): void {
    const next: number = this.weatherLocationSource === 1 ? 0 : 1;
    this.weatherLocationSource = next;
    this.writeNumber(PrefKeys.WEATHER_LOCATION_SOURCE, next);
  }

  private toggleAutoRefreshWeatherLocation(on: boolean): void {
    this.autoRefreshWeatherLocation = on;
    this.writeBool(PrefKeys.AUTO_REFRESH_WEATHER_LOCATION, on);
  }

  /**
   * 明文 HTTP。
   *
   * 换协议会改掉后面每一条请求的 URL，所以立刻重取一次 —— 用户拨这个开关的
   * 动机十有八九是「地里的设备证书过期导致 https 一直失败」，拨完就想知道
   * 通没通。
   */
  private toggleNoTlsWeatherRequests(on: boolean): void {
    this.noTlsWeatherRequests = on;
    this.writeBool(PrefKeys.NO_TLS_WEATHER_REQUESTS, on);
    void this.refreshWeather();
  }

  private commitCityId(text: string): void {
    const trimmed: string = text.trim();
    const cityId: string = trimmed.length === 0 ? DEFAULT_CITY_ID : trimmed;
    this.cityId = cityId;
    this.prefs?.put(PrefKeys.CITY_ID, cityId);
    this.editingCity = false;
    void this.refreshWeather();
  }

  private commitCityName(text: string): void {
    const trimmed: string = text.trim();
    this.cityName = trimmed;
    this.prefs?.put(PrefKeys.CITY_NAME, trimmed);
  }

  /**
   * 提交排除的预警。
   *
   * 输入是「、」「,」「，」分隔的一段文字，落盘是字符串数组（桌面版是
   * ObservableCollection<string>）。这里不用正则 split：ArkTS 对正则字面量
   * 的支持不完整，逐字符扫一遍更稳，也顺手把空段丢掉。
   */
  private commitExcludedAlerts(text: string): void {
    const items: string[] = [];
    let current: string = '';
    for (let i: number = 0; i < text.length; i++) {
      const ch: string = text.charAt(i);
      if (ch === '、' || ch === ',' || ch === '，' || ch === '\n') {
        if (current.length > 0) {
          items.push(current);
          current = '';
        }
      } else {
        current += ch;
      }
    }
    if (current.length > 0) {
      items.push(current);
    }
    this.excludedAlertsText = items.join('、');
    this.prefs?.putStringArray(PrefKeys.EXCLUDED_WEATHER_ALERTS, items);
    this.editingExclusions = false;
    void this.refreshWeather();
  }

  private async refreshWeather(): Promise<void> {
    const service: WeatherService | undefined = this.weatherService();
    if (service === undefined || this.refreshingWeather) {
      return;
    }
    this.refreshingWeather = true;
    try {
      await service.refreshNow();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'refreshWeather threw: %{public}s', `${err}`);
    }
    this.weatherStatus = service.statusText();
    this.refreshingWeather = false;
  }

  // ------------------------------------------------------------ 跨设备

  private distributedService(): DistributedStateService | undefined {
    if (this.host === undefined) {
      return undefined;
    }
    return resolveDistributedStateService(this.host);
  }

  /**
   * 拨同步开关。
   *
   * 打开时会就地建会话，如果会话 ID 还没生成过就顺手生成一个 —— 否则「打开
   * 同步却什么也没发生」是这条路径最容易踩的坑。刚入会话时 statusText() 可能
   * 还没变成「已加入」，因为 setSessionId 是异步的，这里先显示一份快照即可。
   */
  private toggleDistributed(on: boolean): void {
    this.distributedEnabled = on;
    const service: DistributedStateService | undefined = this.distributedService();
    if (service === undefined) {
      this.writeBool(PrefKeys.DISTRIBUTED_SYNC_ENABLED, on);
      return;
    }
    service.setEnabled(on);
    if (on) {
      this.distributedSessionId = service.currentSessionId();
    }
    this.distributedStatus = service.statusText();
    // 跨设备一开，保活就该从「任务保持」切到「多设备互联」（手机上前者几乎
    // 申请不到），所以顺手让保活服务重算一次。
    this.refreshKeepAlive();
  }

  private generateDistributedSessionId(): void {
    const service: DistributedStateService | undefined = this.distributedService();
    if (service === undefined) {
      return;
    }
    this.distributedSessionId = service.generateSessionId();
    this.editingSessionId = false;
    this.distributedStatus = service.statusText();
  }

  /**
   * 提交会话 ID。
   *
   * 回填的是服务规范化之后的值 —— 用户输了中文或标点，服务会把它们丢掉，
   * 界面必须显示最终生效的那个，否则用户会以为自己的输入没保存上。
   */
  private commitSessionId(text: string): void {
    this.editingSessionId = false;
    const service: DistributedStateService | undefined = this.distributedService();
    if (service === undefined) {
      const normalized: string = text.trim();
      this.distributedSessionId = normalized;
      this.prefs?.put(PrefKeys.DISTRIBUTED_SESSION_ID, normalized);
      return;
    }
    this.distributedSessionId = service.setSessionId(text);
    this.distributedStatus = service.statusText();
  }

  // ------------------------------------------------------------ 后台保活

  private backgroundService(): BackgroundTaskService | undefined {
    if (this.host === undefined) {
      return undefined;
    }
    return resolveBackgroundTaskService(this.host);
  }

  /**
   * 拨保活开关。
   *
   * 立刻调 start()/stop() 而不是等下次进前台：用户拨完开关就会看状态那一行，
   * 停到下次进前台才申请的话，这里会一直显示「未启动」，用户以为拨了没用。
   */
  private toggleBackgroundKeepAlive(on: boolean): void {
    this.backgroundKeepAlive = on;
    const service: BackgroundTaskService | undefined = this.backgroundService();
    if (service === undefined) {
      this.writeBool(PrefKeys.BACKGROUND_KEEP_ALIVE, on);
      this.backgroundKeepAliveStatus = on ? t('settings_not_started') : t('settings_off');
      return;
    }
    service.setEnabled(on);
    this.backgroundKeepAliveStatus = service.statusText();
  }

  /**
   * 重新评估保活类型。
   *
   * 跨设备同步 / 自动化开关会改变「该申请哪一种长时任务」的结论（见 core 的
   * planKeepAlive），所以这两个开关拨完要顺手让保活服务重算一次。
   */
  private refreshKeepAlive(): void {
    const service: BackgroundTaskService | undefined = this.backgroundService();
    if (service === undefined) {
      return;
    }
    service.start();
    this.backgroundKeepAliveStatus = service.statusText();
  }

  // ------------------------------------------------------------ 扩展

  /** 取扩展服务。没装配好时返回 undefined（此时分组显示「未启动」）。 */
  private pluginService(): PluginService | undefined {
    const host: common.UIAbilityContext | undefined = this.host;
    if (host === undefined) {
      return undefined;
    }
    return resolvePluginService(host);
  }

  /** 从登记表重读一遍扩展行。整体替换，理由见 pluginRows 的注释。 */
  private reloadPlugins(): void {
    const service: PluginService | undefined = this.pluginService();
    if (service === undefined) {
      this.pluginRows = [];
      this.pluginSummary = '扩展服务未启动';
      return;
    }
    const issues: Map<string, PluginLoadIssue> = new Map<string, PluginLoadIssue>();
    for (const issue of service.loadIssues()) {
      issues.set(issue.pluginId, issue);
    }
    const rows: PluginListRow[] = [];
    for (const record of service.records()) {
      rows.push(PluginListRow.from(record, issues.get(record.pluginId)));
    }
    this.pluginRows = rows;
    this.pluginSummary = service.summaryText();
  }

  /** 拨某个扩展的开关。落盘失败时把开关拨回去，别让界面与盘上不一致。 */
  private togglePlugin(row: PluginListRow): void {
    const service: PluginService | undefined = this.pluginService();
    if (service === undefined) {
      return;
    }
    try {
      service.setEnabled(row.pluginId, !row.enabled);
    } catch (err) {
      UiFeedback.toast(this.getUIContext(), `保存失败：${describe(err)}`);
      return;
    }
    this.reloadPlugins();
  }

  private uninstallPlugin(row: PluginListRow): void {
    UiFeedback.confirm(this.getUIContext(), '卸载扩展',
      `会删掉「${row.displayName()}」的清单与开关状态。它声明的组件、触发器、行动会一起从面板与自动化里消失。`,
      '卸载', () => {
        const service: PluginService | undefined = this.pluginService();
        if (service === undefined) {
          return;
        }
        try {
          service.uninstall(row.pluginId);
        } catch (err) {
          UiFeedback.toast(this.getUIContext(), `卸载失败：${describe(err)}`);
          return;
        }
        this.reloadPlugins();
      });
  }

  /**
   * 导入一份扩展清单（.json）。
   *
   * 装不上也要留在盘上（PluginService.installFromText 的口径），所以这里只在
   * 「装不上」时提示原因，不把文件删掉 —— 用户改一行 apiVersion 就能重试，
   * 而文件已经不在的话他得先找到它。
   */
  private async importPluginJson(): Promise<void> {
    const host: common.UIAbilityContext | undefined = this.host;
    if (host === undefined) {
      return;
    }
    this.importing = true;
    this.pluginImportError = '';
    try {
      const picked = await pickPluginFile(host);
      if (picked.canceled) {
        return;
      }
      const text: string = ProfileTransfer.readText(picked.uri);
      const service: PluginService | undefined = this.pluginService();
      if (service === undefined) {
        return;
      }
      const result = service.installFromText(text);
      if (!result.loaded) {
        this.pluginImportError = result.reason;
        UiFeedback.toast(this.getUIContext(), `没有装上：${result.reason}`);
      } else {
        UiFeedback.toast(this.getUIContext(),
          `已装「${result.pluginId}」，${result.entryCount} 条条目。`);
      }
      this.reloadPlugins();
    } catch (err) {
      this.pluginImportError = describe(err);
      UiFeedback.toast(this.getUIContext(), `导入失败：${describe(err)}`);
    } finally {
      this.importing = false;
    }
  }

  /**
   * 导入一个桌面版插件包（.cipx）。
   *
   * 与 .json 导入的分工：.cipx 里只有元信息（那份 dll 是 .NET 程序集，本端
   * 没有运行时去加载它），所以走 PluginPackageImporter 先转成清单文本，再交给
   * 同一条 installFromText —— 两条路在「装」这一步必须汇合，否则「装不上时
   * 留在盘上」这类口径会出现两份。
   */
  private async importPluginCipx(): Promise<void> {
    const host: common.UIAbilityContext | undefined = this.host;
    if (host === undefined) {
      return;
    }
    this.importing = true;
    this.pluginImportError = '';
    try {
      const picked = await pickPluginFile(host);
      if (picked.canceled) {
        return;
      }
      const converted = await PluginPackageImporter.convertCipx(host, picked.uri);
      const service: PluginService | undefined = this.pluginService();
      if (service === undefined) {
        return;
      }
      const result = service.installFromText(converted.manifestText);
      UiFeedback.toast(this.getUIContext(), converted.summary);
      if (!result.loaded) {
        this.pluginImportError = result.reason;
      }
      this.reloadPlugins();
    } catch (err) {
      this.pluginImportError = describe(err);
      UiFeedback.toast(this.getUIContext(), `导入失败：${describe(err)}`);
    } finally {
      this.importing = false;
    }
  }

  /** 导出某个扩展的清单。给作者改完再传回来用。 */
  private async exportPlugin(row: PluginListRow): Promise<void> {
    const host: common.UIAbilityContext | undefined = this.host;
    const service: PluginService | undefined = this.pluginService();
    if (host === undefined || service === undefined) {
      return;
    }
    try {
      const text: string = service.exportTextOf(row.pluginId);
      const picked = await ProfileTransfer.pickSaveUri(host, `${row.pluginId}.json`);
      if (picked.canceled) {
        return;
      }
      ProfileTransfer.writeText(picked.uri, text);
      UiFeedback.toast(this.getUIContext(), t('settings_exported'));
    } catch (err) {
      UiFeedback.toast(this.getUIContext(), `导出失败：${describe(err)}`);
    }
  }

  // ------------------------------------------------------------ 精确时间

  private toggleExactTime(on: boolean): void {
    this.exactTimeEnabled = on;
    const exact: ExactTimeService | undefined = this.exactService();
    if (exact !== undefined) {
      exact.setEnabled(on);
      this.syncStatus = exact.statusText();
    }
  }

  /**
   * 提交 NTP 服务器。
   *
   * 走服务而不是直接写盘：换服务器会立刻触发一次查询，用户按回车到看见
   * 结果之间的那 1~3 秒正是「这个改动有没有生效」的答案。
   */
  private commitServer(text: string): void {
    const exact: ExactTimeService | undefined = this.exactService();
    if (exact === undefined) {
      return;
    }
    exact.setServer(text);
    this.exactTimeServer = exact.currentServer();
    this.editingServer = false;
    this.syncing = true;
    this.refreshStatusSoon();
  }

  private cycleOffset(): void {
    const next: number = SettingsPage.nextStep(OFFSET_STEPS, this.timeOffsetSeconds);
    this.timeOffsetSeconds = next;
    this.exactService()?.setOffsetSeconds(next);
  }

  private toggleAutoAdjust(on: boolean): void {
    this.timeAutoAdjustEnabled = on;
    this.exactService()?.setAutoAdjustEnabled(on);
  }

  private cycleAutoAdjust(): void {
    const next: number = SettingsPage.nextStep(AUTO_ADJUST_STEPS, this.timeAutoAdjustSeconds);
    this.timeAutoAdjustSeconds = next;
    this.exactService()?.setAutoAdjustSeconds(next);
  }

  /** 立即校时。等结果再刷状态，不 await 到界面。 */
  private async syncNow(): Promise<void> {
    const exact: ExactTimeService | undefined = this.exactService();
    if (exact === undefined || this.syncing) {
      return;
    }
    this.syncing = true;
    try {
      await exact.syncNow();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'syncNow threw: %{public}s', `${err}`);
    }
    this.syncStatus = exact.statusText();
    this.syncing = false;
  }

  /**
   * 延迟一拍再读状态。
   *
   * setServer 里那次查询是 fire-and-forget 的（不 await），所以提交后立刻读
   * 拿到的必然是「正在同步时间……」。等它自己回来更简单，也避免为了等一个
   * 3 秒的查询把提交回调变成异步（那会让 TextInput 的 onBlur/onSubmit 语义
   * 变模糊）。200 毫秒够覆盖本地网络的往返，不够也不影响正确性 ——
   * 下一条状态本来就是用户自己再点一次「立即校时」看出来的。
   */
  private refreshStatusSoon(): void {
    setTimeout((): void => {
      this.syncStatus = this.exactService()?.statusText() ?? '';
      this.syncing = false;
    }, 200);
  }

  /** 在档位表里往后走一档，到顶后回到第一档。 */
  private static nextStep(steps: number[], current: number): number {
    for (let i: number = 0; i < steps.length; i++) {
      if (steps[i] > current + 1e-9) {
        return steps[i];
      }
    }
    return steps[0];
  }

  private offsetLabel(): string {
    const seconds: number = this.timeOffsetSeconds;
    if (seconds === 0) {
      return '不调整';
    }
    const sign: string = seconds > 0 ? '+' : '-';
    return `${sign}${Math.abs(seconds)} 秒`;
  }

  private autoAdjustLabel(): string {
    if (this.timeAutoAdjustSeconds === 0) {
      return '不补偿';
    }
    return `每天 +${this.timeAutoAdjustSeconds} 秒`;
  }

  private resetAll(): void {
    this.prefs?.resetToDefaults();

    // 校时要在 reload 之前 start：它不只是读 @Local，服务自己还持有一份
    // 启用状态、偏移与定时器。盘上重置了而服务还按旧值跑，就是「界面写着关、
    // 服务还在每 10 分钟发包」。start() 重读全部设置并重建定时器，之后
    // reload() 才能从服务读到已归零的值 —— 顺序反了就会读到旧值。
    //
    // 它顺带会跑一次每日补偿：刚重置时 LastTimeAdjustDateTime 已被置空，
    // 天数算出来是 0，不会多补。
    this.exactService()?.start();

    // 音色缓存在 SystemSpeechService 里（引擎的创建参数），重置后要一起拨回
    // 默认值 —— 否则盘上写着 13、内存里还是 21，试听出来是男声而设置页写着
    // 女声。
    this.speechService()?.setSystemPerson(DEFAULT_SYSTEM_SPEECH_PERSON);

    this.reload();
    this.editingServer = false;

    // 主题要重新落到窗口上：reload() 只改了 @Local，屏幕上还是重置前的配色。
    // 其他设置项没有这个问题 —— 它们在 build 里读 @Local，reload 完就重画了；
    // 配色是窗口级属性，不经过 build。
    if (this.host !== undefined) {
      ThemeService.apply(this.host, this.theme);
    }
    UiFeedback.toast(this.getUIContext(), t('settings_reset_done'));
  }

  private goAutomation(): void {
    const uiContext: UIContext = this.getUIContext();
    uiContext.getRouter().pushUrl({ url: 'pages/Automation' }).catch(() => {
      UiFeedback.toast(uiContext, '进不去自动化页');
    });
  }

  // ------------------------------------------------------------ 渲染片段

  /** 分组标题：一条只放文字的浅底 ListItem，没有交互。 */
  @Builder
  private groupTitle(text: string) {
    ListItem() {
      Text(text)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_secondary'))
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 6 })
        .backgroundColor($r('app.color.ch_surface_alt'))
    }
  }

  /** 可点击的行：左标题、右当前值、末尾箭头。 */
  @Builder
  private valueRow(title: string, value: string, onTap: () => void) {
    ListItem() {
      Row() {
        Text(title)
          .fontSize(16)
          .fontColor($r('app.color.ch_text_primary'))
        Blank()
        Text(value)
          .fontSize(15)
          .fontColor($r('app.color.ch_text_secondary'))
          .maxLines(1)
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.ch_text_hint'))
          .margin({ left: 6 })
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })
    }
    .onClick(() => {
      onTap();
    })
  }

  /** 开关行：左标题、右侧开关。 */
  @Builder
  private toggleRow(title: string, isOn: boolean, onChange: (on: boolean) => void) {
    ListItem() {
      Row() {
        Text(title)
          .fontSize(16)
          .fontColor($r('app.color.ch_text_primary'))
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: isOn })
          .selectedColor($r('app.color.ch_accent'))
          .onChange((on: boolean) => {
            onChange(on);
          })
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })
    }
  }

  /**
   * 说明行：左标题、右侧可换行的长文本。用来放校时状态。
   *
   * 不用 valueRow：那个把值限成 maxLines(1)，而状态文案在「系统时间被修改」
   * 这种场景下会带上「上次同步：……」的前后缀，截断成一行就看不出发生了什么。
   */
  @Builder
  private noteRow(title: string, body: string) {
    ListItem() {
      Row() {
        Text(title)
          .fontSize(16)
          .fontColor($r('app.color.ch_text_primary'))
          .width(96)
        Text(body)
          .fontSize(13)
          .fontColor($r('app.color.ch_text_secondary'))
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    }
  }

  /** 纯文字的整行按钮。 */
  @Builder
  private actionRow(label: string, enabled: boolean, onTap: () => void) {
    ListItem() {
      Text(label)
        .fontSize(16)
        .fontColor(enabled ? $r('app.color.ch_accent') : $r('app.color.ch_text_hint'))
        .width('100%')
        .height(52)
        .padding({ left: 16, right: 16 })
        .textAlign(TextAlign.Start)
    }
    .onClick(() => {
      if (enabled) {
        onTap();
      }
    })
  }

  /**
   * 扩展列表里的一行。
   *
   * 头部一行常显（名字 + 开关），点开是详情。常显只放名字与开关，是因为这一屏
   * 里「装上了几条」是次要信息，而「它叫什么、开没开」是用户进来就要看的两件事；
   * 详情里再放描述、声明了什么、问题明细 —— 那些是「它为什么不工作」时才需要
   * 的东西，而那种时候用户会去点。
   *
   * 开关放在头部而不是详情里：开关是这一屏唯一会「拨一下」的控件，把它塞进
   * 展开区意味着每次拨都要先点开一次。
   */
  @Builder
  private pluginRow(row: PluginListRow) {
    ListItem() {
      Column() {
        Row() {
          Column() {
            Text(row.displayName())
              .fontSize(16)
              .fontColor($r('app.color.ch_text_primary'))
              .maxLines(1)
            Text(row.subtitle())
              .fontSize(12)
              .fontColor($r('app.color.ch_text_hint'))
              .maxLines(2)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .constraintSize({ maxWidth: '72%' })
          Toggle({ type: ToggleType.Switch, isOn: row.enabled })
            .selectedColor($r('app.color.ch_accent'))
            .onChange((on: boolean) => {
              this.togglePlugin(row);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .onClick(() => {
          row.expanded = !row.expanded;
        })

        if (row.expanded) {
          Column() {
            this.noteRow(t('settings_status'), row.statusText())
            if (row.description.length > 0) {
              this.noteRow(t('settings_description'), row.description)
            }
            this.noteRow(t('settings_declared'), row.declaredText())
            this.noteRow(t('settings_author'), row.author.length > 0 ? row.author : '没写')
            ForEach(row.issueLines(), (line: string) => {
              Text(`· ${line}`)
                .fontSize(13)
                .fontColor($r('app.color.ch_text_hint'))
                .width('100%')
                .padding({ left: 16, right: 16 })
            }, (line: string) => line)
            if (row.issueLines().length > 0) {
              Blank()
            }
            this.actionRow(t('settings_export_manifest'), true, () => {
              this.exportPlugin(row);
            })
            this.actionRow(t('settings_uninstall'), true, () => {
              this.uninstallPlugin(row);
            })
          }
          .width('100%')
          .padding({ top: 2, bottom: 10 })
        }
      }
      .width('100%')
      .backgroundColor($r('app.color.ch_surface_weak'))
    }
  }

  build() {
    Column() {
      if (!this.ready) {
        Text('正在准备设置…')
          .fontSize(14)
          .fontColor($r('app.color.ch_text_secondary'))
          .width('100%')
          .height('100%')
          .textAlign(TextAlign.Center)
      } else {
        List() {
          // ---- 界面
          this.groupTitle(t('settings_group_ui'))
          this.valueRow(t('settings_theme'), this.themeLabel(), () => {
            this.cycleTheme();
          })
          this.valueRow(t('settings_font_scale'), this.fontScaleLabel(), () => {
            this.cycleFontScale();
          })
          this.valueRow(t('settings_default_page'), this.defaultPageLabel(), () => {
            this.cycleDefaultPage();
          })

          // ---- 课表
          this.groupTitle(t('settings_group_schedule'))
          this.toggleRow(t('settings_show_week_num'), this.showWeekNum, (on: boolean) => {
            this.showWeekNum = on;
            this.writeBool(PrefKeys.SHOW_WEEK_NUM, on);
          })
          this.toggleRow(t('settings_show_free_time'), this.showFreeTime, (on: boolean) => {
            this.showFreeTime = on;
            this.writeBool(PrefKeys.SHOW_FREE_TIME, on);
          })
          this.toggleRow(t('settings_conflict_detection'), this.conflictDetection, (on: boolean) => {
            this.conflictDetection = on;
            this.writeBool(PrefKeys.CONFLICT_DETECTION, on);
          })
          this.toggleRow(t('settings_auto_week'), this.autoSelectCurrentWeek, (on: boolean) => {
            this.autoSelectCurrentWeek = on;
            this.writeBool(PrefKeys.AUTO_SELECT_CURRENT_WEEK, on);
          })

          // ---- 课前提醒
          this.groupTitle(t('settings_group_reminder'))
          this.toggleRow(t('settings_enable_reminder'), this.reminderEnabled, (on: boolean) => {
            this.reminderEnabled = on;
            this.writeBool(PrefKeys.REMINDER_ENABLED, on);
          })
          this.valueRow(t('settings_advance_indoor'), this.advanceLabel(this.advanceIndoor), () => {
            this.cycleAdvanceIndoor();
          })
          this.valueRow(t('settings_advance_outdoor'), this.advanceLabel(this.advanceOutdoor), () => {
            this.cycleAdvanceOutdoor();
          })
          this.valueRow(t('settings_reminder_mode'), this.reminderModeLabel(), () => {
            this.cycleReminderMode();
          })

          // ---- 自动化
          this.groupTitle(t('settings_group_automation'))
          this.toggleRow(t('settings_enable_automation'), this.automationEnabled, (on: boolean) => {
            this.automationEnabled = on;
            this.writeBool(PrefKeys.AUTOMATION_ENABLED, on);
            this.refreshKeepAlive();
          })
          this.valueRow(t('settings_automation_config'), this.automationConfig, () => {
            this.goAutomation();
          })

          // ---- 精确时间
          this.groupTitle(t('settings_group_time'))
          this.toggleRow(t('settings_enable_exact_time'), this.exactTimeEnabled, (on: boolean) => {
            this.toggleExactTime(on);
          })
          this.valueRow(t('settings_ntp_server'), this.exactTimeServer, () => {
            this.editingServer = !this.editingServer;
          })
          if (this.editingServer) {
            // 只在展开时挂载：EditorTextField 在 aboutToAppear 里把值拷进
            // draft，折叠再展开会重新挂载并重新拷贝，正好是想要的「重置编辑框」。
            ListItem() {
              Column() {
                EditorTextField({
                  label: '服务器',
                  value: this.exactTimeServer,
                  placeholder: 'ntp.aliyun.com',
                  onCommit: (text: string) => {
                    this.commitServer(text);
                  }
                })
                Text('回车或点别处生效。留空则回落到 ntp.aliyun.com。')
                  .fontSize(12)
                  .fontColor($r('app.color.ch_text_hint'))
                  .width('100%')
                  .padding({ top: 4 })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            }
          }
          this.valueRow(t('settings_manual_offset'), this.offsetLabel(), () => {
            this.cycleOffset();
          })
          this.toggleRow(t('settings_daily_compensate'), this.timeAutoAdjustEnabled, (on: boolean) => {
            this.toggleAutoAdjust(on);
          })
          this.valueRow(t('settings_daily_compensate_amount'), this.autoAdjustLabel(), () => {
            this.cycleAutoAdjust();
          })
          this.noteRow(t('settings_sync_status'), this.syncStatus.length === 0 ? '尚未开始' : this.syncStatus)
          this.actionRow(this.syncing ? '正在校时…' : '立即校时',
            this.exactTimeEnabled && !this.syncing, () => {
              this.syncNow();
            })

          // ---- 语音朗读
          this.groupTitle(t('settings_group_speech'))
          this.toggleRow(t('settings_enable_speech'), this.speechEnabled, (on: boolean) => {
            this.toggleSpeech(on);
          })
          this.toggleRow(t('settings_speech_notification'), this.allowNotificationSpeech, (on: boolean) => {
            this.toggleAllowNotificationSpeech(on);
          })
          this.valueRow(t('settings_speech_provider'), this.speechProviderLabel(), () => {
            this.cycleSpeechProvider();
          })
          if (this.speechProviderId === SPEECH_PROVIDER_SYSTEM) {
            // 只在真的用系统 TTS 时才显示音色。挂在 EdgeTTS 上显示一个改不动
            // 的音色，是一件需要解释的事。
            this.valueRow(t('settings_speech_person'), this.personLabel(), () => {
              this.cycleSystemPerson();
            })
          }
          this.noteRow(t('settings_speech_status'),
            this.speechStatus.length === 0 ? '尚未初始化' : this.speechStatus)
          this.noteRow(t('settings_speech_volume'), t('settings_volume_hint'))
          this.actionRow(this.testingSpeech ? '正在试听…' : '试听', !this.testingSpeech, () => {
            this.testSpeak();
          })

          // ---- 天气
          this.groupTitle(t('settings_group_weather'))
          this.valueRow(t('settings_weather_location'), this.weatherLocationLabel(), () => {
            this.cycleWeatherLocationSource();
          })
          this.valueRow(t('settings_city'),
            this.cityName.length > 0 ? this.cityName : this.cityId, () => {
              this.editingCity = !this.editingCity;
            })
          if (this.editingCity) {
            ListItem() {
              Column() {
                EditorTextField({
                  label: '城市 id',
                  value: this.cityId,
                  placeholder: DEFAULT_CITY_ID,
                  onCommit: (text: string) => {
                    this.commitCityId(text);
                  }
                })
                Text(t('settings_city_hint'))
                  .fontSize(12)
                  .fontColor($r('app.color.ch_text_hint'))
                  .width('100%')
                  .padding({ top: 4, bottom: 10 })
                EditorTextField({
                  label: '显示名',
                  value: this.cityName,
                  placeholder: DEFAULT_CITY_NAME,
                  onCommit: (text: string) => {
                    this.commitCityName(text);
                  }
                })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            }
          }
          this.toggleRow(t('settings_auto_refresh_location'), this.autoRefreshWeatherLocation, (on: boolean) => {
            this.toggleAutoRefreshWeatherLocation(on);
          })
          this.toggleRow(t('settings_no_tls'), this.noTlsWeatherRequests, (on: boolean) => {
            this.toggleNoTlsWeatherRequests(on);
          })
          this.valueRow(t('settings_excluded_alerts'),
            this.excludedAlertsText.length === 0 ? '不排除' : this.excludedAlertsText, () => {
              this.editingExclusions = !this.editingExclusions;
            })
          if (this.editingExclusions) {
            ListItem() {
              Column() {
                EditorTextField({
                  label: t('settings_alert_keyword'),
                  value: this.excludedAlertsText,
                  placeholder: t('settings_alert_keyword_placeholder'),
                  onCommit: (text: string) => {
                    this.commitExcludedAlerts(text);
                  }
                })
                Text(t('settings_alert_hint'))
                  .fontSize(12)
                  .fontColor($r('app.color.ch_text_hint'))
                  .width('100%')
                  .padding({ top: 4 })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            }
          }
          this.noteRow(t('settings_icon_scheme'), `${this.weatherIconId}（图标字体未移植，该键只读写不生效）`)
          this.noteRow(t('settings_alert_icon'), t('settings_alert_icon_hint'))
          this.noteRow(t('settings_status'), this.weatherStatus.length === 0 ? '尚未初始化' : this.weatherStatus)
          this.actionRow(this.refreshingWeather ? '正在刷新…' : '立即刷新',
            !this.refreshingWeather, () => {
              this.refreshWeather();
            })

          // ---- 跨设备
          this.groupTitle(t('settings_group_ipc'))
          this.toggleRow('开启跨设备同步', this.distributedEnabled, (on: boolean) => {
            this.toggleDistributed(on);
          })
          this.noteRow('本机名称',
            this.distributedDeviceName.length === 0 ? '未知设备' : this.distributedDeviceName)
          this.valueRow('会话 ID',
            this.distributedSessionId.length === 0 ? '未生成' : this.distributedSessionId, () => {
              this.editingSessionId = !this.editingSessionId;
            })
          if (this.editingSessionId) {
            ListItem() {
              Column() {
                EditorTextField({
                  label: '会话 ID',
                  value: this.distributedSessionId,
                  placeholder: '字母、数字、下划线',
                  onCommit: (text: string) => {
                    this.commitSessionId(text);
                  }
                })
                Text(t('settings_session_hint'))
                  .fontSize(12)
                  .fontColor($r('app.color.ch_text_hint'))
                  .width('100%')
                  .padding({ top: 4 })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            }
          }
          this.actionRow('生成新会话 ID', true, () => {
            this.generateDistributedSessionId();
          })
          this.noteRow(t('settings_status'),
            this.distributedStatus.length === 0 ? '未开启' : this.distributedStatus)

          // ---- 后台保活
          this.groupTitle(t('settings_group_background'))
          this.toggleRow('允许后台运行', this.backgroundKeepAlive, (on: boolean) => {
            this.toggleBackgroundKeepAlive(on);
          })
          this.noteRow(t('settings_status'),
            this.backgroundKeepAliveStatus.length === 0 ? '未启动' : this.backgroundKeepAliveStatus)
          ListItem() {
            Text(t('settings_background_hint'))
              .fontSize(12)
              .fontColor($r('app.color.ch_text_hint'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 6, bottom: 12 })
          }

          // ---- 扩展
          this.groupTitle(t('settings_group_plugins'))
          this.noteRow(t('settings_installed_extensions'), this.pluginSummary)
          this.actionRow('导入扩展（.json）', !this.importing, () => {
            this.importPluginJson();
          })
          this.actionRow('导入扩展（.cipx）', !this.importing, () => {
            this.importPluginCipx();
          })
          if (this.pluginImportError.length > 0) {
            this.noteRow(t('settings_last_import'), t('settings_import_failed_prefix') + this.pluginImportError)
          }
          if (this.pluginRows.length === 0) {
            this.noteRow(t('settings_hint'), t('settings_no_plugins_hint'))
          }
          ForEach(this.pluginRows, (row: PluginListRow) => {
            this.pluginRow(row);
          }, (row: PluginListRow) => row.pluginId)

          // ---- 诊断
          this.groupTitle(t('settings_group_debug'))
          this.toggleRow('调试日志', this.debugLog, (on: boolean) => {
            this.debugLog = on;
            this.writeBool(PrefKeys.DEBUG_LOG, on);
          })
          this.toggleRow('性能叠加层', this.performanceOverlay, (on: boolean) => {
            this.performanceOverlay = on;
            this.writeBool(PrefKeys.PERFORMANCE_OVERLAY, on);
          })

          // ---- 重置
          this.groupTitle(t('settings_group_reset'))
          ListItem() {
            Text('恢复全部默认设置')
              .fontSize(16)
              .fontColor($r('app.color.ch_accent'))
              .width('100%')
              .height(52)
              .padding({ left: 16, right: 16 })
              .textAlign(TextAlign.Start)
          }
          .onClick(() => {
            UiFeedback.confirm(this.getUIContext(), '恢复默认设置',
              t('settings_reset_confirm'), t('settings_reset'), () => {
                this.resetAll();
              });
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.ch_surface_weak'))
        .divider({
          strokeWidth: 1,
          color: $r('app.color.ch_outline'),
          startMargin: 16,
          endMargin: 16
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.ch_surface_weak'))
    // 宽屏封顶居中，理由见 ContentWidth.ets 头注
    .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
    .alignSelf(ItemAlign.Center)
  }
}
