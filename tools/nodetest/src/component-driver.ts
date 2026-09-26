/*
 * 主界面组件布局测试台。
 *
 * 这一层的风险和课表档案那边不一样。档案的字段是「少一个就报错」的那种，
 * 布局的字段大多是「少一个也能显示」的那种 —— 出错时界面上表现为面板里某个
 * 组件名不对、颜色不对、位置不对，没有异常、没有日志。所以断言必须盯住那些
 * 只有读过桌面版源码才知道的东西：
 *
 *   1. 颜色字面量是 #RRGGBBAA 而不是 #AARRGGBB。写反了 JSON 完全合法，只是
 *      不透明红被当成透明度、面板背景变黑红 —— 真机上也看不出是「颜色错了」
 *      还是「深色主题就这样」。
 *   2. 字段顺序即落盘顺序。System.Text.Json 没有 DefaultIgnoreCondition，
 *      属性顺序取 C# 声明顺序。顺序错了不影响解析，但两端来回保存会让整个
 *      文件每次都被重写，同步到别的设备上就体现为「我什么都没改，文件却变了」。
 *   3. 行的 IsVisible 落盘、组件的 IsVisible 不落盘。两处同名，只看名字会写反。
 *   4. Settings 是裸 JSON。就地改键之后，未建模的字段与字段顺序必须原样留着；
 *      重建对象会把插件私有数据悄悄丢掉，而丢的时候没有任何症状。
 *   5. 嵌套容器的子列表是副本。改动操作漏了写回的话，界面上「点了没反应」，
 *      而顶层的增删改一切正常 —— 因为只有顶层不需要写回。
 *   6. 移动要挡掉「移进自己的子孙」。不挡是无限递归，界面表现为面板卡死。
 *
 * 夹具 component-layout.json 覆盖 3 行、11 类内置组件里的 10 类（含全部 4 个
 * 容器）、一条未知 GUID 的插件组件、一条带规则集的组件，以及
 * LastWidthCache 260.5 这种必须保真的非整数 double。
 */

import { readFileSync } from 'fs';
import { join } from 'path';

import { ColorValue } from '../../common_shared/src/main/ets/json/ColorValue';
import { JsonNode, JsonObject, JsonString } from '../../common_shared/src/main/ets/json/JsonNode';
import { JsonReader } from '../../common_shared/src/main/ets/json/JsonReader';
import { JsonWriter } from '../../common_shared/src/main/ets/json/JsonWriter';
import { JsonValue } from '../../common_shared/src/main/ets/json/JsonValue';
import { ModelCodec } from '../../common_shared/src/main/ets/models/ModelCodec';
import {
  ComponentProfile,
  ComponentSettings
} from '../../common_shared/src/main/ets/models/ComponentProfile';
import {
  COMPONENT_CLOCK,
  COMPONENT_COUNTDOWN,
  COMPONENT_DATE,
  COMPONENT_GROUP,
  COMPONENT_ROLLING,
  COMPONENT_SCHEDULE,
  COMPONENT_SEPARATOR,
  COMPONENT_SLIDE,
  COMPONENT_STACK,
  COMPONENT_TEXT,
  COMPONENT_WEATHER,
  ComponentCatalog,
  ComponentDescriptor
} from '../../common_core/src/main/ets/components/ComponentCatalog';
import {
  ComponentLayoutMutations,
  ComponentLocation
} from '../../common_core/src/main/ets/components/ComponentLayoutMutations';
import {
  ClockPayload,
  ComponentPayload,
  CountDownPayload,
  TextPayload
} from '../../common_core/src/main/ets/components/ComponentPayloads';

let passed: number = 0;
const failures: string[] = [];

function check(name: string, condition: boolean, detail: string = ''): void {
  if (condition) {
    passed++;
  } else {
    failures.push(detail.length === 0 ? name : `${name} —— ${detail}`);
  }
}

function checkEqual(name: string, actual: string, expected: string): void {
  check(name, actual === expected, `实际 ${actual}，期望 ${expected}`);
}

function checkNum(name: string, actual: number, expected: number): void {
  checkEqual(name, String(actual), String(expected));
}

function checkTrue(name: string, value: boolean): void {
  check(name, value, '期望 true');
}

function fixture(name: string): string {
  return readFileSync(join(__dirname, '..', 'fixtures', name), 'utf8');
}

/** 组件的设置节点。取不到时记账并给一个空对象，让后续断言继续跑完。 */
function nodeOf(settings: ComponentSettings): JsonObject {
  const node: JsonObject | undefined = JsonValue.asObject(settings.settings);
  if (node === undefined) {
    check('取设置节点', false, `组件 ${settings.id} 的 Settings 不是对象`);
    return new JsonObject();
  }
  return node;
}

/** 节点的键序列表。 */
function keysOf(node: JsonObject): string[] {
  return node.entries().map((member) => member.name);
}

// ---------------------------------------------------------------- 1. 字节级往返

/**
 * 黄金样本：往返稳定。
 *
 * 夹具写成缩进版，这里比的是压缩之后的结果 —— 桌面版 SaveConfig 走的是
 * writeIndented=false 的重载，压缩才是我们真正写盘时的形态。
 *
 * 「一次往返就等于二次往返」是这里最关键的一条：任何字段的读写不对称（读进来
 * 丢信息、写出去多出键、double 被截断）都会让它失败。
 */
function testGoldenLayout(): void {
  const original: string = fixture('component-layout.json');
  const once: string = ComponentProfile.stringify(ComponentProfile.parse(original));
  const twice: string = ComponentProfile.stringify(ComponentProfile.parse(once));
  checkEqual('黄金样本：一次往返稳定', twice, once);
  check('黄金样本：压缩输出不含换行', once.indexOf('\n') < 0);

  const profile: ComponentProfile = ComponentProfile.parse(once);
  checkNum('黄金样本：行数', profile.lines.length, 3);
  checkNum('黄金样本：首行组件数', profile.lines[0].children.length, 3);
  checkEqual('黄金样本：首行第一个是日期组件', profile.lines[0].children[0].id, COMPONENT_DATE);
  checkEqual('黄金样本：首行第二个是分组容器', profile.lines[0].children[1].id, COMPONENT_GROUP);
  checkEqual('黄金样本：首行第三个是课程表', profile.lines[0].children[2].id, COMPONENT_SCHEDULE);
  checkNum('黄金样本：第二行组件数', profile.lines[1].children.length, 3);
  checkNum('黄金样本：第三行组件数', profile.lines[2].children.length, 3);

  // 根对象只有一个键，顺序与名字都要对
  const root: JsonObject = JsonValue.asObject(
    ComponentProfile.parse(once).toJson()) ?? new JsonObject();
  checkEqual('根对象只有 Lines 一个键', keysOf(root).join(','), 'Lines');
}

