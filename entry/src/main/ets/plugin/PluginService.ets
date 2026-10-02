/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 扩展的服务层：扫描装载、开关、卸载、导入导出。
 *
 * 进程内单例
 * ----------
 * 登记表（ExtensionRegistry 与三处目录的插件分区）是**进程级**静态状态，而它由
 * 本类在装载时重建。做两份实例就意味着两份登记表：设置页看到的扩展和自动化实际
 * 跑的扩展对不上，症状是「我明明装上了，组件列表里没有」。
 *
 * 生命周期跟着 Ability 走
 * ----------------------
 * 装配在 EntryAbility.onCreate（进程起来时），不随页面进出。组件面板是独立
 * 运行时（FormExtensionAbility），它自己跑自己那份 —— 引擎层没有跨实例可变状态，
 * 与 AppServices 里的 ViewModel 是同一个取舍。
 *
 * 白名单从哪来
 * ------------
 * 沙箱里「允许改哪些设置键」由 AppPreferences 声明（见那里的
 * PLUGIN_WRITABLE_SETTING_KEYS）。core 不复制一份名单：复制的那份迟早与真的
 * 偏好存储对不上，而对不上时的表现是「扩展改了个它不该改的设置」，极难排查。
 *
 * 装载失败不阻断其它扩展
 * --------------------
 * 一份扩展的清单坏了，那一个扩展不生效，其余照装（理由见 PluginValidation 顶上：
 * 另一个扩展先装好了，不该让后来这份彻底废掉）。装载期的问题按扩展聚成一条
 * PluginLoadIssue 显示在设置页，不弹提示 —— 装不上的扩展是它自己的问题，
 * 值得知道，但不该打断用户手头的事。
 */

import { common } from '@kit.AbilityKit';
import { t } from 'common_core';
import {
  ExtensionManifest,
  ExtensionManifestCodec,
  ExtensionRegistry,
  MAX_MANIFEST_TEXT_LENGTH,
  PluginInstallResult,
  PluginIssue,
  PluginRecord,
  PluginSandbox,
  defaultPluginSandbox,
  installPlugin,
  uninstallAllPlugins,
  uninstallPlugin
} from 'common_core';
import { PLUGIN_WRITABLE_SETTING_KEYS } from '../common/AppPreferences';
import { PluginStore, ManifestReadResult } from '../data/PluginStore';

/** 装载期某个扩展出的问题（一行 = 一个扩展）。 */
export class PluginLoadIssue {
  pluginId: string = '';
  /** 人话说明，直接显示。 */
  reason: string = '';
}

export class PluginService {
  private readonly store: PluginStore;
  private readonly sandbox: PluginSandbox;
  private issues: PluginLoadIssue[] = [];
  private summary: string = '';

  /**
   * @param context UIAbility 的 context，提供 filesDir
   */
  constructor(context: common.UIAbilityContext) {
    this.store = new PluginStore(context.filesDir);
    this.sandbox = defaultPluginSandbox();
    for (const key of PLUGIN_WRITABLE_SETTING_KEYS) {
      this.sandbox.writableSettingKeys.add(key);
    }
  }

