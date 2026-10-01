/*
 * 扩展清单校验。
 *
 * 沙箱是什么
 * ----------
 * 一份声明式清单没有代码可执行，所以「沙箱」不是内存隔离或权限检查，而是
 * **清单能被允许声明什么**。三道闸：
 *   1. 版本闸：apiVersion 得是本应用认的（同主版本且不低于下限）。
 *   2. 占用闸：条目 id 不能占掉内置注册位，也不能在同一份清单里重名。
 *      占用是硬伤 —— 同一个 id 解析出两种实现时，症状是面板上同一类组件时而
 *      正常时而空白，而日志里什么也没有。
 *   3. 能力闸：声明的类别必须在白名单里，参数必须自洽（cron 解得出来、
 *      秒数在 0~86399、颜色是合法十六进制）。
 *
 * 为什么校验是纯函数而不在装载时顺手做
 * ----------------------------------
 * 因为「这份清单为什么不能用」是用户要在安装前看到的东西，而不是日志里的一行。
 * 纯函数返回**全部**问题而不是遇到第一个就停：作者一次改完比来回试二十次强。
 *
 * 白名单由调用方给
 * --------------
 * 设置键的白名单住在 entry（AppPreferences 才是唯一真源），core 不复制一份 ——
 * 两份名单迟早会对不上，而对不上时表现是「扩展改了个它其实不该改的设置」，
 * 极难排查。所以这里只接收一个集合。
 */

import { CronExpression } from '../automation/CronExpression';
import { ActionCatalog } from '../automation/ActionCatalog';
import { TriggerCatalog } from '../automation/TriggerCatalog';
import { ComponentCatalog } from '../components/ComponentCatalog';
import { PLUGIN_COMPONENT_KINDS } from './PluginManifest';
import {
  ActionExtension,
  ComponentExtension,
  ExtensionKind,
  ExtensionManifest,
  NotificationProviderExtension,
  PluginActionKind,
  PluginScheduleKind,
  ThemeExtension,
  TriggerExtension,
  extensionKindField
} from './PluginManifest';
import { SemVer, checkPluginApiVersion, isValidPluginId } from './PluginApi';
import { Guid } from 'common_shared';

/** 单类条目数量上限。一份清单里塞 50 个组件没有意义，只有故障或攻击才会到这。 */
export const MAX_ENTRIES_PER_KIND: number = 50;
/**
 * 单个条目 id 的长度上限。
 *
 * 比扩展 id 的 64 宽：条目 id 要和内置那批共处一个命名空间，内置里最长的
 * `classisland.lessons.currentTimeStateChanged` 已经 47 位，64 也就够 ——
 * 留到 128 是为了不给将来更长的内置 id 留隐患，而不是鼓励写长 id。
 */
export const MAX_ENTRY_ID_LENGTH: number = 128;

/** 整份清单文本长度上限（字节）。 */
export const MAX_MANIFEST_TEXT_LENGTH: number = 512 * 1024;

/** 主题可用的配色档。 */
export const PLUGIN_THEME_MODES: string[] = ['light', 'dark', 'both'];

/** 问题级别。 */
export enum PluginIssueSeverity {
  Error = 'error',
  Warning = 'warning'
}

/** 问题代码。稳定不变，界面按它决定要不要显示、以及要不要给「怎么改」的提示。 */
export enum PluginIssueCode {
  ManifestTooLarge = 'manifestTooLarge',
  IdMissing = 'idMissing',
  IdInvalid = 'idInvalid',
  IdDuplicated = 'idDuplicated',
  NameMissing = 'nameMissing',
  VersionMissing = 'versionMissing',
  VersionInvalid = 'versionInvalid',
  ApiVersionIncompatible = 'apiVersionIncompatible',
  TooManyEntries = 'tooManyEntries',
  EntryIdMissing = 'entryIdMissing',
  EntryIdInvalid = 'entryIdInvalid',
  EntryIdReserved = 'entryIdReserved',
  EntryIdDuplicated = 'entryIdDuplicated',
  EntryNameMissing = 'entryNameMissing',
  ComponentKindUnknown = 'componentKindUnknown',
  TriggerScheduleInvalid = 'triggerScheduleInvalid',
  TriggerScheduleNone = 'triggerScheduleNone',
  ActionKindUnsupported = 'actionKindUnsupported',
  ActionNotificationEmpty = 'actionNotificationEmpty',
  ActionSettingKeyNotWritable = 'actionSettingKeyNotWritable',
  ThemeModeUnknown = 'themeModeUnknown',
  ThemeColorInvalid = 'themeColorInvalid',
  ThemeColorsEmpty = 'themeColorsEmpty',
  ProviderTriggerUnknown = 'providerTriggerUnknown',
  NothingDeclared = 'nothingDeclared'
}