/** 关键字段逐个核对，防止「顺序对了但值读错了」被往返掩盖过去。 */
function testFieldValues(): void {
  const profile: ComponentProfile = ComponentProfile.parse(fixture('component-layout.json'));

  // 行：IsVisible 落盘
  checkTrue('行 IsVisible 落盘并可读回', profile.lines[0].isVisible);
  checkTrue('行 IsMainLine 首行为假', !profile.lines[0].isMainLine);
  checkTrue('行 IsMainLine 第二行为真', profile.lines[1].isMainLine);
  checkNum('行 IslandSeparationMode', profile.lines[1].islandSeparationMode, 2);
  checkNum('行 BackgroundOpacity', profile.lines[1].backgroundOpacity, 0.25);
  checkNum('行 CustomCornerRadius', profile.lines[1].customCornerRadius, 12);
  checkNum('行 Opacity', profile.lines[1].opacity, 0.9);
  checkNum('行 MainWindowSecondaryFontSize', profile.lines[1].mainWindowSecondaryFontSize, 12);
  checkTrue('行 IsResourceOverridingEnabled', profile.lines[1].isResourceOverridingEnabled);
  checkTrue('行 IsCustomForegroundColorEnabled', profile.lines[1].isCustomForegroundColorEnabled);
  checkTrue('行 IsCustomBackgroundColorEnabled', profile.lines[1].isCustomBackgroundColorEnabled);
  checkTrue('行 IsCustomBackgroundOpacityEnabled', profile.lines[1].isCustomBackgroundOpacityEnabled);
  checkTrue('行 IsCustomCornerRadiusEnabled', profile.lines[1].isCustomCornerRadiusEnabled);
  checkEqual('行 ForegroundColor', profile.lines[1].foregroundColor.toString(), '#FFFFFFFF');
  checkEqual('行 BackgroundColor', profile.lines[1].backgroundColor.toString(), '#10203040');

  // 组件：IsVisible 不落盘，所以默认 true 恒成立；其余字段按 C# 名字读
  const weather: ComponentSettings = profile.lines[1].children[0];
  checkNum('组件 LastWidthCache 非整数不被截断', weather.lastWidthCache, 260.5);
  checkNum('组件 RelativeLineNumber', weather.relativeLineNumber, 1);
  checkNum('组件 HorizontalAlignment', weather.horizontalAlignment, 1);
  checkNum('组件 MinWidth', weather.minWidth, 180);
  checkNum('组件 MaxWidth', weather.maxWidth, 420);
  checkNum('组件 FixedWidth 默认', weather.fixedWidth, 200);
  checkNum('组件 Opacity', weather.opacity, 0.75);
  checkNum('组件 CustomCornerRadius', weather.customCornerRadius, 8);
  checkNum('组件 MarginLeft', weather.marginLeft, 6);
  checkNum('组件 MarginTop', weather.marginTop, 2);
  checkNum('组件 MarginBottom', weather.marginBottom, 2);
  checkTrue('组件 IsMinWidthEnabled', weather.isMinWidthEnabled);
  checkTrue('组件 IsMaxWidthEnabled', weather.isMaxWidthEnabled);
  checkTrue('组件 IsCustomMarginEnabled', weather.isCustomMarginEnabled);
  checkTrue('组件 IsFixedWidthEnabled 为假', !weather.isFixedWidthEnabled);

  // Settings 为 null 的两个：无设置对象的组件
  check('日期组件 Settings 保持 null', profile.lines[0].children[0].settings === undefined);
  check('分割线组件 Settings 保持 null', profile.lines[1].children[1].settings === undefined);
  checkEqual('分割线组件 Id', profile.lines[1].children[1].id, COMPONENT_SEPARATOR);

  // 未知 GUID 的插件组件
  const plugin: ComponentSettings = profile.lines[2].children[2];
  checkEqual('未知组件 Id 原样保留', plugin.id, 'd1e2f3a4-b5c6-4d7e-8f90-a1b2c3d4e5f6');
  checkEqual('未知组件 NameCache 保留', plugin.nameCache, '校园公告（插件）');
  checkEqual('未知组件的私有字段保留', ModelCodec.string(nodeOf(plugin), 'ApiUrl', ''),
    'https://example.invalid/notice');
  checkNum('未知组件的私有数字字段保留', ModelCodec.int(nodeOf(plugin), 'RefreshMinutes', 0), 30);
  checkNum('未知组件的私有上限字段保留', ModelCodec.int(nodeOf(plugin), 'MaxItems', 0), 5);
  check('未知组件不算已注册', !ComponentCatalog.isKnown(plugin.id));

  // 规则集是裸节点，形状不对也要原样留着（P8 才解释它）
  const text: ComponentSettings = ComponentCatalog.childrenOf(profile.lines[0].children[1])[1];
  checkTrue('文本组件 HideOnRule', text.hideOnRule);
  const rules: JsonObject | undefined = JsonValue.asObject(text.hidingRules);
  check('HidingRules 是对象', rules !== undefined);
  if (rules !== undefined) {
    checkNum('HidingRules.Mode 保留', ModelCodec.int(rules, 'Mode', -1), 0);
    check('HidingRules.Groups 保留',
      JsonValue.asArray(rules.tryGet('Groups'))?.count === 1);
  }
}

// ---------------------------------------------------------------- 2. 颜色

function testColor(): void {
  // 桌面版 Colors.DodgerBlue = #1E90FF 全不透明，落盘成 #1E90FFFF
  const dodger: ColorValue | undefined = ColorValue.tryParse('#1E90FFFF');
  check('8 位颜色可解析', dodger !== undefined);
  if (dodger !== undefined) {
    checkNum('透明度在末尾：a', dodger.a, 255);
    checkNum('透明度在末尾：r', dodger.r, 0x1e);
    checkNum('透明度在末尾：g', dodger.g, 0x90);
    checkNum('透明度在末尾：b', dodger.b, 0xff);
    checkEqual('落盘字面量大写', dodger.toString(), '#1E90FFFF');
    // ArkUI 的 '#AARRGGBB' 把透明度放开头，两者不是同一个字符串
    checkEqual('ArkUI 字面量透明度在开头', dodger.toArkUi(), '#FF1E90FF');
  }

  // 半透明红 #80FF0000：前两位是 R，末两位才是 A
  const halfRed: ColorValue | undefined = ColorValue.tryParse('#80FF0000');
  check('半透明红可解析', halfRed !== undefined);
  if (halfRed !== undefined) {
    checkNum('半透明红 a', halfRed.a, 0x00);
    checkNum('半透明红 r', halfRed.r, 0x80);
    checkNum('半透明红 g', halfRed.g, 0xff);
    checkNum('半透明红 b', halfRed.b, 0x00);
    checkEqual('半透明红往返', halfRed.toString(), '#80FF0000');
  }

  // #10203040：全不透明的深蓝灰
  const slate: ColorValue | undefined = ColorValue.tryParse('#10203040');
  check('深色不透明可解析', slate !== undefined);
  if (slate !== undefined) {
    checkNum('深色 a', slate.a, 0x40);
    checkNum('深色 r', slate.r, 0x10);
    checkNum('深色 g', slate.g, 0x20);
    checkNum('深色 b', slate.b, 0x30);
  }

  const short6: ColorValue | undefined = ColorValue.tryParse('#1E90FF');
  checkTrue('6 位颜色补不透明', short6 !== undefined && short6.a === 255);
  checkTrue('6 位颜色的 rgb 正确', short6 !== undefined && short6.r === 0x1e);

  checkTrue('小写可解析', ColorValue.tryParse('#1e90ffff')?.r === 0x1e);
  checkTrue('无 # 前缀可解析', ColorValue.tryParse('1E90FFFF')?.g === 0x90);
  check('4 位缩写不算数', ColorValue.tryParse('#1E9F') === undefined);
  check('非十六进制按位读 0', ColorValue.tryParse('#ZZ90FFFF')?.r === 0);
  check('空串读不出来', ColorValue.tryParse('') === undefined);

  checkEqual('白', ColorValue.white().toString(), '#FFFFFFFF');
  checkEqual('黑', ColorValue.black().toString(), '#000000FF');
  checkEqual('红', ColorValue.red().toString(), '#FF0000FF');
  checkEqual('全透明', ColorValue.transparent().toString(), '#00000000');
  checkTrue('颜色相等判断', ColorValue.red().equals(ColorValue.red()));
  check('颜色不等判断', !ColorValue.red().equals(ColorValue.white()));
  check('与 undefined 不等', !ColorValue.red().equals(undefined));

  // 字段存在但字面量损坏 -> 桌面版的 `?? default` = 全透明黑，而不是默认色。
  // 换成「好看的回退色」反而会让「颜色写坏了」在界面上完全看不出来。
  const brokenNode: JsonObject = new JsonObject();
  brokenNode.set('ForegroundColor', new JsonString('#这不是颜色'));
  checkEqual('字面量损坏走全透明',
    ComponentSettings.fromJson(brokenNode).foregroundColor.toString(), '#00000000');
  // 字段整个缺失 -> 走字段声明里的默认值
  checkEqual('字段缺失走默认值',
    ComponentSettings.fromJson(new JsonObject()).foregroundColor.toString(), '#1E90FFFF');
}

