/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 应用设置：读写 settings.json。
 *
 * 这一层是「一个键一个值」的薄封装，没有类型化字段。
 *
 * 为什么不做成强类型字段
 * --------------------
 * 提醒那边（P6）已经按「键 + 默认值」的方式在用了（`getNumber(PrefKeys.X, 60)`），
 * 桌面版那边也是 SettingItem 那一套。改成强类型会让那边全部要跟着改，而强类型
 * 换来的只是编译期检查 —— 值本来就可能是从别的设备同步过来的，指望它在编译期
 * 就合法是不现实的。
 *
 * 落盘形状
 * --------
 * 扁平对象，键名就是 PrefKeys 里的常量，不嵌套、不分组。桌面版那边是嵌套的
 * （Settings.json 里的 Reminder.AdvanceIndoor），但那一套是给设置页自己用的；
 * 这里只存被显式写进去的键，没写过的键不落盘，读时回落默认值。
 * 这样桌面版新加一个设置项时，老版本的鸿蒙侧读到的是默认值，而不是一个
 * 不认识的嵌套结构。
 *
 * 原子写
 * ------
 * 临时文件 + rename。settings.json 会被设置页、自动化 tick、提醒同步同时写，
 * 直接覆写在中途被杀会留下半截 JSON，而半截 JSON 的解析结果是「全部设置回
 * 默认值」—— 用户会以为刚改的全丢了。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import {
  JsonArray,
  JsonBoolean,
  JsonNode,
  JsonNull,
  JsonObject,
  JsonReader,
  JsonString,
  JsonWriter,
  ModelCodec
} from 'common_shared';

const FILE_NAME: string = 'settings.json';
const TEMP_NAME: string = 'settings.json.tmp';

/**
 * 设置键名。
 *
 * 加新键只在这里加一行，别散落到各处 —— 「重置为默认值」与「导入」都要按
 * 这张表遍历，散落的键会被漏掉。
 */
export class PrefKeys {
  /** 课前提醒：总开关。 */
  static readonly REMINDER_ENABLED: string = 'ReminderEnabled';
  /** 课前提醒：室内课提前秒数。 */
  static readonly REMINDER_ADVANCE_INDOOR: string = 'ReminderAdvanceIndoor';
  /** 课前提醒：室外课提前秒数。 */
  static readonly REMINDER_ADVANCE_OUTDOOR: string = 'ReminderAdvanceOutdoor';
  /** 课前提醒：形态覆盖（-1 自动 / 0 精确 / 1 折叠）。 */
  static readonly REMINDER_MODE: string = 'ReminderMode';

  /** 面板：当前布局方案名。 */
  static readonly PANEL_SCHEME: string = 'PanelScheme';

  /** 自动化：总开关。与桌面版 IsAutomationEnabled 同名同义。 */
  static readonly AUTOMATION_ENABLED: string = 'IsAutomationEnabled';
  /** 自动化：当前方案名。与桌面版 CurrentAutomationConfig 同名。 */
  static readonly AUTOMATION_CONFIG: string = 'CurrentAutomationConfig';

  /** 界面：主题（0 跟随系统 / 1 浅色 / 2 深色）。 */
  static readonly THEME: string = 'Theme';
  /** 界面：字体缩放倍数。 */
  static readonly FONT_SCALE: string = 'FontScale';
  /** 界面：首页默认页。 */
  static readonly DEFAULT_PAGE: string = 'DefaultPage';

  /** 课表：是否显示周数。 */
  static readonly SHOW_WEEK_NUM: string = 'ShowWeekNum';
  /** 课表：是否显示课间空档。 */
  static readonly SHOW_FREE_TIME: string = 'ShowFreeTime';
  /** 课表：是否检测时间冲突。 */
  static readonly CONFLICT_DETECTION: string = 'ConflictDetection';
  /** 课表：是否自动定位到当前周。 */
  static readonly AUTO_SELECT_CURRENT_WEEK: string = 'AutoSelectCurrentWeek';

  /** 诊断：是否打调试日志。 */
  static readonly DEBUG_LOG: string = 'DebugLog';
  /** 诊断：是否开性能叠加层。 */
  static readonly PERFORMANCE_OVERLAY: string = 'PerformanceOverlay';

  /*
   * 精确时间（P11）。键名与桌面版 Settings.cs 的属性名逐字一致，且是
   * 顶层扁平键 —— 那边用 System.Text.Json 且没有配 NamingStrategy，
   * 所以落盘就是属性名原样，嵌套结构并不存在。
   *
   * 别把这几个键挪进什么「Time」子对象里：跨端读的是同一个文件，
   * 扁平是为了让两边写出的字节也一致。
   */

