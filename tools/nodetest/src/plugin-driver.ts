/*
 * 声明式插件系统测试台（P12 core 层）。
 *
 * 这个阶段最容易坏的地方，按危险程度排：
 *
 *   1. **摘不干净**。扩展卸载后条目还留在注册表里 → 面板上留着一个既选不中也删不掉
 *      的组件，或者工作流里的触发器永远显示成「未知 id」。三处注册表各自持有条目，
 *      摘漏一处就留下悬空 id，而症状是「面板上少了个东西却不知道它去哪了」。
 *   2. **占用没挡住**。两个扩展用同一个 id，或者扩展用了内置组件的 GUID。挡住的话
 *      症状是「同一个组件时而正常时而空白」，日志里什么都没有。
 *   3. **日程判错**。dailyAt / everyMinutes 差一秒就是「每天触发」或「永远不触发」。
 *      轮询是每秒一次、比较整秒，所以判据必须是**相等**而不是「>=」——用 >= 的话
 *      那个秒之后每 tick 都触发。
 *   4. **沙箱失效**。声明式动作改了它不该改的设置键。声明式扩展的全部安全模型就是
 *      「只能改明确开放的键」，这道判据失效等于沙箱不存在。
 *   5. **模板占位符**。未知占位符必须原样保留。替换成空串的话作者会以为「这个占位符
 *      不支持」，去改成另一个也不支持的，永远找不到真正的原因。
 *   6. **版本闸**。跨主版本硬读会把用户配置写成另一种意思 —— 比拒绝加载糟糕得多。
 *
 * 另外测了往返保真（一份清单写出再读回来逐字不变）与「AutomationEngine 真的会
 * 调声明式触发器」这条端到端路径 —— 后者是 P11e 踩过的坑（类写了没人 new），
 * 所以必须由测试证明引擎那一帧真的走了声明式分支。
 */

import { ActionItem } from '../../common_shared/src/main/ets/models/Automation/ActionItem';
import { ActionSet } from '../../common_shared/src/main/ets/models/Automation/ActionSet';
import { ActionSetStatus } from '../../common_shared/src/main/ets/enums/ActionSetStatus';
import { ComponentSettings } from '../../common_shared/src/main/ets/models/ComponentProfile';
import { TriggerSettings } from
  '../../common_shared/src/main/ets/models/Automation/TriggerSettings';
import { Workflow } from '../../common_shared/src/main/ets/models/Automation/Workflow';
import { DateTimeValue } from '../../common_shared/src/main/ets/json/DateTimeValue';
import { JsonObject, JsonString } from '../../common_shared/src/main/ets/json/JsonNode';
import { JsonValue } from '../../common_shared/src/main/ets/json/JsonValue';
import { JsonWriter } from '../../common_shared/src/main/ets/json/JsonWriter';
import { ActionIds } from '../../common_shared/src/main/ets/models/Automation/Actions';
import { TriggerIds } from '../../common_shared/src/main/ets/models/Automation/Triggers';
import { TextPayload } from '../../common_core/src/main/ets/components/ComponentPayloads';

import {
  ActionCatalog,
  ActionSupport
} from '../../common_core/src/main/ets/automation/ActionCatalog';
import {
  AutomationEngine,
  AutomationReason,
  AutomationTick,
  AutomationTickResult
} from '../../common_core/src/main/ets/automation/AutomationEngine';
import {
  TriggerCatalog,
  TriggerSupport
} from '../../common_core/src/main/ets/automation/TriggerCatalog';
import { WorkflowMutations } from '../../common_core/src/main/ets/automation/WorkflowMutations';
import { ComponentCatalog } from '../../common_core/src/main/ets/components/ComponentCatalog';
import { ClockPayload } from '../../common_core/src/main/ets/components/ComponentPayloads';

import { ExtensionRegistry, PluginRecord } from
  '../../common_core/src/main/ets/plugins/ExtensionRegistry';
import { PluginInstallResult, installPlugin, uninstallPlugin, uninstallAllPlugins } from
  '../../common_core/src/main/ets/plugins/PluginInstaller';
import {
  ActionExtension,
  ActionExtensionCodec,
  ComponentExtension,
  ComponentExtensionCodec,
  ExtensionKind,
  ExtensionManifest,
  ExtensionManifestCodec,
  NotificationProviderExtension,
  NotificationProviderExtensionCodec,
  PluginActionKind,
  PluginScheduleKind,
  ThemeExtension,
  ThemeExtensionCodec,
  TriggerExtension,
  TriggerExtensionCodec
} from '../../common_core/src/main/ets/plugins/PluginManifest';
import {
  ApiCompatibility,
  PLUGIN_API_MIN_VERSION,
  PLUGIN_API_VERSION,
  SemVer,
  checkPluginApiVersion,
  isValidPluginId
} from '../../common_core/src/main/ets/plugins/PluginApi';
import {
  PluginIssue,
  PluginIssueCode,
  PluginIssueSeverity,
  PluginSandbox,
  blockingIssues,
  defaultPluginSandbox,
  hasBlockingIssues,
  isHexColor,
  summarizeIssues,
  validateManifest,
  validateManifestTextLength
} from '../../common_core/src/main/ets/plugins/PluginValidation';
import {
  PLUGIN_REASON_BAD_SETTINGS,
  PLUGIN_REASON_FIRED,
  PluginSchedule,
  PluginScheduleVerdict,
  evaluatePluginSchedule,
  formatSecondOfDay,
  parsePluginSchedule,
  scheduleSettingsProblem,
  scheduleText,
  settingsOfTriggerExtension
} from '../../common_core/src/main/ets/plugins/PluginSchedule';
import { PluginTriggerVerdict, judgePluginTrigger } from
  '../../common_core/src/main/ets/plugins/PluginTriggerEval';
import {
  PluginActionPlan,
  normalizeCategory,
  planPluginAction,
  settingsOfActionExtension
} from '../../common_core/src/main/ets/plugins/PluginActionEval';
import {
  PLUGIN_TEMPLATE_PLACEHOLDERS,
  TIME_STATE_LABELS,
  PluginTemplateContext,
  pluginTemplatePlaceholders,
  renderPluginTemplate,
  timeStateLabel,
  unresolvedPlaceholders
} from '../../common_core/src/main/ets/plugins/PluginTemplate';
import {
  DESKTOP_IMPORT_NOTE,
  DesktopPluginMeta,
  FALLBACK_DESKTOP_PLUGIN_ID,
  desktopImportNote,
  desktopPluginManifest,
  normalizeDesktopPluginId,
  parseDesktopPluginYaml
} from '../../common_core/src/main/ets/plugins/PluginPackage';
import { LessonsSnapshot } from '../../common_core/src/main/ets/engine/LessonsSnapshot';
import { TimeState } from '../../common_shared/src/main/ets/enums/TimeState';

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
  check(name, actual === expected, `实际「${actual}」，期望「${expected}」`);
}

function checkNum(name: string, actual: number, expected: number): void {
  check(name, actual === expected, `实际 ${actual}，期望 ${expected}`);
}

function checkBool(name: string, actual: boolean, expected: boolean): void {
  check(name, actual === expected, `实际 ${actual}，期望 ${expected}`);
}

// --------------------------------------------------------------- 夹具

const PLUGIN_GUID_A: string = 'a0000000-0000-0000-0000-000000000001';
const PLUGIN_GUID_B: string = 'b0000000-0000-0000-0000-000000000002';
const PLUGIN_GUID_C: string = 'c0000000-0000-0000-0000-000000000003';
const TRIGGER_ID: string = 'demo.trigger.morning';
const ACTION_ID: string = 'demo.action.notify';

function dt(text: string): DateTimeValue {
  return DateTimeValue.parseOrMin(text);
}

function component(id: string, name: string, payloadKind: string,
  settings?: JsonObject): ComponentExtension {
  const out: ComponentExtension = new ComponentExtension();
  out.id = id;
  out.name = name;
  out.description = `${name}的说明`;
  out.payloadKind = payloadKind;
  if (settings !== undefined) {
    out.settings = settings;
  }
  return out;
}

/** 键名照抄 TextPayload.applyTo —— 声明式组件的默认值必须真的能被解码器读出来。 */
function textSettings(text: string): JsonObject {
  const out: JsonObject = new JsonObject();
  out.set('TextContent', new JsonString(text));
  return out;
}

function dailyTrigger(id: string, hour: number, minute: number): TriggerExtension {
  const out: TriggerExtension = new TriggerExtension();
  out.id = id;
  out.name = `${hour} 点提醒`;
  out.scheduleKind = PluginScheduleKind.DailyAt;
  out.atSeconds = hour * 3600 + minute * 60;
  return out;
}

function notifyAction(id: string, title: string, content: string): ActionExtension {
  const out: ActionExtension = new ActionExtension();
  out.id = id;
  out.name = '发通知';
  out.actionKind = PluginActionKind.Notification;
  out.title = title;
  out.content = content;
  return out;
}

function theme(id: string, colors: Map<string, string>): ThemeExtension {
  const out: ThemeExtension = new ThemeExtension();
  out.id = id;
  out.name = '示例主题';
  out.mode = 'both';
  out.colors = colors;
  return out;
}

/** 一份能装的最小清单。 */
function goodManifest(id: string = 'demo.plugin'): ExtensionManifest {
  const out: ExtensionManifest = new ExtensionManifest();
  out.id = id;
  out.name = '示例扩展';
  out.version = '1.0.0';
  out.apiVersion = PLUGIN_API_VERSION;
  out.author = 'tester';
  out.description = '给测试台用';
  out.components.push(component(PLUGIN_GUID_A, '示例文本', 'text', textSettings('原神启动')));
  out.triggers.push(dailyTrigger(TRIGGER_ID, 7, 0));
  out.actions.push(notifyAction(ACTION_ID, '上课了', '{time} 该上课了'));
  return out;
}

function sandboxWith(keys: string[]): PluginSandbox {
  const out: PluginSandbox = defaultPluginSandbox();
  for (const key of keys) {
    out.writableSettingKeys.add(key);
  }
  return out;
}

function issueCodes(issues: PluginIssue[]): string[] {
  const out: string[] = [];
  for (const issue of issues) {
    out.push(issue.code);
  }
  return out;
}

function hasCode(issues: PluginIssue[], code: PluginIssueCode): boolean {
  return issueCodes(issues).indexOf(code) >= 0;
}

// =========================================================== A. 版本闸

function testSemVer(): void {
  const good: SemVer = SemVer.tryParse('1.2.3') as SemVer;
  checkNum('1.2.3 → major', good.major, 1);
  checkNum('1.2.3 → minor', good.minor, 2);
  checkNum('1.2.3 → patch', good.patch, 3);
  checkEqual('1.2.3 → toString', good.toString(), '1.2.3');

  // 手填的版本号：短版本、v 前缀、前导零
  const short: SemVer = SemVer.tryParse('1.0') as SemVer;
  checkNum('1.0 → patch 补 0', short.patch, 0);
  const prefixed: SemVer = SemVer.tryParse('v2.1.0') as SemVer;
  checkNum('v 前缀剥掉', prefixed.major, 2);
  const leadingZero: SemVer = SemVer.tryParse('01.02') as SemVer;
  checkNum('前导零容忍', leadingZero.minor, 2);

  check('空串解不出', SemVer.tryParse('') === undefined);
  check('纯空白解不出', SemVer.tryParse('   ') === undefined);
  check('四段解不出', SemVer.tryParse('1.2.3.4') === undefined);
  check('非数字解不出', SemVer.tryParse('1.x') === undefined);
  check('空段解不出', SemVer.tryParse('1..3') === undefined);
  check('下划线解不出', SemVer.tryParse('1_0') === undefined);

  // 预发布段：beta < 正式版
  const beta: SemVer = SemVer.tryParse('1.0.0-beta') as SemVer;
  const release: SemVer = SemVer.tryParse('1.0.0') as SemVer;
  check('beta 排在正式版之前', SemVer.compare(beta, release) < 0);
  check('正式版排在 beta 之后', SemVer.compare(release, beta) > 0);
  checkEqual('beta 的 toString 保留预发布段', beta.toString(), '1.0.0-beta');
  checkNum('beta 的主版本仍是 1', beta.major, 1);
  check('同版本相等', SemVer.compare(release, SemVer.tryParse('1.0.0') as SemVer) === 0);
  check('1.0.1 > 1.0.0', SemVer.compare(SemVer.tryParse('1.0.1') as SemVer, release) > 0);
  check('2.0.0 > 1.9.9', SemVer.compare(SemVer.tryParse('2.0.0') as SemVer,
    SemVer.tryParse('1.9.9') as SemVer) > 0);
}