/** 一条校验问题。 */
export class PluginIssue {
  code: PluginIssueCode = PluginIssueCode.IdMissing;
  severity: PluginIssueSeverity = PluginIssueSeverity.Error;
  /** 出问题的位置，写给人看：`components[2].id`。 */
  path: string = '';
  /** 给用户看的一句话。 */
  message: string = '';

  static create(code: PluginIssueCode, path: string, message: string,
    severity: PluginIssueSeverity = PluginIssueSeverity.Error): PluginIssue {
    const out: PluginIssue = new PluginIssue();
    out.code = code;
    out.path = path;
    out.message = message;
    out.severity = severity;
    return out;
  }
}

/** 清单能声明什么的白名单。 */
export class PluginSandbox {
  /** 允许 ModifySetting 动作改的设置键（小写驼峰原样，即 AppPreferences 里的键）。 */
  writableSettingKeys: Set<string> = new Set<string>();
  /** 允许借用的组件渲染类别。空表示用 PLUGIN_COMPONENT_KINDS 的默认十种。 */
  componentKinds: string[] = [];

  /** 实际生效的组件类别。 */
  effectiveComponentKinds(): string[] {
    return this.componentKinds.length === 0 ? PLUGIN_COMPONENT_KINDS : this.componentKinds;
  }
}

/** 默认沙箱：十种组件类别、一个设置键都不许改。 */
export function defaultPluginSandbox(): PluginSandbox {
  return new PluginSandbox();
}

/** 有没有 Error 级问题。 */
export function hasBlockingIssues(issues: PluginIssue[]): boolean {
  for (const issue of issues) {
    if (issue.severity === PluginIssueSeverity.Error) {
      return true;
    }
  }
  return false;
}

/** 只留 Error 级。装载前的最后一道判断用它。 */
export function blockingIssues(issues: PluginIssue[]): PluginIssue[] {
  const out: PluginIssue[] = [];
  for (const issue of issues) {
    if (issue.severity === PluginIssueSeverity.Error) {
      out.push(issue);
    }
  }
  return out;
}

/** 一句话汇总（给状态栏用）。 */
export function summarizeIssues(issues: PluginIssue[]): string {
  if (issues.length === 0) {
    return '没有发现问题';
  }
  const errors: number = blockingIssues(issues).length;
  const warnings: number = issues.length - errors;
  if (errors === 0) {
    return `${warnings} 条提醒`;
  }
  if (warnings === 0) {
    return `${errors} 个错误，装不上`;
  }
  return `${errors} 个错误、${warnings} 条提醒，装不上`;
}

/**
 * 校验一份清单。
 *
 * 返回**全部**问题（错误 + 提醒）。空数组 = 可以装。
 */
export function validateManifest(manifest: ExtensionManifest, sandbox: PluginSandbox): PluginIssue[] {
  const out: PluginIssue[] = [];
  validateManifestHead(manifest, out);
  const count: number = manifest.components.length + manifest.triggers.length +
    manifest.actions.length + manifest.notificationProviders.length + manifest.themes.length;
  if (count === 0) {
    out.push(PluginIssue.create(PluginIssueCode.NothingDeclared, '',
      '这份清单一个扩展条目都没声明，装上不会有任何东西出现。',
      PluginIssueSeverity.Warning));
  }
  // 从这里开始的问题全是**条目级**的，一律降级成提醒（理由见 downgradeToWarning）。
  const entryMark: number = out.length;
  validateComponents(manifest, sandbox, out);
  validateTriggers(manifest, out);
  validateActions(manifest, sandbox, out);
  validateProviders(manifest, out);
  validateThemes(manifest, out);
  downgradeEntryIssues(entryMark, out);
  return out;
}