  /** 精确时间：NTP 服务器。默认 ntp.aliyun.com。 */
  static readonly EXACT_TIME_SERVER: string = 'ExactTimeServer';
  /** 精确时间：总开关。默认开。 */
  static readonly EXACT_TIME_ENABLED: string = 'IsExactTimeEnabled';
  /** 精确时间：用户手动偏移秒数。默认 0。 */
  static readonly TIME_OFFSET_SECONDS: string = 'TimeOffsetSeconds';
  /** 精确时间：每日自动补偿开关。默认关。 */
  static readonly TIME_AUTO_ADJUST_ENABLED: string = 'IsTimeAutoAdjustEnabled';
  /** 精确时间：每日补偿秒数。默认 0。 */
  static readonly TIME_AUTO_ADJUST_SECONDS: string = 'TimeAutoAdjustSeconds';
  /** 精确时间：上次补偿的基准时刻（ISO 8601）。缺键视为首次运行。 */
  static readonly LAST_TIME_ADJUST: string = 'LastTimeAdjustDateTime';
  /**
   * 精确时间：调试偏移秒数。默认 0。
   *
   * 名字里带 Debug，但桌面版是无条件参与运算、无条件落盘的
   * （ExactTimeService.GetCurrentLocalDateTime 把它加在 TimeOffsetSeconds
   * 之后）。所以这里也得读 —— 不读的话，一个在桌面版上把它调成 5 秒的用户
   * 同步到鸿蒙侧会看到时间差 5 秒，而且没有任何线索指向原因。
   */
  static readonly DEBUG_TIME_OFFSET_SECONDS: string = 'DebugTimeOffsetSeconds';

  /*
   * 语音朗读（P11b）。前六个键名与桌面版 Settings.cs 的属性名逐字一致，
   * 也是顶层扁平键 —— 那边没有配 NamingStrategy，落盘就是属性名原样。
   *
   * SpeechSource 是**遗留字段**：桌面版早期的选择器（0=系统 TTS / 1=EdgeTTS），
   * 现在真正的选择器是 SelectedSpeechProvider。这里照常读写是为了跨端往返
   * （不读的话，一个在桌面上把它改成 1 的用户同步过来的文件会被鸿蒙侧改回 0，
   * 而那是个纯粹的信息丢失），但不拿它做路由。
   *
   * 桌面版的 SpeechSource setter 里有一句「!IsSystemSpeechSystemExist 时强制
   * 置 1」—— 那是为了 Linux/macOS 上没有 Windows 的 System.Speech 而写的。
   * 鸿蒙有系统 TTS，所以这里**不照抄**那个强制转换。
   */

  /** 语音：全局开关。桌面版默认开。 */
  static readonly SPEECH_ENABLED: string = 'IsSpeechEnabled';
  /** 语音：音量（0~1）。 */
  static readonly SPEECH_VOLUME: string = 'SpeechVolume';
  /** 语音：遗留的来源选择（0 系统 TTS / 1 EdgeTTS）。只读写，不参与路由。 */
  static readonly SPEECH_SOURCE: string = 'SpeechSource';
  /** 语音：提供方 id。默认与桌面版一致（classisland.speech.edgeTts）。 */
  static readonly SELECTED_SPEECH_PROVIDER: string = 'SelectedSpeechProvider';
  /** 语音：EdgeTTS 音色名。本端未实现 EdgeTTS，但键要留住。 */
  static readonly EDGE_TTS_VOICE_NAME: string = 'EdgeTtsVoiceName';
  /** 语音：是否允许通知朗读。桌面版默认**关**。 */
  static readonly ALLOW_NOTIFICATION_SPEECH: string = 'AllowNotificationSpeech';
  /**
   * 语音：系统 TTS 的音色（13 女 / 21 男）。
   *
   * 这是**鸿蒙侧独有的键**，桌面版没有对应项：那边的系统 TTS 音色从 Windows
   * 的语音列表里选，是一串名字，与这里的整数编号对不上，硬凑一个映射只会
   * 让两端互相覆盖。桌面版读到这个键会忽略（System.Text.Json 默认跳过不认识的
   * 成员），所以放在同一个文件里是安全的。
   *
   * 与 PrefKeys.PANEL_SCHEME 同一种情况：扁平键里有几个是本端独有的。
   */
  static readonly SYSTEM_SPEECH_PERSON: string = 'SystemSpeechPerson';