function testApiCompatibility(): void {
  const exact: ApiCompatibility = checkPluginApiVersion(PLUGIN_API_VERSION);
  checkBool('同版本认', exact.supported, true);
  checkEqual('同版本没有理由', exact.reason, '');
  checkNum('同版本主版本号', exact.parsedMajor, 1);

  const short: ApiCompatibility = checkPluginApiVersion('1.0');
  checkBool('短版本号认', short.supported, true);

  const higher: ApiCompatibility = checkPluginApiVersion('1.9.0');
  checkBool('更高同主版本认', higher.supported, true);

  // 四种拒绝，理由各不相同（界面按理由给建议）
  const missing: ApiCompatibility = checkPluginApiVersion('');
  checkBool('没写 apiVersion 不认', missing.supported, false);
  checkEqual('没写的理由给 key', missing.reason, 'plugin_api_version_missing');

  const garbage: ApiCompatibility = checkPluginApiVersion('latest');
  checkBool('乱写的 apiVersion 不认', garbage.supported, false);
  check('乱写的理由给例子', garbage.reason.indexOf('1.0') >= 0, garbage.reason);

  const otherMajor: ApiCompatibility = checkPluginApiVersion('2.0.0');
  checkBool('跨主版本不认', otherMajor.supported, false);
  check('跨主版本的理由给出两边的版本号',
    otherMajor.reason.indexOf('2') >= 0 && otherMajor.reason.indexOf('1') >= 0,
    otherMajor.reason);
  check('跨主版本的理由说清为什么不硬读',
    otherMajor.reason.indexOf('不加载') >= 0, otherMajor.reason);

  // 下限：低于 PLUGIN_API_MIN_VERSION 拒。
  // 0.9.0 与当前 1.x 跨主版本，所以走的是跨主版本那条文案 —— 两条路径都拒，
  // 但理由必须各自成立，不能互相张冠李戴（跨主版本的理由里不该提「下限」，
  // 而下限的理由里不该让人以为「换个主版本号就能装」）。
  const below: ApiCompatibility = checkPluginApiVersion('0.9.0');
  checkBool('低于下限不认', below.supported, false);
  check('低于下限的理由提到主版本不同',
    below.reason.indexOf('主版本') >= 0, below.reason);
  check('低于下限的理由给出扩展要的版本', below.reason.indexOf('0') >= 0, below.reason);

  // 下限是 1.0.0 时，1.0.0-beta 低于下限 → 拒（预发布段确实排在正式版之前）
  const beta: ApiCompatibility = checkPluginApiVersion('1.0.0-beta');
  checkBool('预发布版低于正式下限时拒', beta.supported, false);
}

function testPluginId(): void {
  checkBool('合法 id', isValidPluginId('demo.plugin'), true);
  checkBool('带横线的合法', isValidPluginId('my-plugin-1'), true);
  checkBool('纯数字合法', isValidPluginId('123'), true);
  checkBool('空串不合法', isValidPluginId(''), false);
  checkBool('大写不合法', isValidPluginId('Demo'), false);
  checkBool('下划线不合法', isValidPluginId('demo_plugin'), false);
  checkBool('开头是横线不合法', isValidPluginId('-demo'), false);
  checkBool('开头是点不合法', isValidPluginId('.demo'), false);
  checkBool('超长不合法', isValidPluginId('a'.repeat(65)), false);
  checkBool('恰好 64 位合法', isValidPluginId('a'.repeat(64)), true);
}

// =========================================================== B. 清单往返

function testManifestCodec(): void {
  const manifest: ExtensionManifest = goodManifest();
  const colors: Map<string, string> = new Map<string, string>();
  colors.set('accent', '#1E90FF');
  colors.set('bg', '#0A0A0A');
  manifest.themes.push(theme('demo.theme', colors));

  const provider: NotificationProviderExtension = new NotificationProviderExtension();
  provider.id = 'demo.provider';
  provider.name = '示例通知源';
  provider.providerKind = 'lesson';
  provider.triggerId = TRIGGER_ID;
  manifest.notificationProviders.push(provider);

  const text: string = ExtensionManifestCodec.writeText(manifest, 2);
  const back: ExtensionManifest | undefined = ExtensionManifestCodec.parseText(text);
  check('往返拿得到清单', back !== undefined);
  if (back === undefined) {
    return;
  }

  checkEqual('id 往返', back.id, manifest.id);
  checkEqual('name 往返', back.name, manifest.name);
  checkEqual('version 往返', back.version, manifest.version);
  checkEqual('apiVersion 往返', back.apiVersion, manifest.apiVersion);
  checkEqual('author 往返', back.author, manifest.author);
  checkEqual('description 往返', back.description, manifest.description);
  checkNum('组件数往返', back.components.length, 1);
  checkNum('触发器数往返', back.triggers.length, 1);
  checkNum('行动数往返', back.actions.length, 1);
  checkNum('通知者数往返', back.notificationProviders.length, 1);
  checkNum('主题数往返', back.themes.length, 1);

  // 逐字相等才是真往返（字段顺序变了也要发现）
  checkEqual('写出再读回逐字不变', ExtensionManifestCodec.writeText(back, 2), text);

  checkEqual('组件 id 往返', back.components[0].id, PLUGIN_GUID_A);
  checkEqual('组件渲染类别往返', back.components[0].payloadKind, 'text');
  checkEqual('组件默认设置往返',
    JsonValue.asStringLoose(back.components[0].settings.tryGet('TextContent'), ''), '原神启动');
  checkEqual('触发器日程类别往返', back.triggers[0].scheduleKind, PluginScheduleKind.DailyAt);
  checkNum('触发器 atSeconds 往返', back.triggers[0].atSeconds, 7 * 3600);
  checkEqual('行动类别往返', back.actions[0].actionKind, PluginActionKind.Notification);
  checkEqual('行动标题往返', back.actions[0].title, '上课了');
  checkNum('主题颜色数往返', back.themes[0].colors.size, 2);
  checkEqual('主题颜色取值往返', back.themes[0].colors.get('accent') as string, '#1E90FF');

  // 空清单也要能读
  const empty: ExtensionManifest | undefined = ExtensionManifestCodec.parseText('{}');
  check('空对象读得出空清单', empty !== undefined);
  if (empty !== undefined) {
    checkEqual('空清单 id 是空串', empty.id, '');
    checkNum('空清单没有组件', empty.components.length, 0);
  }
  check('顶层是数组时读不出', ExtensionManifestCodec.parseText('[]') === undefined);
  check('顶层是字符串时读不出', ExtensionManifestCodec.parseText('"x"') === undefined);
  check('顶层是 null 时读不出', ExtensionManifestCodec.parseText('null') === undefined);

  // 陌生类别落 None（恒不触发 / 什么也不做），不是猜一个
  const weird: string = '{"scheduleKind":"reboot","actionKind":"exec"}';
  const weirdManifest: ExtensionManifest | undefined = ExtensionManifestCodec.parseText(weird);
  check('陌生清单能读', weirdManifest !== undefined);
  if (weirdManifest !== undefined) {
    checkNum('scheduleKind 陌生时数组为空', weirdManifest.triggers.length, 0);
  }
  const scheduleNode: JsonObject = new JsonObject();
  scheduleNode.set('scheduleKind', new JsonString('reboot'));
  checkEqual('日程类别陌生落 None', parsePluginSchedule(scheduleNode).kind,
    PluginScheduleKind.None);
}

// =========================================================== C. 校验

function testValidationHead(): void {
  const ok: PluginIssue[] = validateManifest(goodManifest(), defaultPluginSandbox());
  checkBool('好清单没有阻塞问题', hasBlockingIssues(ok), false);
  checkEqual('好清单确实一个 issue 都没有', summarizeIssues(ok), 'plugin_no_issues');

  // id
  const noId: ExtensionManifest = goodManifest();
  noId.id = '';
  checkBool('没 id 阻塞', hasCode(validateManifest(noId, defaultPluginSandbox()),
    PluginIssueCode.IdMissing), true);

  const badId: ExtensionManifest = goodManifest();
  badId.id = 'Demo Plugin';
  checkBool('非法 id 阻塞', hasCode(validateManifest(badId, defaultPluginSandbox()),
    PluginIssueCode.IdInvalid), true);

  // name
  const noName: ExtensionManifest = goodManifest();
  noName.name = '  ';
  checkBool('没 name 阻塞', hasCode(validateManifest(noName, defaultPluginSandbox()),
    PluginIssueCode.NameMissing), true);

  // version
  const badVersion: ExtensionManifest = goodManifest();
  badVersion.version = '一';
  checkBool('非法 version 阻塞', hasCode(validateManifest(badVersion, defaultPluginSandbox()),
    PluginIssueCode.VersionInvalid), true);

  const noVersion: ExtensionManifest = goodManifest();
  noVersion.version = '';
  checkBool('没 version 阻塞', hasCode(validateManifest(noVersion, defaultPluginSandbox()),
    PluginIssueCode.VersionMissing), true);

  // apiVersion
  const badApi: ExtensionManifest = goodManifest();
  badApi.apiVersion = '9.0.0';
  checkBool('跨主版本 apiVersion 阻塞',
    hasCode(validateManifest(badApi, defaultPluginSandbox()),
      PluginIssueCode.ApiVersionIncompatible), true);

  // 什么都没声明 → 提醒而不是错误（装上合法，只是没用）
  const bare: ExtensionManifest = new ExtensionManifest();
  bare.id = 'demo.bare';
  bare.name = '空的';
  bare.version = '1.0.0';
  bare.apiVersion = PLUGIN_API_VERSION;
  const bareIssues: PluginIssue[] = validateManifest(bare, defaultPluginSandbox());
  checkBool('空清单不阻塞', hasBlockingIssues(bareIssues), false);
  checkBool('空清单给提醒', hasCode(bareIssues, PluginIssueCode.NothingDeclared), true);
  checkEqual('空清单的提醒是 warning', bareIssues[0].severity,
    PluginIssueSeverity.Warning);

  // 体积
  checkNum('正常体积不报', validateManifestTextLength('x'.repeat(1000)).length, 0);
  checkNum('超体积报一条', validateManifestTextLength('x'.repeat(600 * 1024)).length, 1);
  checkBool('超体积的代码是 manifestTooLarge',
    hasCode(validateManifestTextLength('x'.repeat(600 * 1024)),
      PluginIssueCode.ManifestTooLarge), true);
}

