/*
 * 11 个内置组件各自的设置对象。
 *
 * 写回一律「就地改键」
 * --------------------
 * 每个 payload 的 applyTo 都往**已经存在的** JsonObject 上写，不新建对象。
 * 理由写在 ComponentProfile.ets 的文件头：桌面版的 Settings 是 object?，
 * 文件里可能有我们没建模的字段（未来版本新增、插件私有），重建对象会把它们
 * 全部丢掉，而丢的时候没有任何报错 —— 只是下次桌面版打开时设置悄悄回到默认。
 *
 * 就地改还有个附带好处：字段顺序天然保持原样，桌面版刚写出的文件在我们手上
 * 改一个设置再写出去，只会有那一个键的值变化，而不是整个 Settings 被重排。
 *
 * 只建模显示相关的字段
 * ------------------
 * 倒计时组件有 25 个字段（含 TimeSpan 与周期设置），这里只建倒计时真正会被
 * 面板用到的那些。理由是漏建模的字段在往返中原样保留（就地改键的必然结果），
 * 代价为零；而建全了却写错一个字段的顺序或默认值，代价比漏建大得多。
 * 规则集（PauseRule / StopRule / HidingRules）整体留给 P8。
 *
 * 同理，Read 时不回填缺失字段：桌面版读文件时会把顶层组件的 Settings 补成
 * 默认实例，但我们只在自己新建组件时才这么做（见 ComponentCatalog.create）。
 * 「读」保持原样才不会在只读一遍之后凭空多出十几个键。
 */

import { t } from '../i18n/I18n';
import {
  ColorValue,
  ComponentSettings,
  DateTimeValue,
  JsonBoolean,
  JsonNode,
  JsonObject,
  JsonString,
  JsonValue,
  ModelCodec,
  TimeSpanValue
} from 'common_shared';

/** 设置对象的基类。空实现：没有设置的内置组件（日期、分割线）用它。 */
export class ComponentPayload {
  /** 把本组件认识的值就地写回 node。不认识的键原样不动。 */
  applyTo(node: JsonObject): void {
  }
}

/** 读一个可空颜色字面量，缺失走默认值。 */
function readColor(node: JsonObject, fieldName: string, fallback: ColorValue): ColorValue {
  const parsed: ColorValue | undefined =
    ColorValue.tryParse(ModelCodec.string(node, fieldName, ''));
  return parsed === undefined ? fallback : parsed;
}

function writeColor(node: JsonObject, fieldName: string, value: ColorValue): void {
  node.set(fieldName, new JsonString(value.toString()));
}

/**
 * 读一个可空 TimeSpan 字面量，缺失或读不出来走默认值。
 *
 * 用 parseOrZero 兜底而不是跳过这个键：TimeSpan 的落盘格式在 .NET 侧可以写成
 * `"1.00:00:00"`（带天数）也可以是 `"24:00:00"`，tryParse 认得两种；真正读不
 * 出来的是用户手改坏的值，那种情况下把它当 0 比抛出去更可用 —— 抛出去的话整个
 * 面板都渲染不出来，而一个周期的时长为 0 只是让倒计时显示「0天」。
 */
function readTimeSpan(node: JsonObject, fieldName: string, fallback: TimeSpanValue): TimeSpanValue {
  if (!node.has(fieldName)) {
    return fallback;
  }
  const parsed: TimeSpanValue | undefined = TimeSpanValue.tryParse(ModelCodec.string(node, fieldName, ''));
  return parsed === undefined ? TimeSpanValue.zero() : parsed;
}

/** 时钟组件。 */
export class ClockPayload extends ComponentPayload {
  showSeconds: boolean = false;
  showRealTime: boolean = false;
  flashTimeSeparator: boolean = true;

  static decode(node: JsonObject): ClockPayload {
    const out: ClockPayload = new ClockPayload();
    out.showSeconds = ModelCodec.bool(node, 'ShowSeconds', false);
    out.showRealTime = ModelCodec.bool(node, 'ShowRealTime', false);
    out.flashTimeSeparator = ModelCodec.bool(node, 'FlashTimeSeparator', true);
    return out;
  }

  override applyTo(node: JsonObject): void {
    node.set('ShowSeconds', new JsonBoolean(this.showSeconds));
    node.set('ShowRealTime', new JsonBoolean(this.showRealTime));
    node.set('FlashTimeSeparator', new JsonBoolean(this.flashTimeSeparator));
  }
}