  /*
   * 天气（P11c）。九个键名与桌面版 Settings.cs 的属性名逐字一致，且是顶层
   * 扁平键 —— 那边 System.Text.Json 默认无 NamingStrategy，落盘就是属性名原样。
   *
   * LastWeatherInfo **不在这里**：那是天气缓存，本端落 weather.json 独立文件
   * （见 entry/weather/WeatherStore.ets）。桌面版 settings.json 里那份原样保留，
   * 本端不读不写 —— 见 WeatherStore 顶上写的三条理由。
   *
   * ExcludedWeatherAlerts 是数组（桌面版 ObservableCollection<string>），
   * 用 getStringArray / putStringArray 读写，不走 put。
   */
  /** 天气：城市 id（`weathercn:101010100` 形式）。 */
  static readonly CITY_ID: string = 'CityId';
  /** 天气：城市显示名。 */
  static readonly CITY_NAME: string = 'CityName';
  /** 天气：手动定位经度。 */
  static readonly WEATHER_LONGITUDE: string = 'WeatherLongitude';
  /** 天气：手动定位纬度。 */
  static readonly WEATHER_LATITUDE: string = 'WeatherLatitude';
  /** 天气：定位来源（0 用城市 id / 1 自动定位）。 */
  static readonly WEATHER_LOCATION_SOURCE: string = 'WeatherLocationSource';
  /** 天气：是否每次刷新都重新定位。 */
  static readonly AUTO_REFRESH_WEATHER_LOCATION: string = 'AutoRefreshWeatherLocation';
  /** 天气：是否强制明文 HTTP。 */
  static readonly NO_TLS_WEATHER_REQUESTS: string = 'NoTLSWeatherRequests';
  /** 天气：图标方案 id。本端不移植图标字体，键照常读写。 */
  static readonly WEATHER_ICON_ID: string = 'WeatherIconId';
  /** 天气：被排除的预警（按标题 / 详情子串匹配，数组）。 */
  static readonly EXCLUDED_WEATHER_ALERTS: string = 'ExcludedWeatherAlerts';

  /*
   * 跨设备（P11d）。这两个是本端独有的键 —— 桌面版没有跨设备能力，那边的
   * IPC 是命名管道，只在同一台机器内用。
   *
   * DistributedSessionId 是一条会话的标识：两端填同一个 ID 才会进同一个
   * 会话，所以它必须落盘、可复制、可手工填。空串表示「还没生成过」，首次
   * 开启同步时用 distributedDataObject.genSessionId() 生成后写回。
   */
  /** 跨设备：是否开启公开状态同步。 */
  static readonly DISTRIBUTED_SYNC_ENABLED: string = 'DistributedSyncEnabled';
  /** 跨设备：会话 ID（字母 / 数字 / 下划线，≤128）。 */
  static readonly DISTRIBUTED_SESSION_ID: string = 'DistributedSessionId';

  /*
   * 后台保活（P11e）。本端独有：桌面版是常驻进程，没有「要不要保活」的问题。
   *
   * 默认开 —— 课前一分钟提醒、上下课通知最常发生在应用不在前台的时候，
   * 不开的话这些功能只剩「用户正看着屏幕」那一种场景。申请不到长时任务的
   * 设备（手机上的「任务保持」类型需要受限权限）会回落成「仅前台」，
   * 不影响其余功能，设置页会把回落原因写出来。
   */
  /** 后台保活：是否申请长时任务。 */
  static readonly BACKGROUND_KEEP_ALIVE: string = 'BackgroundKeepAlive';
}