function testValidationEntries(): void {
  // 组件 id 必须是 GUID，且不能占内置的
  // 下面这一组都是**条目级**问题：报了问题，但整份清单仍算能装
  //（只有被跳掉的那一条不生效）。分档理由见 PluginValidation 的注释：
  // 「另一个扩展先装了」不该让后来这份彻底废掉。
  const notGuid: ExtensionManifest = goodManifest();
  notGuid.components[0].id = 'not-a-guid';
  checkBool('组件 id 非 GUID 报问题',
    hasCode(validateManifest(notGuid, defaultPluginSandbox()),
      PluginIssueCode.EntryIdInvalid), true);
  checkBool('组件 id 非 GUID 不阻塞整份',
    hasBlockingIssues(validateManifest(notGuid, defaultPluginSandbox())), false);

  const builtinGuid: ExtensionManifest = goodManifest();
  builtinGuid.components[0].id = ComponentCatalog.all()[0].guid;
  checkBool('占内置组件 id 报问题',
    hasCode(validateManifest(builtinGuid, defaultPluginSandbox()),
      PluginIssueCode.EntryIdReserved), true);

  // 大写 GUID 是合法 GUID，但要按归一后的值判占用
  const upperGuid: ExtensionManifest = goodManifest();
  upperGuid.components[0].id = ComponentCatalog.all()[0].guid.toUpperCase();
  checkBool('大写 GUID 不算 id 非法',
    hasCode(validateManifest(upperGuid, defaultPluginSandbox()),
      PluginIssueCode.EntryIdInvalid), false);
  checkBool('大写 GUID 同样占内置',
    hasCode(validateManifest(upperGuid, defaultPluginSandbox()),
      PluginIssueCode.EntryIdReserved), true);

  // 清单内重名（大小写不同也算重名）
  const dup: ExtensionManifest = goodManifest();
  dup.components.push(component(PLUGIN_GUID_A.toUpperCase(), '第二个', 'text'));
  checkBool('清单内组件重名报问题',
    hasCode(validateManifest(dup, defaultPluginSandbox()),
      PluginIssueCode.EntryIdDuplicated), true);
  checkBool('清单内组件重名不阻塞整份',
    hasBlockingIssues(validateManifest(dup, defaultPluginSandbox())), false);

  // 未知渲染类别
  const badKind: ExtensionManifest = goodManifest();
  badKind.components[0].payloadKind = 'hologram';
  checkBool('未知渲染类别报问题',
    hasCode(validateManifest(badKind, defaultPluginSandbox()),
      PluginIssueCode.ComponentKindUnknown), true);

  // 触发器占内置 id
  const builtinTrigger: ExtensionManifest = goodManifest();
  builtinTrigger.triggers[0].id = TriggerIds.LESSONS_ON_CLASS;
  checkBool('占内置触发器 id 报问题',
    hasCode(validateManifest(builtinTrigger, defaultPluginSandbox()),
      PluginIssueCode.EntryIdReserved), true);

  // 日程参数
  const badAt: ExtensionManifest = goodManifest();
  badAt.triggers[0].atSeconds = 90000;
  checkBool('atSeconds 越界报问题',
    hasCode(validateManifest(badAt, defaultPluginSandbox()),
      PluginIssueCode.TriggerScheduleInvalid), true);

  const badCron: ExtensionManifest = goodManifest();
  badCron.triggers[0].scheduleKind = PluginScheduleKind.Cron;
  badCron.triggers[0].cronExpression = '这不是 cron';
  checkBool('解不出的 cron 报问题',
    hasCode(validateManifest(badCron, defaultPluginSandbox()),
      PluginIssueCode.TriggerScheduleInvalid), true);

  const cronNoText: ExtensionManifest = goodManifest();
  cronNoText.triggers[0].scheduleKind = PluginScheduleKind.Cron;
  cronNoText.triggers[0].cronExpression = '';
  checkBool('cron 类别没写表达式报问题',
    hasCode(validateManifest(cronNoText, defaultPluginSandbox()),
      PluginIssueCode.TriggerScheduleInvalid), true);

  const noSchedule: ExtensionManifest = goodManifest();
  noSchedule.triggers[0].scheduleKind = PluginScheduleKind.None;
  const noScheduleIssues: PluginIssue[] = validateManifest(noSchedule, defaultPluginSandbox());
  checkBool('无日程只是提醒',
    hasCode(noScheduleIssues, PluginIssueCode.TriggerScheduleNone), true);
  checkBool('无日程不阻塞', hasBlockingIssues(noScheduleIssues), false);

  const badEvery: ExtensionManifest = goodManifest();
  badEvery.triggers[0].scheduleKind = PluginScheduleKind.EveryMinutes;
  badEvery.triggers[0].everyMinutes = 0;
  checkBool('everyMinutes 为 0 报问题',
    hasCode(validateManifest(badEvery, defaultPluginSandbox()),
      PluginIssueCode.TriggerScheduleInvalid), true);

  // 行动占内置 id
  const builtinAction: ExtensionManifest = goodManifest();
  builtinAction.actions[0].id = ActionIds.SETTINGS;
  checkBool('占内置行动 id 报问题',
    hasCode(validateManifest(builtinAction, defaultPluginSandbox()),
      PluginIssueCode.EntryIdReserved), true);

  // 发通知缺标题/正文
  const emptyNotify: ExtensionManifest = goodManifest();
  emptyNotify.actions[0].content = '';
  checkBool('通知行动缺正文报问题',
    hasCode(validateManifest(emptyNotify, defaultPluginSandbox()),
      PluginIssueCode.ActionNotificationEmpty), true);

  // 改设置的白名单
  const modify: ActionExtension = notifyAction('demo.action.set', '', '');
  modify.actionKind = PluginActionKind.ModifySetting;
  modify.settingKey = 'IsSpeechEnabled';
  modify.settingValue = 'true';
  const whitelistManifest: ExtensionManifest = goodManifest();
  whitelistManifest.actions.push(modify);

  checkBool('白名单外的设置键报问题',
    hasCode(validateManifest(whitelistManifest, defaultPluginSandbox()),
      PluginIssueCode.ActionSettingKeyNotWritable), true);
  checkBool('白名单外的设置键不阻塞整份',
    hasBlockingIssues(validateManifest(whitelistManifest, defaultPluginSandbox())), false);
  checkBool('白名单内的设置键不报错',
    hasCode(validateManifest(whitelistManifest, sandboxWith(['IsSpeechEnabled'])),
      PluginIssueCode.ActionSettingKeyNotWritable), false);

  const noKey: ExtensionManifest = goodManifest();
  noKey.actions.push(modify);
  noKey.actions[1].settingKey = '';
  checkBool('改设置没写键报问题',
    hasCode(validateManifest(noKey, defaultPluginSandbox()),
      PluginIssueCode.ActionSettingKeyNotWritable), true);

  // 主题
  const badColor: ExtensionManifest = goodManifest();
  const badColors: Map<string, string> = new Map<string, string>();
  badColors.set('accent', 'rgb(1,2,3)');
  badColor.themes.push(theme('demo.theme', badColors));
  checkBool('非法颜色报问题',
    hasCode(validateManifest(badColor, defaultPluginSandbox()),
      PluginIssueCode.ThemeColorInvalid), true);

  const noColors: ExtensionManifest = goodManifest();
  noColors.themes.push(theme('demo.theme', new Map<string, string>()));
  checkBool('主题没颜色报问题',
    hasCode(validateManifest(noColors, defaultPluginSandbox()),
      PluginIssueCode.ThemeColorsEmpty), true);

  const badMode: ExtensionManifest = goodManifest();
  const okColors: Map<string, string> = new Map<string, string>();
  okColors.set('accent', '#1E90FF');
  badMode.themes.push(theme('demo.theme', okColors));
  badMode.themes[0].mode = 'sepia';
  checkBool('未知 mode 报问题',
    hasCode(validateManifest(badMode, defaultPluginSandbox()),
      PluginIssueCode.ThemeModeUnknown), true);

  // 通知提供者缺 id 只是提醒 —— 声明式做不到取数，provider 本来就只登记元信息
  const badProvider: ExtensionManifest = goodManifest();
  badProvider.notificationProviders.push(new NotificationProviderExtension());
  const providerIssues: PluginIssue[] = validateManifest(badProvider, defaultPluginSandbox());
  checkBool('通知提供者缺 id 报问题', hasCode(providerIssues, PluginIssueCode.EntryIdMissing), true);
  checkBool('通知提供者缺 id 不阻塞整份', hasBlockingIssues(providerIssues), false);

  // 整个条目级问题集合里一个 Error 都没有 —— Error 只留给头部与体积。
  // 这条断言的作用是防止以后有人给某个条目级分支随手补个 Error：
  // 那样装一个扩展时，它另一类里完全没问题的条目会跟着一起消失。
  const allEntryBad: ExtensionManifest = goodManifest();
  allEntryBad.components[0].id = 'not-a-guid';
  allEntryBad.triggers[0].id = TriggerIds.LESSONS_ON_CLASS;
  allEntryBad.actions[0].id = ActionIds.SETTINGS;
  const mixedIssues: PluginIssue[] = validateManifest(allEntryBad, defaultPluginSandbox());
  checkNum('三个条目级问题都报了出来', mixedIssues.length, 3);
  for (const issue of mixedIssues) {
    checkEqual(`${issue.path} 的严重级`,
      `${issue.severity}`, `${PluginIssueSeverity.Warning}`);
  }
}

function testHexColor(): void {
  checkBool('6 位合法', isHexColor('#1E90FF'), true);
  checkBool('8 位合法', isHexColor('#1E90FFFF'), true);
  checkBool('小写合法', isHexColor('#1e90ff'), true);
  checkBool('无 # 不合法', isHexColor('1E90FF'), false);
  checkBool('3 位不合法', isHexColor('#1E9'), false);
  checkBool('7 位不合法', isHexColor('#1E90FFA'), false);
  checkBool('非十六进制字符不合法', isHexColor('#1E90FG'), false);
  checkBool('空串不合法', isHexColor(''), false);
  checkBool('前后空白容忍', isHexColor('  #1E90FF  '), true);
}

function testSummarize(): void {
  checkEqual('空汇总', summarizeIssues([]), 'plugin_no_issues');
  const warnOnly: PluginIssue[] = [
    PluginIssue.create(PluginIssueCode.NothingDeclared, '', 'x', PluginIssueSeverity.Warning)
  ];
  checkEqual('只有提醒', summarizeIssues(warnOnly), '1 条提醒');
  const oneError: PluginIssue[] = [PluginIssue.create(PluginIssueCode.IdMissing, '', 'x')];
  checkEqual('只有错误', summarizeIssues(oneError), '1 个错误，装不上');
  const mixed: PluginIssue[] = [
    PluginIssue.create(PluginIssueCode.IdMissing, '', 'x'),
    PluginIssue.create(PluginIssueCode.NothingDeclared, '', 'y', PluginIssueSeverity.Warning)
  ];
  checkEqual('错误加提醒', summarizeIssues(mixed), '1 个错误、1 条提醒，装不上');
  checkNum('blockingIssues 只留错误', blockingIssues(mixed).length, 1);
}

// =========================================================== D. 日程求值

function testScheduleBasics(): void {
  checkEqual('格式化 0 秒', formatSecondOfDay(0), '00:00:00');
  checkEqual('格式化 7 点整', formatSecondOfDay(7 * 3600), '07:00:00');
  checkEqual('格式化 9 点 5 分 3 秒', formatSecondOfDay(9 * 3600 + 5 * 60 + 3), '09:05:03');

  const none: PluginSchedule = new PluginSchedule();
  checkEqual('无日程文案', scheduleText(none), '不触发');
  const daily: PluginSchedule = new PluginSchedule();
  daily.kind = PluginScheduleKind.DailyAt;
  daily.atSeconds = 7 * 3600;
  checkEqual('dailyAt 文案', scheduleText(daily), '每天 07:00:00');
  const every: PluginSchedule = new PluginSchedule();
  every.kind = PluginScheduleKind.EveryMinutes;
  every.everyMinutes = 15;
  checkEqual('everyMinutes 文案', scheduleText(every), '每 15 分钟');
  const cron: PluginSchedule = new PluginSchedule();
  cron.kind = PluginScheduleKind.Cron;
  cron.cronExpression = '0 0 7 * * *';
  checkEqual('cron 文案是原文', scheduleText(cron), '0 0 7 * * *');
  const cronEmpty: PluginSchedule = new PluginSchedule();
  cronEmpty.kind = PluginScheduleKind.Cron;
  checkEqual('cron 没写表达式', scheduleText(cronEmpty), '未设置 cron');
}

function testScheduleEvaluation(): void {
  // dailyAt：必须「相等」，不能用 >=（否则那个秒之后每 tick 都触发）
  const daily: PluginSchedule = new PluginSchedule();
  daily.kind = PluginScheduleKind.DailyAt;
  daily.atSeconds = 7 * 3600;
  checkBool('dailyAt 命中', evaluatePluginSchedule(daily, 7 * 3600).fired, true);
  checkBool('dailyAt 差一秒不命中', evaluatePluginSchedule(daily, 7 * 3600 - 1).fired, false);
  checkBool('dailyAt 晚一秒不命中', evaluatePluginSchedule(daily, 7 * 3600 + 1).fired, false);
  checkEqual('dailyAt 命中时的原因',
    evaluatePluginSchedule(daily, 7 * 3600).reason, PLUGIN_REASON_FIRED);
  checkEqual('dailyAt 没中时的原因',
    evaluatePluginSchedule(daily, 7 * 3600 + 1).reason, 'notYet');

  // 边界：0 与 86399 都合法
  const midnight: PluginSchedule = new PluginSchedule();
  midnight.kind = PluginScheduleKind.DailyAt;
  midnight.atSeconds = 0;
  checkBool('午夜命中', evaluatePluginSchedule(midnight, 0).fired, true);
  const lastSecond: PluginSchedule = new PluginSchedule();
  lastSecond.kind = PluginScheduleKind.DailyAt;
  lastSecond.atSeconds = 86399;
  checkBool('一天最后一秒命中', evaluatePluginSchedule(lastSecond, 86399).fired, true);

  // 越界给 badSettings 而不是「永不命中」
  const overflow: PluginSchedule = new PluginSchedule();
  overflow.kind = PluginScheduleKind.DailyAt;
  overflow.atSeconds = 86400;
  checkEqual('atSeconds 越界是 badSettings',
    evaluatePluginSchedule(overflow, 0).reason, PLUGIN_REASON_BAD_SETTINGS);
  checkBool('badSettings 时不触发', evaluatePluginSchedule(overflow, 0).fired, false);
  check('badSettings 带说明', evaluatePluginSchedule(overflow, 0).detail.length > 0);

  // everyMinutes：取模为 0
  const every: PluginSchedule = new PluginSchedule();
  every.kind = PluginScheduleKind.EveryMinutes;
  every.everyMinutes = 15;
  checkBool('每 15 分钟在 00:00:00 命中', evaluatePluginSchedule(every, 0).fired, true);
  checkBool('每 15 分钟在 00:15:00 命中', evaluatePluginSchedule(every, 900).fired, true);
  checkBool('每 15 分钟在 00:14:59 不命中', evaluatePluginSchedule(every, 899).fired, false);
  checkBool('每 15 分钟在 10:00:00 命中', evaluatePluginSchedule(every, 36000).fired, true);
  checkBool('每 15 分钟在 10:00:01 不命中', evaluatePluginSchedule(every, 36001).fired, false);

  const everyMinute: PluginSchedule = new PluginSchedule();
  everyMinute.kind = PluginScheduleKind.EveryMinutes;
  everyMinute.everyMinutes = 1;
  checkBool('每分钟在整分命中', evaluatePluginSchedule(everyMinute, 61).fired, false);
  checkBool('每分钟在整分秒命中', evaluatePluginSchedule(everyMinute, 60).fired, true);

  const zeroMinutes: PluginSchedule = new PluginSchedule();
  zeroMinutes.kind = PluginScheduleKind.EveryMinutes;
  zeroMinutes.everyMinutes = 0;
  checkEqual('everyMinutes 为 0 是 badSettings',
    evaluatePluginSchedule(zeroMinutes, 0).reason, PLUGIN_REASON_BAD_SETTINGS);

  // None：恒不触发，但不是 badSettings（这是「作者还没写日程」）
  const none: PluginScheduleVerdict = evaluatePluginSchedule(new PluginSchedule(), 0);
  checkBool('无日程不触发', none.fired, false);
  checkEqual('无日程的理由是 notYet', none.reason, 'notYet');
  check('无日程有说明', none.detail.indexOf('不会触发') >= 0, none.detail);
}

