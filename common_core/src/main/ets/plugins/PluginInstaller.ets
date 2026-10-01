/*
 * 清单 → 运行期注册表（装 / 卸 / 开关）。
 *
 * 这一层做什么、不做什么
 * ----------------------
 * 做：把校验通过的一份清单变成「ComponentCatalog / TriggerCatalog /
 * ActionCatalog 里多了几条」，以及反向的全部摘掉。
 *
 * 不做：不碰文件（那是 entry 的 PluginStore）、不碰通知与系统能力。
 * 于是整个装载过程能进 Node 测试台 —— 「装一个扩展 → 面板能选到 → 卸掉 →
 * 面板立刻认不出」这条链是可以断言的，而它是 P12 最容易坏的地方（注册表
 * 三处各自持有条目，摘漏一处就留下一个永远悬空的 id）。
 *
 * 为什么冲突走「跳过并记账」而不是抛
 * ---------------------------------
 * 一批扩展里第 3 条撞了 id，不该让第 1、2 条也装不上。所以每条独立 try，
 * 冲突的记成 PluginIssue 挂在那个扩展上，扩展整体仍算「装上了（有 2 条没用上）」。
 * 只有**整份清单**被拒（版本不认、id 不合法）才完全不装 —— 那时候后面的条目
 * 根本没有意义。
 *
 * 部分装载的状态怎么表达
 * ---------------------
 * PluginRecord.loaded 表示「这份清单的头部被接受了」，entryCount 是实际生效的条数。
 * 于是「装上了但有 3 条没用上」在设置页显示为「已启用 · 5 条可用（3 条冲突）」，
 * 而不是笼统的「安装失败」。
 */

import {
  ActionCatalog,
  ActionInfo,
  ActionSettingsKind,
  ActionSupport
} from '../automation/ActionCatalog';
import {
  TriggerCatalog,
  TriggerInfo,
  TriggerSettingsKind,
  TriggerSupport
} from '../automation/TriggerCatalog';
import {
  ComponentCatalog,
  ComponentDescriptor,
  componentDecoderOfKind
} from '../components/ComponentCatalog';
import { ComponentPayload } from '../components/ComponentPayloads';
import { JsonObject } from 'common_shared';
import {
  ActionExtension,
  ComponentExtension,
  ExtensionKind,
  ExtensionManifest,
  NotificationProviderExtension,
  ThemeExtension,
  TriggerExtension
} from './PluginManifest';
import { PluginActionPlan, settingsOfActionExtension } from './PluginActionEval';
import { PluginSchedule, settingsOfTriggerExtension } from './PluginSchedule';
import { ExtensionRegistry, PluginRecord } from './ExtensionRegistry';
import {
  PluginIssue,
  PluginIssueCode,
  PluginIssueSeverity,
  PluginSandbox,
  blockingIssues,
  hasBlockingIssues,
  validateManifest
} from './PluginValidation';

/** 一次装载的结果。设置页拿它显示「装了什么、有什么问题」。 */
export class PluginInstallResult {
  /** 扩展 id。 */
  pluginId: string = '';
  /** 是否登记成功（= 头部被接受）。 */
  loaded: boolean = false;
  /** 实际生效的条目数。 */
  entryCount: number = 0;
  /** 校验问题（含装载期新增的冲突类）。 */
  issues: PluginIssue[] = [];
  /** 一句话说明，写进 PluginRecord.reason。 */
  reason: string = '';
}

/**
 * 装一个扩展。
 *
 * 已有同名扩展会先被卸掉再装新的一份 —— 「重装」是常见操作（改完清单再导入），
 * 不先卸会在注册表里撞 id，于是用户看到「装不上」而实际上是他自己刚装过一次。
 */