/** 全部可识别的键。导出是为了「重置」与「导入」能遍历。 */
export const ALL_PREF_KEYS: string[] = [
  PrefKeys.REMINDER_ENABLED,
  PrefKeys.REMINDER_ADVANCE_INDOOR,
  PrefKeys.REMINDER_ADVANCE_OUTDOOR,
  PrefKeys.REMINDER_MODE,
  PrefKeys.PANEL_SCHEME,
  PrefKeys.AUTOMATION_ENABLED,
  PrefKeys.AUTOMATION_CONFIG,
  PrefKeys.THEME,
  PrefKeys.FONT_SCALE,
  PrefKeys.DEFAULT_PAGE,
  PrefKeys.SHOW_WEEK_NUM,
  PrefKeys.SHOW_FREE_TIME,
  PrefKeys.CONFLICT_DETECTION,
  PrefKeys.AUTO_SELECT_CURRENT_WEEK,
  PrefKeys.DEBUG_LOG,
  PrefKeys.PERFORMANCE_OVERLAY,
  PrefKeys.EXACT_TIME_SERVER,
  PrefKeys.EXACT_TIME_ENABLED,
  PrefKeys.TIME_OFFSET_SECONDS,
  PrefKeys.TIME_AUTO_ADJUST_ENABLED,
  PrefKeys.TIME_AUTO_ADJUST_SECONDS,
  PrefKeys.LAST_TIME_ADJUST,
  PrefKeys.DEBUG_TIME_OFFSET_SECONDS,
  PrefKeys.SPEECH_ENABLED,
  PrefKeys.SPEECH_VOLUME,
  PrefKeys.SPEECH_SOURCE,
  PrefKeys.SELECTED_SPEECH_PROVIDER,
  PrefKeys.EDGE_TTS_VOICE_NAME,
  PrefKeys.ALLOW_NOTIFICATION_SPEECH,
  PrefKeys.SYSTEM_SPEECH_PERSON,
  PrefKeys.CITY_ID,
  PrefKeys.CITY_NAME,
  PrefKeys.WEATHER_LONGITUDE,
  PrefKeys.WEATHER_LATITUDE,
  PrefKeys.WEATHER_LOCATION_SOURCE,
  PrefKeys.AUTO_REFRESH_WEATHER_LOCATION,
  PrefKeys.NO_TLS_WEATHER_REQUESTS,
  PrefKeys.WEATHER_ICON_ID,
  PrefKeys.EXCLUDED_WEATHER_ALERTS,
  PrefKeys.DISTRIBUTED_SYNC_ENABLED,
  PrefKeys.DISTRIBUTED_SESSION_ID,
  PrefKeys.BACKGROUND_KEEP_ALIVE
];

/** 主题档位。值必须与桌面版 Settings.Theme 一致（那边以整数落盘）。 */
export enum ThemeMode {
  /** 跟随系统。默认。 */
  System = 0,
  /** 强制浅色。 */
  Light = 1,
  /** 强制深色。 */
  Dark = 2
}

/** 首页默认页。 */
export enum DefaultPage {
  Schedule = 0,
  Editor = 1,
  Panel = 2,
  Automation = 3
}

/*
 * 精确时间的默认值。必须与桌面版 Settings.cs 第 139-148 行的字段初始值
 * 一致（那边没有 [JsonPropertyName]，也没有 DefaultValue 特性，默认值来自
 * 字段初始化器）：
 *
 *   _exactTimeServer         = "ntp.aliyun.com"
 *   _isExactTimeEnabled      = true
 *   _timeOffsetSeconds       = 0.0
 *   _isTimeAutoAdjustEnabled = false
 *   _timeAutoAdjustSeconds   = 0.0
 *   _lastTimeAdjustDateTime  = DateTime.Now
 *   _debugTimeOffsetSeconds  = 0.0
 *
 * 桌面版对 IsExactTimeEnabled 的默认值是「开」。这是本项目唯一一处默认
 * 开启联网功能的地方，不跟着改 —— 改了两端默认值就不一致了，而默认值
 * 不一致是最难被发现的那种不一致。
 */
export const DEFAULT_EXACT_TIME_SERVER: string = 'ntp.aliyun.com';
/** 手动偏移的合理范围（秒）。超出会被夹住。 */
export const TIME_OFFSET_LIMIT: number = 86400;

/*
 * 语音朗读的默认值。前六个同样必须与桌面版 Settings.cs 的字段初值一致：
 *
 *   _isSpeechEnabled          = true
 *   _speechVolume             = 1.0
 *   _speechSource             = 0
 *   _selectedSpeechProvider   = "classisland.speech.edgeTts"
 *   _edgeTtsVoiceName         = "zh-CN-XiaoxiaoNeural"
 *   _allowNotificationSpeech  = false
 *
 * 注意 SelectedSpeechProvider 的默认值：那是本端**没有实现**的提供方。刻意
 * 不改成本端的首选（系统 TTS）—— 这个键是跨端读写的，改了之后用户在桌面上
 * 存的偏好会被鸿蒙侧的默认值覆盖。不可用由 resolveSpeechProvider 回退，
 * 设置页会把回退说出来。
 */