// ---------------------------------------------------------------- 3. 注册表

function testCatalog(): void {
  checkNum('内置组件 11 个', ComponentCatalog.all().length, 11);

  const guids: string[] = [
    COMPONENT_CLOCK, COMPONENT_COUNTDOWN, COMPONENT_DATE, COMPONENT_GROUP,
    COMPONENT_ROLLING, COMPONENT_SCHEDULE, COMPONENT_SEPARATOR, COMPONENT_SLIDE,
    COMPONENT_STACK, COMPONENT_TEXT, COMPONENT_WEATHER
  ];
  for (const guid of guids) {
    checkTrue(`GUID ${guid} 已注册`, ComponentCatalog.isKnown(guid));
  }

  // GUID 一个都不能错：改了等于让用户在桌面版排好的面板全部变成「未识别组件」
  checkEqual('时钟 GUID', COMPONENT_CLOCK, '9e1af71d-8f77-4b21-a342-448787104dd9');
  checkEqual('倒计时 GUID', COMPONENT_COUNTDOWN, '7c645d35-8151-48ba-b4ac-15017460d994');
  checkEqual('日期 GUID', COMPONENT_DATE, 'df3f8295-21f6-482e-bada-fa0e5f14bb66');
  checkEqual('分组容器 GUID', COMPONENT_GROUP, 'c911d762-107f-40c6-84cc-0146ab3c86b1');
  checkEqual('滚动容器 GUID', COMPONENT_ROLLING, '70fcd5ea-3fae-4e06-aca2-4f4df47f9acd');
  checkEqual('课程表 GUID', COMPONENT_SCHEDULE, '1db2017d-e374-4bc6-9d57-0b4adf03a6b8');
  checkEqual('分割线 GUID', COMPONENT_SEPARATOR, 'ab0f26d5-9df6-4575-b844-73b04d0907c1');
  checkEqual('轮播容器 GUID', COMPONENT_SLIDE, '7e19a113-d281-4f33-970a-834a0b78b5ad');
  checkEqual('堆叠容器 GUID', COMPONENT_STACK, '2d849ece-9f21-4c78-9434-415cfc283294');
  checkEqual('文本 GUID', COMPONENT_TEXT, 'ee8f66bd-c423-4e7c-ab46-aa9976b00e08');
  checkEqual('天气简报 GUID', COMPONENT_WEATHER, 'ca495086-e297-4beb-9603-c5c1c1a8551e');

  // 文件里不该有大写，但查表不该因此失败（桌面版 Id setter 会 ToLower）
  checkTrue('大写 GUID 也能查到', ComponentCatalog.isKnown(COMPONENT_CLOCK.toUpperCase()));

  checkTrue('分组容器是容器', ComponentCatalog.find(COMPONENT_GROUP)?.isContainer === true);
  checkTrue('滚动容器是容器', ComponentCatalog.find(COMPONENT_ROLLING)?.isContainer === true);
  checkTrue('轮播容器是容器', ComponentCatalog.find(COMPONENT_SLIDE)?.isContainer === true);
  checkTrue('堆叠容器是容器', ComponentCatalog.find(COMPONENT_STACK)?.isContainer === true);
  checkTrue('文本不是容器', ComponentCatalog.find(COMPONENT_TEXT)?.isContainer === false);
  checkTrue('课程表不是容器', ComponentCatalog.find(COMPONENT_SCHEDULE)?.isContainer === false);

  checkTrue('日期组件无设置对象', ComponentCatalog.find(COMPONENT_DATE)?.hasSettings === false);
  checkTrue('分割线组件无设置对象', ComponentCatalog.find(COMPONENT_SEPARATOR)?.hasSettings === false);
  checkTrue('文本组件有设置对象', ComponentCatalog.find(COMPONENT_TEXT)?.hasSettings === true);
  checkTrue('分组容器有设置对象', ComponentCatalog.find(COMPONENT_GROUP)?.hasSettings === true);

  // 显示名三级退化，从不返回空串：界面上一个空名字会占掉一整行，
  // 用户看不出那里本来有个组件
  const known: ComponentSettings = new ComponentSettings();
  known.id = COMPONENT_CLOCK;
  checkEqual('已知组件用注册名', ComponentCatalog.displayNameOf(known), '时钟');
  const cached: ComponentSettings = new ComponentSettings();
  cached.id = 'aaaaaaaa-1111-2222-3333-444444444444';
  cached.nameCache = '旧版名字';
  checkEqual('未知组件退回 NameCache', ComponentCatalog.displayNameOf(cached), '旧版名字');
  const bare: ComponentSettings = new ComponentSettings();
  bare.id = 'abcdef0123456789';
  checkEqual('两者皆无退回 GUID 前 8 位', ComponentCatalog.displayNameOf(bare), 'abcdef01');
  const shortId: ComponentSettings = new ComponentSettings();
  shortId.id = 'abc';
  checkEqual('GUID 短于 8 位时用占位名', ComponentCatalog.displayNameOf(shortId), '未识别组件');
  const none: ComponentSettings = new ComponentSettings();
  checkTrue('全空时不返回空串', ComponentCatalog.displayNameOf(none).length > 0);
}

/** 重复 GUID 必须抛错：覆盖的后果是同一 GUID 在不同模块解析出不同实现。 */
function testRegisterConflict(): void {
  let threw: boolean = false;
  try {
    ComponentCatalog.register(ComponentDescriptor.create(COMPONENT_CLOCK, '假的时钟', '',
      false, false, (): ComponentPayload => new ComponentPayload()));
  } catch (error) {
    threw = true;
  }
  checkTrue('重复 GUID 注册抛错', threw);
  checkEqual('抛错后注册表未被污染', ComponentCatalog.find(COMPONENT_CLOCK)?.name, '时钟');
  checkNum('抛错后总数不变', ComponentCatalog.all().length, 11);
}

// ---------------------------------------------------------------- 4. 新建组件

function testCreate(): void {
  // 有设置对象的：补一份默认实例（对齐桌面版 ButtonAddComponentToTargetList_OnClick）
  const clock: ComponentSettings = ComponentCatalog.create(COMPONENT_CLOCK);
  checkEqual('新建时钟的 Id', clock.id, COMPONENT_CLOCK);
  const clockNode: JsonObject = nodeOf(clock);
  checkTrue('新建时钟补出默认设置', clockNode.tryGet('ShowSeconds') !== undefined);
  checkTrue('新建时钟 ShowSeconds 默认为假', !ModelCodec.bool(clockNode, 'ShowSeconds', true));
  checkTrue('新建时钟 FlashTimeSeparator 默认为真',
    ModelCodec.bool(clockNode, 'FlashTimeSeparator', false));
  checkEqual('新建时钟的键序', keysOf(clockNode).join(','),
    'ShowSeconds,ShowRealTime,FlashTimeSeparator');

  // 容器：Children 排在最前，与 C# 字段声明顺序一致
  const rolling: ComponentSettings = ComponentCatalog.create(COMPONENT_ROLLING);
  const rollingNode: JsonObject = nodeOf(rolling);
  checkEqual('容器 Children 打头', keysOf(rollingNode)[0], 'Children');
  checkNum('新建滚动容器 SpeedPixelPerSecond',
    ModelCodec.number(rollingNode, 'SpeedPixelPerSecond', 0), 40);
  checkNum('新建滚动容器 PauseSeconds', ModelCodec.number(rollingNode, 'PauseSeconds', 0), 10);

  // 无设置对象的：Settings 留 null，与桌面版 LoadComponentSettings 的提前返回一致
  check('新建日期组件 Settings 仍为 null', ComponentCatalog.create(COMPONENT_DATE).settings === undefined);
  check('新建分割线组件 Settings 仍为 null',
    ComponentCatalog.create(COMPONENT_SEPARATOR).settings === undefined);
  check('新建未知组件 Settings 为 null',
    ComponentCatalog.create('d1e2f3a4-b5c6-4d7e-8f90-a1b2c3d4e5f6').settings === undefined);

  // Id 一律归一为小写
  checkEqual('大写 GUID 新建后归一',
    ComponentCatalog.create(COMPONENT_TEXT.toUpperCase()).id, COMPONENT_TEXT);
  checkEqual('新建时钟的 NameCache 是组件名', clock.nameCache, '时钟');
}