/**
 * 把 from 之后的问题统统降成提醒。
 *
 * 只有清单头部（id / name / version / apiVersion）与文件体积是「装不装」的判据：
 * 那几项不对，这份清单整体就没有意义，后面的条目无从谈起。
 *
 * 条目级问题只跳过**那一条**。清单里 10 个组件、第 3 个撞了内置 id 时，
 * 应当装上 9 个并记账 —— 而不是一个都不装。后者会让「另一个扩展先装上了」
 * 这种完全正常的先后顺序，把后来那份扩展彻底废掉：用户看到的现象是
 * 「刚才还好好的扩展突然装不上了，而且日志里只有一句 id 已被占用」。
 */
function downgradeEntryIssues(from: number, out: PluginIssue[]): void {
  for (let i = from; i < out.length; i++) {
    out[i].severity = PluginIssueSeverity.Warning;
  }
}

/** 清单文本长度单独判：它不是清单内容的问题，是文件本身的问题。 */
export function validateManifestTextLength(text: string): PluginIssue[] {
  if (text.length <= MAX_MANIFEST_TEXT_LENGTH) {
    return [];
  }
  return [PluginIssue.create(PluginIssueCode.ManifestTooLarge, '',
    `清单有 ${text.length} 字节，超过上限 ${MAX_MANIFEST_TEXT_LENGTH} 字节。`)];
}

// ---------------------------------------------------------------- 头部

function validateManifestHead(manifest: ExtensionManifest, out: PluginIssue[]): void {
  const id: string = manifest.id.trim();
  if (id.length === 0) {
    out.push(PluginIssue.create(PluginIssueCode.IdMissing, 'id', '清单里没写 id。'));
  } else if (!isValidPluginId(id)) {
    out.push(PluginIssue.create(PluginIssueCode.IdInvalid, 'id',
      `id「${id}」不合法。只用小写字母、数字、点和横线，长度 1~64，且以字母或数字开头。`));
  }
  if (manifest.name.trim().length === 0) {
    out.push(PluginIssue.create(PluginIssueCode.NameMissing, 'name', '清单里没写 name。'));
  }
  if (manifest.version.trim().length === 0) {
    out.push(PluginIssue.create(PluginIssueCode.VersionMissing, 'version', '清单里没写 version。'));
  } else if (SemVer.tryParse(manifest.version) === undefined) {
    out.push(PluginIssue.create(PluginIssueCode.VersionInvalid, 'version',
      `version「${manifest.version}」不是能认的版本号。写成 1.0 或 1.0.0 这样的形式。`));
  }
  const compat = checkPluginApiVersion(manifest.apiVersion);
  if (!compat.supported) {
    out.push(PluginIssue.create(PluginIssueCode.ApiVersionIncompatible, 'apiVersion', compat.reason));
  }
}

// ---------------------------------------------------------------- 各类条目

/**
 * 条目 id 的通用检查：非空、不超长、不含空白与控制字符。
 *
 * **不查大小写。** 条目 id 与内置触发器 / 行动共用同一个命名空间，而内置那批
 * 本来就带大写字母（`classisland.lessons.onClass`）—— 拿「只许小写字母数字点横线」
 * 那条规则（那是给扩展 id 用的）去判，会把内置 id 判成非法，于是「占内置 id」
 * 这条检查永远走不到：用户看到的提示是「条目 id 不合法，请用小写」，而真正
 * 的原因是「这个 id 已经被占用了」，于是他去改了一堆没用的字符。
 */
function checkEntryId(id: string, path: string, out: PluginIssue[]): boolean {
  const trimmed: string = id.trim();
  if (trimmed.length === 0) {
    out.push(PluginIssue.create(PluginIssueCode.EntryIdMissing, path, '条目没写 id。'));
    return false;
  }
  if (trimmed.length > MAX_ENTRY_ID_LENGTH) {
    out.push(PluginIssue.create(PluginIssueCode.EntryIdInvalid, path,
      `条目 id 有 ${trimmed.length} 个字符，超过上限 ${MAX_ENTRY_ID_LENGTH}。`));
    return false;
  }
  for (let i = 0; i < trimmed.length; i++) {
    const code: number = trimmed.charCodeAt(i);
    if (code <= 32 || code === 127) {
      out.push(PluginIssue.create(PluginIssueCode.EntryIdInvalid, path,
        '条目 id 里不能有空白或控制字符（它是配置里的一项，会被原样写进用户档案）。'));
      return false;
    }
  }
  return true;
}

