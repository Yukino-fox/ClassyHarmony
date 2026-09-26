/*
 * 桌面版「主界面组件布局」的持久化模型。
 *
 * 存在哪
 * ------
 * 不在 profile.json 里，而在 AppConfigPath/ComponentLayouts/{方案名}.json，
 * 方案名由 settings.json 的 CurrentComponentConfig 指定。桌面版另有
 * DefaultComponentProfile（单行：日期组件 + 课程表组件）作为文件缺失时的兜底。
 *
 * 这条边界值得单独记一笔：组件布局与课表档案是**两个文件、两个方案**。
 * 混在一起的话，「换一套课表」会连带把精心排的面板一起换掉，而这两件事在
 * 桌面版里从来就不相关。
 *
 * 为什么 Settings 是裸 JsonNode
 * ---------------------------
 * 桌面版 ComponentSettings.Settings 的声明类型是 object?，落盘时按组件各自的
 * 实际类型多态序列化。ArkTS 没有运行时多态，这里原样承载节点树：
 *
 *   - 未被本实现认识的组件（插件注册的）原样透传，逐字节不丢；
 *   - 已认识的组件在 common_core 里按 schema 读出强类型视图（ComponentPayloads），
 *     写回时**在原节点上就地改键**，不重建对象 —— 于是字段顺序、未建模的字段、
 *     以及未来版本新增的字段全都原样留着。
 *
 * 反过来做（先 new 一个默认对象再序列化）在语义上更干净，但桌面版是从不这么
 * 读的：它读文件时把 Settings 缺失的情况补成默认实例，于是「桌面版写出来的
 * 文件」必然字段齐全，而「我们补出来的默认」一旦与桌面版的默认值有出入
 * （比如 CountDown 的 OverTimeTime 默认为 DateTime.Now.Date），两端就开始
 * 互相改写对方的数据。就地改键没有这个问题。
 *
 * HidingRules 同理：Ruleset 是 P8 的范围，这里也当裸节点透传。
 *
 * 字段顺序即落盘顺序
 * ----------------
 * System.Text.Json 没有 DefaultIgnoreCondition，默认值也写；属性顺序取 C#
 * 声明顺序（[ObservableProperty] 生成的属性按字段声明顺序排）。所以每个
 * toJson() 的 set 顺序必须与 C# 源码里的属性顺序逐字对应，不能按字母排、
 * 不能按语义分组。改顺序不改变解析结果，但会让「桌面版写、我们改、再读」
 * 之后与「桌面版写、我们改」的文件产生无谓的差异，同步到别的设备上就体现为
 * 整个文件都变了。
 */

import { ColorValue } from '../json/ColorValue';
import { JsonBoolean, JsonNode, JsonNull, JsonObject, JsonString } from '../json/JsonNode';
import { JsonReader } from '../json/JsonReader';
import { JsonValue } from '../json/JsonValue';
import { JsonWriter } from '../json/JsonWriter';
import { ModelCodec } from './ModelCodec';

/** Avalonia Layout.HorizontalAlignment 的数值。写进 JSON 就是整数。 */
export const HORIZONTAL_STRETCH: number = 0;
export const HORIZONTAL_CENTER: number = 1;
export const HORIZONTAL_LEFT: number = 2;
export const HORIZONTAL_RIGHT: number = 3;

/** MainWindowLineSettings.IslandSeparationMode：0 默认 / 1 禁用 / 2 启用。 */
export const ISLAND_SEPARATION_DEFAULT: number = 0;

/** 桌面版 DefaultComponentProfile 里那两个组件的 GUID（小写）。 */
export const DATE_COMPONENT_ID: string = 'df3f8295-21f6-482e-bada-fa0e5f14bb66';
export const SCHEDULE_COMPONENT_ID: string = '1db2017d-e374-4bc6-9d57-0b4adf03a6b8';