// ---------------------------------------------------------------- 5. 设置就地改键

/**
 * 核心保真断言：改一个已知字段，别的一动都不动。
 *
 * 若 encode 改成「新建对象再序列化」，这条会同时在「未知字段丢失」与
 * 「字段顺序被重排」两处失败。两者都是装机后才暴露的问题：设置悄悄回到默认，
 * 或者文件每次保存都被整体重写。
 */
function testInPlaceEncode(): void {
  const profile: ComponentProfile = ComponentProfile.parse(fixture('component-layout.json'));

  // 5.1 文本组件：改 FontSize，保留别人塞进来的额外键
  const group: ComponentSettings = profile.lines[0].children[1];
  // childrenOf 给的是副本，往里加键之后必须 setChildrenOf 写回
  const groupChildren: ComponentSettings[] = ComponentCatalog.childrenOf(group);
  const textNode: JsonObject = nodeOf(groupChildren[1]);
  textNode.set('PluginExtra', new JsonString('x'));
  ComponentCatalog.setChildrenOf(group, groupChildren);
  const textKeysBefore: string = keysOf(nodeOf(ComponentCatalog.childrenOf(group)[1])).join(',');
  const payload: TextPayload = ComponentCatalog.decodeChild(group, 1) as TextPayload;
  check('文本 decode 出强类型视图', payload instanceof TextPayload);
  checkNum('文本 FontSize 读到 24', payload.fontSize, 24);
  checkEqual('文本内容读到', payload.textContent, '距高考还有 100 天');
  checkEqual('文本 FontColor 读到', payload.fontColor.toString(), '#FFFFFFFF');
  checkTrue('文本 UseCustomFontColor 读到', payload.useCustomFontColor);
  payload.fontSize = 32;
  checkTrue('encodeChild 写回成功', ComponentCatalog.encodeChild(group, 1, payload));

  const textNodeAfter: JsonObject = nodeOf(ComponentCatalog.childrenOf(group)[1]);
  checkNum('FontSize 已改', ModelCodec.int(textNodeAfter, 'FontSize', 0), 32);
  checkEqual('未知键 PluginExtra 还在',
    ModelCodec.string(textNodeAfter, 'PluginExtra', ''), 'x');
  checkEqual('字段顺序完全未变', keysOf(textNodeAfter).join(','), textKeysBefore);
  // encodeChild 的存在意义：直接 encode 一个 childrenOf 出来的副本是无效操作
  const stale: TextPayload = ComponentCatalog.decode(ComponentCatalog.childrenOf(group)[1]) as TextPayload;
  stale.fontSize = 99;
  ComponentCatalog.encode(ComponentCatalog.childrenOf(group)[1], stale);
  checkNum('encode 副本不生效（这正是 encodeChild 存在的原因）',
    ModelCodec.int(nodeOf(ComponentCatalog.childrenOf(group)[1]), 'FontSize', 0), 32);

  // 5.2 倒计时：只建模 12 个字段，另外 13 个必须原样留着。
  // 比对方式是把「旧值」和「新值」都遮罩掉再比 —— 直接替换字面量不行，
  // JsonWriter 会把非 ASCII 转义成 \uXXXX，替换串得跟着一起转义。
  const slide: ComponentSettings = profile.lines[2].children[0];
  const before: string = JsonWriter.writeCompact(nodeOf(ComponentCatalog.childrenOf(slide)[0]));
  const cdPayload: CountDownPayload = ComponentCatalog.decodeChild(slide, 0) as CountDownPayload;
  check('倒计时 decode 出强类型视图', cdPayload instanceof CountDownPayload);
  checkEqual('倒计时名称', cdPayload.countDownName, '期末');
  checkEqual('倒计时终点', cdPayload.overTime.toDateString(), '2027-01-15');
  checkEqual('倒计时起点', cdPayload.startTime.toDateString(), '2026-09-01');
  checkNum('倒计时字号', cdPayload.fontSize, 20);
  checkEqual('倒计时颜色', cdPayload.fontColor.toString(), '#FF0000FF');
  checkEqual('倒计时连接词读到', cdPayload.countDownConnector, '还有');
  checkTrue('倒计时显示进度', cdPayload.showProgress);
  checkTrue('倒计时连接词强调读到', cdPayload.isConnectorColorEmphasized);
  checkTrue('倒计时进度不反转读到', !cdPayload.isProgressInverted);
  checkEqual('倒计时格式串', cdPayload.customStringFormat, '%D天');
  cdPayload.countDownConnector = '仅剩';
  ComponentCatalog.encodeChild(slide, 0, cdPayload);
  const afterNode: JsonObject = JsonValue.asObject(JsonReader.parse(
    JsonWriter.writeCompact(nodeOf(ComponentCatalog.childrenOf(slide)[0])))) ?? new JsonObject();
  const beforeNode: JsonObject = JsonValue.asObject(JsonReader.parse(before)) ?? new JsonObject();
  // 逐键比对而不是整串比对：JsonWriter 会把非 ASCII 转义成 \uXXXX，
  // 整串替换掉连接词这件事做不到（替换串本身得先转义），而逐键比就是准的。
  const changed: string[] = [];
  for (const member of beforeNode.entries()) {
    const other: JsonNode | undefined = afterNode.tryGet(member.name);
    if (other === undefined ||
      JsonWriter.writeCompact(member.value) !== JsonWriter.writeCompact(other)) {
      changed.push(member.name);
    }
  }
  checkEqual('改一个键后只有那一个键变了', changed.join(','), 'CountDownConnector');
  checkEqual('键的个数没变', String(afterNode.count), String(beforeNode.count));

  // 5.3 时钟：三个字段都该被读到
  const clockPayload: ClockPayload = ComponentCatalog.decodeChild(group, 0) as ClockPayload;
  check('时钟 decode 出强类型视图', clockPayload instanceof ClockPayload);
  checkTrue('时钟显示秒', clockPayload.showSeconds);
  checkTrue('时钟秒分隔符闪烁', clockPayload.flashTimeSeparator);
  checkTrue('时钟不显示秒级时间', !clockPayload.showRealTime);
  checkTrue('encodeChild 越界被拒', !ComponentCatalog.encodeChild(group, 9, new ComponentPayload()));
  checkTrue('decodeChild 越界给空 payload',
    ComponentCatalog.decodeChild(group, 9) instanceof ComponentPayload);

  // 5.4 容器：改子组件列表不影响容器自己的设置
  const rolling: ComponentSettings = profile.lines[1].children[2];
  const rollingNode: JsonObject = nodeOf(rolling);
  checkNum('滚动容器速度读到 25.5', ModelCodec.number(rollingNode, 'SpeedPixelPerSecond', 0), 25.5);
  checkNum('滚动容器子组件数', ComponentCatalog.childrenOf(rolling).length, 1);
  // 规则字段属于 P8，我们不该碰过
  checkTrue('规则字段 PauseOnRule 未被我们碰过',
    rollingNode.tryGet('PauseOnRule') !== undefined);
  checkTrue('规则字段 PauseRule 未被我们碰过', rollingNode.tryGet('PauseRule') !== undefined);
  checkTrue('规则字段 StopOnRule 未被我们碰过',
    rollingNode.tryGet('StopOnRule') !== undefined);
  checkTrue('规则字段 StopRule 未被我们碰过', rollingNode.tryGet('StopRule') !== undefined);
  const rollingKeys: string = keysOf(rollingNode).join(',');
  ComponentCatalog.setChildrenOf(rolling, []);
  checkNum('子组件清空后容器还在', ComponentCatalog.childrenOf(rolling).length, 0);
  checkNum('清空子组件不动容器速度',
    ModelCodec.number(nodeOf(rolling), 'SpeedPixelPerSecond', 0), 25.5);
  checkEqual('清空子组件后键序不变', keysOf(nodeOf(rolling)).join(','), rollingKeys);

  // 5.5 Settings 为 null 的组件：decode 出默认值，encode 时才建节点
  const date: ComponentSettings = profile.lines[0].children[0];
  check('日期组件 decode 仍是空 payload', ComponentCatalog.decode(date) instanceof ComponentPayload);
  ComponentCatalog.encode(date, new ComponentPayload());
  check('encode 空 payload 不建节点', date.settings === undefined);
  const separator: ComponentSettings = profile.lines[1].children[1];
  ComponentCatalog.encode(separator, new ComponentPayload());
  check('分割线 encode 不建节点', separator.settings === undefined);

  // 5.6 未注册的组件：encode 什么都不做，绝不覆盖它的 Settings
  const plugin: ComponentSettings = profile.lines[2].children[2];
  const pluginJson: string = JsonWriter.writeCompact(nodeOf(plugin));
  ComponentCatalog.encode(plugin, new ComponentPayload());
  checkEqual('未注册组件的 Settings 未被动过',
    JsonWriter.writeCompact(nodeOf(plugin)), pluginJson);
  checkNum('未注册组件没有子组件', ComponentCatalog.childrenOf(plugin).length, 0);
  ComponentCatalog.setChildrenOf(plugin, [ComponentCatalog.create(COMPONENT_TEXT)]);
  checkEqual('未注册组件加子组件无效',
    JsonWriter.writeCompact(nodeOf(plugin)), pluginJson);
  check('未注册组件 decode 出空 payload',
    ComponentCatalog.decode(plugin) instanceof ComponentPayload);

  // 5.7 Settings 为 null 但组件有设置对象：encode 时才建节点，且带全默认值
  const bare: ComponentSettings = new ComponentSettings();
  bare.id = COMPONENT_TEXT;
  const barePayload: TextPayload = ComponentCatalog.decode(bare) as TextPayload;
  checkNum('Settings 为 null 时 decode 出默认值', barePayload.fontSize, 16);
  barePayload.textContent = 'hi';
  ComponentCatalog.encode(bare, barePayload);
  checkEqual('encode 时才建节点', ModelCodec.string(nodeOf(bare), 'TextContent', ''), 'hi');
  checkEqual('建出来的键序与 C# 一致', keysOf(nodeOf(bare)).join(','),
    'TextContent,FontSize,FontColor,UseCustomFontColor');
}

