/**
 * 自动化行动的执行器（entry 侧，有 UIAbilityContext，可调用 terminateSelf）。
 *
 * 已实现的 5 个行动：
 *  - classisland.action.sleep        → 等待指定秒数
 *  - classisland.settings            → 修改应用设置（写 settings.json）
 *  - classisland.app.quit            → 退出应用（调用 terminateSelf）
 *  - classisland.showNotification    → 显示本地通知
 *  - classisland.notification.weather → 显示天气提醒（预报 / 预警 / 逐时）
 *
 * 未实现的 2 个行动（占位，返回 false 供上层记录失败）：
 *  - classisland.os.run            → 鸿蒙无法拉起任意进程
 *  - classisland.app.restart       → 无对应物
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { JsonNode, JsonObject, JsonReader, JsonWriter } from 'common_shared';
import { ActionIds } from 'common_shared';
import {
  SleepActionSettings,
  ModifyAppSettingsActionSettings,
  NotificationActionSettings,
  WeatherNotificationActionSettings,
  ActionItem,
  RangedValue,
  WeatherAlert,
  WeatherInfo,
  DateTimeValue
} from 'common_shared';
import { weatherTextByCode } from 'common_core';
import { AutomationSettings } from './AutomationSettings';
import { common } from '@kit.AbilityKit';
import { NotificationService, NotificationCategory } from '../notification/NotificationService';
import { WeatherService, resolveWeatherService } from '../weather/WeatherService';

/** 执行结果：true=成功，false=失败 */
export type ExecResult = boolean;

/** 执行器需要的上下文 */
export interface ExecutorContext {
  context: common.UIAbilityContext;
  filesDir: string;
}

/** 原因文本载体 */
export class CauseText {
  value: string = '';
}

export class AutomationExecutor {
  private readonly ctx: ExecutorContext;
  private readonly settings: AutomationSettings;
  private readonly notificationService: NotificationService;
  /**
   * 已经发过的预警详情。
   *
   * 桌面版 WeatherNotificationProvider 上有同样一份 `ShownAlerts`，作用是
   * 「同一条预警只弹一次」—— 否则每次触发都会把当前所有预警重弹一遍。执行器
   * 与调度器同生命周期（进程内唯一），所以这里存得住。
   */
  private readonly shownAlerts: Set<string> = new Set<string>();

  constructor(ctx: ExecutorContext) {
    this.ctx = ctx;
    this.settings = new AutomationSettings(ctx.filesDir);
    this.notificationService = new NotificationService(ctx.context);
  }

  /** 执行单个行动 */
  async execute(action: ActionItem, causeText: CauseText): Promise<ExecResult> {
    switch (action.id) {
      case ActionIds.SLEEP:
        return this.execSleep(action, causeText);
      case ActionIds.SETTINGS:
        return this.execModifySettings(action, causeText);
      case ActionIds.APP_QUIT:
        return this.execQuit(action, causeText);
      case ActionIds.SHOW_NOTIFICATION:
        return this.execShowNotification(action, causeText);
      case ActionIds.NOTIFICATION_WEATHER:
        return this.execWeatherNotification(action, causeText);
      case ActionIds.OS_RUN:
        causeText.value = '行动「运行程序」在鸿蒙上不可用';
        return false;
      case ActionIds.APP_RESTART:
        causeText.value = '行动「重启应用」无对应实现';
        return false;
      default:
        causeText.value = `未知行动 id：${action.id}`;
        return false;
    }
  }

