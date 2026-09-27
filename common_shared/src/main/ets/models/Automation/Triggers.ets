/*
 * 五个带设置的触发器。对应 ClassIsland/Models/Automation/Triggers 下的五个类。
 *
 * 十二个触发器里只有五个有设置类，其余七个是无参触发器（见 common_core 的
 * TriggerCatalog）。这里把「有没有设置」这件事记在类上：桌面版靠
 * `TriggerBase<T>` 的泛型参数区分，P1 以来 ArkTS 侧一律用显式表
 * （TriggerCatalog 的 settingsKind），不靠继承链。
 *
 * 落盘顺序
 * --------
 * System.Text.Json 默认值也写、键顺序取 C# 属性声明顺序，所以每个 toJson()
 * 的 set 顺序必须与 C# 源码逐字对应：
 *   CronTriggerSettings      : CronExpression
 *   PreTimePointTriggerSettings: TargetState, TimeSeconds
 *   SignalTriggerSettings    : SignalName, IsRevert
 *   TrayMenuTriggerSettings  : Header, IsRevert
 *   UriTriggerSettings       : UriSuffix
 *
 * IsActive 排最后
 * --------------
 * CronTriggerSettings / SignalTriggerSettings 继承 ObservableRecipient，
 * 那个基类带一个 IsActive，桌面版会持久化它。PreTimePointTriggerSettings /
 * TrayMenuTriggerSettings / UriTriggerSettings 继承的是 ObservableObject，没有
 * 这个字段 —— 与 ActionSet / ActionItem 同一套取舍：IsActive 一律排在声明
 * 属性之后。
 */

import { TimeState } from '../../enums/TimeState';
import { JsonBoolean, JsonNode, JsonObject, JsonString } from '../../json/JsonNode';
import { JsonValue } from '../../json/JsonValue';
import { ModelCodec } from '../ModelCodec';

/** cron 触发器设置。classisland.cron */
export class CronTriggerSettings {
  /** cron 表达式。桌面版默认 "* * * * *"（每分钟）。 */
  cronExpression: string = '* * * * *';

  /** 来自 ObservableRecipient。 */
  isActive: boolean = false;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('CronExpression', new JsonString(this.cronExpression));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static parse(node: JsonNode): CronTriggerSettings {
    const out: CronTriggerSettings = new CronTriggerSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.cronExpression = ModelCodec.string(obj, 'CronExpression', '* * * * *');
    out.isActive = ModelCodec.bool(obj, 'IsActive', false);
    return out;
  }
}

/** 特定时间点前触发器设置。classisland.lessons.preTimePoint */
export class PreTimePointTriggerSettings {
  /** 目标状态：在这个状态开始前 N 秒触发。 */
  targetState: TimeState = TimeState.OnClass;

  /** 提前多少秒。负数表示停用（桌面版里 TimeSeconds < 0 直接不触发）。 */
  timeSeconds: number = 60;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('TargetState', ModelCodec.intNode(this.targetState));
    out.set('TimeSeconds', ModelCodec.doubleNode(this.timeSeconds));
    return out;
  }

  static parse(node: JsonNode): PreTimePointTriggerSettings {
    const out: PreTimePointTriggerSettings = new PreTimePointTriggerSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    // 越界值退回 OnClass，与 C# 的行为一致（枚举反序列化失败会抛，
    // 而 PreTimePointTrigger 的 tick 没有 try/catch 之外的处理，
    // 表现上就是这条触发器不工作）。
    const raw: number = ModelCodec.int(obj, 'TargetState', TimeState.OnClass);
    out.targetState = raw >= TimeState.None && raw <= TimeState.AfterSchool
      ? raw as TimeState
      : TimeState.OnClass;
    out.timeSeconds = ModelCodec.number(obj, 'TimeSeconds', 60);
    return out;
  }
}

/** 信号触发器设置。classisland.signal */
export class SignalTriggerSettings {
  /** 要响应的信号名。 */
  signalName: string = '';