function testScheduleSettingsProblem(): void {
  const none: PluginSchedule = new PluginSchedule();
  checkEqual('None 不算参数问题', scheduleSettingsProblem(none), '');
  const cronEmpty: PluginSchedule = new PluginSchedule();
  cronEmpty.kind = PluginScheduleKind.Cron;
  check('cron 空表达式算问题', scheduleSettingsProblem(cronEmpty).length > 0);
  const cronOk: PluginSchedule = new PluginSchedule();
  cronOk.kind = PluginScheduleKind.Cron;
  cronOk.cronExpression = '0 0 7 * * *';
  checkEqual('cron 有表达式不算问题', scheduleSettingsProblem(cronOk), '');
  const negative: PluginSchedule = new PluginSchedule();
  negative.kind = PluginScheduleKind.DailyAt;
  negative.atSeconds = -1;
  check('负秒数算问题', scheduleSettingsProblem(negative).length > 0);
  const tooBig: PluginSchedule = new PluginSchedule();
  tooBig.kind = PluginScheduleKind.EveryMinutes;
  tooBig.everyMinutes = 1441;
  check('超过一天的分钟数算问题', scheduleSettingsProblem(tooBig).length > 0);
  const maxMinutes: PluginSchedule = new PluginSchedule();
  maxMinutes.kind = PluginScheduleKind.EveryMinutes;
  maxMinutes.everyMinutes = 1440;
  checkEqual('1440 分钟不算问题', scheduleSettingsProblem(maxMinutes), '');
}

/** 把条目转成 TriggerSettings 用的配置节点，再解回日程（往返）。 */
function testTriggerSettingsNode(): void {
  const entry: TriggerExtension = dailyTrigger('demo.x', 6, 30);
  const node: JsonObject = settingsOfTriggerExtension(entry);
  const back: PluginSchedule = parsePluginSchedule(node);
  checkEqual('日程类别往返', back.kind, PluginScheduleKind.DailyAt);
  checkNum('atSeconds 往返', back.atSeconds, 6 * 3600 + 30 * 60);
  checkNum('everyMinutes 往返', back.everyMinutes, 0);

  // 空节点 → 空日程
  const empty: PluginSchedule = parsePluginSchedule(undefined);
  checkEqual('undefined 解出 None', empty.kind, PluginScheduleKind.None);
  const emptyObject: PluginSchedule = parsePluginSchedule(new JsonObject());
  checkEqual('空对象解出 None', emptyObject.kind, PluginScheduleKind.None);
}

function testJudgePluginTrigger(): void {
  // dailyAt
  const entry: TriggerExtension = dailyTrigger('demo.x', 7, 0);
  const node: JsonObject = settingsOfTriggerExtension(entry);
  const hit: PluginTriggerVerdict = judgePluginTrigger(node, dt('2026-09-26T07:00:00'), undefined, '');
  checkBool('7 点整命中', hit.fired, true);
  const miss: PluginTriggerVerdict =
    judgePluginTrigger(node, dt('2026-09-26T07:00:01'), undefined, '');
  checkBool('过一秒不命中', miss.fired, false);
  checkEqual('不命中理由', miss.reason, 'notYet');

  // cron：缓存命中的判据是「表达式文本没变」
  const cronEntry: TriggerExtension = new TriggerExtension();
  cronEntry.id = 'demo.cron';
  cronEntry.scheduleKind = PluginScheduleKind.Cron;
  cronEntry.cronExpression = '0 0 7 * * *';
  const cronNode: JsonObject = settingsOfTriggerExtension(cronEntry);
  const cronHit: PluginTriggerVerdict =
    judgePluginTrigger(cronNode, dt('2026-09-26T07:00:00'), undefined, '');
  checkBool('cron 命中', cronHit.fired, true);
  check('cron 判定带回表达式', cronHit.cron !== undefined);
  checkEqual('cron 判定带回表达式文本', cronHit.cronText, '0 0 7 * * *');

  // 传入缓存的 cron（文本相同）时不再重解
  const cached: PluginTriggerVerdict =
    judgePluginTrigger(cronNode, dt('2026-09-26T07:00:00'), cronHit.cron, '0 0 7 * * *');
  checkBool('用缓存的 cron 仍然命中', cached.fired, true);

  // 缓存文本不匹配 → 重解
  const stale: PluginTriggerVerdict =
    judgePluginTrigger(cronNode, dt('2026-09-26T07:00:00'), cronHit.cron, '别的表达式');
  checkBool('缓存过期时重解', stale.fired, true);

  // 解不出的 cron → badSettings
  const badEntry: TriggerExtension = new TriggerExtension();
  badEntry.scheduleKind = PluginScheduleKind.Cron;
  badEntry.cronExpression = '这不是 cron';
  const badVerdict: PluginTriggerVerdict =
    judgePluginTrigger(settingsOfTriggerExtension(badEntry), dt('2026-09-26T07:00:00'),
      undefined, '');
  checkEqual('cron 解不出是 badSettings', badVerdict.reason, PLUGIN_REASON_BAD_SETTINGS);
  checkBool('badSettings 不触发', badVerdict.fired, false);

  // 参数越界 → badSettings（不是「永不命中」）
  const badEntry2: TriggerExtension = dailyTrigger('demo.y', 7, 0);
  badEntry2.atSeconds = -5;
  const badVerdict2: PluginTriggerVerdict =
    judgePluginTrigger(settingsOfTriggerExtension(badEntry2), dt('2026-09-26T07:00:00'),
      undefined, '');
  checkEqual('参数越界是 badSettings', badVerdict2.reason, PLUGIN_REASON_BAD_SETTINGS);

  // 无日程
  const noneEntry: TriggerExtension = new TriggerExtension();
  const noneVerdict: PluginTriggerVerdict =
    judgePluginTrigger(settingsOfTriggerExtension(noneEntry), dt('2026-09-26T07:00:00'),
      undefined, '');
  checkEqual('无日程是 notYet', noneVerdict.reason, 'notYet');
  check('无日程有说明', noneVerdict.detail.length > 0);

  // 非对象节点
  const scalar: PluginTriggerVerdict =
    judgePluginTrigger(new JsonString('x'), dt('2026-09-26T07:00:00'), undefined, '');
  checkEqual('标量节点当无日程', scalar.reason, 'notYet');
}

// =========================================================== E. 声明式行动

function testPluginAction(): void {
  const entry: ActionExtension = notifyAction('demo.a', '标题', '正文');
  const node: JsonObject = settingsOfActionExtension(entry);

  const plan: PluginActionPlan = planPluginAction(node, new Set<string>());
  checkEqual('动作类别', plan.kind, PluginActionKind.Notification);
  checkEqual('标题', plan.notification.title, '标题');
  checkEqual('正文', plan.notification.content, '正文');
  checkEqual('分类归到 automation', plan.notification.category, 'automation');
  checkEqual('能执行时没有理由', plan.reason, '');

  // 分类归一：认识的就用，不认识的落 automation（响铃方向错代价更大）
  checkEqual('认识 weather', normalizeCategory('weather'), 'weather');
  checkEqual('认识 class_reminder', normalizeCategory('class_reminder'), 'class_reminder');
  checkEqual('不认识落 automation', normalizeCategory('screamer'), 'automation');
  checkEqual('空值落 automation', normalizeCategory('  '), 'automation');
  checkEqual('带空白先裁掉', normalizeCategory(' weather '), 'weather');

  // 改设置：白名单内放行
  const modify: ActionExtension = notifyAction('demo.b', '', '');
  modify.actionKind = PluginActionKind.ModifySetting;
  modify.settingKey = 'IsSpeechEnabled';
  modify.settingValue = 'false';
  const allowed: Set<string> = new Set<string>();
  allowed.add('IsSpeechEnabled');
  const allowedPlan: PluginActionPlan =
    planPluginAction(settingsOfActionExtension(modify), allowed);
  checkEqual('白名单内可执行', allowedPlan.kind, PluginActionKind.ModifySetting);
  checkEqual('设置键', allowedPlan.setting.key, 'IsSpeechEnabled');
  checkEqual('设置值原文', allowedPlan.setting.value, 'false');

  // 白名单外 → 落 None 且说明（校验被绕过也不越权）
  const deniedPlan: PluginActionPlan =
    planPluginAction(settingsOfActionExtension(modify), new Set<string>());
  checkEqual('白名单外跳过', deniedPlan.kind, PluginActionKind.None);
  check('白名单外有理由', deniedPlan.reason.indexOf('IsSpeechEnabled') >= 0, deniedPlan.reason);

  // 通知类行动即使没白名单也不受影响
  const notifyPlan: PluginActionPlan =
    planPluginAction(node, new Set<string>());
  checkEqual('通知类不看白名单', notifyPlan.kind, PluginActionKind.Notification);

  // 节点不是对象
  const badPlan: PluginActionPlan = planPluginAction(undefined, new Set<string>());
  checkEqual('缺配置是 None', badPlan.kind, PluginActionKind.None);
  check('缺配置有理由', badPlan.reason.length > 0);

  // 陌生类别
  const stranger: ActionExtension = notifyAction('demo.c', 't', 'c');
  stranger.actionKind = 'exec' as PluginActionKind;
  const strangerPlan: PluginActionPlan =
    planPluginAction(settingsOfActionExtension(stranger), new Set<string>());
  checkEqual('陌生类别落 None', strangerPlan.kind, PluginActionKind.None);
}

// =========================================================== F. 模板

function templateContext(): PluginTemplateContext {
  const out: PluginTemplateContext = new PluginTemplateContext();
  out.now = dt('2026-09-26T07:08:09');
  out.profileName = '我的档案';
  out.stateText = 'time_state_break';
  return out;
}