export function installPlugin(manifest: ExtensionManifest,
  sandbox: PluginSandbox): PluginInstallResult {
  const out: PluginInstallResult = new PluginInstallResult();
  out.pluginId = manifest.id;

  // 先把同名扩展的条目摘掉，让重装不撞自己；但**不删记录** ——
  // 删了记录再 putPlugin 就会把它挪到列表末尾，而「重装一下」是用户在设置页
  // 反复会做的操作，不该每次都把扩展排到列表最后面。
  detachEntries(manifest.id);

  const issues: PluginIssue[] = validateManifest(manifest, sandbox);
  out.issues = issues;
  if (hasBlockingIssues(issues)) {
    out.reason = blockingIssues(issues)[0].message;
    const rejected: PluginRecord = makeRecord(manifest, false, 0, out.reason);
    rejected.issues = issues;
    ExtensionRegistry.putPlugin(rejected);
    return out;
  }

  const conflicts: PluginIssue[] = [];
  const record: PluginRecord = makeRecord(manifest, true, 0, '');
  let count: number = 0;
  count += installComponents(manifest, conflicts, record.attachedComponents);
  count += installTriggers(manifest, conflicts, record.attachedTriggers);
  count += installActions(manifest, conflicts, record.attachedActions);
  count += countProviders(manifest, conflicts);
  count += countThemes(manifest, conflicts);

  out.issues = issues.concat(conflicts);
  out.loaded = true;
  out.entryCount = count;
  out.reason = count === 0 ? '这份清单一个可用条目都没装上。'
    : conflicts.length === 0 ? '' : `${conflicts.length} 条条目因为冲突或非法被跳过。`;
  record.entryCount = count;
  record.reason = out.reason;
  record.issues = out.issues;
  ExtensionRegistry.putPlugin(record);
  return out;
}

/**
 * 卸一个扩展，连带把它的条目从三处注册表里摘掉。
 *
 * 从 record.manifest 逐条摘，而不是查注册表的条目表：条目表只摊开「加载成功且
 * 用户没关掉」的扩展，所以一个**被关掉**的扩展在那里查不到任何条目 —— 而它关掉
 * 时如果已经注册过（关掉 → 重装 → 又是关掉的），条目就会留在注册表里变成悬空 id，
 * 面板上那些位置既不认得也删不掉。manifest 是权威来源，不受 enabled 影响。
 */
export function uninstallPlugin(pluginId: string): boolean {
  const existed: boolean = detachEntries(pluginId);
  // removePlugin 返回 false 说明本来就没这个扩展，但那时它也不可能有条目，
  // 所以「存在过就算卸成功」是对的口径。
  ExtensionRegistry.removePlugin(pluginId);
  return existed;
}

/**
 * 只把条目从三处注册表里摘掉，保留扩展记录本身。
 *
 * 卸载（连记录一起删）与重装（只摘条目）共用的那一步。摘哪些条目看
 * record.attached*，不看注册表的条目表 —— 后者只摊开「加载成功且用户没关掉」的
 * 扩展，一个被关掉的扩展在那里查不到任何条目，卸载就会漏下一批悬空 id。
 */
function detachEntries(pluginId: string): boolean {
  const record: PluginRecord | undefined = ExtensionRegistry.findPlugin(pluginId);
  if (record === undefined) {
    return false;
  }
  // 只摘 attached* —— 清单里「声明了但被跳过」的条目不归这个扩展所有，
  // 摘它会连带把先装的那个扩展的条目拆掉（详见 PluginRecord.attachedComponents）。
  for (const id of record.attachedComponents) {
    ComponentCatalog.unregister(id);
  }
  for (const id of record.attachedTriggers) {
    TriggerCatalog.unregister(id);
  }
  for (const id of record.attachedActions) {
    ActionCatalog.unregister(id);
  }
  return true;
}

/** 全清。装载前调一次，保证重装后不残留上一次的条目。 */
export function uninstallAllPlugins(): void {
  ComponentCatalog.unregisterAllPlugins();
  TriggerCatalog.unregisterAll();
  ActionCatalog.unregisterAll();
  ExtensionRegistry.clear();
}

function makeRecord(manifest: ExtensionManifest, loaded: boolean, entryCount: number,
  reason: string): PluginRecord {
  const out: PluginRecord = new PluginRecord();
  out.pluginId = manifest.id;
  out.name = manifest.name;
  out.version = manifest.version;
  out.description = manifest.description;
  out.author = manifest.author;
  out.loaded = loaded;
  out.entryCount = entryCount;
  out.reason = reason;
  out.manifest = manifest;
  return out;
}