/** 改设置 → 序列化 → 重新解析 → 改回原值，必须逐字节等于原文件。 */
function testEncodeThenRoundTrip(): void {
  const original: string = ComponentProfile.stringify(
    ComponentProfile.parse(fixture('component-layout.json')));
  const profile: ComponentProfile = ComponentProfile.parse(original);
  const group: ComponentSettings = profile.lines[0].children[1];
  const payload: TextPayload = ComponentCatalog.decodeChild(group, 1) as TextPayload;
  payload.fontSize = 32;
  payload.textContent = '改了';
  ComponentCatalog.encodeChild(group, 1, payload);

  const once: string = ComponentProfile.stringify(profile);
  check('改动确实落盘', once !== original);
  checkEqual('改过设置后往返稳定',
    ComponentProfile.stringify(ComponentProfile.parse(once)), once);

  // 改回原值必须逐字节等于原文件 —— 这是「就地改键」最硬的判据
  const restored: ComponentProfile = ComponentProfile.parse(once);
  const restoredGroup: ComponentSettings = restored.lines[0].children[1];
  const restoredPayload: TextPayload =
    ComponentCatalog.decodeChild(restoredGroup, 1) as TextPayload;
  restoredPayload.fontSize = 24;
  restoredPayload.textContent = '距高考还有 100 天';
  ComponentCatalog.encodeChild(restoredGroup, 1, restoredPayload);
  checkEqual('改回原值后与原文件逐字节相同', ComponentProfile.stringify(restored), original);
}

/** 默认布局：与桌面版 DefaultComponentProfile 一致。 */
function testDefaultProfile(): void {
  const profile: ComponentProfile = ComponentProfile.defaultProfile();
  checkNum('默认布局单行', profile.lines.length, 1);
  checkNum('默认布局两个组件', profile.lines[0].children.length, 2);
  checkEqual('默认布局第一个是日期', profile.lines[0].children[0].id, COMPONENT_DATE);
  checkEqual('默认布局第二个是课程表', profile.lines[0].children[1].id, COMPONENT_SCHEDULE);
  // 桌面版 DefaultComponentProfile 只赋了 Id，Settings 保持 null
  check('默认布局日期组件 Settings 为 null', profile.lines[0].children[0].settings === undefined);
  check('默认布局课程表 Settings 为 null', profile.lines[0].children[1].settings === undefined);
  const once: string = ComponentProfile.stringify(profile);
  checkEqual('默认布局往返稳定', ComponentProfile.stringify(ComponentProfile.parse(once)), once);
  check('默认布局 Date 组件名被填上',
    ComponentCatalog.displayNameOf(profile.lines[0].children[0]) === '日期');
}

// ---------------------------------------------------------------- 6. 行的增删移

function testLineMutations(): void {
  const profile: ComponentProfile = ComponentProfile.defaultProfile();
  checkNum('初始 1 行', profile.lines.length, 1);

  checkTrue('在开头插行', ComponentLayoutMutations.addLine(profile, 0));
  checkNum('插行后 2 行', profile.lines.length, 2);
  checkTrue('末尾追加行', ComponentLayoutMutations.addLine(profile, 2));
  checkNum('追加后 3 行', profile.lines.length, 3);
  checkTrue('超界插行被拒', !ComponentLayoutMutations.addLine(profile, 9));
  checkTrue('负下标插行被拒', !ComponentLayoutMutations.addLine(profile, -1));
  checkNum('被拒后行数不变', profile.lines.length, 3);

  // 删行：空行也要能删
  checkTrue('删中间行', ComponentLayoutMutations.removeLine(profile, 1));
  checkNum('删后 2 行', profile.lines.length, 2);
  checkTrue('删越界行被拒', !ComponentLayoutMutations.removeLine(profile, 5));
  checkTrue('删负下标行被拒', !ComponentLayoutMutations.removeLine(profile, -1));
  checkNum('被拒后行数不变', profile.lines.length, 2);

  // 移行。moveLine 的 to 是「移动后所在的下标」，所以往后移要 +1 抵消取出动作
  const markerA: ComponentSettings = ComponentCatalog.create(COMPONENT_TEXT);
  const markerB: ComponentSettings = ComponentCatalog.create(COMPONENT_SEPARATOR);
  profile.lines[0].children = [markerA];
  profile.lines[1].children = [markerB];
  checkTrue('把第 0 行往后移', ComponentLayoutMutations.moveLine(profile, 0, 2));
  checkTrue('后移后 B 在前', profile.lines[0].children[0] === markerB);
  checkTrue('后移后 A 在后', profile.lines[1].children[0] === markerA);
  checkTrue('把末行移到首位', ComponentLayoutMutations.moveLine(profile, 1, 0));
  checkTrue('回到原序', profile.lines[0].children[0] === markerA);
  checkTrue('原地不动也成功', ComponentLayoutMutations.moveLine(profile, 0, 1));
  checkTrue('原地不动后仍是 A', profile.lines[0].children[0] === markerA);
  checkTrue('移行源越界被拒', !ComponentLayoutMutations.moveLine(profile, 5, 0));
  checkTrue('移行目标越界被拒', !ComponentLayoutMutations.moveLine(profile, 0, 9));
  checkTrue('移行负下标被拒', !ComponentLayoutMutations.moveLine(profile, -1, 0));
}