function testTemplate(): void {
  const ctx: PluginTemplateContext = templateContext();
  checkEqual('时间', renderPluginTemplate('{time}', ctx), '07:08:09');
  checkEqual('小时补零', renderPluginTemplate('{hour}', ctx), '07');
  checkEqual('分钟补零', renderPluginTemplate('{minute}', ctx), '08');
  checkEqual('日期', renderPluginTemplate('{date}', ctx), '2026-09-26');
  checkEqual('星期（.NET 口径：周日=0）', renderPluginTemplate('{weekday}', ctx), 'time_weekday_saturday');
  checkEqual('状态', renderPluginTemplate('{state}', ctx), 'time_state_break');
  checkEqual('档案名', renderPluginTemplate('{profile}', ctx), '我的档案');

  // 组合与字面量
  checkEqual('组合', renderPluginTemplate('{date} {time}', ctx), '2026-09-26 07:08:09');
  checkEqual('没有占位符原样返回',
    renderPluginTemplate('纯文本', ctx), '纯文本');
  checkEqual('空串', renderPluginTemplate('', ctx), '');
  checkEqual('前后字面量', renderPluginTemplate('现在是 {time} 了', ctx), '现在是 07:08:09 了');
  checkEqual('同一个占位符出现两次',
    renderPluginTemplate('{time} 和 {time}', ctx), '07:08:09 和 07:08:09');

  // 未知占位符原样保留（拼错时作者要能一眼看出来）
  checkEqual('未知占位符原样保留',
    renderPluginTemplate('{tme}', ctx), '{tme}');
  checkEqual('未知与已知混排',
    renderPluginTemplate('{time} {tme}', ctx), '07:08:09 {tme}');
  checkEqual('花括号不配对原样保留',
    renderPluginTemplate('{time', ctx), '{time');
  checkEqual('空占位符原样保留',
    renderPluginTemplate('{} {time}', ctx), '{} 07:08:09');
  checkEqual('嵌套花括号原样保留',
    renderPluginTemplate('{a{b}', ctx), '{a{b}');

  // 没给 now 时，占位符落空串而不是崩
  const bare: PluginTemplateContext = new PluginTemplateContext();
  checkEqual('没 now 时时间是空串', renderPluginTemplate('{time}', bare), '');
  checkEqual('没 now 时星期是空串', renderPluginTemplate('{weekday}', bare), '');
  checkEqual('没 now 时未知仍是原样', renderPluginTemplate('{tme}', bare), '{tme}');

  // 占位符清单工具
  checkEqual('列出占位符（保序去重）',
    pluginTemplatePlaceholders('{time} {date} {time}').join(','), 'time,date');
  checkNum('没有占位符时给空数组', pluginTemplatePlaceholders('无').length, 0);
  checkEqual('找出未识别的占位符',
    unresolvedPlaceholders('{time} {tme} {zzz}', ctx).join(','), 'tme,zzz');
  checkNum('全部认识时没有未识别项',
    unresolvedPlaceholders('{time} {date}', ctx).length, 0);
  checkNum('受支持的占位符共 12 个', PLUGIN_TEMPLATE_PLACEHOLDERS.length, 12);

  // {state} 的回落：stateText 留空时从快照上取。
  //
  // 留空是常态而不是异常 —— 调用方（AutomationTickScheduler）手上有一份快照，
  // 但它没有理由知道「作者想管状态叫课间还是叫休息」，所以它不会去填
  // stateText。字段注释写着「为空时取快照上的状态」，实现却恒返回 stateText，
  // 于是 {state} 永远空串而清单作者无从下手。
  const withSnapshot: PluginTemplateContext = templateContext();
  withSnapshot.stateText = '';
  const snap: LessonsSnapshot = new LessonsSnapshot();
  snap.state = TimeState.Breaking;
  withSnapshot.snapshot = snap;
  checkEqual('stateText 留空时按快照取',
    renderPluginTemplate('{state}', withSnapshot), 'time_state_break');
  const onClass: PluginTemplateContext = templateContext();
  onClass.stateText = '';
  const onClassSnap: LessonsSnapshot = new LessonsSnapshot();
  onClassSnap.state = TimeState.OnClass;
  onClass.snapshot = onClassSnap;
  checkEqual('快照是上课中时取上课中',
    renderPluginTemplate('{state}', onClass), 'time_state_on_class');
  const override: PluginTemplateContext = templateContext();
  override.snapshot = onClassSnap;
  override.stateText = '距离下课还有一会儿';
  checkEqual('显式给的 stateText 优先',
    renderPluginTemplate('{state}', override), '距离下课还有一会儿');
  checkEqual('stateText 与快照都没有时是空串',
    renderPluginTemplate('{state}', bare), '');

  // 时间状态中文名：五个状态 + 越界
  checkNum('五个时间状态的名字', TIME_STATE_LABELS.length, 5);
  checkEqual('上课中', timeStateLabel(TimeState.OnClass), 'time_state_on_class');
  checkEqual('课间休息', timeStateLabel(TimeState.Breaking), 'time_state_break');
  checkEqual('已放学', timeStateLabel(TimeState.AfterSchool), 'time_state_after_school');
  checkEqual('无课程', timeStateLabel(TimeState.None), 'time_state_none');
  checkEqual('准备上课', timeStateLabel(TimeState.PrepareOnClass), 'time_state_prepare');
  checkEqual('越界值给未知而不是空串', timeStateLabel(9), 'time_state_unknown');
  checkEqual('负值给未知而不是空串', timeStateLabel(-1), 'time_state_unknown');
  for (let i = 0; i < TIME_STATE_LABELS.length; i++) {
    check('每个状态都有名字', timeStateLabel(i).length > 0, timeStateLabel(i));
  }
}

// =========================================================== G. 装 / 卸

function resetRegistry(): void {
  uninstallAllPlugins();
}

function testInstallBasics(): void {
  resetRegistry();
  const before: number = TriggerCatalog.all().length;
  const result: PluginInstallResult = installPlugin(goodManifest(), defaultPluginSandbox());
  checkBool('装上', result.loaded, true);
  checkEqual('没有理由', result.reason, '');
  // 1 组件 + 1 触发器 + 1 行动
  checkNum('三个条目都装上', result.entryCount, 3);
  checkNum('触发器多了一条', TriggerCatalog.all().length, before + 1);

  // 组件进了 ComponentCatalog，且能解出 payload
  const descriptor = ComponentCatalog.find(PLUGIN_GUID_A);
  check('扩展组件查得到', descriptor !== undefined);
  checkEqual('扩展组件显示名', descriptor === undefined ? '' : descriptor.name, '示例文本');
  checkBool('标记为扩展注册', ComponentCatalog.isPlugin(PLUGIN_GUID_A), true);
  checkBool('内置组件不算扩展', ComponentCatalog.isPlugin(ComponentCatalog.all()[0].guid), false);

  // 新建这个组件时带上扩展声明的默认设置
  const instance: ComponentSettings = ComponentCatalog.create(PLUGIN_GUID_A);
  const payload: TextPayload = ComponentCatalog.decode(instance) as TextPayload;
  checkBool('解出文本 payload', payload instanceof TextPayload, true);
  checkEqual('清单声明的默认设置被用上', payload.textContent, '原神启动');
  checkNum('没声明的键走解码器默认值', payload.fontSize, 16);

  // 触发器进了 TriggerCatalog，标成 Plugin + Implemented
  const info = TriggerCatalog.find(TRIGGER_ID);
  check('扩展触发器查得到', info !== undefined);
  if (info !== undefined) {
    checkEqual('触发器显示名', info.name, '7 点提醒');
    checkEqual('声明式触发器标成可实现', `${info.support}`, `${TriggerSupport.Implemented}`);
    checkBool('声明式触发器不可撤销', info.canRevert, false);
  }

  // 行动进了 ActionCatalog
  const action = ActionCatalog.find(ACTION_ID);
  check('扩展行动查得到', action !== undefined);
  if (action !== undefined) {
    checkEqual('声明式行动标成可实现', `${action.support}`, `${ActionSupport.Implemented}`);
    checkBool('声明式行动不可回滚', action.isRevertable, false);
  }

  // 注册表条目摊平：三类各一条，provider/theme 也记账
  checkNum('组件类摊平出一条', ExtensionRegistry.entriesOf(ExtensionKind.Component).length, 1);
  checkNum('触发器类摊平出一条', ExtensionRegistry.entriesOf(ExtensionKind.Trigger).length, 1);
  checkNum('行动类摊平出一条', ExtensionRegistry.entriesOf(ExtensionKind.Action).length, 1);
  checkEqual('提供者可查', ExtensionRegistry.providerOf(ExtensionKind.Action, ACTION_ID),
    'demo.plugin');

  // 卸掉：四处都要清干净
  checkBool('卸掉', uninstallPlugin('demo.plugin'), true);
  checkBool('组件摘干净', ComponentCatalog.find(PLUGIN_GUID_A) === undefined, true);
  checkBool('触发器摘干净', TriggerCatalog.find(TRIGGER_ID) === undefined, true);
  checkBool('行动摘干净', ActionCatalog.find(ACTION_ID) === undefined, true);
  checkBool('注册表摘干净', ExtensionRegistry.findPlugin('demo.plugin') === undefined, true);
  checkNum('触发器数回到装之前', TriggerCatalog.all().length, before);
  checkNum('没有摊平的条目了',
    ExtensionRegistry.entriesOf(ExtensionKind.Component).length, 0);
  checkBool('内置组件没被误摘', ComponentCatalog.find(ComponentCatalog.all()[0].guid) !== undefined,
    true);
  checkBool('再卸一次返回 false', uninstallPlugin('demo.plugin'), false);
}

function testInstallRejects(): void {
  resetRegistry();
  const bad: ExtensionManifest = goodManifest();
  bad.apiVersion = '9.0.0';
  const result: PluginInstallResult = installPlugin(bad, defaultPluginSandbox());
  checkBool('版本不认不装', result.loaded, false);
  checkNum('一条都没装上', result.entryCount, 0);
  check('组件没进注册表', ComponentCatalog.find(PLUGIN_GUID_A) === undefined);
  check('触发器没进注册表', TriggerCatalog.find(TRIGGER_ID) === undefined);
  check('行动没进注册表', ActionCatalog.find(ACTION_ID) === undefined);
  // 但它仍然被登记了，用户在设置页能看到「装了个东西但没装上」
  const record: PluginRecord | undefined = ExtensionRegistry.findPlugin('demo.plugin');
  check('失败的扩展也被登记', record !== undefined);
  if (record !== undefined) {
    checkBool('登记为未加载', record.loaded, false);
    check('有失败原因', record.reason.length > 0);
    checkNum('条目数为 0', record.entryCount, 0);
  }
  resetRegistry();
}

function testInstallConflict(): void {
  resetRegistry();
  // 第一个装上
  installPlugin(goodManifest(), defaultPluginSandbox());

  // 第二个扩展声明同一个组件 id —— 第二个的这条被跳过，第一个照旧
  const second: ExtensionManifest = new ExtensionManifest();
  second.id = 'demo.other';
  second.name = '另一个扩展';
  second.version = '1.0.0';
  second.apiVersion = PLUGIN_API_VERSION;
  second.components.push(component(PLUGIN_GUID_A, '撞车的组件', 'text'));
  second.components.push(component(PLUGIN_GUID_B, '不撞的组件', 'text'));
  const result: PluginInstallResult = installPlugin(second, defaultPluginSandbox());

  checkBool('整体仍算装上', result.loaded, true);
  checkNum('只装上一条组件', result.entryCount, 1);
  checkBool('报了一条冲突', hasCode(result.issues, PluginIssueCode.EntryIdReserved), true);
  check('冲突说明提到 id',
    result.issues.length > 0 && result.issues[0].message.indexOf(PLUGIN_GUID_A) >= 0,
    result.issues.length > 0 ? result.issues[0].message : '(没有 issue)');
  checkEqual('第一个扩展的组件名还在',
    ComponentCatalog.find(PLUGIN_GUID_A) === undefined ? '' : ComponentCatalog.find(PLUGIN_GUID_A)!.name,
    '示例文本');
  checkEqual('第二个扩展的组件在', ComponentCatalog.find(PLUGIN_GUID_B) === undefined ? '' :
    ComponentCatalog.find(PLUGIN_GUID_B)!.name, '不撞的组件');

  // 卸第二个不该影响第一个
  uninstallPlugin('demo.other');
  check('第一个的组件还在', ComponentCatalog.find(PLUGIN_GUID_A) !== undefined);
  check('第二个的组件摘掉了', ComponentCatalog.find(PLUGIN_GUID_B) === undefined);
  resetRegistry();
}

function testInstallReinstall(): void {
  resetRegistry();
  installPlugin(goodManifest(), defaultPluginSandbox());
  // 重装同一个 id：先卸再装，不会因为「自己撞自己」而失败
  const renamed: ExtensionManifest = goodManifest();
  renamed.name = '改过名的扩展';
  const result: PluginInstallResult = installPlugin(renamed, defaultPluginSandbox());
  checkBool('重装成功', result.loaded, true);
  checkNum('重装后条目数不变', result.entryCount, 3);
  checkEqual('重装后显示名是新的',
    ComponentCatalog.find(PLUGIN_GUID_A) === undefined ? '' :
      ComponentCatalog.find(PLUGIN_GUID_A)!.name, '示例文本');
  const record: PluginRecord | undefined = ExtensionRegistry.findPlugin('demo.plugin');
  check('重装后只有一个记录', record !== undefined && ExtensionRegistry.plugins().length === 1);
  if (record !== undefined) {
    checkEqual('记录里的显示名是新的', record.name, '改过名的扩展');
  }
  resetRegistry();
}

