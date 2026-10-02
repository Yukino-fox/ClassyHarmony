/**
 * 自动化行动的执行器（entry 侧，有 UIAbilityContext，可调用 terminateSelf）。
 *
 * 已实现的 5 个行动：
 *  - classisland.action.sleep        → 等待指定秒数
 *  - classisland.settings            → 修改应用设置（写 settings.json）
 *  - classisland.app.quit            → 退出应用（调用 terminateSelf）
 *  - classisland.showNotification    → 显示本地通知
 *  - classisland.notification.weather → 显示天气提醒（预报 / 预警 / 逐时）
 *  - 扩展声明的行动（P12）→ 同样只有「发通知」与「改设置」两种，见 execPlugin
 *
 * 未实现的 2 个行动（占位，返回 false 供上层记录失败）：
 *  - classisland.os.run            → 鸿蒙无法拉起任意进程
 *  - classisland.app.restart       → 无对应物
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  JsonBoolean,
  JsonMember,
  JsonNode,
  JsonNull,
  JsonNumber,
  JsonObject,
  JsonReader,
  JsonString,
  JsonValue,
  JsonWriter
} from 'common_shared';
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
import { t } from 'common_core';
import { weatherTextByCode } from 'common_core';
import { LessonsSnapshot } from 'common_core';
import {
  ActionCatalog,
  ActionInfo,
  ActionSettingsKind,
  ExtensionRegistry,
  PLUGIN_CATEGORY_CLASS_REMINDER,
  PLUGIN_CATEGORY_SYSTEM,
  PLUGIN_CATEGORY_WEATHER,
  PluginActionKind,
  PluginActionPlan,
  PluginTemplateContext,
  planPluginAction,
  renderPluginTemplate
} from 'common_core';
import { AppPreferences } from '../common/AppPreferences';
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

  /**
   * 渲染声明式模板要用的取值。由调度器在每次 tick 执行前塞进来。
   *
   * 不用构造参数传：那一处是「每秒重新算一次」的快照，而执行器是常驻的。
   * 塞进构造参数就得连快照一起传一份进去，然后每次 tick 重建执行器 ——
   * 而执行器持有 NotificationService，重建会丢掉它的已初始化状态。
   *
   * 留空时模板原样输出（占位符不被替换）：宁可让作者一眼看出「这个占位符没
   * 替换」，也不要用一份可能过期的快照拼出一条看着通顺但内容错的提醒。
   */
  private templateContext: PluginTemplateContext | undefined = undefined;

  constructor(ctx: ExecutorContext) {
    this.ctx = ctx;
    this.settings = new AutomationSettings(ctx.filesDir);
    this.notificationService = new NotificationService(ctx.context);
  }

  /**
   * 塞入本次 tick 的模板取值（声明式动作的 {time} / {subject} 等占位符靠它）。
   *
   * stateText 刻意留空，让 core 按快照上的状态自己取（见 PluginTemplate）。
   * 调度器没有理由知道作者管「课间休息」叫「课间」还是「休息」，而猜一个
   * 就等于让提醒文案与课表页上的说法不一致。
   */
  setTemplateContext(now: DateTimeValue, snapshot: LessonsSnapshot, profileName: string): void {
    const ctx: PluginTemplateContext = new PluginTemplateContext();
    ctx.now = now;
    ctx.snapshot = snapshot;
    ctx.profileName = profileName;
    this.templateContext = ctx;
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
        causeText.value = t('exec_run_unavailable');
        return false;
      case ActionIds.APP_RESTART:
        causeText.value = t('exec_restart_unimplemented');
        return false;
      default:
        // 扩展声明的行动 id 是作者自己起的，不可能出现在上面这张表里，所以
        // 「表里没有」不等于「不认得」。先问一次目录再判未知，否则一个正常
        // 装着的扩展会每秒在自动化里留下一条「未知行动 id」。
        if (this.isPluginAction(action.id)) {
          return this.execPlugin(action, causeText);
        }
        causeText.value = `未知行动 id：${action.id}`;
        return false;
    }
  }

  /** 这个行动 id 是不是扩展声明的行动。 */
  private isPluginAction(actionId: string): boolean {
    const info: ActionInfo | undefined = ActionCatalog.find(actionId);
    return info !== undefined && info.settingsKind === ActionSettingsKind.Plugin;
  }

  /**
   * 扩展声明的行动。
   *
   * 只有两种能跑：发通知、改设置。判定在 core（planPluginAction），这里只做
   * 「拿到决定之后真的去做」：渲染模板、发通知 / 落盘。
   *
   * 朗读不另外接：通知走 NotificationService.publish，那里有统一的开关判断与
   * 入队。两处都念会让同一句话被念两遍，而且第二遍在第一遍念完之后，像回声。
   */
  private async execPlugin(action: ActionItem, causeText: CauseText): Promise<ExecResult> {
    const plan: PluginActionPlan =
      planPluginAction(action.settings, ExtensionRegistry.writableSettingKeys);
    if (plan.reason.length > 0) {
      causeText.value = plan.reason;
      return false;
    }
    if (plan.kind === PluginActionKind.Notification) {
      return this.execPluginNotification(plan, causeText);
    }
    if (plan.kind === PluginActionKind.ModifySetting) {
      return this.execPluginSetting(plan, causeText);
    }
    // kind 为 None 时 reason 是空的（core 只在「配置读不出来」或「越权」时给
    // reason），但这个行动确实什么也做不了 —— 照样要说一句，否则自动化里的
    // 失败原因会空着，用户看不懂为什么这条没动静。
    causeText.value = '这条扩展行动什么都没做（清单里没写清楚要做什么）。';
    return false;
  }

  /** 扩展的发通知行动。 */
  private async execPluginNotification(plan: PluginActionPlan,
    causeText: CauseText): Promise<ExecResult> {
    const title: string = this.renderTemplate(plan.notification.title);
    const content: string = this.renderTemplate(plan.notification.content);
    if (title.length === 0 && content.length === 0) {
      causeText.value = t('exec_plugin_empty_notice');
      return false;
    }
    const category: NotificationCategory =
      pluginCategoryOf(plan.notification.category);
    await this.notificationService.publish(category, {
      title: title.length > 0 ? title : 'ClassIsland',
      content: content,
      subText: '',
      ongoing: false,
      // 不给 color：内置行动的那些色值是按「这属于哪一类提醒」挑的，而扩展
      // 声明的分类是作者自己写的，套用其中任一个色值都是在替它表态。
      speechText: content.length > 0 ? content : title
    });
    return true;
  }

  /** 扩展的改设置行动。值是文本，按设置键自己说的类型解释。 */
  private execPluginSetting(plan: PluginActionPlan, causeText: CauseText): ExecResult {
    const key: string = plan.setting.key;
    if (key.length === 0) {
      causeText.value = '扩展的改设置行动没写设置键。';
      return false;
    }
    const prefs: AppPreferences = new AppPreferences(this.ctx.context);
    const current: JsonNode | undefined = prefs.rawValueOf(key);
    const value: JsonNode | undefined = this.pluginSettingValue(plan.setting.value, current);
    if (value === undefined) {
      causeText.value = `无法把「${plan.setting.value}」解释成设置项 ${key} 的值。`;
      return false;
    }
    if (current !== undefined && value !== undefined &&
      JsonWriter.writeCompact(current) === JsonWriter.writeCompact(value)) {
      // 已经是这个值了，算成功。不这么做的话一条「到点就静音」的动作每到点
      // 都会失败一次，自动化里堆满从没出错的失败记录，而那些记录会让真正的
      // 失败再也找不到。
      return true;
    }
    if (value instanceof JsonBoolean) {
      prefs.put(key, value.value);
      return true;
    }
    if (value instanceof JsonNumber) {
      prefs.put(key, value.value);
      return true;
    }
    prefs.put(key, JsonValue.asString(value, ''));
    return true;
  }

  /**
   * 把清单里的文本值翻译成 JSON 节点。
   *
   * 按**现在那个值**的类型走，而不是给一份「哪些键是布尔」的名单：那份名单会
   * 和 AppPreferences 对不上，而对不上时的症状是「改了没反应」。读到的旧值
   * 不存在时（本端独有键第一次被扩展写）按文本猜：认得 on/true/1 当布尔，
   * 认得数字当数字，其它一律当字符串。
   *
   * @returns 解释不了时 undefined。
   */
  private pluginSettingValue(text: string, current: JsonNode | undefined): JsonNode | undefined {
    if (current instanceof JsonBoolean) {
      return new JsonBoolean(textToBool(text, current.value));
    }
    if (current instanceof JsonNumber) {
      const asNumber: number = Number(text);
      return isFinite(asNumber) ? JsonNumber.of(asNumber) : undefined;
    }
    if (current instanceof JsonString) {
      return new JsonString(text);
    }
    const normalized: string = text.trim().toLowerCase();
    if (normalized === 'true' || normalized === 'on' || normalized === '1') {
      return new JsonBoolean(true);
    }
    if (normalized === 'false' || normalized === 'off' || normalized === '0') {
      return new JsonBoolean(false);
    }
    const asNumber: number = Number(text);
    if (isFinite(asNumber) && text.trim().length > 0) {
      return JsonNumber.of(asNumber);
    }
    return new JsonString(text);
  }

  /** 渲染一段模板。取不到上下文时原样输出占位符，不猜。 */
  private renderTemplate(template: string): string {
    const ctx: PluginTemplateContext | undefined = this.templateContext;
    if (ctx === undefined) {
      return template;
    }
    return renderPluginTemplate(template, ctx);
  }

  /** classisland.action.sleep：等待 Value 秒（支持小数） */
  private async execSleep(action: ActionItem, causeText: CauseText): Promise<ExecResult> {
    const s: SleepActionSettings | undefined = SleepActionSettings.parse(action.settings ?? new JsonObject());
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
    const s: ModifyAppSettingsActionSettings | undefined = ModifyAppSettingsActionSettings.parse(action.settings ?? new JsonObject());
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
          all.set(s.name, new JsonNull());
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
    const s: NotificationActionSettings | undefined = NotificationActionSettings.parse(action.settings ?? new JsonObject());
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
      WeatherNotificationActionSettings.parse(action.settings ?? new JsonObject());
    if (s === undefined) {
      causeText.value = 'WeatherNotification 设置解析失败';
      return false;
    }

    // 天气数据由进程内单例持有。拿不到就是「还没有数据」，不是错误 ——
    // 用户大多是「刚开机就触发了这条自动化」，等下一次刷新就好。
    const service: WeatherService = resolveWeatherService(this.ctx.context);
    const info: WeatherInfo = service.lastInfo();
    if (!info.hasData()) {
      causeText.value = t('exec_weather_no_data');
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
      causeText.value = t('exec_weather_nothing');
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
      title: t('exec_weather_title'),
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
      title: t('exec_weather_title'),
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
      const title: string = alert.title.length > 0 ? alert.title : t('exec_alert_title');
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
    const members: JsonMember[] = src.entries();
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
    const members: JsonMember[] = obj.entries();
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
      // terminateSelf() 返回 Promise，失败只可能是「进程已经在退」这类不可挽回的
      // 情况，重试没有意义，所以不 await、也不把失败反馈给上层 —— 进程都没了，
      // 反馈给谁看。
      this.ctx.context.terminateSelf().catch(() => {
        // 进程正在退出，忽略。
      });
      return true;
    } catch {
      causeText.value = t('exec_quit_failed');
      return false;
    }
  }
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