/** 读可空颜色字面量。 */
function readColor(node: JsonObject, fieldName: string, fallback: ColorValue): ColorValue {
  const parsed: ColorValue | undefined =
    ColorValue.tryParse(ModelCodec.string(node, fieldName, ''));
  if (parsed !== undefined) {
    return parsed;
  }
  // 字段缺失走 fallback，字段在但读不出来走 default(Color)（全透明黑）：
  // 桌面版 ColorHexJsonConverter.Read 的 ParseHexString 失败时 `?? default`。
  return node.has(fieldName) ? ColorValue.transparent() : fallback;
}

/** 写可空节点。undefined 写 null，与 C# 的 object? 一致。 */
function putOptional(out: JsonObject, name: string, value: JsonNode | undefined): void {
  out.set(name, value === undefined ? new JsonNull() : value);
}

/** 主界面上的一个组件。 */
export class ComponentSettings {
  /**
   * 组件 GUID，小写 D 格式。
   *
   * 桌面版的 setter 里有 `value = value.ToLower()`，所以写进文件的一定是小写。
   * 这里在读入时就归一，否则同一个组件在文件里可能一半大写一半小写，
   * 与注册表查表对不上（桌面版的比较用的是 OrdinalIgnoreCase，但我们不该
   * 依赖这一点）。
   */
  id: string = '';
  nameCache: string = '';
  settings: JsonNode | undefined = undefined;
  hideOnRule: boolean = false;
  hidingRules: JsonNode | undefined = undefined;
  isResourceOverridingEnabled: boolean = false;
  mainWindowSecondaryFontSize: number = 14;
  mainWindowBodyFontSize: number = 16;
  mainWindowEmphasizedFontSize: number = 18;
  mainWindowLargeFontSize: number = 20;
  isCustomForegroundColorEnabled: boolean = false;
  foregroundColor: ColorValue = ColorValue.dodgerBlue();
  backgroundOpacity: number = 0.5;
  isCustomBackgroundOpacityEnabled: boolean = false;
  backgroundColor: ColorValue = ColorValue.black();
  isCustomBackgroundColorEnabled: boolean = false;
  customCornerRadius: number = 0;
  isCustomCornerRadiusEnabled: boolean = false;
  opacity: number = 1;
  relativeLineNumber: number = 0;
  isMinWidthEnabled: boolean = false;
  minWidth: number = 100;
  isMaxWidthEnabled: boolean = false;
  maxWidth: number = 300;
  isFixedWidthEnabled: boolean = false;
  fixedWidth: number = 200;
  horizontalAlignment: number = HORIZONTAL_STRETCH;
  isCustomMarginEnabled: boolean = false;
  marginLeft: number = 0;
  marginTop: number = 0;
  marginRight: number = 0;
  marginBottom: number = 0;
  lastWidthCache: number = 100;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Id', new JsonString(this.id));
    out.set('NameCache', new JsonString(this.nameCache));
    putOptional(out, 'Settings', this.settings);
    out.set('HideOnRule', new JsonBoolean(this.hideOnRule));
    putOptional(out, 'HidingRules', this.hidingRules);
    out.set('IsResourceOverridingEnabled', new JsonBoolean(this.isResourceOverridingEnabled));
    out.set('MainWindowSecondaryFontSize', ModelCodec.doubleNode(this.mainWindowSecondaryFontSize));
    out.set('MainWindowBodyFontSize', ModelCodec.doubleNode(this.mainWindowBodyFontSize));
    out.set('MainWindowEmphasizedFontSize', ModelCodec.doubleNode(this.mainWindowEmphasizedFontSize));
    out.set('MainWindowLargeFontSize', ModelCodec.doubleNode(this.mainWindowLargeFontSize));
    out.set('IsCustomForegroundColorEnabled', new JsonBoolean(this.isCustomForegroundColorEnabled));
    out.set('ForegroundColor', new JsonString(this.foregroundColor.toString()));
    out.set('BackgroundOpacity', ModelCodec.doubleNode(this.backgroundOpacity));
    out.set('IsCustomBackgroundOpacityEnabled', new JsonBoolean(this.isCustomBackgroundOpacityEnabled));
    out.set('BackgroundColor', new JsonString(this.backgroundColor.toString()));
    out.set('IsCustomBackgroundColorEnabled', new JsonBoolean(this.isCustomBackgroundColorEnabled));
    out.set('CustomCornerRadius', ModelCodec.doubleNode(this.customCornerRadius));
    out.set('IsCustomCornerRadiusEnabled', new JsonBoolean(this.isCustomCornerRadiusEnabled));
    out.set('Opacity', ModelCodec.doubleNode(this.opacity));
    out.set('RelativeLineNumber', ModelCodec.intNode(this.relativeLineNumber));
    out.set('IsMinWidthEnabled', new JsonBoolean(this.isMinWidthEnabled));
    out.set('MinWidth', ModelCodec.doubleNode(this.minWidth));
    out.set('IsMaxWidthEnabled', new JsonBoolean(this.isMaxWidthEnabled));
    out.set('MaxWidth', ModelCodec.doubleNode(this.maxWidth));
    out.set('IsFixedWidthEnabled', new JsonBoolean(this.isFixedWidthEnabled));
    out.set('FixedWidth', ModelCodec.doubleNode(this.fixedWidth));
    out.set('HorizontalAlignment', ModelCodec.intNode(this.horizontalAlignment));
    out.set('IsCustomMarginEnabled', new JsonBoolean(this.isCustomMarginEnabled));
    out.set('MarginLeft', ModelCodec.doubleNode(this.marginLeft));
    out.set('MarginTop', ModelCodec.doubleNode(this.marginTop));
    out.set('MarginRight', ModelCodec.doubleNode(this.marginRight));
    out.set('MarginBottom', ModelCodec.doubleNode(this.marginBottom));
    out.set('LastWidthCache', ModelCodec.doubleNode(this.lastWidthCache));
    return out;
  }

  static fromJson(node: JsonObject): ComponentSettings {
    const out: ComponentSettings = new ComponentSettings();
    out.id = ModelCodec.string(node, 'Id', '').toLowerCase();
    out.nameCache = ModelCodec.string(node, 'NameCache', '');
    // 判「显式 null」要用 JsonValue.isNull：解析出来的 null 是一个 JsonNull
    // 实例，跟 JS 的 null 不是一回事。按 === null 判会漏掉它，于是本该是
    // 「无设置对象」的组件会挂上一个 JsonNull 实例，写出去还是 null（看着
    // 没问题），但 JsonValue.asObject 对它返回 undefined，界面上的「新建/改设置」
    // 分支与「已存在」分支行为不一致 —— 这类不一致只在装机后才显形。
    //
    // 判据写成「非空且非 null」而不是 isNull(...) ? : ...，是因为 ArkTS 不会
    // 借一个自写的判定函数做类型收窄，isNull 为假之后 rawSettings 仍是
    // JsonNode | undefined，传给 cloneNode 会被判 10605999。
    const rawSettings: JsonNode | undefined = node.tryGet('Settings');
    out.settings = rawSettings !== undefined && !JsonValue.isNull(rawSettings)
      ? ModelCodec.cloneNode(rawSettings)
      : undefined;
    out.hideOnRule = ModelCodec.bool(node, 'HideOnRule', false);
    const rawRules: JsonNode | undefined = node.tryGet('HidingRules');
    out.hidingRules = rawRules !== undefined && !JsonValue.isNull(rawRules)
      ? ModelCodec.cloneNode(rawRules)
      : undefined;
    out.isResourceOverridingEnabled = ModelCodec.bool(node, 'IsResourceOverridingEnabled', false);
    out.mainWindowSecondaryFontSize = ModelCodec.number(node, 'MainWindowSecondaryFontSize', 14);
    out.mainWindowBodyFontSize = ModelCodec.number(node, 'MainWindowBodyFontSize', 16);
    out.mainWindowEmphasizedFontSize = ModelCodec.number(node, 'MainWindowEmphasizedFontSize', 18);
    out.mainWindowLargeFontSize = ModelCodec.number(node, 'MainWindowLargeFontSize', 20);
    out.isCustomForegroundColorEnabled = ModelCodec.bool(node, 'IsCustomForegroundColorEnabled', false);
    out.foregroundColor = readColor(node, 'ForegroundColor', ColorValue.dodgerBlue());
    out.backgroundOpacity = ModelCodec.number(node, 'BackgroundOpacity', 0.5);
    out.isCustomBackgroundOpacityEnabled = ModelCodec.bool(node, 'IsCustomBackgroundOpacityEnabled', false);
    out.backgroundColor = readColor(node, 'BackgroundColor', ColorValue.black());
    out.isCustomBackgroundColorEnabled = ModelCodec.bool(node, 'IsCustomBackgroundColorEnabled', false);
    out.customCornerRadius = ModelCodec.number(node, 'CustomCornerRadius', 0);
    out.isCustomCornerRadiusEnabled = ModelCodec.bool(node, 'IsCustomCornerRadiusEnabled', false);
    out.opacity = ModelCodec.number(node, 'Opacity', 1);
    out.relativeLineNumber = ModelCodec.int(node, 'RelativeLineNumber', 0);
    out.isMinWidthEnabled = ModelCodec.bool(node, 'IsMinWidthEnabled', false);
    out.minWidth = ModelCodec.number(node, 'MinWidth', 100);
    out.isMaxWidthEnabled = ModelCodec.bool(node, 'IsMaxWidthEnabled', false);
    out.maxWidth = ModelCodec.number(node, 'MaxWidth', 300);
    out.isFixedWidthEnabled = ModelCodec.bool(node, 'IsFixedWidthEnabled', false);
    out.fixedWidth = ModelCodec.number(node, 'FixedWidth', 200);
    out.horizontalAlignment = ModelCodec.int(node, 'HorizontalAlignment', HORIZONTAL_STRETCH);
    out.isCustomMarginEnabled = ModelCodec.bool(node, 'IsCustomMarginEnabled', false);
    out.marginLeft = ModelCodec.number(node, 'MarginLeft', 0);
    out.marginTop = ModelCodec.number(node, 'MarginTop', 0);
    out.marginRight = ModelCodec.number(node, 'MarginRight', 0);
    out.marginBottom = ModelCodec.number(node, 'MarginBottom', 0);
    out.lastWidthCache = ModelCodec.number(node, 'LastWidthCache', 100);
    return out;
  }

  /** 深拷贝。容器组件的子树要能各自持有互不可见的节点。 */
  clone(): ComponentSettings {
    return ComponentSettings.fromJson(this.toJson());
  }
}