  /**
   * 全量重新装载：先全卸，再按盘上的目录逐个装。
   *
   * 全量重建而不是「只装新增的」，因为登记表是静态状态：少一个目录文件、一次
   * 开关翻转，都会让「增量维护」比「重建」更容易算错。重建只是几十次目录读 +
   * 几份 JSON 解析，在启动路径上做一次完全不疼。
   */
  loadAll(): void {
    this.issues = [];
    uninstallAllPlugins();
    // 执行前的二次白名单判据（清单校验时也判过，但那份判据是「校验那一刻」的；
    // 这一份是「执行那一刻」生效的，两处必须是同一份名单）。见 PluginActionEval 顶上。
    ExtensionRegistry.setWritableSettingKeys(PLUGIN_WRITABLE_SETTING_KEYS);

    for (const pluginId of this.store.installedIds()) {
      const read: ManifestReadResult = this.store.readManifest(pluginId);
      if (read.manifest === undefined) {
        this.setIssue(pluginId, read.note);
        continue;
      }
      // 目录名与清单里的 id 不一致时以**清单**为准。反过来（以目录名为准）的
      // 症状是「装上了但设置页里找不到」—— 用户改一份清单的 id 再放进自己的
      // 目录就会撞上，所以判据必须是清单内容。
      const manifest: ExtensionManifest = read.manifest;
      const result: PluginInstallResult = installPlugin(manifest, this.sandbox);
      if (read.note.length > 0) {
        // 用了备份要报。清单是用户可改的文件，被截断的症状是「我改的文案变了
        // 回去」，不报的话用户只能靠猜。
        this.setIssue(manifest.id, read.note);
      } else if (!result.loaded) {
        this.setIssue(manifest.id, result.reason);
      } else if (result.reason.length > 0) {
        // 装上了但有条目被跳过（core 那边已经把条数算清并写成一句话了）
        this.setIssue(manifest.id, result.reason);
      }
      // 开关：装完再关。反过来的话 setEnabled 会因为「记录还没进注册表」而
      // 找不到它，于是关不掉 —— 而「关掉」是用户在设置页最常做的事。
      if (!this.store.isEnabled(manifest.id)) {
        ExtensionRegistry.setEnabled(manifest.id, false);
      }
    }
    this.summary = ExtensionRegistry.summaryText();
  }

  /** 全部扩展记录，按登记顺序。 */
  records(): PluginRecord[] {
    return ExtensionRegistry.plugins();
  }

  /** 装载期出的问题。正常时是空数组。 */
  loadIssues(): PluginLoadIssue[] {
    return this.issues;
  }

  /** 一行摘要（「3 个扩展在用」/「没有安装扩展」）。 */
  summaryText(): string {
    return this.summary;
  }

  /** 是否已落盘（不管它当前装没装上）。 */
  isInstalled(pluginId: string): boolean {
    return this.store.isInstalled(pluginId);
  }

  /**
   * 某扩展的校验/冲突问题明细。
   *
   * 与 loadIssues 的分工：这里给的是「一条条的问题」，用于展开某个扩展的详情；
   * 那里给的是「一行一个扩展的摘要」，用于列表。两者都从 record.issues 来，
   * 所以不会出现「列表说有 2 条、展开一条没有」的情况。
   */
  issuesOf(pluginId: string): PluginIssue[] {
    const record: PluginRecord | undefined = ExtensionRegistry.findPlugin(pluginId);
    return record === undefined ? [] : record.issues;
  }

  /**
   * 开关一个扩展。
   *
   * 落盘 + 立刻生效。setEnabled 是唯一的开关入口 —— 直接改 record.enabled 不会
   * 重摊条目表，登记表里会留着它的条目，于是「关掉的扩展的组件还能用」。
   *
   * @returns 状态确实变了返回 true。
   * @throws 落盘失败时抛出。此时内存状态也没改，避免界面上看着关掉了、
   *   下次启动又开回来。
   */
  setEnabled(pluginId: string, enabled: boolean): boolean {
    if (!this.store.isInstalled(pluginId)) {
      return false;
    }
    this.store.writeEnabled(pluginId, enabled);
    return ExtensionRegistry.setEnabled(pluginId, enabled);
  }

  /**
   * 卸载一个扩展：摘条目 + 删目录。
   *
   * 摘条目按 record.attached* 逐条来（core 的 uninstallPlugin 负责），所以卸 B
   * 不会顺手摘掉 A 的条目 —— 两者共用一个 id 时那在面板上看起来就是「卸载了 B，
   * A 的组件也消失了」。
   *
   * @returns 之前确实在盘上返回 true。
   * @throws 删目录失败时抛出。此时条目已摘而目录还在，下次启动会重新装上它 ——
   *   这是「卸载没成功」而不是「装坏了」，所以错误文案要让人敢重试。
   */
  uninstall(pluginId: string): boolean {
    if (!this.store.isInstalled(pluginId)) {
      return false;
    }
    this.store.remove(pluginId);
    uninstallPlugin(pluginId);
    this.dropIssue(pluginId);
    this.summary = ExtensionRegistry.summaryText();
    return true;
  }