/**
 * 扩展声明的通知分类 → 本端的通知渠道。
 *
 * 认不出来的落 automation：声明式动作是用户自己配的东西，用 automation
 * 渠道（默认优先级、用户可静音）比落 class_reminder（响铃震动）安全 ——
 * 归错方向的代价是不该响的东西响了。
 *
 * 归一其实 core 已经做过（normalizeCategory），这里仍留一个 default：
 * 分类是外部数据，`default` 分支的可达性不该由「调用方记得先归一」来保证。
 */
function pluginCategoryOf(text: string): NotificationCategory {
  if (text === PLUGIN_CATEGORY_CLASS_REMINDER) {
    return NotificationCategory.ClassReminder;
  }
  if (text === PLUGIN_CATEGORY_WEATHER) {
    return NotificationCategory.Weather;
  }
  if (text === PLUGIN_CATEGORY_SYSTEM) {
    return NotificationCategory.System;
  }
  return NotificationCategory.Automation;
}

/**
 * 清单里的开关文本 → 布尔。
 *
 * 认不出来的保留旧值：写「静音」不会让开关变 true，而会什么都没发生 ——
 * 静默失败比报错难查得多。
 */
function textToBool(text: string, current: boolean): boolean {
  const normalized: string = text.trim().toLowerCase();
  if (normalized === 'true' || normalized === 'on' || normalized === '1' || normalized === '是') {
    return true;
  }
  if (normalized === 'false' || normalized === 'off' || normalized === '0' || normalized === '否') {
    return false;
  }
  return current;
}