export const DEFAULT_SPEECH_ENABLED: boolean = true;
export const DEFAULT_SPEECH_VOLUME: number = 1.0;
export const DEFAULT_SPEECH_SOURCE: number = 0;
export const DEFAULT_SELECTED_SPEECH_PROVIDER: string = 'classisland.speech.edgeTts';
export const DEFAULT_EDGE_TTS_VOICE_NAME: string = 'zh-CN-XiaoxiaoNeural';
export const DEFAULT_ALLOW_NOTIFICATION_SPEECH: boolean = false;
/** 系统 TTS 音色：13 = 凌晓山（女声，推荐值，无需下载）。 */
export const DEFAULT_SYSTEM_SPEECH_PERSON: number = 13;

/*
 * 天气默认值。前八个与桌面版 Settings.cs 的字段初值逐字一致：
 *
 *   _cityId                   = "weathercn:101010100"
 *   _cityName                 = "北京 (北京, 中国)"
 *   _weatherLongitude         = 0.0
 *   _weatherLatitude          = 0.0
 *   _weatherLocationSource    = 0
 *   _autoRefreshWeatherLocation = false
 *   _noTLSWeatherRequests     = false
 *   _weatherIconId            = "classisland.weatherIcons.lucide"
 *   _excludedWeatherAlerts    = []
 */
export const DEFAULT_CITY_ID: string = 'weathercn:101010100';
export const DEFAULT_CITY_NAME: string = '北京 (北京, 中国)';
export const DEFAULT_WEATHER_LONGITUDE: number = 0.0;
export const DEFAULT_WEATHER_LATITUDE: number = 0.0;
/** 0 = 用 CityId 查；1 = 用设备定位。 */
export const DEFAULT_WEATHER_LOCATION_SOURCE: number = 0;
export const DEFAULT_AUTO_REFRESH_WEATHER_LOCATION: boolean = false;
export const DEFAULT_NO_TLS_WEATHER_REQUESTS: boolean = false;
export const DEFAULT_WEATHER_ICON_ID: string = 'classisland.weatherIcons.lucide';

/*
 * 跨设备默认值。默认关：这是一条会把课表状态广播给同网设备的路径，
 * 必须显式开启（与桌面版 IPC 只在本机、不需要额外开关的情况不同）。
 */
export const DEFAULT_DISTRIBUTED_SYNC_ENABLED: boolean = false;
/** 空串 = 还没生成过；首次开启时用系统 genSessionId() 生成。 */
export const DEFAULT_DISTRIBUTED_SESSION_ID: string = '';

/*
 * 后台保活默认开。理由：课前一分钟提醒、上下课通知最常发生在应用不在
 * 前台的时候；默认关等于把「提醒」限制在用户正看着屏幕的场景，那正是最
 * 不需要提醒的场景。申请不到长时任务的设备会回落成仅前台，不报错。
 */
export const DEFAULT_BACKGROUND_KEEP_ALIVE: boolean = true;

/** 字体缩放下界。 */
export const FONT_SCALE_MIN: number = 0.8;
/** 字体缩放上界。 */
export const FONT_SCALE_MAX: number = 1.6;

export class AppPreferences {
  private readonly dir: string;

  /**
   * 收 context 而不是 filesDir。
   *
   * filesDir 在鸿蒙侧有两种取法（`context.filesDir` 与
   * `context.context.filesDir`），混用过一次就会在跨端时读错目录。收 context
   * 把这个选择收在这一处。
   */
  constructor(context: common.Context) {
    this.dir = context.filesDir;
  }

  private path(): string {
    return `${this.dir}/${FILE_NAME}`;
  }

  /**
   * 读整个 settings.json。
   *
   * 文件不存在、被截断、不是对象 —— 三种情况都返回空对象。第一种是首次
   * 运行，后两种是上次写崩了。都不该抛：抛了的话整个应用起不来，而「设置
   * 读不出来」的表现应该是「全用默认值」，不是「白屏」。
   */
  private readAll(): JsonObject {
    try {
      const content: string = fs.readTextSync(this.path());
      const node: JsonNode = JsonReader.parse(content);
      if (node instanceof JsonObject) {
        return node;
      }
      return new JsonObject();
    } catch {
      return new JsonObject();
    }
  }

  /**
   * 原子写。
   *
   * 同进程内没人会同时写（都是单线程的 UI 回调），而跨进程的那几个扩展写的是
   * 各自的文件，不碰 settings.json。所以「临时文件 + rename」已经够了，
   * 不需要加锁。
   */
  private writeAll(obj: JsonObject): void {
    const temp: string = `${this.dir}/${TEMP_NAME}`;
    const file: fs.File = fs.openSync(temp,
      fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JsonWriter.writeCompact(obj), { encoding: 'utf-8' });
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(temp, this.path());
  }