/** 倒计时组件。只建模面板用得到的字段。 */
export class CountDownPayload extends ComponentPayload {
  countDownName: string = t('component_countdown');
  overTime: DateTimeValue = DateTimeValue.now().dateOnly();
  daysLeft: number = 0;
  fontColor: ColorValue = ColorValue.red();
  fontSize: number = 16;
  isCompactModeEnabled: boolean = false;
  countDownConnector: string = t('countdown_connector');
  isConnectorColorEmphasized: boolean = false;
  startTime: DateTimeValue = DateTimeValue.now().dateOnly();
  useAccentOnProgressBar: boolean = true;
  progressBarMode: number = 0;
  showProgress: boolean = false;
  isProgressInverted: boolean = false;
  customStringFormat: string = t('countdown_days_format');
  // --- 以下是「倒计时从哪一段时间算起」的四组设置 ---
  //
  // 之前没建模，代价是倒计时只能用 start/end 两个日期（P7c 加面板渲染时才
  // 发现）：CountdownSource 有 0..3 四档，用户选了 1（周期）或 3（本周）就得到
  // 一个按 start/end 算的、与设置对不上的数 —— 显示的数字看着合理，错的是
  // 语义，用户查不出来。补上比留个「不支持」诚实。
  countdownSource: number = 0;
  cycleStartTime: DateTimeValue = DateTimeValue.now();
  cycleBeforeDuration: TimeSpanValue = TimeSpanValue.zero();
  cycleDuration: TimeSpanValue = TimeSpanValue.fromHours(24);
  cycleAfterDuration: TimeSpanValue = TimeSpanValue.zero();
  isCycleCountLimited: boolean = false;
  cycleCountLimit: number = 2;
  isAdvancedCycleTimingEnabled: boolean = false;
  /** 自然日口径：0 按课表首末节，1 整天，2 找不到课表时不显示。 */
  natureTimeUseMode: number = 0;
  /** 0 = 周日，与档案里所有星期几字段同口径。桌面版默认 Monday = 1。 */
  weekCountdownStartDay: number = 1;
  isCustomWeekCountdownStartDayEnabled: boolean = false;

  static decode(node: JsonObject): CountDownPayload {
    const out: CountDownPayload = new CountDownPayload();
    out.countDownName = ModelCodec.string(node, 'CountDownName', t('component_countdown'));
    out.overTime = ModelCodec.readDateTime(node, 'OverTime');
    out.daysLeft = ModelCodec.int(node, 'DaysLeft', 0);
    out.fontColor = readColor(node, 'FontColor', ColorValue.red());
    out.fontSize = ModelCodec.int(node, 'FontSize', 16);
    out.isCompactModeEnabled = ModelCodec.bool(node, 'IsCompactModeEnabled', false);
    out.countDownConnector = ModelCodec.string(node, 'CountDownConnector', t('countdown_connector'));
    out.isConnectorColorEmphasized = ModelCodec.bool(node, 'IsConnectorColorEmphasized', false);
    out.startTime = ModelCodec.readDateTime(node, 'StartTime');
    out.useAccentOnProgressBar = ModelCodec.bool(node, 'UseAccentOnProgressBar', true);
    out.progressBarMode = ModelCodec.int(node, 'ProgressBarMode', 0);
    out.showProgress = ModelCodec.bool(node, 'ShowProgress', false);
    out.isProgressInverted = ModelCodec.bool(node, 'IsProgressInverted', false);
    out.customStringFormat = ModelCodec.string(node, 'CustomStringFormat', t('countdown_days_format'));
    out.countdownSource = ModelCodec.int(node, 'CountdownSource', 0);
    out.cycleStartTime = ModelCodec.readDateTime(node, 'CycleStartTime');
    out.cycleBeforeDuration = readTimeSpan(node, 'CycleBeforeDuration', TimeSpanValue.zero());
    out.cycleDuration = readTimeSpan(node, 'CycleDuration', TimeSpanValue.fromHours(24));
    out.cycleAfterDuration = readTimeSpan(node, 'CycleAfterDuration', TimeSpanValue.zero());
    out.isCycleCountLimited = ModelCodec.bool(node, 'IsCycleCountLimited', false);
    out.cycleCountLimit = ModelCodec.int(node, 'CycleCountLimit', 2);
    out.isAdvancedCycleTimingEnabled = ModelCodec.bool(node, 'IsAdvancedCycleTimingEnabled', false);
    out.natureTimeUseMode = ModelCodec.int(node, 'NatureTimeUseMode', 0);
    out.weekCountdownStartDay = ModelCodec.int(node, 'WeekCountdownStartDay', 1);
    out.isCustomWeekCountdownStartDayEnabled =
      ModelCodec.bool(node, 'IsCustomWeekCountdownStartDayEnabled', false);
    return out;
  }