/** 条目名与数量上限的通用检查。 */
function checkEntryCommon(id: string, name: string, path: string, count: number,
  out: PluginIssue[]): void {
  if (count > MAX_ENTRIES_PER_KIND) {
    out.push(PluginIssue.create(PluginIssueCode.TooManyEntries,
      extensionKindFieldOf(path),
      `这一类有 ${count} 条，超过上限 ${MAX_ENTRIES_PER_KIND} 条。`));
  }
  if (name.trim().length === 0) {
    out.push(PluginIssue.create(PluginIssueCode.EntryNameMissing, `${path}.name`, '条目没写 name。'));
  }
}

/** 从路径前缀反推类别字段名（`components[2].id` → `components`）。 */
function extensionKindFieldOf(path: string): string {
  const bracket: number = path.indexOf('[');
  return bracket < 0 ? path : path.substring(0, bracket);
}

function validateComponents(manifest: ExtensionManifest, sandbox: PluginSandbox,
  out: PluginIssue[]): void {
  const kinds: string[] = sandbox.effectiveComponentKinds();
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < manifest.components.length; i++) {
    const entry: ComponentExtension = manifest.components[i];
    const path: string = `components[${i}]`;
    checkEntryCommon(entry.id, entry.name, path, manifest.components.length, out);
    // 组件 id 走 GUID 口径，不走 checkEntryId 那套「小写字母数字点横线」：
    // 组件 id 是 GUID，会写进用户档案与内置组件共用同一张查找表，而 GUID 的
    // 十六进制字母大小写都合法（用户从注册表 / 生成器里抄来的常常是大写）。
    // 按插件 id 的规则去判会把一堆合法 GUID 判成非法，作者完全摸不着头脑。
    const trimmedId: string = entry.id.trim();
    if (trimmedId.length === 0) {
      out.push(PluginIssue.create(PluginIssueCode.EntryIdMissing, `${path}.id`, '条目没写 id。'));
      continue;
    }
    const guid: Guid | undefined = Guid.tryParse(trimmedId);
    if (guid === undefined) {
      out.push(PluginIssue.create(PluginIssueCode.EntryIdInvalid, `${path}.id`,
        `组件 id「${entry.id}」必须是 GUID（32 位十六进制 + 4 个横线）。` +
        '组件 id 会写进用户档案，与内置组件共用同一套查找表。'));
      continue;
    }
    // 归一后判占用：用户档案里存的是小写 D 格式，判重必须按归一后的值。
    const key: string = guid.toString();
    if (seen.has(key)) {
      out.push(PluginIssue.create(PluginIssueCode.EntryIdDuplicated, `${path}.id`,
        `组件 id「${key}」在这一份清单里出现了两次。`));
      continue;
    }
    seen.add(key);
    if (ComponentCatalog.isKnown(key)) {
      out.push(PluginIssue.create(PluginIssueCode.EntryIdReserved, `${path}.id`,
        `组件 id「${key}」是内置组件的 id，换一个。`));
      continue;
    }
    if (kinds.indexOf(entry.payloadKind) < 0) {
      out.push(PluginIssue.create(PluginIssueCode.ComponentKindUnknown, `${path}.payloadKind`,
        `payloadKind「${entry.payloadKind}」不认识。能借用的只有：${kinds.join('、')}。`));
    }
  }
}

