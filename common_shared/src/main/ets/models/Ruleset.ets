/*
 * 规则集模型。对应 ClassIsland.Core/Models/Ruleset 下的四个类。
 *
 * 存在哪、怎么被用
 * --------------
 * 规则集是「按条件隐藏」的配置本体，挂在两处：
 *   - ComponentSettings.HideOnRule / HidingRules（每个组件一份）
 *   - MainWindowLineSettings.HideOnRule / HidingRules（每一行一份）
 * 两处的 HidingRules 声明类型都是 Ruleset?，但 ComponentProfile 把它们当**裸
 * JsonNode** 透传（理由与 Settings 一样：插件可以注册我们不认识的规则，透传才能
 * 逐字节保住它们）。需要读的时候由 common_core 的 RuleCatalog 按 Id 解出这里的
 * 强类型视图。
 *
 * 求值在哪
 * ------
 * 不在这里。求值要读档案与时刻状态，进不了 common_shared；放在
 * common_core/rules/RuleEngine.ets。这个文件只管「长得什么样、怎么存回去」。
 *
 * 字段顺序即落盘顺序
 * ----------------
 * 与 ComponentProfile 同一条纪律：System.Text.Json 默认值也写、键顺序取 C# 属性
 * 声明顺序，所以每个 toJson() 的 set 顺序必须与 C# 源码逐字对应。
 *   Rule       : IsReversed, Id, Settings
 *   RuleGroup  : Rules, Mode, IsReversed, IsEnabled
 *   Ruleset    : Mode, IsReversed, Groups
 *
 * State 不落盘
 * ----------
 * 桌面版 Rule / RuleGroup / Ruleset 上都有一个 int State，标了 [JsonIgnore]，
 * 那是给编辑器显示「哪条规则没过」用的运行时值。鸿蒙侧照样不写进文件：求值结果
 * 放在 RuleEngine 返回的轨迹对象里（common_core），模型本身保持纯数据。
 *
 * Settings 为什么是裸 JsonNode
 * --------------------------
 * 与 ComponentSettings.Settings 完全同一个理由：声明类型是 object?，落盘时按规则
 * 各自的实际类型多态序列化。未注册规则（或已注册但我们还没实现的规则）的设置
 * 必须原样留着，否则用户在桌面版里配好的正则匹配会被这边抹成 null。
 */

import { TimeState } from '../enums/TimeState';
import { Guid } from '../json/Guid';
import {
  JsonArray,
  JsonBoolean,
  JsonNode,
  JsonNull,
  JsonObject,
  JsonString
} from '../json/JsonNode';
import { JsonValue } from '../json/JsonValue';
import { JsonWriter } from '../json/JsonWriter';
import { ModelCodec } from './ModelCodec';

/** 规则集的逻辑组合方式。值必须与桌面版一致——该枚举以整数写入 JSON。 */
export enum RulesetLogicalMode {
  /** 任一规则组成立即成立。桌面版 Ruleset 的默认值。 */
  Or = 0,
  /** 所有规则组都成立才成立。桌面版 RuleGroup 的默认值。 */
  And = 1
}

/** 单条规则。 */
export class Rule {
  /** 取反：把这条规则的结果反过来。 */
  isReversed: boolean = false;
  /** 规则 ID，例如 classisland.lessons.timeState。空串表示这条规则还没挑。 */
  id: string = '';
  /** 规则设置，按 id 决定实际形状。未填时求值按「空设置」处理。 */
  settings: JsonNode | undefined = undefined;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('IsReversed', new JsonBoolean(this.isReversed));
    out.set('Id', new JsonString(this.id));
    out.set('Settings', this.settings === undefined ? new JsonNull() : this.settings);
    return out;
  }

  static parse(node: JsonNode): Rule {
    const out: Rule = new Rule();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.isReversed = ModelCodec.bool(obj, 'IsReversed', false);
    out.id = ModelCodec.string(obj, 'Id', '');
    const raw: JsonNode | undefined = obj.tryGet('Settings');
    out.settings = JsonValue.isNull(raw) ? undefined : ModelCodec.cloneNode(raw as JsonNode);
    return out;
  }
}

/** 一组规则。组内按 mode 组合，组结果再按 ruleset 的 mode 组合。 */
export class RuleGroup {
  rules: Rule[] = [];
  mode: RulesetLogicalMode = RulesetLogicalMode.And;
  isReversed: boolean = false;
  /** 停用的组整组不参与求值（桌面版 `foreach (var group in ruleset.Groups.Where(x => x.IsEnabled))`）。 */
  isEnabled: boolean = true;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    const arr: JsonArray = new JsonArray();
    for (const rule of this.rules) {
      arr.push(rule.toJson());
    }
    out.set('Rules', arr);
    out.set('Mode', ModelCodec.intNode(this.mode));
    out.set('IsReversed', new JsonBoolean(this.isReversed));
    out.set('IsEnabled', new JsonBoolean(this.isEnabled));
    return out;
  }

  static parse(node: JsonNode): RuleGroup {
    const out: RuleGroup = new RuleGroup();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    const list: JsonArray | undefined = JsonValue.asArray(obj.tryGet('Rules'));
    if (list !== undefined) {
      const items: JsonNode[] = list.values();
      for (const item of items) {
        out.rules.push(Rule.parse(item));
      }
    }
    out.mode = ModelCodec.int(obj, 'Mode', RulesetLogicalMode.And) === RulesetLogicalMode.Or
      ? RulesetLogicalMode.Or
      : RulesetLogicalMode.And;
    out.isReversed = ModelCodec.bool(obj, 'IsReversed', false);
    out.isEnabled = ModelCodec.bool(obj, 'IsEnabled', true);
    return out;
  }
}