  override applyTo(node: JsonObject): void {
    node.set('CountDownName', new JsonString(this.countDownName));
    node.set('OverTime', new JsonString(this.overTime.toString()));
    node.set('DaysLeft', ModelCodec.intNode(this.daysLeft));
    writeColor(node, 'FontColor', this.fontColor);
    node.set('FontSize', ModelCodec.intNode(this.fontSize));
    node.set('IsCompactModeEnabled', new JsonBoolean(this.isCompactModeEnabled));
    node.set('CountDownConnector', new JsonString(this.countDownConnector));
    node.set('IsConnectorColorEmphasized', new JsonBoolean(this.isConnectorColorEmphasized));
    node.set('StartTime', new JsonString(this.startTime.toString()));
    node.set('UseAccentOnProgressBar', new JsonBoolean(this.useAccentOnProgressBar));
    node.set('ProgressBarMode', ModelCodec.intNode(this.progressBarMode));
    node.set('ShowProgress', new JsonBoolean(this.showProgress));
    node.set('IsProgressInverted', new JsonBoolean(this.isProgressInverted));
    node.set('CustomStringFormat', new JsonString(this.customStringFormat));
    node.set('CountdownSource', ModelCodec.intNode(this.countdownSource));
    node.set('CycleStartTime', new JsonString(this.cycleStartTime.toString()));
    node.set('CycleBeforeDuration', new JsonString(this.cycleBeforeDuration.toString()));
    node.set('CycleDuration', new JsonString(this.cycleDuration.toString()));
    node.set('CycleAfterDuration', new JsonString(this.cycleAfterDuration.toString()));
    node.set('IsCycleCountLimited', new JsonBoolean(this.isCycleCountLimited));
    node.set('CycleCountLimit', ModelCodec.intNode(this.cycleCountLimit));
    node.set('IsAdvancedCycleTimingEnabled', new JsonBoolean(this.isAdvancedCycleTimingEnabled));
    node.set('NatureTimeUseMode', ModelCodec.intNode(this.natureTimeUseMode));
    node.set('WeekCountdownStartDay', ModelCodec.intNode(this.weekCountdownStartDay));
    node.set('IsCustomWeekCountdownStartDayEnabled',
      new JsonBoolean(this.isCustomWeekCountdownStartDayEnabled));
  }
}

/** 文本组件。 */
export class TextPayload extends ComponentPayload {
  textContent: string = '';
  fontSize: number = 16;
  fontColor: ColorValue = ColorValue.white();
  useCustomFontColor: boolean = true;

  static decode(node: JsonObject): TextPayload {
    const out: TextPayload = new TextPayload();
    out.textContent = ModelCodec.string(node, 'TextContent', '');
    out.fontSize = ModelCodec.int(node, 'FontSize', 16);
    out.fontColor = readColor(node, 'FontColor', ColorValue.white());
    out.useCustomFontColor = ModelCodec.bool(node, 'UseCustomFontColor', true);
    return out;
  }

  override applyTo(node: JsonObject): void {
    node.set('TextContent', new JsonString(this.textContent));
    node.set('FontSize', ModelCodec.intNode(this.fontSize));
    writeColor(node, 'FontColor', this.fontColor);
    node.set('UseCustomFontColor', new JsonBoolean(this.useCustomFontColor));
  }
}

/** 天气简报组件。 */
export class WeatherPayload extends ComponentPayload {
  showAlerts: boolean = true;
  alertsTitleShowMode: number = 1;
  showRainTime: boolean = true;
  isFuzzyLongRainCountdownEnabled: boolean = true;
  showMainWeatherInfo: boolean = true;
  mainWeatherInfoKind: number = 0;

  static decode(node: JsonObject): WeatherPayload {
    const out: WeatherPayload = new WeatherPayload();
    out.showAlerts = ModelCodec.bool(node, 'ShowAlerts', true);
    out.alertsTitleShowMode = ModelCodec.int(node, 'AlertsTitleShowMode', 1);
    out.showRainTime = ModelCodec.bool(node, 'ShowRainTime', true);
    out.isFuzzyLongRainCountdownEnabled =
      ModelCodec.bool(node, 'IsFuzzyLongRainCountdownEnabled', true);
    out.showMainWeatherInfo = ModelCodec.bool(node, 'ShowMainWeatherInfo', true);
    out.mainWeatherInfoKind = ModelCodec.int(node, 'MainWeatherInfoKind', 0);
    return out;
  }