  // ------------------------------------------------------------ 读

  getString(key: string, fallback: string): string {
    return ModelCodec.string(this.readAll(), key, fallback);
  }

  getBoolean(key: string, fallback: boolean): boolean {
    return ModelCodec.bool(this.readAll(), key, fallback);
  }

  getNumber(key: string, fallback: number): number {
    return ModelCodec.number(this.readAll(), key, fallback);
  }

  // ------------------------------------------------------------ 写

  /**
   * 写一个标量。
   *
   * 收联合类型而不是分 putString / putBoolean / putNumber 三个方法：调用点
   * （`prefs.put(PrefKeys.REMINDER_ENABLED, this.enabled)`）不需要关心值的
   * 类型，而值本来就只有这三种。联合类型在这里不构成 ArkTS 的结构化类型
   * 问题，因为它不是对象字面量。
   */
  put(key: string, value: string | number | boolean): void {
    const all: JsonObject = this.readAll();
    if (typeof value === 'string') {
      all.set(key, new JsonString(value));
    } else if (typeof value === 'number') {
      all.set(key, ModelCodec.doubleNode(value));
    } else {
      all.set(key, new JsonBoolean(value));
    }
    this.writeAll(all);
  }

  /**
   * 写一个被夹到 [min, max] 的整数。
   *
   * 提前量、字体缩放都用这个。夹在写侧而不是读侧：读侧夹意味着坏值一直在盘
   * 上，每次启动都被夹一次；写侧夹意味着它当场就正了。
   */
  putClamped(key: string, value: number, min: number, max: number): void {
    this.put(key, AppPreferences.clampInt(value, min, max));
  }

  /**
   * 读一个字符串数组。
   *
   * 只用于天气的 ExcludedWeatherAlerts。非数组、元素非字符串一律跳过，
   * 不抛也不整份作废：这个键从桌面版同步过来时可能混着别的类型，丢一个
   * 坏元素比丢掉整份排除列表更不伤。
   */
  getStringArray(key: string): string[] {
    const out: string[] = [];
    const node: JsonNode | undefined = this.readAll().tryGet(key);
    if (node === undefined || !(node instanceof JsonArray)) {
      return out;
    }
    for (const item of node.values()) {
      if (item instanceof JsonString) {
        out.push(item.value);
      }
    }
    return out;
  }

  /** 写一个字符串数组。空数组也照写（与桌面版写 `[]` 一致）。 */
  putStringArray(key: string, values: string[]): void {
    const array: JsonArray = new JsonArray();
    for (const value of values) {
      array.push(new JsonString(value));
    }
    const all: JsonObject = this.readAll();
    all.set(key, array);
    this.writeAll(all);
  }

  /** 删除一个键。唯一用到它的是「重置」里那些没有默认值的键。 */
  remove(key: string): void {
    const all: JsonObject = this.readAll();
    all.set(key, new JsonNull());
    this.writeAll(all);
  }

  // ------------------------------------------------------------ 语义读取

  /**
   * 主题档位。
   *
   * 越界值回落跟随系统：桌面版加了一档新主题时，老版本读到 3 不该崩，
   * 按「跟随系统」渲染是所有取值里最不会出事的。
   */
  theme(): ThemeMode {
    const raw: number = this.getNumber(PrefKeys.THEME, ThemeMode.System);
    if (raw === ThemeMode.Light || raw === ThemeMode.Dark) {
      return raw as ThemeMode;
    }
    return ThemeMode.System;
  }

  setTheme(value: ThemeMode): void {
    this.put(PrefKeys.THEME, value);
  }

  /**
   * 字体缩放。
   *
   * 非有限数与越界值都夹到合法区间，不回落 1.0：用户明明拖过滑块，坏了也该
   * 看到边缘值（最直观地告诉他「改了但没生效」）而不是无声地回到默认。
   */
  fontScale(): number {
    const raw: number = this.getNumber(PrefKeys.FONT_SCALE, 1.0);
    if (!isFinite(raw)) {
      return 1.0;
    }
    return AppPreferences.clampNumber(raw, FONT_SCALE_MIN, FONT_SCALE_MAX);
  }

  setFontScale(value: number): void {
    this.put(PrefKeys.FONT_SCALE, AppPreferences.clampNumber(
      value, FONT_SCALE_MIN, FONT_SCALE_MAX));
  }