/** 完整的规则集。 */
export class Ruleset {
  mode: RulesetLogicalMode = RulesetLogicalMode.Or;
  isReversed: boolean = false;
  groups: RuleGroup[] = [];

  /**
   * 桌面版的新建默认：Groups = [new RuleGroup { Rules = [new Rule()] }]，
   * 也就是「一个组、组里一条空规则」。求值时空规则不计入，于是这份默认值等价于
   * false。这里照抄同样的形状，编辑器打开就能直接往里填。
   */
  static defaultRuleset(): Ruleset {
    const out: Ruleset = new Ruleset();
    const group: RuleGroup = new RuleGroup();
    group.rules.push(new Rule());
    out.groups.push(group);
    return out;
  }

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Mode', ModelCodec.intNode(this.mode));
    out.set('IsReversed', new JsonBoolean(this.isReversed));
    const arr: JsonArray = new JsonArray();
    for (const group of this.groups) {
      arr.push(group.toJson());
    }
    out.set('Groups', arr);
    return out;
  }

  static parse(node: JsonNode): Ruleset {
    const out: Ruleset = new Ruleset();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.mode = ModelCodec.int(obj, 'Mode', RulesetLogicalMode.Or) === RulesetLogicalMode.And
      ? RulesetLogicalMode.And
      : RulesetLogicalMode.Or;
    out.isReversed = ModelCodec.bool(obj, 'IsReversed', false);
    const list: JsonArray | undefined = JsonValue.asArray(obj.tryGet('Groups'));
    if (list !== undefined) {
      const items: JsonNode[] = list.values();
      for (const item of items) {
        out.groups.push(RuleGroup.parse(item));
      }
    }
    return out;
  }

  /** 紧凑序列化，给往返比较与脏检查用。 */
  static stringify(ruleset: Ruleset): string {
    return JsonWriter.writeCompact(ruleset.toJson());
  }
}

/**
 * 字符串匹配设置。
 *
 * 对应桌面版 ClassIsland.Core/Models/Ruleset/StringMatchingSettings，被四条规则用：
 *   classisland.windows.className / text / processName、classisland.weather.hasWeatherAlert
 * 前三条在鸿蒙侧没有对应物（不存在「前台窗口」），最后一条等 P11 接上天气。
 * 模型照留：用户从桌面版同步过来的设置不该被这边抹掉。
 */
export class StringMatchingSettings {
  /** 要匹配的字符串，或正则表达式。 */
  text: string = '';
  /** 是否按正则解释 text。 */
  useRegex: boolean = false;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Text', new JsonString(this.text));
    out.set('UseRegex', new JsonBoolean(this.useRegex));
    return out;
  }

  static parse(node: JsonNode): StringMatchingSettings {
    const out: StringMatchingSettings = new StringMatchingSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.text = ModelCodec.string(obj, 'Text', '');
    out.useRegex = ModelCodec.bool(obj, 'UseRegex', false);
    return out;
  }

  /**
   * 判断给定字符串是否满足此匹配。
   *
   * 正则编译失败返回 false，与桌面版 `try { Regex.Match } catch { return false }` 一致。
   * 刻意不加 g 标志：桌面版看的是 Match.Success，全局正则会带 lastIndex 状态、
   * 连续两次匹配同一串的结果可能不同，而这里每次调用都是一次独立判定。
   */
  isMatching(str: string): boolean {
    if (!this.useRegex) {
      return str === this.text;
    }
    try {
      const pattern: RegExp = new RegExp(this.text);
      return pattern.test(str);
    } catch (error) {
      return false;
    }
  }
}

/** 当前时间状态规则设置。classisland.lessons.timeState */
export class TimeStateRuleSettings {
  state: TimeState = TimeState.OnClass;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('State', ModelCodec.intNode(this.state));
    return out;
  }

  static parse(node: JsonNode): TimeStateRuleSettings {
    const out: TimeStateRuleSettings = new TimeStateRuleSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    // 越界值退回 OnClass，与 C# 的行为一致：枚举反序列化失败会抛，
    // 而 RulesetService 把异常吞掉并返回 false —— 表现上就是「这条规则不成立」，
    // 不成立与「配了 OnClass 但当前不在上课」在求值上无法区分，所以取默认值即可。
    const raw: number = ModelCodec.int(obj, 'State', TimeState.OnClass);
    out.state = raw >= TimeState.None && raw <= TimeState.AfterSchool
      ? raw as TimeState
      : TimeState.OnClass;
    return out;
  }
}

