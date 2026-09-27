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
  PrefKeys.PERFORMANCE_OVERLAY
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