// ---------------------------------------------------------------- 7. 组件的增删移

/**
 * 顺着 path 走到底，返回最后落到的那个组件。
 *
 * 空 path 返回 undefined —— 空 path 指的是「行本身」这一层，不是某个组件。
 * 要取行的直接子列表请直接用 profile.lines[i].children。
 */
function nodeAt(profile: ComponentProfile, location: ComponentLocation): ComponentSettings | undefined {
  if (location.lineIndex < 0 || location.lineIndex >= profile.lines.length ||
    location.path.length === 0) {
    return undefined;
  }
  let list: ComponentSettings[] = profile.lines[location.lineIndex].children;
  let node: ComponentSettings | undefined = undefined;
  for (const index of location.path) {
    node = list[index];
    if (node === undefined) {
      return undefined;
    }
    list = ComponentCatalog.childrenOf(node);
  }
  return node;
}

/** 数 path 指向的那个容器里有几个子组件。路径无效或不是容器返回 -1。 */
function countIn(profile: ComponentProfile, location: ComponentLocation): number {
  if (location.lineIndex < 0 || location.lineIndex >= profile.lines.length) {
    return -1;
  }
  if (location.path.length === 0) {
    return profile.lines[location.lineIndex].children.length;
  }
  const node: ComponentSettings | undefined = nodeAt(profile, location);
  if (node === undefined) {
    return -1;
  }
  const descriptor: ComponentDescriptor | undefined = ComponentCatalog.find(node.id);
  if (descriptor === undefined || !descriptor.isContainer) {
    return -1;
  }
  return ComponentCatalog.childrenOf(node).length;
}

function testAddRemove(): void {
  const profile: ComponentProfile = ComponentProfile.defaultProfile();
  const text: ComponentSettings = ComponentCatalog.create(COMPONENT_TEXT);

  checkTrue('加到行的直接子列表', ComponentLayoutMutations.addComponent(profile,
    ComponentLocation.of(0, []), text));
  checkNum('行里 3 个组件', profile.lines[0].children.length, 3);

  // 加到嵌套容器：写回必须生效，否则界面上「点了没反应」
  const group: ComponentSettings = ComponentCatalog.create(COMPONENT_GROUP);
  checkTrue('加一个分组容器', ComponentLayoutMutations.addComponent(profile,
    ComponentLocation.of(0, []), group));
  // 默认布局 2 项 + text + group = 4 项，group 在下标 3
  checkNum('加完 4 个', profile.lines[0].children.length, 4);
  checkTrue('加到分组容器里', ComponentLayoutMutations.addComponent(profile,
    ComponentLocation.of(0, [3]), text));
  checkNum('分组容器里 1 个子组件', ComponentCatalog.childrenOf(group).length, 1);
  // 注意比的是内容不是引用：childrenOf 每次都从裸节点重新解析，写回之后
  // 拿到的必然是新的对象。靠对象引用追踪某个组件是走不通的。
  checkEqual('加进去的就是那个组件', ComponentCatalog.childrenOf(group)[0].id, text.id);
  checkTrue('行的直接子列表保持同一引用（行本身就是活数组）',
    profile.lines[0].children[3] === group);

  // 往非容器里加 —— 必须被拒。静默加到行首的话，用户以为组件进了容器，
  // 结果它出现在行的最前面，而行里原本就有别的组件，位置完全对不上
  checkTrue('往非容器加组件被拒', !ComponentLayoutMutations.addComponent(profile,
    ComponentLocation.of(0, [0]), ComponentCatalog.create(COMPONENT_TEXT)));
  checkNum('被拒后行里仍是 4 个', profile.lines[0].children.length, 4);
  checkTrue('往越界行加组件被拒', !ComponentLayoutMutations.addComponent(profile,
    ComponentLocation.of(7, []), ComponentCatalog.create(COMPONENT_TEXT)));
  checkTrue('往越界的容器路径加组件被拒', !ComponentLayoutMutations.addComponent(profile,
    ComponentLocation.of(0, [99]), ComponentCatalog.create(COMPONENT_TEXT)));

  // 删
  checkTrue('删掉嵌套里的组件', ComponentLayoutMutations.removeComponent(profile,
    ComponentLocation.of(0, [3, 0])));
  checkNum('分组容器空了', ComponentCatalog.childrenOf(group).length, 0);
  checkTrue('空容器还在行里', profile.lines[0].children[3] === group);
  checkTrue('删越界组件被拒', !ComponentLayoutMutations.removeComponent(profile,
    ComponentLocation.of(0, [3, 5])));
  checkTrue('删行本身被拒', !ComponentLayoutMutations.removeComponent(profile,
    ComponentLocation.of(0, [])));
  checkTrue('删不存在行的组件被拒', !ComponentLayoutMutations.removeComponent(profile,
    ComponentLocation.of(9, [0])));
  checkTrue('删行里的非容器被拒', !ComponentLayoutMutations.removeComponent(profile,
    ComponentLocation.of(0, [99])));
}