  /**
   * 是否作为「恢复」信号。
   *
   * 桌面版 SignalTrigger 里这个字段直接决定它调 Trigger() 还是 TriggerRevert()
   * —— 也就是说「发出信号」和「撤销」由**接收方**的配置区分，不是两个触发器。
   */
  isRevert: boolean = false;

  /** 来自 ObservableRecipient。 */
  isActive: boolean = false;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('SignalName', new JsonString(this.signalName));
    out.set('IsRevert', new JsonBoolean(this.isRevert));
    out.set('IsActive', new JsonBoolean(this.isActive));
    return out;
  }

  static parse(node: JsonNode): SignalTriggerSettings {
    const out: SignalTriggerSettings = new SignalTriggerSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.signalName = ModelCodec.string(obj, 'SignalName', '');
    out.isRevert = ModelCodec.bool(obj, 'IsRevert', false);
    out.isActive = ModelCodec.bool(obj, 'IsActive', false);
    return out;
  }
}

/**
 * 托盘菜单触发器设置。classisland.trayMenu
 *
 * 鸿蒙侧没有托盘，这个触发器暂不实现。模型留着：用户从桌面版同步过来的配置里
 * 若有它，落盘时必须原样保住，不然来回同步一次就少一条。
 */
export class TrayMenuTriggerSettings {
  /** 菜单项标题。 */
  header: string = '';

  /** 菜单项是否是「恢复」项。 */
  isRevert: boolean = false;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Header', new JsonString(this.header));
    out.set('IsRevert', new JsonBoolean(this.isRevert));
    return out;
  }

  static parse(node: JsonNode): TrayMenuTriggerSettings {
    const out: TrayMenuTriggerSettings = new TrayMenuTriggerSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.header = ModelCodec.string(obj, 'Header', '');
    out.isRevert = ModelCodec.bool(obj, 'IsRevert', false);
    return out;
  }
}

/**
 * URI 触发器设置。classisland.uri
 *
 * 桌面版由 ClassIsland.Desktop 的单实例互操作接 Uri 命令行。鸿蒙侧的对应物是
 * ability 的 `want.uri`（深链），需要先在 module.json5 里声明 skills 匹配规则，
 * 属于后续的入口工作，暂不实现。模型同样留着。
 */
export class UriTriggerSettings {
  /** 要匹配的后缀。 */
  uriSuffix: string = '';

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('UriSuffix', new JsonString(this.uriSuffix));
    return out;
  }

  static parse(node: JsonNode): UriTriggerSettings {
    const out: UriTriggerSettings = new UriTriggerSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.uriSuffix = ModelCodec.string(obj, 'UriSuffix', '');
    return out;
  }
}

/**
 * 桌面版注册的全部 12 个触发器的 ID。
 *
 * 顺序照 Services/Automation/Triggers 目录下的文件顺序（App.Services.xaml.cs
 * 里的注册顺序与之一致），编辑器里的触发器选择器按这个顺序排。
 */
export class TriggerIds {
  static readonly LIFETIME_STARTUP: string = 'classisland.lifetime.startup';
  static readonly LIFETIME_STOPPING: string = 'classisland.lifetime.stopping';
  static readonly CRON: string = 'classisland.cron';
  static readonly LESSONS_CURRENT_TIME_STATE_CHANGED: string =
    'classisland.lessons.currentTimeStateChanged';
  static readonly LESSONS_ON_AFTER_SCHOOL: string = 'classisland.lessons.onAfterSchool';
  static readonly LESSONS_ON_BREAKING_TIME: string = 'classisland.lessons.onBreakingTime';
  static readonly LESSONS_ON_CLASS: string = 'classisland.lessons.onClass';
  static readonly LESSONS_PRE_TIME_POINT: string = 'classisland.lessons.preTimePoint';
  static readonly RULESET_CHANGED: string = 'classisland.ruleSet.rulesetChanged';
  static readonly SIGNAL: string = 'classisland.signal';
  static readonly TRAY_MENU: string = 'classisland.trayMenu';
  static readonly URI: string = 'classisland.uri';
}