/** 科目匹配规则设置。三个科目类规则共用。 */
export class CurrentSubjectRuleSettings {
  subjectId: Guid = Guid.empty();

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('SubjectId', ModelCodec.guidNode(this.subjectId));
    return out;
  }

  static parse(node: JsonNode): CurrentSubjectRuleSettings {
    const out: CurrentSubjectRuleSettings = new CurrentSubjectRuleSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.subjectId = ModelCodec.readNullableGuid(obj, 'SubjectId') ?? Guid.empty();
    return out;
  }
}

/** 天气匹配规则设置。classisland.weather.currentWeather / tomorrowWeather */
export class CurrentWeatherRuleSettings {
  weatherId: number = 0;
  isFuzzyMatch: boolean = false;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('WeatherId', ModelCodec.intNode(this.weatherId));
    out.set('IsFuzzyMatch', new JsonBoolean(this.isFuzzyMatch));
    return out;
  }

  static parse(node: JsonNode): CurrentWeatherRuleSettings {
    const out: CurrentWeatherRuleSettings = new CurrentWeatherRuleSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.weatherId = ModelCodec.int(obj, 'WeatherId', 0);
    out.isFuzzyMatch = ModelCodec.bool(obj, 'IsFuzzyMatch', false);
    return out;
  }
}

/** 降水时间规则设置。classisland.weather.rainTime */
export class RainTimeRuleSettings {
  rainTimeMinutes: number = 60;
  /** true 表示「还剩多少分钟」，false 表示「已经过去多少分钟」。 */
  isRemainingTime: boolean = false;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('RainTimeMinutes', ModelCodec.doubleNode(this.rainTimeMinutes));
    out.set('IsRemainingTime', new JsonBoolean(this.isRemainingTime));
    return out;
  }

  static parse(node: JsonNode): RainTimeRuleSettings {
    const out: RainTimeRuleSettings = new RainTimeRuleSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.rainTimeMinutes = ModelCodec.number(obj, 'RainTimeMinutes', 60);
    out.isRemainingTime = ModelCodec.bool(obj, 'IsRemainingTime', false);
    return out;
  }
}

/** 日出日落规则设置。classisland.weather.sunRiseSet */
export class SunRiseSetRuleSettings {
  timeMinutes: number = 60;
  isSunset: boolean = false;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('TimeMinutes', ModelCodec.doubleNode(this.timeMinutes));
    out.set('IsSunset', new JsonBoolean(this.isSunset));
    return out;
  }

  static parse(node: JsonNode): SunRiseSetRuleSettings {
    const out: SunRiseSetRuleSettings = new SunRiseSetRuleSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.timeMinutes = ModelCodec.number(obj, 'TimeMinutes', 60);
    out.isSunset = ModelCodec.bool(obj, 'IsSunset', false);
    return out;
  }
}

/** 前台窗口状态规则设置。classisland.windows.status */
export class WindowStatusRuleSettings {
  /** 0 最小化 / 1 正常 / 2 最大化。鸿蒙侧无前台窗口，这条规则恒为 false。 */
  state: number = 1;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('State', ModelCodec.intNode(this.state));
    return out;
  }

  static parse(node: JsonNode): WindowStatusRuleSettings {
    const out: WindowStatusRuleSettings = new WindowStatusRuleSettings();
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      return out;
    }
    out.state = ModelCodec.int(obj, 'State', 1);
    return out;
  }
}

/**
 * 桌面版注册的全部 13 条规则的 ID。
 *
 * 顺序照 App.Services.xaml.cs 的注册顺序，编辑器里的规则选择器按这个顺序排 ——
 * 与桌面版一致，用户在两边看到的次序相同。
 */
export class RuleIds {
  static readonly WINDOW_CLASS_NAME: string = 'classisland.windows.className';
  static readonly WINDOW_TEXT: string = 'classisland.windows.text';
  static readonly WINDOW_STATUS: string = 'classisland.windows.status';
  static readonly WINDOW_PROCESS_NAME: string = 'classisland.windows.processName';
  static readonly LESSONS_CURRENT_SUBJECT: string = 'classisland.lessons.currentSubject';
  static readonly LESSONS_NEXT_SUBJECT: string = 'classisland.lessons.nextSubject';
  static readonly LESSONS_PREVIOUS_SUBJECT: string = 'classisland.lessons.previousSubject';
  static readonly LESSONS_TIME_STATE: string = 'classisland.lessons.timeState';
  static readonly WEATHER_CURRENT: string = 'classisland.weather.currentWeather';
  static readonly WEATHER_TOMORROW: string = 'classisland.weather.tomorrowWeather';
  static readonly WEATHER_ALERT: string = 'classisland.weather.hasWeatherAlert';
  static readonly WEATHER_RAIN_TIME: string = 'classisland.weather.rainTime';
  static readonly WEATHER_SUN_RISE_SET: string = 'classisland.weather.sunRiseSet';
}