function testMove(): void {
  // 结构：行0 = [A, B]；A 是分组容器里有 [C, D]；B 是堆叠容器里是空的
  const profile: ComponentProfile = ComponentProfile.defaultProfile();
  const group: ComponentSettings = ComponentCatalog.create(COMPONENT_GROUP);
  const stack: ComponentSettings = ComponentCatalog.create(COMPONENT_STACK);
  ComponentCatalog.setChildrenOf(group, [
    ComponentCatalog.create(COMPONENT_CLOCK),
    ComponentCatalog.create(COMPONENT_TEXT)
  ]);
  ComponentCatalog.setChildrenOf(stack, []);
  profile.lines[0].children = [group, stack];

  // 同一列表内前移。insertIndex 是「移动后所在下标」，取出动作不需额外修正
  checkTrue('同一列表内前移', ComponentLayoutMutations.moveComponent(profile,
    ComponentLocation.at(0, 1), ComponentLocation.of(0, []), 0));
  checkTrue('行首变成了堆叠容器', profile.lines[0].children[0] === stack);
  checkTrue('分组容器挪到第二位', profile.lines[0].children[1] === group);

  // 嵌套 -> 顶层
  checkTrue('把嵌套组件提到行里', ComponentLayoutMutations.moveComponent(profile,
    ComponentLocation.at(0, 1, 0), ComponentLocation.of(0, []), 2));
  checkNum('行里 3 个组件', profile.lines[0].children.length, 3);
  checkNum('分组容器空了', ComponentCatalog.childrenOf(group).length, 1);
  // 搬出来的是时钟（不是文本）：分组的两个子项原本是 [时钟, 文本]，
  // 取的是 path 末位 0 那个
  checkEqual('时钟到了行末', profile.lines[0].children[2].id, COMPONENT_CLOCK);
  checkEqual('分组容器里剩下文本',
    ComponentCatalog.childrenOf(group)[0].id, COMPONENT_TEXT);

  // 顶层 -> 嵌套
  const clockId: string = profile.lines[0].children[2].id;
  checkTrue('把顶层组件塞进堆叠容器', ComponentLayoutMutations.moveComponent(profile,
    ComponentLocation.at(0, 2), ComponentLocation.at(0, 0), 0));
  checkNum('行里回到 2 个组件', profile.lines[0].children.length, 2);
  checkNum('堆叠容器里有 1 个', ComponentCatalog.childrenOf(stack).length, 1);
  checkEqual('搬过去的是同一个组件（按 Id 判）',
    ComponentCatalog.childrenOf(stack)[0].id, clockId);

  // 挡环。不挡的话渲染时无限递归，界面表现为面板卡死
  checkTrue('移进自己被拒', !ComponentLayoutMutations.moveComponent(profile,
    ComponentLocation.at(0, 0), ComponentLocation.at(0, 0), 0));
  checkTrue('移进自己的子孙被拒', !ComponentLayoutMutations.moveComponent(profile,
    ComponentLocation.at(0, 1), ComponentLocation.at(0, 1, 0), 0));
  checkNum('被拒后行里仍是 2 个', profile.lines[0].children.length, 2);
  checkNum('被拒后堆叠容器仍是 1 个', ComponentCatalog.childrenOf(stack).length, 1);

  // 同一容器内换位：取出再插回同一位置，净效果是不变
  const firstId: string = ComponentCatalog.childrenOf(stack)[0].id;
  checkTrue('同一容器内换位', ComponentLayoutMutations.moveComponent(profile,
    ComponentLocation.at(0, 0, 0), ComponentLocation.at(0, 0), 1));
  checkNum('堆叠容器里还是 1 个', ComponentCatalog.childrenOf(stack).length, 1);
  checkEqual('换位后还是同一个组件',
    ComponentCatalog.childrenOf(stack)[0].id, firstId);

  // insertIndex 超界夹到末尾，而不是失败 —— 拖到列表下面的空白处就是这个语义。
  // 搬的是行里的分组容器（此时行里是 [堆叠容器, 分组容器]）
  checkNum('搬之前行里 2 个', profile.lines[0].children.length, 2);
  checkTrue('越界 insertIndex 夹到末尾', ComponentLayoutMutations.moveComponent(profile,
    ComponentLocation.at(0, 1), ComponentLocation.at(0, 0), 99));
  checkNum('行里剩 1 个（只剩堆叠容器）', profile.lines[0].children.length, 1);
  checkTrue('剩下的就是堆叠容器', profile.lines[0].children[0].id === COMPONENT_STACK);
  checkNum('堆叠容器里有 2 个', ComponentCatalog.childrenOf(stack).length, 2);
  checkEqual('最后一个是搬过来的分组容器',
    ComponentCatalog.childrenOf(stack)[1].id, COMPONENT_GROUP);
  checkEqual('搬动保留内容（按 Id 判）',
    ComponentCatalog.childrenOf(stack)[0].id, firstId);

  // 各种非法参数
  checkTrue('负 insertIndex 被拒', !ComponentLayoutMutations.moveComponent(profile,
    ComponentLocation.at(0, 1), ComponentLocation.of(0, []), -1));
  checkTrue('移不存在的组件被拒', !ComponentLayoutMutations.moveComponent(profile,
    ComponentLocation.at(0, 9), ComponentLocation.of(0, []), 0));
  checkTrue('移到不存在的行被拒', !ComponentLayoutMutations.moveComponent(profile,
    ComponentLocation.at(0, 0), ComponentLocation.of(9, []), 0));
  checkTrue('移到不存在的容器被拒', !ComponentLayoutMutations.moveComponent(profile,
    ComponentLocation.at(0, 0), ComponentLocation.of(0, [9]), 0));
  checkTrue('把行本身当组件移被拒', !ComponentLayoutMutations.moveComponent(profile,
    ComponentLocation.of(0, []), ComponentLocation.of(0, []), 0));
  checkNum('一堆拒绝之后行里仍是 1 个', profile.lines[0].children.length, 1);
  checkNum('一堆拒绝之后堆叠容器仍是 2 个', ComponentCatalog.childrenOf(stack).length, 2);
  checkEqual('一堆拒绝之后堆叠容器的内容没变',
    ComponentCatalog.childrenOf(stack)[0].id, firstId);
}

/**
 * 移动失败必须让布局原样不变。
 *
 * 这条单独一组，因为它防的是一个「返回值说了失败、界面却丢了东西」的 bug：
 * 源里那个组件已经被取出来了，才发现目标不存在。早先的实现就是这样的，
 * 而且界面上根本看不出发生了什么 —— 面板里少了一个组件，没有任何报错。
 */
function testMoveFailureRollsBack(): void {
  // 目标在移动前根本不存在
  const profile: ComponentProfile = ComponentProfile.defaultProfile();
  const before: string = ComponentProfile.stringify(profile);
  checkTrue('目标不存在时移动失败', !ComponentLayoutMutations.moveComponent(profile,
    ComponentLocation.at(0, 0), ComponentLocation.of(0, [7]), 0));
  checkEqual('目标不存在时布局原样不变', ComponentProfile.stringify(profile), before);

  // 目标在移动前存在，移动后却挪没了：from 是第 0 个，to 指向第 1 个那个容器，
  // 取出第 0 个之后它挪到了下标 0，to 解析不到。这一步必须真的走到回滚分支 ——
  // 预检在移动前做，所以它是通过的；挂掉的是移动后的那一次解析。
  const outer: ComponentProfile = ComponentProfile.defaultProfile();
  const first: ComponentSettings = ComponentCatalog.create(COMPONENT_TEXT);
  const host: ComponentSettings = ComponentCatalog.create(COMPONENT_GROUP);
  ComponentCatalog.setChildrenOf(host, [ComponentCatalog.create(COMPONENT_CLOCK)]);
  outer.lines[0].children = [first, host];
  const outerBefore: string = ComponentProfile.stringify(outer);
  // 下面那条「布局原样不变」就是回滚真的跑过的证据：不回滚的话
  // 行里会少掉 first，序列化结果必然不同。
  checkTrue('目标在移动后消失时移动失败', !ComponentLayoutMutations.moveComponent(outer,
    ComponentLocation.at(0, 0), ComponentLocation.at(0, 1), 0));
  checkEqual('目标在移动后消失时布局原样不变',
    ComponentProfile.stringify(outer), outerBefore);
  checkNum('源组件还在行里', outer.lines[0].children.length, 2);
  checkTrue('源组件还是原来那个', outer.lines[0].children[0] === first);
  checkNum('目标容器还保持原样', ComponentCatalog.childrenOf(host).length, 1);

  // 反过来，搬到「源的前驱兄弟」里就没事：取出源不影响它前面的下标
  const sibling: ComponentProfile = ComponentProfile.defaultProfile();
  const keeper: ComponentSettings = ComponentCatalog.create(COMPONENT_GROUP);
  const moved: ComponentSettings = ComponentCatalog.create(COMPONENT_TEXT);
  ComponentCatalog.setChildrenOf(keeper, [ComponentCatalog.create(COMPONENT_CLOCK)]);
  sibling.lines[0].children = [keeper, moved];
  checkTrue('搬进前驱兄弟的容器成功', ComponentLayoutMutations.moveComponent(sibling,
    ComponentLocation.at(0, 1), ComponentLocation.at(0, 0), 0));
  checkNum('行里只剩容器', sibling.lines[0].children.length, 1);
  checkNum('容器里有 2 个', ComponentCatalog.childrenOf(keeper).length, 2);
  checkEqual('搬进去的排在最前', ComponentCatalog.childrenOf(keeper)[0].id, COMPONENT_TEXT);
  checkEqual('原来的子组件被挤到第二位',
    ComponentCatalog.childrenOf(keeper)[1].id, COMPONENT_CLOCK);
  checkEqual('搬完之后往返仍稳定', ComponentProfile.stringify(
    ComponentProfile.parse(ComponentProfile.stringify(sibling))),
  ComponentProfile.stringify(sibling));
}