/** 主界面行。 */
export class MainWindowLineSettings {
  children: ComponentSettings[] = [];
  isMainLine: boolean = false;
  isNotificationEnabled: boolean = true;
  isResourceOverridingEnabled: boolean = false;
  mainWindowSecondaryFontSize: number = 14;
  mainWindowBodyFontSize: number = 16;
  mainWindowEmphasizedFontSize: number = 18;
  mainWindowLargeFontSize: number = 20;
  isCustomForegroundColorEnabled: boolean = false;
  foregroundColor: ColorValue = ColorValue.dodgerBlue();
  backgroundOpacity: number = 0.5;
  isCustomBackgroundOpacityEnabled: boolean = false;
  backgroundColor: ColorValue = ColorValue.black();
  isCustomBackgroundColorEnabled: boolean = false;
  customCornerRadius: number = 0;
  isCustomCornerRadiusEnabled: boolean = false;
  opacity: number = 1;
  /**
   * 行的 IsVisible 是落盘的。
   *
   * 组件上的同名属性被 [JsonIgnore]（那是布局算出来的运行态），行上的这个不是
   * —— 行是用户显式关掉整行的开关。两处同名，一个落盘一个不落盘，读代码时
   * 很容易看错，所以在这里写明。
   */
  isVisible: boolean = true;
  hideOnRule: boolean = false;
  hidingRules: JsonNode | undefined = undefined;
  islandSeparationMode: number = ISLAND_SEPARATION_DEFAULT;

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Children', ModelCodec.writeArray(this.children,
      (v: ComponentSettings) => v.toJson()));
    out.set('IsMainLine', new JsonBoolean(this.isMainLine));
    out.set('IsNotificationEnabled', new JsonBoolean(this.isNotificationEnabled));
    out.set('IsResourceOverridingEnabled', new JsonBoolean(this.isResourceOverridingEnabled));
    out.set('MainWindowSecondaryFontSize', ModelCodec.doubleNode(this.mainWindowSecondaryFontSize));
    out.set('MainWindowBodyFontSize', ModelCodec.doubleNode(this.mainWindowBodyFontSize));
    out.set('MainWindowEmphasizedFontSize', ModelCodec.doubleNode(this.mainWindowEmphasizedFontSize));
    out.set('MainWindowLargeFontSize', ModelCodec.doubleNode(this.mainWindowLargeFontSize));
    out.set('IsCustomForegroundColorEnabled', new JsonBoolean(this.isCustomForegroundColorEnabled));
    out.set('ForegroundColor', new JsonString(this.foregroundColor.toString()));
    out.set('BackgroundOpacity', ModelCodec.doubleNode(this.backgroundOpacity));
    out.set('IsCustomBackgroundOpacityEnabled', new JsonBoolean(this.isCustomBackgroundOpacityEnabled));
    out.set('BackgroundColor', new JsonString(this.backgroundColor.toString()));
    out.set('IsCustomBackgroundColorEnabled', new JsonBoolean(this.isCustomBackgroundColorEnabled));
    out.set('CustomCornerRadius', ModelCodec.doubleNode(this.customCornerRadius));
    out.set('IsCustomCornerRadiusEnabled', new JsonBoolean(this.isCustomCornerRadiusEnabled));
    out.set('Opacity', ModelCodec.doubleNode(this.opacity));
    out.set('IsVisible', new JsonBoolean(this.isVisible));
    out.set('HideOnRule', new JsonBoolean(this.hideOnRule));
    putOptional(out, 'HidingRules', this.hidingRules);
    out.set('IslandSeparationMode', ModelCodec.intNode(this.islandSeparationMode));
    return out;
  }

  static fromJson(node: JsonObject): MainWindowLineSettings {
    const out: MainWindowLineSettings = new MainWindowLineSettings();
    out.children = ModelCodec.readArray(node, 'Children',
      (item: JsonNode) => ComponentSettings.fromJson(JsonValue.asObject(item) ?? new JsonObject()));
    out.isMainLine = ModelCodec.bool(node, 'IsMainLine', false);
    out.isNotificationEnabled = ModelCodec.bool(node, 'IsNotificationEnabled', true);
    out.isResourceOverridingEnabled = ModelCodec.bool(node, 'IsResourceOverridingEnabled', false);
    out.mainWindowSecondaryFontSize = ModelCodec.number(node, 'MainWindowSecondaryFontSize', 14);
    out.mainWindowBodyFontSize = ModelCodec.number(node, 'MainWindowBodyFontSize', 16);
    out.mainWindowEmphasizedFontSize = ModelCodec.number(node, 'MainWindowEmphasizedFontSize', 18);
    out.mainWindowLargeFontSize = ModelCodec.number(node, 'MainWindowLargeFontSize', 20);
    out.isCustomForegroundColorEnabled = ModelCodec.bool(node, 'IsCustomForegroundColorEnabled', false);
    out.foregroundColor = readColor(node, 'ForegroundColor', ColorValue.dodgerBlue());
    out.backgroundOpacity = ModelCodec.number(node, 'BackgroundOpacity', 0.5);
    out.isCustomBackgroundOpacityEnabled = ModelCodec.bool(node, 'IsCustomBackgroundOpacityEnabled', false);
    out.backgroundColor = readColor(node, 'BackgroundColor', ColorValue.black());
    out.isCustomBackgroundColorEnabled = ModelCodec.bool(node, 'IsCustomBackgroundColorEnabled', false);
    out.customCornerRadius = ModelCodec.number(node, 'CustomCornerRadius', 0);
    out.isCustomCornerRadiusEnabled = ModelCodec.bool(node, 'IsCustomCornerRadiusEnabled', false);
    out.opacity = ModelCodec.number(node, 'Opacity', 1);
    out.isVisible = ModelCodec.bool(node, 'IsVisible', true);
    out.hideOnRule = ModelCodec.bool(node, 'HideOnRule', false);
    const rules: JsonNode | undefined = node.tryGet('HidingRules');
    out.hidingRules = rules !== undefined && !JsonValue.isNull(rules)
      ? ModelCodec.cloneNode(rules)
      : undefined;
    out.islandSeparationMode = ModelCodec.int(node, 'IslandSeparationMode', ISLAND_SEPARATION_DEFAULT);
    return out;
  }
}

