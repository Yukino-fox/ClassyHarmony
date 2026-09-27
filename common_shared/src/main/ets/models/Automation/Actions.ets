/*
 * 六个带设置的行动。对应 ClassIsland/Models/Actions 下的六个类。
 *
 * 七个行动里只有 AppQuitAction 是无参的（: ActionBase，其余六个都是
 * ActionBase<T>）。「有没有设置」这件事记在 common_core 的 ActionCatalog 上
 * （settingsKind 标签），不靠继承链。
 *
 * 落盘顺序
 * --------
 *   AppRestartActionSettings      : Value, IsActive
 *   ModifyAppSettingsActionSettings: Name, Value, Mode, IsActive
 *   NotificationActionSettings    : Content, Mask, IsContentSpeechEnabled,
 *                                   IsMaskSpeechEnabled, IsAdvancedSettingsEnabled,
 *                                   IsSoundEffectEnabled, IsTopmostEnabled,
 *                                   CustomSoundEffectPath, IsEffectEnabled,
 *                                   MaskDurationSeconds, ContentDurationSeconds,
 *                                   IsWaitForCompleteEnabled, IsActive
 *   RunActionSettings             : RunType, Value, Args, IsActive
 *   SleepActionSettings           : Value, IsActive
 *   WeatherNotificationActionSettings: NotificationKind
 *
 * 三处不是笔误，别照直觉改：
 *
 * 1. NotificationActionSettings 的属性顺序是源码里的**书写顺序**，不是逻辑分组
 *    顺序。IsAdvancedSettingsEnabled 夹在语音两项和音效两项之间就是这个原因。
 *    而 IsWaitForCompleteEnabled 明明写在最前面（`[ObservableProperty] bool
 *    _isWaitForCompleteEnabled` 在字段区），生成的属性却排在最后 —— 源生成器
 *    追加的属性排在手写属性之后。
 *
 * 2. RunActionSettings.RunType 标了 JsonStringEnumConverter，落盘是**字符串**
 *    "Application" 而非整数。其它枚举（PreTimePoint 的 TargetState）没标，
 *    落盘是整数。
 *
 * 3. ModifyAppSettingsActionSettings.Mode 标了 WhenWritingDefault，为 0 时整个
 *    字段不出现。同一个类里的 Value 没有这个条件，为 null 时会写出 "Value":null。
 */

import { JsonBoolean, JsonNode, JsonNull, JsonObject, JsonString } from '../../json/JsonNode';
import { JsonValue } from '../../json/JsonValue';
import { ModelCodec } from '../ModelCodec';

/** 重启应用行动设置。classisland.app.restart */
export class AppRestartActionSettings {
  /** true = 真正重启，false = 只弹「要重启吗」。 */
  value: boolean = false;

  /** 来自 ObservableRecipient。 */
  isActive: boolean = false;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Value', new JsonBoolean(this.value));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static parse(node: JsonNode): AppRestartActionSettings {
    const out: AppRestartActionSettings = new AppRestartActionSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.value = ModelCodec.bool(obj, 'Value', false);
    out.isActive = ModelCodec.bool(obj, 'IsActive', false);
    return out;
  }
}

/**
 * 修改应用设置行动设置。classisland.settings
 *
 * 唯一支持恢复的行动（ModifyAppSettingsAction 覆写了 OnRevert），
 * 恢复时把旧值写回去。
 */
export class ModifyAppSettingsActionSettings {
  /** 要改的设置项名，对应 Settings 的 C# 属性名。 */
  name: string = '';

  /** 值。按控件实际类型多态序列化，所以这里是裸 JSON。 */
  value: JsonNode | undefined = undefined;

  /** 值怎么解释（对应各个设置控件的 Mode），0 是默认值，值为 0 时不落盘。 */
  mode: number = 0;