function testInstallBuiltinPayloadKind(): void {
  resetRegistry();
  // 借用 clock 渲染器：解出来应当是 ClockPayload
  const manifest: ExtensionManifest = new ExtensionManifest();
  manifest.id = 'demo.clock';
  manifest.name = '时钟扩展';
  manifest.version = '1.0.0';
  manifest.apiVersion = PLUGIN_API_VERSION;
  manifest.components.push(component(PLUGIN_GUID_B, '秒级时钟', 'clock'));
  installPlugin(manifest, defaultPluginSandbox());
  const instance: ComponentSettings = ComponentCatalog.create(PLUGIN_GUID_B);
  const payload: ClockPayload = ComponentCatalog.decode(instance) as ClockPayload;
  checkBool('解出 clock payload', payload instanceof ClockPayload, true);
  const descriptor = ComponentCatalog.find(PLUGIN_GUID_B);
  check('容器标记为 false', descriptor !== undefined && !descriptor.isContainer);
  resetRegistry();

  // group 借用：应该是容器
  const groupManifest: ExtensionManifest = new ExtensionManifest();
  groupManifest.id = 'demo.group';
  groupManifest.name = '容器扩展';
  groupManifest.version = '1.0.0';
  groupManifest.apiVersion = PLUGIN_API_VERSION;
  groupManifest.components.push(component(PLUGIN_GUID_B, '自定义分组', 'group'));
  installPlugin(groupManifest, defaultPluginSandbox());
  const groupDescriptor = ComponentCatalog.find(PLUGIN_GUID_B);
  check('group 标成容器', groupDescriptor !== undefined && groupDescriptor.isContainer);
  resetRegistry();
}

function testUnregisterGuards(): void {
  resetRegistry();
  // unregister 不许拆内置组件
  checkBool('摘内置组件被拒',
    ComponentCatalog.unregister(ComponentCatalog.all()[0].guid), false);
  check('内置组件还在', ComponentCatalog.find(ComponentCatalog.all()[0].guid) !== undefined);

  // unregister 一个从没装过的组件
  checkBool('摘不存在的组件返回 false', ComponentCatalog.unregister(PLUGIN_GUID_A), false);
}

// =========================================================== H. 引擎端到端

/** 造一次 tick 的输入（只带时间，声明式日程不看档案）。 */
function tickAt(at: string): AutomationTick {
  const out: AutomationTick = new AutomationTick(dt(at));
  out.hasTrustedProfile = true;
  out.isAutomationEnabled = true;
  return out;
}

function pluginWorkflow(triggerId: string, settings: Object): Workflow {
  const out: Workflow = new Workflow();
  const triggerSettings: TriggerSettings = new TriggerSettings();
  triggerSettings.id = triggerId;
  triggerSettings.settings = WorkflowMutations.settingsToNode(settings);
  out.triggers.push(triggerSettings);
  const actionSet: ActionSet = new ActionSet();
  actionSet.isEnabled = true;
  actionSet.isRevertEnabled = false;
  actionSet.status = ActionSetStatus.Normal;
  out.actionSet = actionSet;
  const actionItem: ActionItem = new ActionItem();
  actionItem.id = ACTION_ID;
  actionItem.settings = WorkflowMutations.settingsToNode(
    settingsOfActionExtension(notifyAction(ACTION_ID, '上课了', '该上课了')));
  out.actionSet.actions.push(actionItem);
  return out;
}

function verdictReason(at: string): string {
  const engine: AutomationEngine = new AutomationEngine();
  const workflow: Workflow = pluginWorkflow(TRIGGER_ID,
    settingsOfTriggerExtension(dailyTrigger(TRIGGER_ID, 7, 0)));
  const result: AutomationTickResult = engine.tick([workflow], tickAt(at));
  return result.verdicts.length === 0 ? '(没有判定)' : result.verdicts[0].reason;
}

function testEngineEndToEnd(): void {
  resetRegistry();
  installPlugin(goodManifest(), defaultPluginSandbox());

  // 引擎真的走了声明式分支：7 点整触发
  checkEqual('声明式触发器在到点时触发', verdictReason('2026-09-26T07:00:00'), AutomationReason.Fired);
  checkEqual('过一秒不再触发', verdictReason('2026-09-26T07:00:01'), AutomationReason.NotYet);
  checkEqual('前一天同一时刻同样触发（不看星期）',
    verdictReason('2026-09-25T07:00:00'), AutomationReason.Fired);

  // 判定跑完要把行动产出
  const engine: AutomationEngine = new AutomationEngine();
  const workflow: Workflow = pluginWorkflow(TRIGGER_ID,
    settingsOfTriggerExtension(dailyTrigger(TRIGGER_ID, 7, 0)));
  const result: AutomationTickResult = engine.tick([workflow], tickAt('2026-09-26T07:00:00'));
  checkNum('产出一次执行', result.runs.length, 1);
  if (result.runs.length === 1) {
    checkNum('执行落在第 0 个工作流', result.runs[0].workflowIndex, 0);
    checkBool('是一次触发而不是恢复', result.runs[0].isRevert, false);
    check('执行带触发原因', result.runs[0].causeText.length > 0, result.runs[0].causeText);
  }

  // cron 类别：表达式改了要重新判
  const cronEntry: TriggerExtension = new TriggerExtension();
  cronEntry.id = 'demo.cron';
  cronEntry.scheduleKind = PluginScheduleKind.Cron;
  cronEntry.cronExpression = '0 0 7 * * *';
  const cronWorkflow: Workflow = pluginWorkflow('demo.cron', settingsOfTriggerExtension(cronEntry));
  // 这个 id 没注册过 —— 但装一份带它的扩展
  const cronManifest: ExtensionManifest = new ExtensionManifest();
  cronManifest.id = 'demo.cronplugin';
  cronManifest.name = 'cron 扩展';
  cronManifest.version = '1.0.0';
  cronManifest.apiVersion = PLUGIN_API_VERSION;
  cronManifest.triggers.push(cronEntry);
  installPlugin(cronManifest, defaultPluginSandbox());

  const cronEngine: AutomationEngine = new AutomationEngine();
  const cronHit: AutomationTickResult = cronEngine.tick([cronWorkflow], tickAt('2026-09-26T07:00:00'));
  checkNum('cron 扩展到点触发', cronHit.runs.length, 1);

  // 同一个引擎实例连续两帧：第二帧不该重复触发
  const sameEngine: AutomationEngine = new AutomationEngine();
  const first: AutomationTickResult = sameEngine.tick([cronWorkflow], tickAt('2026-09-26T07:00:00'));
  const second: AutomationTickResult = sameEngine.tick([cronWorkflow], tickAt('2026-09-26T07:00:01'));
  checkNum('第一帧触发', first.runs.length, 1);
  checkNum('第二帧不触发', second.runs.length, 0);

  // 解不出的 cron → BadSettings
  const brokenEntry: TriggerExtension = new TriggerExtension();
  brokenEntry.id = 'demo.brokencron';
  brokenEntry.scheduleKind = PluginScheduleKind.Cron;
  brokenEntry.cronExpression = '这不是 cron';
  const brokenManifest: ExtensionManifest = new ExtensionManifest();
  brokenManifest.id = 'demo.brokenplugin';
  brokenManifest.name = '坏 cron 扩展';
  brokenManifest.version = '1.0.0';
  brokenManifest.apiVersion = PLUGIN_API_VERSION;
  brokenManifest.triggers.push(brokenEntry);
  installPlugin(brokenManifest, defaultPluginSandbox());

  const brokenEngine: AutomationEngine = new AutomationEngine();
  const brokenWorkflow: Workflow = pluginWorkflow('demo.brokencron',
    settingsOfTriggerExtension(brokenEntry));
  const brokenResult: AutomationTickResult =
    brokenEngine.tick([brokenWorkflow], tickAt('2026-09-26T07:00:00'));
  checkNum('坏 cron 不触发', brokenResult.runs.length, 0);
  checkEqual('坏 cron 报 badSettings', brokenResult.verdicts.length === 0 ? '' :
    brokenResult.verdicts[0].reason, AutomationReason.BadSettings);

  // 扩展被卸掉后，这条触发器回到「未知 id」
  uninstallPlugin('demo.cronplugin');
  const goneEngine: AutomationEngine = new AutomationEngine();
  const goneResult: AutomationTickResult = goneEngine.tick([cronWorkflow],
    tickAt('2026-09-26T07:00:00'));
  checkEqual('卸掉后触发器变未知', goneResult.verdicts.length === 0 ? '' :
    goneResult.verdicts[0].reason, AutomationReason.UnknownTrigger);

  resetRegistry();
}

function testRegistryDisabled(): void {
  resetRegistry();
  installPlugin(goodManifest(), defaultPluginSandbox());
  const record: PluginRecord | undefined = ExtensionRegistry.findPlugin('demo.plugin');
  check('扩展已登记', record !== undefined);
  checkBool('默认是开着的', ExtensionRegistry.isDisabled('demo.plugin'), false);

  // 关掉扩展（必须走 setEnabled：条目表是那一刻摊平的，直接改字段不会重摊，
  // 于是「在设置里关了它，编辑器里照样选得到」）
  checkBool('关掉扩展返回 true',
    record === undefined ? false : ExtensionRegistry.setEnabled('demo.plugin', false), true);
  checkBool('再关一次返回 false', ExtensionRegistry.setEnabled('demo.plugin', false), false);
  checkBool('关掉后 isDisabled 为真', ExtensionRegistry.isDisabled('demo.plugin'), true);
  checkBool('关掉后条目判定为不可用',
    ExtensionRegistry.isEntryInactive(ExtensionKind.Trigger, TRIGGER_ID), true);
  checkBool('关掉后提供者也查不到',
    ExtensionRegistry.providerOf(ExtensionKind.Action, ACTION_ID) === undefined, true);
  checkNum('关掉后没有摊平的条目',
    ExtensionRegistry.entriesOf(ExtensionKind.Trigger).length, 0);
  checkBool('未装过的条目不算不可用',
    ExtensionRegistry.isEntryInactive(ExtensionKind.Trigger, 'classisland.lessons.onClass'),
    false);

  // 关掉之后引擎不触发（且理由是 notYet，不是 notImplemented）
  checkEqual('关掉扩展后不触发', verdictReason('2026-09-26T07:00:00'), AutomationReason.NotYet);

  resetRegistry();
}

function testRegistryOrder(): void {
  resetRegistry();
  const first: ExtensionManifest = goodManifest('demo.a');
  const second: ExtensionManifest = goodManifest('demo.b');
  second.name = '第二个';
  installPlugin(first, defaultPluginSandbox());
  installPlugin(second, defaultPluginSandbox());
  checkNum('两个扩展都登记了', ExtensionRegistry.plugins().length, 2);
  checkEqual('按登记顺序', ExtensionRegistry.plugins()[0].pluginId, 'demo.a');

  // 重新装第一个不应把它挪到末尾
  installPlugin(goodManifest('demo.a'), defaultPluginSandbox());
  checkEqual('重装不换序', ExtensionRegistry.plugins()[0].pluginId, 'demo.a');
  checkEqual('重装后显示名还是它', ExtensionRegistry.plugins()[0].name, '示例扩展');
  checkNum('重装后仍是两个', ExtensionRegistry.plugins().length, 2);

  // 卸中间那个，剩下的顺序不变
  uninstallPlugin('demo.a');
  checkNum('剩一个', ExtensionRegistry.plugins().length, 1);
  checkEqual('剩下的是 b', ExtensionRegistry.plugins()[0].pluginId, 'demo.b');
  checkEqual('摘要', ExtensionRegistry.summaryText(), '1 个扩展在用');
  resetRegistry();
  checkEqual('全清后摘要', ExtensionRegistry.summaryText(), 'plugin_none_installed');
}

/**
 * 问题清单挂在记录上。
 *
 * 设置页要显示「哪几条被跳过了、为什么」，而问题分两批产生：validateManifest
 * 的那批在装载前，冲突的那批在逐条注册时（注册失败才知道冲突）。调用方手里
 * 只有一份 ExtensionManifest，哪一个问题属于哪个扩展只有 core 知道，所以必须
 * 由 core 存到记录上。
 */