  /** 首页默认页。越界回落课表页。 */
  defaultPage(): DefaultPage {
    const raw: number = this.getNumber(PrefKeys.DEFAULT_PAGE, DefaultPage.Schedule);
    if (raw >= DefaultPage.Schedule && raw <= DefaultPage.Automation) {
      return raw as DefaultPage;
    }
    return DefaultPage.Schedule;
  }

  setDefaultPage(value: DefaultPage): void {
    this.put(PrefKeys.DEFAULT_PAGE, value);
  }

  // ------------------------------------------------------------ 整体操作

  /**
   * 全部恢复默认。
   *
   * 按 defaults() 表走，而不是「删掉所有键让读侧回落」：后者在「默认值被改过」
   * 之后就不对了 —— 改了一次默认值，删了键，用户拿到的是新默认值，而不是他
   * 点重置时该拿到的那次。
   *
   * 表里没有的键写成 null 而不是删掉：JsonObject 没有 delete，置 null 是这里
   * 唯一能表达「这个键到此为止」的方式，读侧的 tryGet 拿到 JsonNull 会走类型
   * 判断、回落到默认值。
   */
  resetToDefaults(): void {
    const all: JsonObject = this.readAll();
    const defaults: JsonObject = AppPreferences.defaults();
    for (const key of ALL_PREF_KEYS) {
      const fallback: JsonNode | undefined = defaults.tryGet(key);
      if (fallback === undefined) {
        all.set(key, new JsonNull());
        continue;
      }
      all.set(key, ModelCodec.cloneNode(fallback));
    }
    this.writeAll(all);
  }

  /**
   * 默认值表。
   *
   * 提醒那几项与 ReminderSettings 的字段初值一致（室内 60 / 室外 600 /
   * 自动 -1），重复写在这里是有意的：那张表是「重置」的唯一依据，如果它从
   * ReminderSettings 读初值，两处就绑死了，将来改了一处忘了另一处，
   * 「重置」会把用户重置到一个与新建档案时不同的状态。
   */
  static defaults(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set(PrefKeys.REMINDER_ENABLED, new JsonBoolean(true));
    out.set(PrefKeys.REMINDER_ADVANCE_INDOOR, ModelCodec.doubleNode(60));
    out.set(PrefKeys.REMINDER_ADVANCE_OUTDOOR, ModelCodec.doubleNode(600));
    out.set(PrefKeys.REMINDER_MODE, ModelCodec.doubleNode(-1));
    out.set(PrefKeys.PANEL_SCHEME, new JsonString('Default'));
    out.set(PrefKeys.AUTOMATION_ENABLED, new JsonBoolean(true));
    out.set(PrefKeys.AUTOMATION_CONFIG, new JsonString('Default'));
    out.set(PrefKeys.THEME, ModelCodec.doubleNode(ThemeMode.System));
    out.set(PrefKeys.FONT_SCALE, ModelCodec.doubleNode(1.0));
    out.set(PrefKeys.DEFAULT_PAGE, ModelCodec.doubleNode(DefaultPage.Schedule));
    out.set(PrefKeys.SHOW_WEEK_NUM, new JsonBoolean(true));
    out.set(PrefKeys.SHOW_FREE_TIME, new JsonBoolean(true));
    out.set(PrefKeys.CONFLICT_DETECTION, new JsonBoolean(true));
    out.set(PrefKeys.AUTO_SELECT_CURRENT_WEEK, new JsonBoolean(true));
    out.set(PrefKeys.DEBUG_LOG, new JsonBoolean(false));
    out.set(PrefKeys.PERFORMANCE_OVERLAY, new JsonBoolean(false));
    out.set(PrefKeys.SPEECH_ENABLED, new JsonBoolean(DEFAULT_SPEECH_ENABLED));
    out.set(PrefKeys.SPEECH_VOLUME, ModelCodec.doubleNode(DEFAULT_SPEECH_VOLUME));
    out.set(PrefKeys.SPEECH_SOURCE, ModelCodec.doubleNode(DEFAULT_SPEECH_SOURCE));
    out.set(PrefKeys.SELECTED_SPEECH_PROVIDER,
      new JsonString(DEFAULT_SELECTED_SPEECH_PROVIDER));
    out.set(PrefKeys.EDGE_TTS_VOICE_NAME, new JsonString(DEFAULT_EDGE_TTS_VOICE_NAME));
    out.set(PrefKeys.ALLOW_NOTIFICATION_SPEECH,
      new JsonBoolean(DEFAULT_ALLOW_NOTIFICATION_SPEECH));
    out.set(PrefKeys.SYSTEM_SPEECH_PERSON, ModelCodec.doubleNode(DEFAULT_SYSTEM_SPEECH_PERSON));
    out.set(PrefKeys.CITY_ID, new JsonString(DEFAULT_CITY_ID));
    out.set(PrefKeys.CITY_NAME, new JsonString(DEFAULT_CITY_NAME));
    out.set(PrefKeys.WEATHER_LONGITUDE, ModelCodec.doubleNode(DEFAULT_WEATHER_LONGITUDE));
    out.set(PrefKeys.WEATHER_LATITUDE, ModelCodec.doubleNode(DEFAULT_WEATHER_LATITUDE));
    out.set(PrefKeys.WEATHER_LOCATION_SOURCE,
      ModelCodec.doubleNode(DEFAULT_WEATHER_LOCATION_SOURCE));
    out.set(PrefKeys.AUTO_REFRESH_WEATHER_LOCATION,
      new JsonBoolean(DEFAULT_AUTO_REFRESH_WEATHER_LOCATION));
    out.set(PrefKeys.NO_TLS_WEATHER_REQUESTS,
      new JsonBoolean(DEFAULT_NO_TLS_WEATHER_REQUESTS));
    out.set(PrefKeys.WEATHER_ICON_ID, new JsonString(DEFAULT_WEATHER_ICON_ID));
    out.set(PrefKeys.EXCLUDED_WEATHER_ALERTS, new JsonArray());
    out.set(PrefKeys.DISTRIBUTED_SYNC_ENABLED,
      new JsonBoolean(DEFAULT_DISTRIBUTED_SYNC_ENABLED));
    out.set(PrefKeys.DISTRIBUTED_SESSION_ID, new JsonString(DEFAULT_DISTRIBUTED_SESSION_ID));
    out.set(PrefKeys.BACKGROUND_KEEP_ALIVE, new JsonBoolean(DEFAULT_BACKGROUND_KEEP_ALIVE));
    return out;
  }