  override applyTo(node: JsonObject): void {
    node.set('ShowAlerts', new JsonBoolean(this.showAlerts));
    node.set('AlertsTitleShowMode', ModelCodec.intNode(this.alertsTitleShowMode));
    node.set('ShowRainTime', new JsonBoolean(this.showRainTime));
    node.set('IsFuzzyLongRainCountdownEnabled', new JsonBoolean(this.isFuzzyLongRainCountdownEnabled));
    node.set('ShowMainWeatherInfo', new JsonBoolean(this.showMainWeatherInfo));
    node.set('MainWeatherInfoKind', ModelCodec.intNode(this.mainWeatherInfoKind));
  }
}

/** 课程表组件（桌面版叫 LessonControlSettings）。 */
export class SchedulePayload extends ComponentPayload {
  showExtraInfoOnTimePoint: boolean = true;
  extraInfoType: number = 0;
  isCountdownEnabled: boolean = true;
  countdownSeconds: number = 60;
  extraInfo4ShowSecondsSeconds: number = 0;
  scheduleSpacing: number = 1;
  showCurrentLessonOnlyOnClass: boolean = false;
  hideFinishedClass: boolean = false;
  showPlaceholderOnEmptyClassPlan: boolean = true;
  placeholderTextNoClass: string = t('panel_no_class_today');
  placeholderTextAllClassEnded: string = t('panel_all_class_ended');
  showTomorrowSchedules: boolean = false;
  tomorrowScheduleShowMode: number = 1;
  highlightChangedClass: boolean = false;
  isNonExactCountdownEnabled: boolean = false;
  fadeCompletedClasses: boolean = true;

  static decode(node: JsonObject): SchedulePayload {
    const out: SchedulePayload = new SchedulePayload();
    out.showExtraInfoOnTimePoint = ModelCodec.bool(node, 'ShowExtraInfoOnTimePoint', true);
    out.extraInfoType = ModelCodec.int(node, 'ExtraInfoType', 0);
    out.isCountdownEnabled = ModelCodec.bool(node, 'IsCountdownEnabled', true);
    out.countdownSeconds = ModelCodec.int(node, 'CountdownSeconds', 60);
    out.extraInfo4ShowSecondsSeconds = ModelCodec.int(node, 'ExtraInfo4ShowSecondsSeconds', 0);
    out.scheduleSpacing = ModelCodec.number(node, 'ScheduleSpacing', 1);
    out.showCurrentLessonOnlyOnClass = ModelCodec.bool(node, 'ShowCurrentLessonOnlyOnClass', false);
    out.hideFinishedClass = ModelCodec.bool(node, 'HideFinishedClass', false);
    out.showPlaceholderOnEmptyClassPlan = ModelCodec.bool(node, 'ShowPlaceholderOnEmptyClassPlan', true);
    out.placeholderTextNoClass = ModelCodec.string(node, 'PlaceholderTextNoClass', t('panel_no_class_today'));
    out.placeholderTextAllClassEnded =
      ModelCodec.string(node, 'PlaceholderTextAllClassEnded', t('panel_all_class_ended'));
    out.showTomorrowSchedules = ModelCodec.bool(node, 'ShowTomorrowSchedules', false);
    out.tomorrowScheduleShowMode = ModelCodec.int(node, 'TomorrowScheduleShowMode', 1);
    out.highlightChangedClass = ModelCodec.bool(node, 'HighlightChangedClass', false);
    out.isNonExactCountdownEnabled = ModelCodec.bool(node, 'IsNonExactCountdownEnabled', false);
    out.fadeCompletedClasses = ModelCodec.bool(node, 'FadeCompletedClasses', true);
    return out;
  }