function validateTriggers(manifest: ExtensionManifest, out: PluginIssue[]): void {
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < manifest.triggers.length; i++) {
    const entry: TriggerExtension = manifest.triggers[i];
    const path: string = `triggers[${i}]`;
    checkEntryCommon(entry.id, entry.name, path, manifest.triggers.length, out);
    if (!checkEntryId(entry.id, `${path}.id`, out)) {
      continue;
    }
    if (seen.has(entry.id)) {
      out.push(PluginIssue.create(PluginIssueCode.EntryIdDuplicated, `${path}.id`,
        `触发器 id「${entry.id}」在这一份清单里出现了两次。`));
      continue;
    }
    seen.add(entry.id);
    if (TriggerCatalog.find(entry.id) !== undefined) {
      out.push(PluginIssue.create(PluginIssueCode.EntryIdReserved, `${path}.id`,
        `触发器 id「${entry.id}」是内置触发器的 id，换一个。`));
      continue;
    }
    if (entry.scheduleKind === PluginScheduleKind.None) {
      // 不拦：留一个「装上但不响」的口子是允许的，扩展作者可能先发骨架。
      out.push(PluginIssue.create(PluginIssueCode.TriggerScheduleNone, `${path}.scheduleKind`,
        '这个触发器没有日程，装上之后永远不会触发。',
        PluginIssueSeverity.Warning));
      continue;
    }
    const detail: string = scheduleProblem(entry);
    if (detail.length > 0) {
      out.push(PluginIssue.create(PluginIssueCode.TriggerScheduleInvalid, `${path}.scheduleKind`,
        detail));
    }
  }
}

/** 日程参数的自洽性检查。没问题返回空串。 */
export function scheduleProblem(entry: TriggerExtension): string {
  if (entry.scheduleKind === PluginScheduleKind.Cron) {
    if (entry.cronExpression.trim().length === 0) {
      return 'scheduleKind 是 cron，但没写 cronExpression。';
    }
    const cron: CronExpression = CronExpression.parse(entry.cronExpression);
    if (!cron.valid) {
      return `cron 表达式「${entry.cronExpression}」解不出来：${cron.reason}`;
    }
    return '';
  }
  if (entry.scheduleKind === PluginScheduleKind.DailyAt) {
    if (entry.atSeconds < 0 || entry.atSeconds > 86399) {
      return `dailyAt 的 atSeconds 是 ${entry.atSeconds}，要落在 0~86399。`;
    }
    return '';
  }
  if (entry.scheduleKind === PluginScheduleKind.EveryMinutes) {
    if (entry.everyMinutes < 1 || entry.everyMinutes > 1440) {
      return `everyMinutes 是 ${entry.everyMinutes}，要落在 1~1440。`;
    }
    return '';
  }
  return '';
}

function validateActions(manifest: ExtensionManifest, sandbox: PluginSandbox,
  out: PluginIssue[]): void {
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < manifest.actions.length; i++) {
    const entry: ActionExtension = manifest.actions[i];
    const path: string = `actions[${i}]`;
    checkEntryCommon(entry.id, entry.name, path, manifest.actions.length, out);
    if (!checkEntryId(entry.id, `${path}.id`, out)) {
      continue;
    }
    if (seen.has(entry.id)) {
      out.push(PluginIssue.create(PluginIssueCode.EntryIdDuplicated, `${path}.id`,
        `行动 id「${entry.id}」在这一份清单里出现了两次。`));
      continue;
    }
    seen.add(entry.id);
    if (ActionCatalog.find(entry.id) !== undefined) {
      out.push(PluginIssue.create(PluginIssueCode.EntryIdReserved, `${path}.id`,
        `行动 id「${entry.id}」是内置行动的 id，换一个。`));
      continue;
    }
    if (entry.actionKind === PluginActionKind.None) {
      out.push(PluginIssue.create(PluginIssueCode.ActionKindUnsupported, `${path}.actionKind`,
        '这个行动没有类别，跑起来什么也不做。',
        PluginIssueSeverity.Warning));
      continue;
    }
    if (entry.actionKind === PluginActionKind.Notification) {
      if (entry.title.trim().length === 0 || entry.content.trim().length === 0) {
        out.push(PluginIssue.create(PluginIssueCode.ActionNotificationEmpty, path,
          '发通知的行动要同时写 title 和 content。'));
      }
      continue;
    }
    // ModifySetting
    if (entry.settingKey.trim().length === 0) {
      out.push(PluginIssue.create(PluginIssueCode.ActionSettingKeyNotWritable, `${path}.settingKey`,
        '改设置的行动没写 settingKey。'));
      continue;
    }
    if (!sandbox.writableSettingKeys.has(entry.settingKey)) {
      out.push(PluginIssue.create(PluginIssueCode.ActionSettingKeyNotWritable, `${path}.settingKey`,
        `设置键「${entry.settingKey}」不在允许改的名单里。` +
        '声明式扩展只能改应用明确开放给扩展的键。'));
    }
  }
}