function testRecordIssues(): void {
  resetRegistry();
  const clean: PluginRecord | undefined = installResultRecord('demo.clean');
  checkBool('干净的扩展有记录', clean !== undefined, true);
  checkNum('干净的扩展没有问题', clean === undefined ? -1 : clean.issues.length, 0);
  checkEqual('干净的扩展没有理由', clean === undefined ? '' : clean.reason, '');

  // 与已有扩展撞 id：装上了，但被撞的那几条被跳过，问题要挂在记录上。
  //
  // 只让**组件**撞：触发器与行动都换成没被占用的 id，于是「只被跳过了组件」
  // 这件事是可断言的（entryCount 能算准），否则五条全撞时「跳过了几条」只能
  // 靠数，得不出「跳过一条、其余照装」这个结论。
  const dup: ExtensionManifest = goodManifest('demo.dup');
  dup.name = '撞车的';
  dup.components[0].id = PLUGIN_GUID_B;
  dup.triggers[0].id = 'demo.trigger.afternoon';
  dup.actions[0].id = 'demo.action.afternoon';
  // 清单里自己撞自己：校验报「重名」，装载报「已占用」—— 两个问题码都要在，
  // 因为它们回答的是不同问题（作者写错了 vs 装的时候撞上了）。
  dup.components.push(component(PLUGIN_GUID_B, '第二个文本', 'text'));
  const dupResult: PluginInstallResult = installPlugin(dup, defaultPluginSandbox());
  checkBool('撞车的仍算装上', dupResult.loaded, true);
  // 2 组件 + 1 触发器 + 1 行动 = 4 条，去掉撞掉的 1 条组件 = 3
  checkNum('只装上三条（组件被撞掉一条）', dupResult.entryCount, 3);
  const dupRecord: PluginRecord | undefined = ExtensionRegistry.findPlugin('demo.dup');
  checkBool('撞车的有记录', dupRecord !== undefined, true);
  // 两个问题各报一次：validateManifest 说「重名」，installComponents 说「已占用」
  checkNum('记录上有两个问题（校验 + 装载各报一次）',
    dupRecord === undefined ? -1 : dupRecord.issues.length, 2);
  let sawDuplicated: boolean = false;
  let sawReserved: boolean = false;
  for (const issue of dupRecord === undefined ? [] : dupRecord.issues) {
    if (issue.code === PluginIssueCode.EntryIdDuplicated) {
      sawDuplicated = true;
    }
    if (issue.code === PluginIssueCode.EntryIdReserved) {
      sawReserved = true;
    }
    // 条目级问题一律是提醒（理由见 PluginValidation.downgradeEntryIssues）
    checkEqual(`${issue.code} 是提醒`, `${issue.severity}`, `${PluginIssueSeverity.Warning}`);
  }
  checkBool('记录上有「清单内重名」', sawDuplicated, true);
  checkBool('记录上有「id 已被占用」', sawReserved, true);
  checkEqual('理由提到跳过了几条',
    dupRecord === undefined ? '' : dupRecord.reason, '1 条条目因为冲突或非法被跳过。');
  checkNum('被撞掉的组件没进 attached',
    dupRecord === undefined ? -1 : dupRecord.attachedComponents.indexOf(PLUGIN_GUID_A), -1);
  checkNum('没撞的组件进了 attached',
    dupRecord === undefined ? -1 : dupRecord.attachedComponents.indexOf(PLUGIN_GUID_B), 0);
  checkBool('先装的那个扩展的组件还认得',
    ComponentCatalog.find(PLUGIN_GUID_A) !== undefined, true);
  const keptDescriptor = ComponentCatalog.find(PLUGIN_GUID_A);
  checkEqual('先装的那个扩展的组件显示名没被改',
    keptDescriptor === undefined ? '' : keptDescriptor.name, '示例文本');

  // 头部被拒：问题同样要挂上去，否则设置页只能显示一句「装不上」
  // （被拒的扩展一个条目都不该注册：PLUGIN_GUID_C 要仍然没人认领）
  const badHead: ExtensionManifest = goodManifest('demo.badhead');
  badHead.apiVersion = '0.9.0';
  // 换掉全部 id，让这份清单除了版本闸之外没有别的问题 ——
  // 否则「有几个问题」这个断言会被撞 id 的那几条搅在一起，数不出「版本这一条」。
  badHead.components[0].id = PLUGIN_GUID_C;
  badHead.triggers[0].id = 'demo.trigger.rejected';
  badHead.actions[0].id = 'demo.action.rejected';
  const badResult: PluginInstallResult = installPlugin(badHead, defaultPluginSandbox());
  checkBool('版本不认就不装', badResult.loaded, false);
  const badRecord: PluginRecord | undefined = ExtensionRegistry.findPlugin('demo.badhead');
  checkBool('版本不认也有记录', badRecord !== undefined, true);
  // 头部被拒时 validateManifest 还会报「白名单外的设置键」那类条目级提醒
  // （好Manifest 里有它们？—— 没有，所以这里就是版本这一条）
  checkNum('版本不认的记录上有问题',
    badRecord === undefined ? -1 : badRecord.issues.length, 1);
  checkEqual('版本不认的问题码',
    badRecord === undefined || badRecord.issues.length === 0
      ? '' : badRecord.issues[0].code,
    `${PluginIssueCode.ApiVersionIncompatible}`);
  checkNum('版本不认的记录没有生效条目',
    badRecord === undefined ? -1 : badRecord.entryCount, 0);
  check('版本不认有理由说清是版本问题',
    (badRecord === undefined ? '' : badRecord.reason).indexOf('API') >= 0,
    badRecord === undefined ? '' : badRecord.reason);
  checkBool('被拒的扩展一个组件都没注册',
    ComponentCatalog.find(PLUGIN_GUID_C) === undefined, true);
  checkNum('被拒的扩展没有生效条目',
    badRecord === undefined ? -1 : badRecord.attachedComponents.length, 0);
  resetRegistry();
}

/** 装一个干净的扩展并把它的记录取出来（测试辅助）。 */
function installResultRecord(pluginId: string): PluginRecord | undefined {
  installPlugin(goodManifest(pluginId), defaultPluginSandbox());
  return ExtensionRegistry.findPlugin(pluginId);
}

function testWritableSettingKeys(): void {
  resetRegistry();
  installPlugin(goodManifest(), defaultPluginSandbox());
  // 装上之前先用一份带 ModifySetting 的扩展，配上白名单
  const modify: ActionExtension = notifyAction('demo.action.set', '', '');
  modify.actionKind = PluginActionKind.ModifySetting;
  modify.settingKey = 'IsSpeechEnabled';
  modify.settingValue = 'false';
  const manifest: ExtensionManifest = new ExtensionManifest();
  manifest.id = 'demo.setter';
  manifest.name = '改设置扩展';
  manifest.version = '1.0.0';
  manifest.apiVersion = PLUGIN_API_VERSION;
  manifest.actions.push(modify);
  installPlugin(manifest, sandboxWith(['IsSpeechEnabled']));

  ExtensionRegistry.setWritableSettingKeys(['IsSpeechEnabled']);
  const item: ActionItem = new ActionItem();
  item.id = 'demo.action.set';
  item.settings = WorkflowMutations.settingsToNode(settingsOfActionExtension(modify));
  const decoded = ActionCatalog.settingsOf(item);
  const plan = decoded as PluginActionPlan;
  checkEqual('执行时按当前白名单放行', plan.kind, PluginActionKind.ModifySetting);

  // 换一份白名单后再解：立即被拒
  ExtensionRegistry.setWritableSettingKeys(['SomethingElse']);
  const decoded2 = ActionCatalog.settingsOf(item);
  const plan2 = decoded2 as PluginActionPlan;
  checkEqual('白名单换了之后被拒', plan2.kind, PluginActionKind.None);
  check('被拒时有理由', plan2.reason.length > 0);
  resetRegistry();
}

function testUnknownComponentAfterUninstall(): void {
  resetRegistry();
  installPlugin(goodManifest(), defaultPluginSandbox());
  // 建一个真实实例（它带 nameCache）
  const instance: ComponentSettings = ComponentCatalog.create(PLUGIN_GUID_A);
  checkEqual('装上时显示名', ComponentCatalog.displayNameOf(instance), '示例文本');
  checkBool('装上时 isKnown', ComponentCatalog.isKnown(PLUGIN_GUID_A), true);

  uninstallPlugin('demo.plugin');
  // 摘掉之后：不是空白，而是「未识别组件」或 nameCache
  const after: string = ComponentCatalog.displayNameOf(instance);
  check('摘掉后仍有名字（不是空串）', after.length > 0, after);
  checkBool('摘掉后 isKnown 为假', ComponentCatalog.isKnown(PLUGIN_GUID_A), false);
  // 没有 nameCache 时退到 GUID 前 8 位
  const bare: ComponentSettings = new ComponentSettings();
  bare.id = PLUGIN_GUID_A;
  checkEqual('没 nameCache 退到前 8 位',
    ComponentCatalog.displayNameOf(bare), PLUGIN_GUID_A.substring(0, 8));
  // 全新实例（没有 nameCache）仍然显示占位名
  const fresh: ComponentSettings = ComponentCatalog.create(PLUGIN_GUID_A);
  checkEqual('新建的退到占位名', ComponentCatalog.displayNameOf(fresh),
    PLUGIN_GUID_A.substring(0, 8));
  resetRegistry();
}

/**
 * 桌面版 manifest.yml 的 YAML 子集解析。
 *
 * 这层解析器是「手写的子集」而不是完整 YAML，所以测试的重点是**边界**：
 * 每一条「认得 / 认不出」的分界都要有一个用例，否则将来改代码时把某条规则
 * 悄悄改掉，症状是「某个扩展的描述/作者名变成空串」—— 那类问题不会报错，
 * 只会在界面上少几个字。
 */
function testDesktopYamlScalars(): void {
  // 最普通的一份：YamlDotNet 对短字符串就是这个形状
  const plain: DesktopPluginMeta = parseDesktopPluginYaml([
    'EntranceAssembly: MyPlugin.dll',
    'Name: 示例扩展',
    'Id: com.example.myplugin',
    'Description: 一个小插件',
    'Icon: icon.png',
    'Readme: README.md',
    'Url: https://example.com/plugin',
    'Version: 1.2.3',
    'ApiVersion: 2.0.0',
    'Author: someone'
  ].join('\n'));
  checkEqual('入口程序集', plain.entranceAssembly, 'MyPlugin.dll');
  checkEqual('名字', plain.name, '示例扩展');
  checkEqual('id', plain.id, 'com.example.myplugin');
  checkEqual('描述', plain.description, '一个小插件');
  checkEqual('url', plain.url, 'https://example.com/plugin');
  checkEqual('版本', plain.version, '1.2.3');
  checkEqual('apiVersion', plain.apiVersion, '2.0.0');
  checkEqual('作者', plain.author, 'someone');
  checkNum('全部字段都读出来了', plain.unreadableFields.length, 0);

  // 行尾 CR（Windows 上保存的 yml）
  checkEqual('CRLF 也读得出来',
    parseDesktopPluginYaml('Name: 带 CR\r\nId: demo.cr\r\n').name, '带 CR');

  // 注释与文档分隔
  const commented: DesktopPluginMeta = parseDesktopPluginYaml([
    '---',
    '# 这是清单',
    'Name: 带注释',
    '',
    '# Author: 被注释掉的作者',
    'Author: 真的作者',
    '...'
  ].join('\n'));
  checkEqual('注释行被跳过', commented.name, '带注释');
  checkEqual('被注释的键不生效', commented.author, '真的作者');

  // 空值的三种写法
  const empties: DesktopPluginMeta = parseDesktopPluginYaml([
    'Name:',
    'Version: ~',
    'Author: null',
    'Description: Null'
  ].join('\n'));
  checkEqual('空冒号 → 空串', empties.name, '');
  checkEqual('~ → 空串', empties.version, '');
  checkEqual('null → 空串', empties.author, '');
  checkEqual('Null → 空串', empties.description, '');

  // 单引号：'' 是一个字面的单引号
  checkEqual('单引号里的 \' 是转义',
    parseDesktopPluginYaml("Name: 'it''s'").name, "it's");
  checkEqual('单引号里 # 不是注释',
    parseDesktopPluginYaml("Description: 'a # b'").description, 'a # b');

  // 双引号：四个转义
  checkEqual('双引号里的换行转义',
    parseDesktopPluginYaml('Name: "a\\nb"').name, 'a\nb');
  checkEqual('双引号里的制表转义',
    parseDesktopPluginYaml('Name: "a\\tb"').name, 'a\tb');
  checkEqual('双引号里的反斜杠',
    parseDesktopPluginYaml('Name: "a\\\\b"').name, 'a\\b');
  checkEqual('双引号里不认识的转义保留反斜杠',
    parseDesktopPluginYaml('Name: "a\\qb"').name, 'a\\qb');
  checkEqual('双引号里的中文',
    parseDesktopPluginYaml('Name: "中文名"').name, '中文名');

  // 裸量后面的行尾注释（必须前面有空格，否则是值的一部分）
  checkEqual('裸量后跟 # 注释', parseDesktopPluginYaml('Name: 值 # 注释').name, '值');
  checkEqual('没空格的 # 是值的一部分',
    parseDesktopPluginYaml('Name: 值#尾巴').name, '值#尾巴');

  // 值里带冒号（URL、版本、路径）不能把键切错
  const colons: DesktopPluginMeta = parseDesktopPluginYaml([
    'Url: https://example.com:8080/x',
    'Description: 备注: 这行有两个冒号'
  ].join('\n'));
  checkEqual('URL 里的冒号', colons.url, 'https://example.com:8080/x');
  checkEqual('描述里的冒号', colons.description, '备注: 这行有两个冒号');
  // 冒号后必须跟空格或行尾：'a:b' 不是分隔
  checkEqual('冒号后无空格不算分隔',
    parseDesktopPluginYaml('Url:https://x').name, '');
}