// ------------------------------------------------------------------ 各类条目

/**
 * 声明式组件 → ComponentCatalog。
 *
 * decode 直接借用对应渲染类别的内置解码器：扩展给的是「新 id + 老渲染器」，
 * 所以 payloadKind 决定了走哪一条 decode 分支，与用户从面板里拖一个内置组件
 * 出来的结果完全一致。
 *
 * hasSettings 一律 true（即使内置那个渲染类别本来无设置，如 separator / date）：
 * 声明式组件总是带一份 settings（扩展作者可以什么都不写，得到一个空对象），
 * 差别在于「空对象解码成默认值」而不是「不写节点」—— 后者会让组件在档案里
 * 少一个字段，而桌面版的 ComponentSettings.Settings 本来就允许为 null。
 * 这里选前者，理由是解码路径只有一条，少一个分支就少一类「面板上空白」。
 */
function installComponents(manifest: ExtensionManifest, conflicts: PluginIssue[],
  attached: string[]): number {
  let count: number = 0;
  for (let i = 0; i < manifest.components.length; i++) {
    const entry: ComponentExtension = manifest.components[i];
    const path: string = `components[${i}]`;
    const decode = componentDecoderOfKind(entry.payloadKind);
    if (decode === undefined) {
      // 校验阶段应该已经报过；到这里说明有人绕过校验直接塞了清单。
      conflicts.push(PluginIssue.create(PluginIssueCode.ComponentKindUnknown, `${path}.payloadKind`,
        `payloadKind「${entry.payloadKind}」不认识，这条组件被跳过。`,
        PluginIssueSeverity.Warning));
      continue;
    }
    const descriptor: ComponentDescriptor = ComponentDescriptor.create(entry.id, entry.name,
      entry.description, true, entry.payloadKind === 'group' || entry.payloadKind === 'stack',
      decode, entry.settings);
    if (!ComponentCatalog.registerPlugin(descriptor)) {
      conflicts.push(PluginIssue.create(PluginIssueCode.EntryIdReserved, `${path}.id`,
        `组件 id「${entry.id}」已经被占用（内置组件或另一个扩展），这条被跳过。`,
        PluginIssueSeverity.Warning));
      continue;
    }
    attached.push(entry.id);
    count++;
  }
  return count;
}

/**
 * 声明式触发器 → TriggerCatalog。
 *
 * 一律 Implemented：声明式日程在鸿蒙侧是能算的（P12 的三种日程 + 轮询）。
 * 与「内置但未实现」那档不同 —— 那档的理由写的是「这个功能在这台设备上不存在」，
 * 而声明式日程不存在这个问题。
 */
function installTriggers(manifest: ExtensionManifest, conflicts: PluginIssue[],
  attached: string[]): number {
  let count: number = 0;
  for (let i = 0; i < manifest.triggers.length; i++) {
    const entry: TriggerExtension = manifest.triggers[i];
    const info: TriggerInfo = new TriggerInfo();
    info.id = entry.id;
    info.name = entry.name;
    info.support = TriggerSupport.Implemented;
    info.settingsKind = TriggerSettingsKind.Plugin;
    info.canRevert = false;
    if (!TriggerCatalog.registerPlugin(info)) {
      conflicts.push(PluginIssue.create(PluginIssueCode.EntryIdReserved, `triggers[${i}].id`,
        `触发器 id「${entry.id}」已经被占用，这条被跳过。`,
        PluginIssueSeverity.Warning));
      continue;
    }
    attached.push(entry.id);
    count++;
  }
  return count;
}

/**
 * 声明式行动 → ActionCatalog。
 *
 * isRevertable 一律 false：桌面版只有 ModifyAppSettingsAction 覆写了 OnRevert，
 * 而扩展的行动是发通知或改设置 —— 改设置理论上可回滚，但声明式动作没法表达
 * 「原来的值是什么」（清单里只有 settingValue，没有旧值），所以不给回滚能力。
 * 这与「未实现」是两回事：这一档能执行，只是不可撤销。
 */