function validateProviders(manifest: ExtensionManifest, out: PluginIssue[]): void {
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < manifest.notificationProviders.length; i++) {
    const entry: NotificationProviderExtension = manifest.notificationProviders[i];
    const path: string = `notificationProviders[${i}]`;
    checkEntryCommon(entry.id, entry.name, path, manifest.notificationProviders.length, out);
    if (!checkEntryId(entry.id, `${path}.id`, out)) {
      continue;
    }
    if (seen.has(entry.id)) {
      out.push(PluginIssue.create(PluginIssueCode.EntryIdDuplicated, `${path}.id`,
        `通知提供者 id「${entry.id}」在这一份清单里出现了两次。`));
      continue;
    }
    seen.add(entry.id);
    if (entry.triggerId.length > 0 && TriggerCatalog.find(entry.triggerId) === undefined) {
      out.push(PluginIssue.create(PluginIssueCode.ProviderTriggerUnknown, `${path}.triggerId`,
        `triggerId「${entry.triggerId}」不是已注册的触发器。`,
        PluginIssueSeverity.Warning));
    }
  }
}

function validateThemes(manifest: ExtensionManifest, out: PluginIssue[]): void {
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < manifest.themes.length; i++) {
    const entry: ThemeExtension = manifest.themes[i];
    const path: string = `themes[${i}]`;
    checkEntryCommon(entry.id, entry.name, path, manifest.themes.length, out);
    if (!checkEntryId(entry.id, `${path}.id`, out)) {
      continue;
    }
    if (seen.has(entry.id)) {
      out.push(PluginIssue.create(PluginIssueCode.EntryIdDuplicated, `${path}.id`,
        `主题 id「${entry.id}」在这一份清单里出现了两次。`));
      continue;
    }
    seen.add(entry.id);
    if (PLUGIN_THEME_MODES.indexOf(entry.mode) < 0) {
      out.push(PluginIssue.create(PluginIssueCode.ThemeModeUnknown, `${path}.mode`,
        `mode「${entry.mode}」不认识。可用：${PLUGIN_THEME_MODES.join('、')}。`));
    }
    if (entry.colors.size === 0) {
      out.push(PluginIssue.create(PluginIssueCode.ThemeColorsEmpty, `${path}.colors`,
        '主题一个颜色都没给。'));
      continue;
    }
    const bad: string[] = [];
    entry.colors.forEach((color: string, key: string) => {
      if (!isHexColor(color)) {
        bad.push(`${key}=${color}`);
      }
    });
    if (bad.length > 0) {
      out.push(PluginIssue.create(PluginIssueCode.ThemeColorInvalid, `${path}.colors`,
        `颜色写法不对：${bad.join('、')}。要 #RRGGBB 或 #AARRGGBB。`));
    }
  }
}

/** #RGB 之外只认 6 位与 8 位。3 位在桌面版主题里出现过，但 ArkUI 侧颜色统一走 8 位。 */
export function isHexColor(text: string): boolean {
  const trimmed: string = text.trim();
  if (trimmed.length !== 7 && trimmed.length !== 9) {
    return false;
  }
  if (trimmed.charAt(0) !== '#') {
    return false;
  }
  for (let i = 1; i < trimmed.length; i++) {
    const code: number = trimmed.charCodeAt(i);
    const isDigit: boolean = code >= 48 && code <= 57;
    const isUpper: boolean = code >= 65 && code <= 70;
    const isLower: boolean = code >= 97 && code <= 102;
    if (!isDigit && !isUpper && !isLower) {
      return false;
    }
  }
  return true;
}

/** 类别字段名（给界面分组显示用）。 */
export function extensionFieldOf(kind: ExtensionKind): string {
  return extensionKindField(kind);
}