/**
 * YAML 子集里「认不出」的写法。
 *
 * 认不出时的口径固定为：值按空串 + 字段名记进 unreadableFields。
 * 这条口径本身要被测到 —— 界面上的说明（「有 N 个字段本端读不出来」）就是靠它
 * 才不会说谎。
 */
function testDesktopYamlUnsupported(): void {
  // 缩进块（嵌套映射 / 列表）
  const nested: DesktopPluginMeta = parseDesktopPluginYaml([
    'Name: 顶层',
    'Dependencies:',
    '  - Id: other.plugin',
    '    Version: 1.0.0'
  ].join('\n'));
  checkEqual('顶层字段不受缩进块影响', nested.name, '顶层');
  checkEqual('缩进块里的键不当成顶层', nested.author, '');
  checkEqual('缩进块本身值按空', nested.entranceAssembly, '');
  check('缩进块记一笔', nested.unreadableFields.length > 0,
    nested.unreadableFields.join(','));

  // 缩进块里的 Id 不能盖掉顶层的 Id
  const shadow: DesktopPluginMeta = parseDesktopPluginYaml([
    'Id: 真正的',
    'Dependencies:',
    '  - Id: 假的'
  ].join('\n'));
  checkEqual('缩进块不覆盖顶层同名键', shadow.id, '真正的');

  // 流式集合
  const flow: DesktopPluginMeta = parseDesktopPluginYaml([
    'Dependencies: []',
    'Name: 好的',
    'SupportedOSPlatforms: [Windows, Linux]'
  ].join('\n'));
  checkEqual('流式集合之后仍读得下去', flow.name, '好的');
  check('流式集合被记账', flow.unreadableFields.length >= 1,
    flow.unreadableFields.join(','));

  // 锚点 / 别名 / 标签
  const anchored: DesktopPluginMeta = parseDesktopPluginYaml([
    'Name: &n 带锚点',
    'Author: *n',
    'Version: !!str 1.0.0'
  ].join('\n'));
  checkEqual('锚点值按空', anchored.name, '');
  checkEqual('别名值按空', anchored.author, '');
  checkEqual('标签值按空', anchored.version, '');
  checkNum('三个字段都记账', anchored.unreadableFields.length, 3);

  // 引号没闭合
  const broken: DesktopPluginMeta = parseDesktopPluginYaml([
    'Name: "没闭合',
    'Author: \'也没闭合'
  ].join('\n'));
  checkEqual('没闭合的双引号按空', broken.name, '');
  checkEqual('没闭合的单引号按空', broken.author, '');
  checkNum('两个字段都记账', broken.unreadableFields.length, 2);

  // 带引号的键不认（免得把 'Name' 当成键名去匹配）
  const quotedKey: DesktopPluginMeta = parseDesktopPluginYaml('"Name": 假的');
  checkEqual('带引号的键不认', quotedKey.name, '');

  // 完全不是映射的输入
  checkEqual('空文本', parseDesktopPluginYaml('').name, '');
  checkEqual('只有注释', parseDesktopPluginYaml('# 全是注释').name, '');
  checkEqual('没有冒号', parseDesktopPluginYaml('这是一段说明文字').name, '');
  checkEqual('第一份文档之后的忽略',
    parseDesktopPluginYaml('Name: 第一份\n---\nName: 第二份').name, '第一份');
}

/** 块标量：描述常常是多行的，不实现就会静默丢描述。 */
function testDesktopYamlBlock(): void {
  const literal: DesktopPluginMeta = parseDesktopPluginYaml([
    'Name: 块标量',
    'Description: |',
    '  第一行',
    '  第二行'
  ].join('\n'));
  checkEqual('保留换行', literal.description, '第一行\n第二行');

  const literalTrim: DesktopPluginMeta = parseDesktopPluginYaml([
    'Name: 去尾换行',
    'Description: |-',
    '  只有一行'
  ].join('\n'));
  checkEqual('|- 不带尾换行', literalTrim.description, '只有一行');

  const folded: DesktopPluginMeta = parseDesktopPluginYaml([
    'Description: >',
    '  折起来',
    '  的一行'
  ].join('\n'));
  checkEqual('> 折成空格', folded.description, '折起来 的一行');

  const foldedBlank: DesktopPluginMeta = parseDesktopPluginYaml([
    'Description: >',
    '  上段',
    '',
    '  下段'
  ].join('\n'));
  checkEqual('> 里的空行变段落分隔', foldedBlank.description, '上段\n\n下段');

  // 块后面接着另一个顶层字段
  const afterBlock: DesktopPluginMeta = parseDesktopPluginYaml([
    'Description: |',
    '  正文',
    'Author: 块后面的人'
  ].join('\n'));
  checkEqual('块之后的顶层字段照读', afterBlock.author, '块后面的人');
  checkEqual('块的内容', afterBlock.description, '正文');

  // 块标量带数字（keep 数量）本子集不认
  const counted: DesktopPluginMeta = parseDesktopPluginYaml([
    'Description: |2',
    '  正文',
    'Author: 还在'
  ].join('\n'));
  checkEqual('带数量的块按空', counted.description, '');
  checkEqual('带数量的块之后的字段照读', counted.author, '还在');

  // 缩进不一致：按最小缩进对齐
  const ragged: DesktopPluginMeta = parseDesktopPluginYaml([
    'Description: |',
    '    缩进多的',
    '   缩进少的'
  ].join('\n'));
  checkEqual('按最小缩进对齐', ragged.description, ' 缩进多的\n缩进少的');
}

/** 桌面版 id → 本端 id。 */
function testDesktopIdNormalize(): void {
  checkEqual('本来就是合规的', normalizeDesktopPluginId('com.example.p'), 'com.example.p');
  checkEqual('大写改小写', normalizeDesktopPluginId('Com.Example.P'), 'com.example.p');
  checkEqual('下划线换横线', normalizeDesktopPluginId('my_plugin'), 'my-plugin');
  checkEqual('连续分隔符合成一个', normalizeDesktopPluginId('my__plugin'), 'my-plugin');
  checkEqual('掐掉首尾横线', normalizeDesktopPluginId('-abc-'), 'abc');
  checkEqual('掐掉首尾点', normalizeDesktopPluginId('.abc.'), 'abc');
  checkEqual('掐掉前导的横线加点', normalizeDesktopPluginId('-.abc'), 'abc');
  checkEqual('全是非法字符', normalizeDesktopPluginId('###'), FALLBACK_DESKTOP_PLUGIN_ID);
  checkEqual('空串', normalizeDesktopPluginId(''), FALLBACK_DESKTOP_PLUGIN_ID);
  checkEqual('空白', normalizeDesktopPluginId('   '), FALLBACK_DESKTOP_PLUGIN_ID);
  checkEqual('超长截到兜底', normalizeDesktopPluginId('a'.repeat(65)),
    FALLBACK_DESKTOP_PLUGIN_ID);
  checkNum('正好 64 字符是合法的', normalizeDesktopPluginId('a'.repeat(64)).length, 64);
  checkEqual('前后空白先掐掉', normalizeDesktopPluginId('  ab.cd  '), 'ab.cd');
}

/**
 * 桌面版元信息 → 本端清单。
 *
 * 三条决策各自对应一个具体后果，逐条断言：
 *  - apiVersion 必须换成本端的（照抄桌面版的 2.0.0 会被版本闸拒掉，导入永远失败）
 *  - 不迁任何条目（.dll 是 .NET 程序集，本端没有运行时）
 *  - 描述里要写清「这是从桌面版包导进来的、它没有可用条目」
 */
function testDesktopManifest(): void {
  const meta: DesktopPluginMeta = new DesktopPluginMeta();
  meta.entranceAssembly = 'MyPlugin.dll';
  meta.name = '桌面版插件';
  meta.id = 'com.example.MyPlugin';
  meta.version = '2.3.4';
  meta.apiVersion = '2.0.0';
  meta.author = 'someone';
  meta.url = 'https://example.com/p';
  meta.description = '原来的描述';
  const manifest: ExtensionManifest = desktopPluginManifest(meta);

  checkEqual('id 改成小写', manifest.id, 'com.example.myplugin');
  checkEqual('名字照搬', manifest.name, '桌面版插件');
  checkEqual('版本照搬', manifest.version, '2.3.4');
  checkEqual('作者照搬', manifest.author, 'someone');
  checkEqual('homepage 拿 url', manifest.homepage, 'https://example.com/p');
  checkEqual('apiVersion 换成本端的', manifest.apiVersion, PLUGIN_API_VERSION);
  checkNum('不带组件', manifest.components.length, 0);
  checkNum('不带触发器', manifest.triggers.length, 0);
  checkNum('不带行动', manifest.actions.length, 0);
  checkNum('不带通知提供者', manifest.notificationProviders.length, 0);
  checkNum('不带主题', manifest.themes.length, 0);
  check('描述写了是从桌面版导入的', manifest.description.indexOf(DESKTOP_IMPORT_NOTE) >= 0,
    manifest.description);
  check('描述写了没有可用条目', manifest.description.indexOf('.NET') >= 0, manifest.description);
  check('描述带了程序集名', manifest.description.indexOf('MyPlugin.dll') >= 0, manifest.description);
  check('描述带了桌面版 API 版本', manifest.description.indexOf('2.0.0') >= 0,
    manifest.description);
  check('描述说明了 id 被改过', manifest.description.indexOf('com.example.MyPlugin') >= 0,
    manifest.description);
  check('描述保留了原描述', manifest.description.indexOf('原来的描述') >= 0,
    manifest.description);
  // 换来的 apiVersion 必须真的能过版本闸，否则「换成本端的」只是句空话
  const compatibility: ApiCompatibility = checkPluginApiVersion(manifest.apiVersion);
  checkBool('换过的 apiVersion 过了版本闸', compatibility.supported, true);

  // 没有 name 时退回 id，别留一个空名字的行
  const unnamed: DesktopPluginMeta = new DesktopPluginMeta();
  unnamed.id = 'demo.anon';
  checkEqual('没名字就退回 id', desktopPluginManifest(unnamed).name, 'demo.anon');

  // 完全空的清单也得给一个能用的东西
  const blank: ExtensionManifest = desktopPluginManifest(new DesktopPluginMeta());
  checkEqual('空元信息给兜底 id', blank.id, FALLBACK_DESKTOP_PLUGIN_ID);
  checkEqual('空元信息的名字等于 id', blank.name, FALLBACK_DESKTOP_PLUGIN_ID);
  // unreadableFields 是解析器自己记的，所以走一遍真解析而不是手工塞
  const withUnreadable: ExtensionManifest = desktopPluginManifest(
    parseDesktopPluginYaml(['Id: demo.x', 'Dependencies: []', 'Name: 好的'].join('\n')));
  check('说明里提到读不出来的字段',
    withUnreadable.description.indexOf('个字段本端读不出来') >= 0, withUnreadable.description);
  check('说明里点名了那个字段',
    withUnreadable.description.indexOf('Dependencies') >= 0, withUnreadable.description);
  // 有个能用的 id 就不该退到兜底
  checkEqual('有 id 时不用兜底', withUnreadable.id, 'demo.x');
}

// ------------------------------------------------------------------ 主流程

testSemVer();
testApiCompatibility();
testPluginId();
testManifestCodec();
testValidationHead();
testValidationEntries();
testHexColor();
testSummarize();
testScheduleBasics();
testScheduleEvaluation();
testScheduleSettingsProblem();
testTriggerSettingsNode();
testJudgePluginTrigger();
testPluginAction();
testTemplate();
testInstallBasics();
testInstallRejects();
testDesktopYamlScalars();
testDesktopYamlUnsupported();
testDesktopYamlBlock();
testDesktopIdNormalize();
testDesktopManifest();
testInstallConflict();
testInstallReinstall();
testInstallBuiltinPayloadKind();
testUnregisterGuards();
testEngineEndToEnd();
testRegistryDisabled();
testRegistryOrder();
testRecordIssues();
testWritableSettingKeys();
testUnknownComponentAfterUninstall();

console.log(`插件系统：${passed} 项通过，${failures.length} 项失败`);
if (failures.length > 0) {
  for (const item of failures) {
    console.log(`  ✗ ${item}`);
  }
}
process.exit(failures.length === 0 ? 0 : 1);
