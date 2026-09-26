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

import {
  ColorValue,
  ComponentSettings,
  DateTimeValue,
  JsonBoolean,
  JsonNode,
  JsonObject,
  JsonString,
  JsonValue,
  ModelCodec
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
  countDownName: string = '倒计时';
  overTime: DateTimeValue = DateTimeValue.now().dateOnly();
  daysLeft: number = 0;
  fontColor: ColorValue = ColorValue.red();
  fontSize: number = 16;
  isCompactModeEnabled: boolean = false;
  countDownConnector: string = '还有';
  isConnectorColorEmphasized: boolean = false;
  startTime: DateTimeValue = DateTimeValue.now().dateOnly();
  showProgress: boolean = false;
  isProgressInverted: boolean = false;
  customStringFormat: string = '%D天';

  static decode(node: JsonObject): CountDownPayload {
    const out: CountDownPayload = new CountDownPayload();
    out.countDownName = ModelCodec.string(node, 'CountDownName', '倒计时');
    out.overTime = ModelCodec.readDateTime(node, 'OverTime');
    out.daysLeft = ModelCodec.int(node, 'DaysLeft', 0);
    out.fontColor = readColor(node, 'FontColor', ColorValue.red());
    out.fontSize = ModelCodec.int(node, 'FontSize', 16);
    out.isCompactModeEnabled = ModelCodec.bool(node, 'IsCompactModeEnabled', false);
    out.countDownConnector = ModelCodec.string(node, 'CountDownConnector', '还有');
    out.isConnectorColorEmphasized = ModelCodec.bool(node, 'IsConnectorColorEmphasized', false);
    out.startTime = ModelCodec.readDateTime(node, 'StartTime');
    out.showProgress = ModelCodec.bool(node, 'ShowProgress', false);
    out.isProgressInverted = ModelCodec.bool(node, 'IsProgressInverted', false);
    out.customStringFormat = ModelCodec.string(node, 'CustomStringFormat', '%D天');
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
    node.set('ShowProgress', new JsonBoolean(this.showProgress));
    node.set('IsProgressInverted', new JsonBoolean(this.isProgressInverted));
    node.set('CustomStringFormat', new JsonString(this.customStringFormat));
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
  placeholderTextNoClass: string = '今天没有课程。';
  placeholderTextAllClassEnded: string = '今日课程已全部结束。';
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
    out.placeholderTextNoClass = ModelCodec.string(node, 'PlaceholderTextNoClass', '今天没有课程。');
    out.placeholderTextAllClassEnded =
      ModelCodec.string(node, 'PlaceholderTextAllClassEnded', '今日课程已全部结束。');
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