  /** 来自 ObservableRecipient。 */
  isActive: boolean = false;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Name', new JsonString(this.name));
    out.set('Value', this.value === undefined ? new JsonNull() : this.value);
    if (this.mode !== 0) {
      out.set('Mode', ModelCodec.intNode(this.mode));
    }
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static parse(node: JsonNode): ModifyAppSettingsActionSettings {
    const out: ModifyAppSettingsActionSettings = new ModifyAppSettingsActionSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.name = ModelCodec.string(obj, 'Name', '');
    const value: JsonNode | undefined = obj.tryGet('Value');
    if (value !== undefined) {
      out.value = ModelCodec.cloneNode(value);
    }
    out.mode = ModelCodec.int(obj, 'Mode', 0);
    out.isActive = ModelCodec.bool(obj, 'IsActive', false);
    return out;
  }
}

/** 显示提醒行动设置。classisland.showNotification */
export class NotificationActionSettings {
  /** 正文。 */
  content: string = '';
  /** 大字遮罩文本。 */
  mask: string = '';
  /** 朗读正文。 */
  isContentSpeechEnabled: boolean = true;
  /** 朗读遮罩。 */
  isMaskSpeechEnabled: boolean = true;
  /** 是否展开高级设置（桌面版控制这一块的可见性）。 */
  isAdvancedSettingsEnabled: boolean = false;
  /** 播音效。 */
  isSoundEffectEnabled: boolean = true;
  /** 置顶。 */
  isTopmostEnabled: boolean = true;
  /** 自定义音效路径。桌面版专属，鸿蒙侧无对应物。 */
  customSoundEffectPath: string = '';
  /** 是否启用效果（淡入淡出等）。 */
  isEffectEnabled: boolean = true;
  /** 遮罩停留秒数。 */
  maskDurationSeconds: number = 5.0;
  /** 正文停留秒数。 */
  contentDurationSeconds: number = 10.0;
  /** 等提醒播完再继续后面的行动。 */
  isWaitForCompleteEnabled: boolean = false;

  /** 来自 ObservableRecipient。 */
  isActive: boolean = false;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Content', new JsonString(this.content));
    out.set('Mask', new JsonString(this.mask));
    out.set('IsContentSpeechEnabled', new JsonBoolean(this.isContentSpeechEnabled));
    out.set('IsMaskSpeechEnabled', new JsonBoolean(this.isMaskSpeechEnabled));
    out.set('IsAdvancedSettingsEnabled', new JsonBoolean(this.isAdvancedSettingsEnabled));
    out.set('IsSoundEffectEnabled', new JsonBoolean(this.isSoundEffectEnabled));
    out.set('IsTopmostEnabled', new JsonBoolean(this.isTopmostEnabled));
    out.set('CustomSoundEffectPath', new JsonString(this.customSoundEffectPath));
    out.set('IsEffectEnabled', new JsonBoolean(this.isEffectEnabled));
    out.set('MaskDurationSeconds', ModelCodec.doubleNode(this.maskDurationSeconds));
    out.set('ContentDurationSeconds', ModelCodec.doubleNode(this.contentDurationSeconds));
    out.set('IsWaitForCompleteEnabled', new JsonBoolean(this.isWaitForCompleteEnabled));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static parse(node: JsonNode): NotificationActionSettings {
    const out: NotificationActionSettings = new NotificationActionSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.content = ModelCodec.string(obj, 'Content', '');
    out.mask = ModelCodec.string(obj, 'Mask', '');
    out.isContentSpeechEnabled = ModelCodec.bool(obj, 'IsContentSpeechEnabled', true);
    out.isMaskSpeechEnabled = ModelCodec.bool(obj, 'IsMaskSpeechEnabled', true);
    out.isAdvancedSettingsEnabled = ModelCodec.bool(obj, 'IsAdvancedSettingsEnabled', false);
    out.isSoundEffectEnabled = ModelCodec.bool(obj, 'IsSoundEffectEnabled', true);
    out.isTopmostEnabled = ModelCodec.bool(obj, 'IsTopmostEnabled', true);
    out.customSoundEffectPath = ModelCodec.string(obj, 'CustomSoundEffectPath', '');
    out.isEffectEnabled = ModelCodec.bool(obj, 'IsEffectEnabled', true);
    out.maskDurationSeconds = ModelCodec.number(obj, 'MaskDurationSeconds', 5.0);
    out.contentDurationSeconds = ModelCodec.number(obj, 'ContentDurationSeconds', 10.0);
    out.isWaitForCompleteEnabled = ModelCodec.bool(obj, 'IsWaitForCompleteEnabled', false);
    out.isActive = ModelCodec.bool(obj, 'IsActive', false);
    return out;
  }
}