  /** classisland.action.sleep：等待 Value 秒（支持小数） */
  private async execSleep(action: ActionItem, causeText: CauseText): Promise<ExecResult> {
    const s: SleepActionSettings | undefined = SleepActionSettings.parse(action.settings);
    if (s === undefined) {
      causeText.value = 'Sleep 设置解析失败';
      return false;
    }
    const seconds: number = s.value;
    if (seconds <= 0) {
      causeText.value = '睡眠时长必须 > 0';
      return false;
    }
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, Math.floor(seconds * 1000));
    });
    return true;
  }

  /** classisland.settings：修改应用设置（写 settings.json） */
  private async execModifySettings(action: ActionItem, causeText: CauseText): Promise<ExecResult> {
    const s: ModifyAppSettingsActionSettings | undefined = ModifyAppSettingsActionSettings.parse(action.settings);
    if (s === undefined) {
      causeText.value = 'ModifyAppSettings 设置解析失败';
      return false;
    }
    if (s.name === '' || s.name === undefined) {
      return true;
    }
    const path: string = `${this.ctx.filesDir}/settings.json`;
    let all: JsonObject = new JsonObject();
    try {
      const content: string = fs.readTextSync(path);
      const node: JsonNode = JsonReader.parse(content);
      if (node instanceof JsonObject) {
        all = node;
      }
    } catch {
      // 文件不存在或解析失败，按空对象处理
    }

    switch (s.mode) {
      case 0: // Replace
        if (s.value !== undefined) {
          all.set(s.name, s.value);
        } else {
          all.set(s.name, JsonNull.getInstance());
        }
        break;
      case 1: // Merge
        if (s.value instanceof JsonObject) {
          const existing: JsonNode | undefined = all.tryGet(s.name);
          if (existing !== undefined && existing instanceof JsonObject) {
            this.mergeObject(existing, s.value);
          } else {
            all.set(s.name, s.value);
          }
        }
        break;
      case 2: // Delete
        all = this.removeKey(all, s.name);
        break;
      default:
        causeText.value = `未知的设置修改模式：${s.mode}`;
        return false;
    }

    const tmp: string = `${path}.tmp.${Date.now()}`;
    const file: fs.File = fs.openSync(tmp, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JsonWriter.writeCompact(all), { encoding: 'utf-8' });
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(tmp, path);
    return true;
  }

  /** classisland.showNotification：显示本地通知 */
  private async execShowNotification(action: ActionItem, causeText: CauseText): Promise<ExecResult> {
    const s: NotificationActionSettings | undefined = NotificationActionSettings.parse(action.settings);
    if (s === undefined) {
      causeText.value = 'Notification 设置解析失败';
      return false;
    }

    // 等待初始化完成
    await this.notificationService.initialize();

    // 发布通知
    const category: NotificationCategory = NotificationCategory.Automation;
    const mask: string = s.mask ?? '';
    const content: string = s.content ?? '';
    /*
     * 念哪一句。
     *
     * 桌面版的提醒内容是「大字遮罩 + 正文」两部分，各自带 IsSpeechEnabled，
     * 但 NotificationWorkerService 有一个「一个会话只发一次声」的守卫
     * （HasSoundsPlayed），所以一条提醒只会念一段。遮罩是先出现的那个（它盖在
     * 屏幕上），因此有遮罩就念遮罩，没有才念正文 —— 与桌面版的实际效果一致。
     *
     * 念短的那一句也更合理：遮罩是「上课了」这种抓注意力的话，正文是「第 1 节
     * 语文 · 张三」这种细节。提醒的全部价值在于快。
     */
    const hasMask: boolean = mask.trim().length > 0;
    await this.notificationService.publish(category, {
      title: hasMask ? mask : 'ClassIsland',
      content: content,
      subText: '',
      ongoing: false,
      color: 0xFF0077D4, // ch_accent
      /*
       * 只把文本交给 publish，由 NotificationService 统一判断三个开关并入队
       * （见那里的 maybeSpeak）。这里**不**另外调一次朗读 —— 两处都念会让
       * 同一句话被念两遍，而且第二遍还在第一遍念完之后，听起来像回声。
       */
      speechText: hasMask ? mask : content,
      speechEnabled: hasMask ? s.isMaskSpeechEnabled : s.isContentSpeechEnabled
    });

    return true;
  }

  /**
   * classisland.notification.weather：发一条天气提醒。
   *
   * 三种（对应桌面版 WeatherNotificationActionSettings.NotificationKind）：
   *   0 = 三天预报（今天 / 明天 / 后天）
   *   1 = 气象预警（逐条发：标题 + 详情）
   *   2 = 逐小时预报（未来 6 小时）
   *
   * 与桌面版的差异
   * ------------
   * 桌面版走 WeatherNotificationProvider 的 mask + overlay 两套内容，预警带
   * 图标、详情用滚动文本。本端只有一条普通通知，压成「标题 + 正文」。
   * 天气预报的图标字体未移植，所以预报正文里的天气一律用中文文字
   * （`weatherTextByCode`），不画图标。
   */
  private async execWeatherNotification(action: ActionItem,
    causeText: CauseText): Promise<ExecResult> {
    const s: WeatherNotificationActionSettings | undefined =
      WeatherNotificationActionSettings.parse(action.settings);
    if (s === undefined) {
      causeText.value = 'WeatherNotification 设置解析失败';
      return false;
    }

    // 天气数据由进程内单例持有。拿不到就是「还没有数据」，不是错误 ——
    // 用户大多是「刚开机就触发了这条自动化」，等下一次刷新就好。
    const service: WeatherService = resolveWeatherService(this.ctx.context);
    const info: WeatherInfo = service.lastInfo();
    if (!info.hasData()) {
      causeText.value = '还没有天气数据，等下一次刷新';
      return false;
    }

    await this.notificationService.initialize();

    let ok: boolean = false;
    switch (s.notificationKind) {
      case 0:
        ok = await this.publishForecast(info);
        break;
      case 1:
        ok = await this.publishAlerts(info);
        break;
      case 2:
        ok = await this.publishHourly(info);
        break;
      default:
        causeText.value = `未知的天气提醒种类：${s.notificationKind}`;
        return false;
    }
    if (!ok) {
      // 三种都是「数据是空的所以没东西可发」，不是失败。
      causeText.value = '没有可播报的天气内容';
    }
    return ok;
  }

  /** 三天预报：今天 / 明天 / 后天。 */
  private async publishForecast(info: WeatherInfo): Promise<ExecResult> {
    const labels: string[] = ['今天', '明天', '后天'];
    const weatherValues: RangedValue[] = info.forecastDaily.weather.value;
    const temperatureValues: RangedValue[] = info.forecastDaily.temperature.value;
    const parts: string[] = [];
    for (let i = 0; i < labels.length; i++) {
      if (i >= weatherValues.length || i >= temperatureValues.length) {
        continue;
      }
      parts.push(`${labels[i]} ${describeWeatherRange(weatherValues[i])}`
        + ` ${describeTemperatureRange(temperatureValues[i])}`);
    }
    if (parts.length === 0) {
      return false;
    }
    await this.notificationService.publish(NotificationCategory.Weather, {
      title: '天气预报',
      content: parts.join('  '),
      subText: '',
      ongoing: false,
      color: 0xFF0077D4, // ch_accent（与自动化通知同一支）
      speechText: parts.join('，')
    });
    return true;
  }

  /** 逐小时预报：从最近一个整点起的 6 个小时。 */
  private async publishHourly(info: WeatherInfo): Promise<ExecResult> {
    const temperatures: number[] = info.forecastHourly.temperature.value;
    const codes: number[] = info.forecastHourly.weather.value;
    const count: number = Math.min(6, Math.min(temperatures.length, codes.length));
    if (count <= 0) {
      return false;
    }
    // 基准时间向上取整到整点（桌面版 RoundUpToHour）：updateTime 落在 14:37
    // 时第一格是 15:00，而不是 14:00 —— 14:00 已经过去了。
    let base: DateTimeValue = DateTimeValue.fromLocalMillis(info.updateTime);
    const remainder: number = base.timeOfDaySeconds() % 3600;
    if (remainder !== 0) {
      base = base.addSeconds(3600 - remainder);
    }
    const parts: string[] = [];
    for (let i = 0; i < count; i++) {
      const at: DateTimeValue = base.addSeconds(i * 3600);
      const hour: number = Math.floor(at.timeOfDaySeconds() / 3600);
      parts.push(`${pad2(hour)}:00 ${weatherTextByCode(`${codes[i]}`)} ${temperatures[i]}℃`);
    }
    await this.notificationService.publish(NotificationCategory.Weather, {
      title: '天气预报',
      content: parts.join('  '),
      subText: '',
      ongoing: false,
      color: 0xFF0077D4,
      speechText: parts.join('，')
    });
    return true;
  }

  /** 气象预警：每条一条通知，已发过的不重发。 */
  private async publishAlerts(info: WeatherInfo): Promise<ExecResult> {
    const pending: WeatherAlert[] = [];
    for (const alert of info.alerts) {
      if (!this.shownAlerts.has(alert.detail)) {
        pending.push(alert);
      }
    }
    if (pending.length === 0) {
      return false;
    }
    for (const alert of pending) {
      const title: string = alert.title.length > 0 ? alert.title : '气象预警';
      await this.notificationService.publish(NotificationCategory.Weather, {
        title: title,
        content: alert.detail,
        subText: '',
        ongoing: false,
        color: 0xFFD84315, // 预警用暖色，与普通预报区分
        speechText: title
      });
      this.shownAlerts.add(alert.detail);
    }
    return true;
  }

  /** 深合并两个 JsonObject（src 覆盖 dst） */
  private mergeObject(dst: JsonObject, src: JsonObject): void {
    const members: readonly { name: string; value: JsonNode }[] = src.entries();
    for (let i = 0; i < members.length; i++) {
      const key: string = members[i].name;
      const val: JsonNode = members[i].value;
      const existing: JsonNode | undefined = dst.tryGet(key);
      if (existing !== undefined && existing instanceof JsonObject && val instanceof JsonObject) {
        this.mergeObject(existing, val);
      } else {
        dst.set(key, val);
      }
    }
  }

  /** 移除键（JsonObject 无 delete，重建） */
  private removeKey(obj: JsonObject, key: string): JsonObject {
    const out: JsonObject = new JsonObject();
    const members: readonly { name: string; value: JsonNode }[] = obj.entries();
    for (let i = 0; i < members.length; i++) {
      if (members[i].name !== key) {
        out.set(members[i].name, members[i].value);
      }
    }
    return out;
  }

  /** classisland.app.quit：退出应用 */
  private async execQuit(action: ActionItem, causeText: CauseText): Promise<ExecResult> {
    try {
      const ctx: common.UIAbilityContext = this.ctx.context;
      const terminateSelf = (ctx as unknown as { terminateSelf?: () => void }).terminateSelf;
      if (terminateSelf) {
        terminateSelf();
        return true;
      }
      causeText.value = '无法获取 terminateSelf 能力';
      return false;
    } catch {
      causeText.value = '退出应用失败';
      return false;
    }
  }
}

/** JsonNull 单例（用于表示 JSON null） */
class JsonNull extends JsonNode {
  private static instance: JsonNull = new JsonNull();
  private constructor() { super(); }
  static getInstance(): JsonNull { return JsonNull.instance; }
  toString(): string { return 'null'; }
}

/** 把区间天气代码写成中文，如「晴转多云」。 */
function describeWeatherRange(range: RangedValue): string {
  const from: string = weatherTextByCode(range.from);
  const to: string = weatherTextByCode(range.to);
  if (from === to) {
    return from;
  }
  return `${from}转${to}`;
}

/** 把温度区间写成「21~29℃」。两端都空时返回空串。 */
function describeTemperatureRange(range: RangedValue): string {
  if (range.from.length === 0 && range.to.length === 0) {
    return '';
  }
  if (range.from === range.to) {
    return `${range.from}℃`;
  }
  return `${range.from}~${range.to}℃`;
}

/** 两位补零。 */
function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}