  /**
   * 从清单文本装一个扩展：先落盘，再装载。
   *
   * 先落盘是为了「装不上也能留着看」：头部被拒（版本不认、id 非法）时目录仍然
   * 在，设置页能列出它的问题，用户改一行 apiVersion 就能重试。反过来（装成功才
   * 落盘）的话，装不上的扩展凭空消失，用户连「它到底写了什么」都无从知道。
   *
   * 同一个 id 再装一次是**覆盖**：目录整个被换掉，而扩展在列表里的位置不变
   * （core 的 installPlugin 只摘条目、不删记录）。这就是「升级」的语义。
   *
   * @returns 装载结果；调用方据 loaded / reason 决定显示什么。
   * @throws 文本不是 JSON 对象、超出体积上限、或落盘失败时抛出。
   */
  installFromText(text: string): PluginInstallResult {
    if (text.length > MAX_MANIFEST_TEXT_LENGTH) {
      throw new Error(`扩展清单太大：${text.length} 字符，上限 ${MAX_MANIFEST_TEXT_LENGTH}。`);
    }
    const manifest: ExtensionManifest | undefined = ExtensionManifestCodec.parseText(text);
    if (manifest === undefined) {
      throw new Error('扩展清单的顶层不是 JSON 对象。');
    }
    this.store.writeManifest(manifest);
    const result: PluginInstallResult = installPlugin(manifest, this.sandbox);
    if (result.loaded) {
      // 新装的一律默认启用。importPlugin 装上就意味着用户想用它，而「装上即关」
      // 的成因只有一个：上一次的 state.json 还在。这个覆盖是升级语义的一部分
      // （新版装上就该生效），所以在写 state.json 之前不查旧值。
      this.store.writeEnabled(manifest.id, true);
      ExtensionRegistry.setEnabled(manifest.id, true);
      this.dropIssue(manifest.id);
    } else {
      this.setIssue(manifest.id, result.reason);
    }
    this.summary = ExtensionRegistry.summaryText();
    return result;
  }

  /**
   * 导出清单文本（缩进 2，字段顺序固定）。
   *
   * 给回盘上那份清单解析后的结果，**不含** enabled —— 导出的是扩展本身，不是
   * 本机对它的开关状态。理由见 PluginStore 顶上。
   *
   * @throws 清单读不出来时抛出。
   */
  exportTextOf(pluginId: string): string {
    const read: ManifestReadResult = this.store.readManifest(pluginId);
    if (read.manifest === undefined) {
      throw new Error(`扩展 ${pluginId} 的清单读不出来：${read.note}`);
    }
    return ExtensionManifestCodec.writeText(read.manifest, 2);
  }

  // ------------------------------------------------------------ 问题清单

  /** 记一条问题。同一个扩展只留最新的一条。 */
  private setIssue(pluginId: string, reason: string): void {
    this.dropIssue(pluginId);
    const out: PluginLoadIssue = new PluginLoadIssue();
    out.pluginId = pluginId;
    out.reason = reason.length > 0 ? reason : t('ps_unknown');
    this.issues.push(out);
  }

  /** 去掉某个扩展的问题（卸载、重新装上之后用）。 */
  private dropIssue(pluginId: string): void {
    const kept: PluginLoadIssue[] = [];
    for (const issue of this.issues) {
      if (issue.pluginId !== pluginId) {
        kept.push(issue);
      }
    }
    this.issues = kept;
  }
}

let instance: PluginService | undefined = undefined;

/**
 * 取进程内唯一的扩展服务，首次调用时装配并装载。
 *
 * @param context UIAbility 的 context
 */
export function resolvePluginService(context: common.UIAbilityContext): PluginService {
  if (instance === undefined) {
    instance = new PluginService(context);
    instance.loadAll();
  }
  return instance;
}

/** 丢掉扩展服务，下次 resolve 重新装配。 */
export function resetPluginService(): void {
  instance = undefined;
}