/**
 * 组件配置方案。落盘文件的根对象，全文只有一个 Lines 字段。
 */
export class ComponentProfile {
  lines: MainWindowLineSettings[] = [];

  toJson(): JsonObject {
    const out: JsonObject = new JsonObject();
    out.set('Lines', ModelCodec.writeArray(this.lines,
      (v: MainWindowLineSettings) => v.toJson()));
    return out;
  }

  static fromJson(node: JsonObject): ComponentProfile {
    const out: ComponentProfile = new ComponentProfile();
    out.lines = ModelCodec.readArray(node, 'Lines',
      (item: JsonNode) => MainWindowLineSettings.fromJson(JsonValue.asObject(item) ?? new JsonObject()));
    return out;
  }

  /** 解析。根值不是对象时抛错，与 Profile.parse 一致。 */
  static parse(text: string): ComponentProfile {
    const node: JsonNode = JsonReader.parse(text);
    const obj: JsonObject | undefined = JsonValue.asObject(node);
    if (obj === undefined) {
      throw new Error('组件布局 JSON 根值不是对象');
    }
    return ComponentProfile.fromJson(obj);
  }

  /**
   * 序列化为 JSON 文本。indentSize=0 为压缩输出。
   *
   * 默认压缩是刻意的：桌面版 ComponentsService 走的是
   * ConfigureFileHelper.SaveConfig(path, o)，而那个的重载默认 writeIndented=false。
   * 我们若写成缩进版，两端每次互相保存都会把整个文件改写一遍。
   */
  static stringify(profile: ComponentProfile, indentSize: number = 0): string {
    return JsonWriter.write(profile.toJson(), indentSize);
  }

  /**
   * 桌面版的 DefaultComponentProfile：单行，日期组件 + 课程表组件。
   *
   * 桌面版在目标文件不存在时用它兜底并立刻 SaveConfig，所以第一次启动之后
   * 文件里就是这两个组件。这里保持一致，好让「鸿蒙侧新建文件」与「桌面版
   * 新建文件」产出同一份布局 —— 否则用户在两端之间切一次，面板就变了。
   */
  static defaultProfile(): ComponentProfile {
    const out: ComponentProfile = new ComponentProfile();
    const line: MainWindowLineSettings = new MainWindowLineSettings();
    const date: ComponentSettings = new ComponentSettings();
    date.id = DATE_COMPONENT_ID;
    const schedule: ComponentSettings = new ComponentSettings();
    schedule.id = SCHEDULE_COMPONENT_ID;
    line.children.push(date);
    line.children.push(schedule);
    out.lines.push(line);
    return out;
  }
}