  /** 导出成 JSON 文本（备份 / 分享用，不落盘）。 */
  exportText(): string {
    return JsonWriter.writeCompact(this.readAll());
  }

  /**
   * 从 JSON 文本导入。
   *
   * 只收可识别的键，其余不参与 —— 但也**不删**。这份文本可能来自比当前版本
   * 新的桌面版，里面有些键这一版还不认识。直接整份覆盖的话，用户在两个版本
   * 之间来回同步一次就永久丢了那些设置。
   *
   * 逐键写而不是攒一次写：攒一次写要先把 16 个键读出来放进一个临时对象，
   * 而写盘失败时是全不生效还是全生效取决于失败点，行为比「逐个写、失败就
   * 停在已经写了的那些」更难解释。
   */
  importText(text: string): boolean {
    let node: JsonNode;
    try {
      node = JsonReader.parse(text);
    } catch {
      return false;
    }
    if (!(node instanceof JsonObject)) {
      return false;
    }
    for (const key of ALL_PREF_KEYS) {
      const incoming: JsonNode | undefined = node.tryGet(key);
      if (incoming === undefined) {
        continue;
      }
      this.putNode(key, incoming);
    }
    return true;
  }

  /** 写一个原始节点（导入时用；调用方保证键是可识别的）。 */
  private putNode(key: string, value: JsonNode): void {
    const all: JsonObject = this.readAll();
    all.set(key, ModelCodec.cloneNode(value));
    this.writeAll(all);
  }

  // ------------------------------------------------------------ 夹取

  /**
   * 夹到 [min, max] 并取整。
   *
   * 非有限数（NaN / Infinity）换成 min 而不是某个默认值：出现 NaN 说明上游
   * 算错了，而 min 在「提前量」这个量上就是「上课那一刻才提醒」—— 所有取值里
   * 最不会出事的一个。换成 60 则是凭空给出一个用户没要求过的行为。
   */
  static clampInt(value: number, min: number, max: number): number {
    if (!isFinite(value)) {
      return min;
    }
    const rounded: number = Math.round(value);
    if (rounded < min) {
      return min;
    }
    if (rounded > max) {
      return max;
    }
    return rounded;
  }

  static clampNumber(value: number, min: number, max: number): number {
    if (!isFinite(value)) {
      return min;
    }
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }
}