function installActions(manifest: ExtensionManifest, conflicts: PluginIssue[],
  attached: string[]): number {
  let count: number = 0;
  for (let i = 0; i < manifest.actions.length; i++) {
    const entry: ActionExtension = manifest.actions[i];
    const info: ActionInfo = new ActionInfo();
    info.id = entry.id;
    info.name = entry.name;
    info.support = ActionSupport.Implemented;
    info.settingsKind = ActionSettingsKind.Plugin;
    info.isRevertable = false;
    if (!ActionCatalog.registerPlugin(info)) {
      conflicts.push(PluginIssue.create(PluginIssueCode.EntryIdReserved, `actions[${i}].id`,
        `行动 id「${entry.id}」已经被占用，这条被跳过。`,
        PluginIssueSeverity.Warning));
      continue;
    }
    attached.push(entry.id);
    count++;
  }
  return count;
}

/**
 * 通知提供者只记账，不注册。
 *
 * 它需要一个「产生通知的运行时」，而声明式做不到（取数要执行代码）。
 * 但它是清单里**唯一**没有运行时对应物的一类，所以这里也把它算进 entryCount ——
 * 否则用户装了个带通知提供者的扩展，看到「0 条可用」会以为装坏了。
 */
function countProviders(manifest: ExtensionManifest, conflicts: PluginIssue[]): number {
  let count: number = 0;
  for (let i = 0; i < manifest.notificationProviders.length; i++) {
    const entry: NotificationProviderExtension = manifest.notificationProviders[i];
    if (entry.id.length === 0) {
      conflicts.push(PluginIssue.create(PluginIssueCode.EntryIdMissing,
        `notificationProviders[${i}].id`, '通知提供者没写 id，这条被跳过。',
        PluginIssueSeverity.Warning));
      continue;
    }
    count++;
  }
  return count;
}

/** 主题同样只记账（配色是给用户看的说明，不是应用真的会读它）。 */
function countThemes(manifest: ExtensionManifest, conflicts: PluginIssue[]): number {
  let count: number = 0;
  for (let i = 0; i < manifest.themes.length; i++) {
    const entry: ThemeExtension = manifest.themes[i];
    if (entry.id.length === 0) {
      conflicts.push(PluginIssue.create(PluginIssueCode.EntryIdMissing, `themes[${i}].id`,
        '主题没写 id，这条被跳过。', PluginIssueSeverity.Warning));
      continue;
    }
    count++;
  }
  return count;
}

/**
 * 新建一条扩展触发器时带的设置。
 *
 * 不做 `instanceof PluginSchedule` 的判定：Node 测试台里 core 会被加载成两个模块
 * 实例（driver 直引源码、而 core 内部按 `'common_core'` 解析），两个实例的
 * PluginSchedule 类不是同一个，用 instanceof 会恒为 false。所以改成按「是对象
 * 且有 kind 字段」判定——那条路径不依赖类身份。
 */
export function defaultSettingsOfPluginTrigger(triggerId: string): PluginSchedule {
  const found: Object | undefined = TriggerCatalog.defaultSettingsOf(triggerId);
  if (found === undefined) {
    return new PluginSchedule();
  }
  const asSchedule: PluginSchedule = found as PluginSchedule;
  return asSchedule.kind === undefined ? new PluginSchedule() : asSchedule;
}

/** 新建一条扩展行动时带的设置。同上，不做 instanceof。 */
export function defaultSettingsOfPluginAction(actionId: string): PluginActionPlan {
  const found: Object | undefined = ActionCatalog.defaultSettingsOf(actionId);
  if (found === undefined) {
    return new PluginActionPlan();
  }
  const asPlan: PluginActionPlan = found as PluginActionPlan;
  return asPlan.kind === undefined ? new PluginActionPlan() : asPlan;
}

/** 提醒级别供设置页区分「装上但不生效」的条目。 */
export const PLUGIN_INACTIVE_REMINDER: string =
  '声明式通知提供者与主题只登记元信息，本版本没有对应的运行时。';

/** 一条提醒（供设置页复用）。 */
export function inactiveReminder(): PluginIssue {
  return PluginIssue.create(PluginIssueCode.NothingDeclared, '', PLUGIN_INACTIVE_REMINDER,
    PluginIssueSeverity.Warning);
}