/** 「运行」行动跑什么类型。落盘为字符串（JsonStringEnumConverter）。 */
export enum RunActionRunType {
  Application = 0,
  Command = 1,
  File = 2,
  Folder = 3,
  Url = 4
}

const RUN_TYPE_NAMES: string[] = ['Application', 'Command', 'File', 'Folder', 'Url'];

/** 运行行动设置。classisland.os.run */
export class RunActionSettings {
  /** 跑什么类型。落盘为字符串。 */
  runType: RunActionRunType = RunActionRunType.Application;

  /** 目标：程序名 / 命令行 / 路径 / URL。 */
  value: string = '';

  /** 命令行参数。 */
  args: string = '';

  /** 来自 ObservableRecipient。 */
  isActive: boolean = false;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('RunType', new JsonString(RUN_TYPE_NAMES[this.runType]));
    out.set('Value', new JsonString(this.value));
    out.set('Args', new JsonString(this.args));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static parse(node: JsonNode): RunActionSettings {
    const out: RunActionSettings = new RunActionSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.runType = RunActionSettings.parseRunType(ModelCodec.string(obj, 'RunType',
      'Application'));
    out.value = ModelCodec.string(obj, 'Value', '');
    out.args = ModelCodec.string(obj, 'Args', '');
    out.isActive = ModelCodec.bool(obj, 'IsActive', false);
    return out;
  }

  /**
   * 解 RunType。
   *
   * 桌面版 `Enum.TryParse` 遇到不认识的字符串会抛 JsonException，而
   * ActionBase.GetInstance 那层没有 catch —— 整个行动组会卡在这一条上。
   * 鸿蒙侧退回 Application（默认值 0）而不是抛：一条配坏的行动不该让同组里
   * 其它行动也跑不起来。原始字符串已被 ModelCodec 忽略，代价是这份配坏的
   * 目标在下次保存时会被改写成 "Application"（桌面版也一样会保存成 0）。
   */
  private static parseRunType(name: string): RunActionRunType {
    for (let i: number = 0; i < RUN_TYPE_NAMES.length; i++) {
      if (RUN_TYPE_NAMES[i] === name) {
        return i as RunActionRunType;
      }
    }
    return RunActionRunType.Application;
  }
}

/** 等待时长行动设置。classisland.action.sleep */
export class SleepActionSettings {
  /** 等几秒。桌面版默认 5。 */
  value: number = 5;

  /** 来自 ObservableRecipient。 */
  isActive: boolean = false;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Value', ModelCodec.doubleNode(this.value));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static parse(node: JsonNode): SleepActionSettings {
    const out: SleepActionSettings = new SleepActionSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.value = ModelCodec.number(obj, 'Value', 5);
    out.isActive = ModelCodec.bool(obj, 'IsActive', false);
    return out;
  }
}

/** 天气提醒行动设置。classisland.notification.weather */
export class WeatherNotificationActionSettings {
  /**
   * 0 = 三天预报、1 = 气象预警、2 = 逐小时预报。
   * 越界值由求值侧判为不成立（见 ActionCatalog 的 note）。
   */
  notificationKind: number = 0;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('NotificationKind', ModelCodec.intNode(this.notificationKind));
    return out;
  }

  static parse(node: JsonNode): WeatherNotificationActionSettings {
    const out: WeatherNotificationActionSettings = new WeatherNotificationActionSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.notificationKind = ModelCodec.int(obj, 'NotificationKind', 0);
    return out;
  }
}

/** 桌面版注册的全部 7 个行动的 ID。 */
export class ActionIds {
  static readonly APP_QUIT: string = 'classisland.app.quit';
  static readonly APP_RESTART: string = 'classisland.app.restart';
  static readonly SETTINGS: string = 'classisland.settings';
  static readonly SHOW_NOTIFICATION: string = 'classisland.showNotification';
  static readonly OS_RUN: string = 'classisland.os.run';
  static readonly SLEEP: string = 'classisland.action.sleep';
  static readonly NOTIFICATION_WEATHER: string = 'classisland.notification.weather';
}