function testSwap(): void {
  const profile: ComponentProfile = ComponentProfile.defaultProfile();
  const a: ComponentSettings = ComponentCatalog.create(COMPONENT_CLOCK);
  const b: ComponentSettings = ComponentCatalog.create(COMPONENT_TEXT);
  const c: ComponentSettings = ComponentCatalog.create(COMPONENT_SEPARATOR);
  profile.lines[0].children = [a, b, c];

  checkTrue('同层互换成功', ComponentLayoutMutations.swapSibling(profile, ComponentLocation.at(0, 0)));
  checkTrue('a 被换到第二位', profile.lines[0].children[1] === a);
  checkTrue('b 被换到首位', profile.lines[0].children[0] === b);
  checkTrue('末位没有下一个，互换失败',
    !ComponentLayoutMutations.swapSibling(profile, ComponentLocation.at(0, 2)));
  checkTrue('失败后末位不变', profile.lines[0].children[2] === c);
  checkTrue('行本身不能互换',
    !ComponentLayoutMutations.swapSibling(profile, ComponentLocation.of(0, [])));
  checkTrue('越界不能互换',
    !ComponentLayoutMutations.swapSibling(profile, ComponentLocation.at(0, 9)));
  checkTrue('不存在的行不能互换',
    !ComponentLayoutMutations.swapSibling(profile, ComponentLocation.at(6, 0)));
  checkNum('失败后行里仍是 3 个', profile.lines[0].children.length, 3);

  // 嵌套里的互换也要写回
  const group: ComponentSettings = ComponentCatalog.create(COMPONENT_GROUP);
  ComponentCatalog.setChildrenOf(group, [a, c]);
  profile.lines[0].children = [group];
  checkTrue('嵌套内互换', ComponentLayoutMutations.swapSibling(profile, ComponentLocation.at(0, 0, 0)));
  const after: ComponentSettings[] = ComponentCatalog.childrenOf(group);
  checkNum('嵌套里仍是 2 个', after.length, 2);
  checkEqual('嵌套内 a 换到了第二位', after[1].id, a.id);
  checkEqual('嵌套内 c 换到了首位', after[0].id, c.id);
  checkTrue('嵌套内末位互换失败',
    !ComponentLayoutMutations.swapSibling(profile, ComponentLocation.at(0, 0, 1)));
  checkEqual('失败的互换不改变顺序', ComponentCatalog.childrenOf(group)[0].id, c.id);
}

function testLocation(): void {
  const a: ComponentLocation = ComponentLocation.at(0, 1, 2);
  checkNum('at 拼出的 path 长度', a.path.length, 2);
  checkTrue('同位置相等', a.equals(ComponentLocation.at(0, 1, 2)));
  checkTrue('异行不等', !a.equals(ComponentLocation.at(1, 1, 2)));
  checkTrue('异层不等', !a.equals(ComponentLocation.at(0, 1)));
  checkTrue('首层不同不等', !a.equals(ComponentLocation.at(0, 9, 2)));
  checkTrue('与 undefined 不等', !a.equals(undefined));
  const source: number[] = [1, 2];
  const b: ComponentLocation = ComponentLocation.of(0, source);
  source.push(3);
  checkNum('of 复制了数组', b.path.length, 2);
  checkTrue('at 与 of 等价', ComponentLocation.at(0, 1, 2).equals(ComponentLocation.of(0, [1, 2])));
  checkNum('空 at 的 path 是空数组', ComponentLocation.at(3).path.length, 0);
  checkNum('at 的 lineIndex', ComponentLocation.at(3, 0).lineIndex, 3);
}

// ---------------------------------------------------------------- 8. 深层定位与落盘

function testDeepLayout(): void {
  const profile: ComponentProfile = ComponentProfile.parse(fixture('component-layout.json'));
  checkNum('行 0 里 3 个', countIn(profile, ComponentLocation.of(0, [])), 3);
  checkNum('分组容器里 2 个', countIn(profile, ComponentLocation.of(0, [1])), 2);
  checkEqual('分组容器第 0 个是时钟',
    nodeAt(profile, ComponentLocation.at(0, 1, 0))?.id ?? '', COMPONENT_CLOCK);
  checkEqual('分组容器第 1 个是文本',
    nodeAt(profile, ComponentLocation.at(0, 1, 1))?.id ?? '', COMPONENT_TEXT);
  checkNum('滚动容器里 1 个', countIn(profile, ComponentLocation.of(1, [2])), 1);
  checkNum('轮播容器里 1 个', countIn(profile, ComponentLocation.of(2, [0])), 1);
  checkEqual('倒计时在轮播容器里',
    nodeAt(profile, ComponentLocation.at(2, 0, 0))?.id ?? '', COMPONENT_COUNTDOWN);
  checkNum('堆叠容器是空的', countIn(profile, ComponentLocation.of(2, [1])), 0);
  checkNum('越界位置返回 -1', countIn(profile, ComponentLocation.of(0, [99])), -1);
  checkNum('越界行返回 -1', countIn(profile, ComponentLocation.of(6, [])), -1);
  checkNum('非容器的子级返回 -1', countIn(profile, ComponentLocation.of(0, [0])), -1);
  checkTrue('越界节点返回 undefined', nodeAt(profile, ComponentLocation.at(0, 99)) === undefined);
  checkTrue('越界行返回 undefined', nodeAt(profile, ComponentLocation.at(6, 0)) === undefined);
  checkTrue('非容器的子级定位失败', nodeAt(profile, ComponentLocation.at(0, 0, 0)) === undefined);
  checkTrue('空 path 取不到组件', nodeAt(profile, ComponentLocation.of(0, [])) === undefined);

  // 深层删除后必须落盘：只改内存里那份副本是最典型的「点了没反应」
  checkTrue('删掉轮播容器里的倒计时', ComponentLayoutMutations.removeComponent(profile,
    ComponentLocation.at(2, 0, 0)));
  const reparsed: ComponentProfile = ComponentProfile.parse(ComponentProfile.stringify(profile));
  checkNum('删除已落盘', ComponentCatalog.childrenOf(reparsed.lines[2].children[0]).length, 0);
  checkNum('别处不受影响：行 0 仍是 3 个', reparsed.lines[0].children.length, 3);
  checkNum('别处不受影响：分组容器里仍是 2 个',
    ComponentCatalog.childrenOf(reparsed.lines[0].children[1]).length, 2);
  // 删的是子组件，容器自己的设置不能跟着没
  checkEqual('别处不受影响：轮播容器的切换间隔还在',
    ModelCodec.number(nodeOf(reparsed.lines[2].children[0]), 'SlideSeconds', 0), 15);
  checkEqual('别处不受影响：行 2 的堆叠容器还在',
    reparsed.lines[2].children[1].id, COMPONENT_STACK);
}

/** 深拷贝：两个实例之间互不可见。 */
function testClone(): void {
  const profile: ComponentProfile = ComponentProfile.parse(fixture('component-layout.json'));
  const copy: ComponentProfile = ComponentProfile.parse(ComponentProfile.stringify(profile));
  const original: ComponentSettings = profile.lines[0].children[0];
  const cloned: ComponentSettings = copy.lines[0].children[0];
  cloned.nameCache = '改过了';
  checkEqual('改副本不动原件', original.nameCache, '');
  checkEqual('改原件不动副本', copy.lines[0].children[0].nameCache, '改过了');
  check('实例的 toJson 独立', ModelCodec.cloneNode(original.toJson()) !== original.toJson());
}

// ---------------------------------------------------------------- 入口

testGoldenLayout();
testFieldValues();
testColor();
testCatalog();
testRegisterConflict();
testCreate();
testInPlaceEncode();
testEncodeThenRoundTrip();
testDefaultProfile();
testLineMutations();
testAddRemove();
testMove();
testMoveFailureRollsBack();
testSwap();
testLocation();
testDeepLayout();
testClone();

console.log(`组件布局 通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('');
  for (const failure of failures) {
    console.log(`✗ ${failure}`);
  }
  process.exit(1);
}