  override applyTo(node: JsonObject): void {
    node.set('ShowExtraInfoOnTimePoint', new JsonBoolean(this.showExtraInfoOnTimePoint));
    node.set('ExtraInfoType', ModelCodec.intNode(this.extraInfoType));
    node.set('IsCountdownEnabled', new JsonBoolean(this.isCountdownEnabled));
    node.set('CountdownSeconds', ModelCodec.intNode(this.countdownSeconds));
    node.set('ExtraInfo4ShowSecondsSeconds', ModelCodec.intNode(this.extraInfo4ShowSecondsSeconds));
    node.set('ScheduleSpacing', ModelCodec.doubleNode(this.scheduleSpacing));
    node.set('ShowCurrentLessonOnlyOnClass', new JsonBoolean(this.showCurrentLessonOnlyOnClass));
    node.set('HideFinishedClass', new JsonBoolean(this.hideFinishedClass));
    node.set('ShowPlaceholderOnEmptyClassPlan', new JsonBoolean(this.showPlaceholderOnEmptyClassPlan));
    node.set('PlaceholderTextNoClass', new JsonString(this.placeholderTextNoClass));
    node.set('PlaceholderTextAllClassEnded', new JsonString(this.placeholderTextAllClassEnded));
    node.set('ShowTomorrowSchedules', new JsonBoolean(this.showTomorrowSchedules));
    node.set('TomorrowScheduleShowMode', ModelCodec.intNode(this.tomorrowScheduleShowMode));
    node.set('HighlightChangedClass', new JsonBoolean(this.highlightChangedClass));
    node.set('IsNonExactCountdownEnabled', new JsonBoolean(this.isNonExactCountdownEnabled));
    node.set('FadeCompletedClasses', new JsonBoolean(this.fadeCompletedClasses));
  }
}

/** 滚动容器组件。 */
export class RollingPayload extends ComponentPayload {
  speedPixelPerSecond: number = 40;
  isPauseEnabled: boolean = true;
  pauseOffsetX: number = 0;
  pauseSeconds: number = 10;

  static decode(node: JsonObject): RollingPayload {
    const out: RollingPayload = new RollingPayload();
    out.speedPixelPerSecond = ModelCodec.number(node, 'SpeedPixelPerSecond', 40);
    out.isPauseEnabled = ModelCodec.bool(node, 'IsPauseEnabled', true);
    out.pauseOffsetX = ModelCodec.number(node, 'PauseOffsetX', 0);
    out.pauseSeconds = ModelCodec.number(node, 'PauseSeconds', 10);
    return out;
  }

  override applyTo(node: JsonObject): void {
    node.set('SpeedPixelPerSecond', ModelCodec.doubleNode(this.speedPixelPerSecond));
    node.set('IsPauseEnabled', new JsonBoolean(this.isPauseEnabled));
    node.set('PauseOffsetX', ModelCodec.doubleNode(this.pauseOffsetX));
    node.set('PauseSeconds', ModelCodec.doubleNode(this.pauseSeconds));
  }
}

/** 轮播容器组件。 */
export class SlidePayload extends ComponentPayload {
  slideSeconds: number = 15;
  slideMode: number = 0;
  useOldPresentingBehavior: boolean = false;
  isAnimationEnabled: boolean = false;

  static decode(node: JsonObject): SlidePayload {
    const out: SlidePayload = new SlidePayload();
    out.slideSeconds = ModelCodec.number(node, 'SlideSeconds', 15);
    out.slideMode = ModelCodec.int(node, 'SlideMode', 0);
    out.useOldPresentingBehavior = ModelCodec.bool(node, 'UseOldPresentingBehavior', false);
    out.isAnimationEnabled = ModelCodec.bool(node, 'IsAnimationEnabled', false);
    return out;
  }

  override applyTo(node: JsonObject): void {
    node.set('SlideSeconds', ModelCodec.doubleNode(this.slideSeconds));
    node.set('SlideMode', ModelCodec.intNode(this.slideMode));
    node.set('UseOldPresentingBehavior', new JsonBoolean(this.useOldPresentingBehavior));
    node.set('IsAnimationEnabled', new JsonBoolean(this.isAnimationEnabled));
  }
}

/** 给容器的 Children 读写用的通用实现：字段名恒为 Children。 */
export class ContainerPayload extends ComponentPayload {
  /**
   * 从节点读子组件。
   *
   * 桌面版的 Children 是 `Settings as IComponentContainerSettings)?.Children`，
   * 是计算属性、不落盘在 ComponentSettings 上。Settings 为 null 时 Children
   * 也为 null —— 也就是「空容器」，而不是「崩」。
   */
  static readChildren(node: JsonObject | undefined): ComponentSettings[] {
    if (node === undefined) {
      return [];
    }
    return ModelCodec.readArray(node, 'Children',
      (item: JsonNode) => ComponentSettings.fromJson(JsonValue.asObject(item) ?? new JsonObject()));
  }

  static writeChildren(node: JsonObject, children: ComponentSettings[]): void {
    node.set('Children', ModelCodec.writeArray(children, (v: ComponentSettings) => v.toJson()));
  }
}
