/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 设置页「扩展」分组里的一行。
 *
 * 为什么是普通类而不是 @Observed
 * ------------------------------
 * 这一行整体来自 PluginRecord，而记录是「整体替换」的（见 PluginService）：
 * 任何一次改动都重建整个数组。给行加 @Trace 不会让刷新更及时，只会让每个字段
 * 多一层可观测包装 —— 而这一行里有一半字段（描述、问题明细）是只读的。
 *
 * 与 RulesetEditModel 的 RuleEditRow 同一个取舍。
 */

import { t, tf } from 'common_core';
import { ExtensionManifest, PluginIssue, PluginRecord } from 'common_core';
import { PluginLoadIssue } from './PluginService';

export class PluginListRow {
  pluginId: string = '';
  name: string = '';
  version: string = '';
  author: string = '';
  description: string = '';
  enabled: boolean = true;
  loaded: boolean = false;
  entryCount: number = 0;
  /** 没装上时的说明，空串表示一切正常。 */
  reason: string = '';
  /** 装载期的问题（一行一个扩展）。与 issues 的分工见 PluginService.issuesOf。 */
  loadIssue: string = '';
  /** 校验与冲突问题，逐条。 */
  issues: PluginIssue[] = [];
  /** 展开显示详情。 */
  expanded: boolean = false;
  /** 声明了几类条目 —— 「声明了什么」明细用。 */
  declaredComponents: number = 0;
  declaredTriggers: number = 0;
  declaredActions: number = 0;
  declaredProviders: number = 0;
  declaredThemes: number = 0;

  static from(record: PluginRecord,
    loadIssue: PluginLoadIssue | undefined): PluginListRow {
    const out: PluginListRow = new PluginListRow();
    out.pluginId = record.pluginId;
    out.name = record.name;
    out.version = record.version;
    out.author = record.author;
    out.description = record.description;
    out.enabled = record.enabled;
    out.loaded = record.loaded;
    out.entryCount = record.entryCount;
    out.reason = record.reason;
    out.issues = record.issues;
    out.loadIssue = loadIssue === undefined ? '' : loadIssue.reason;
    const manifest: ExtensionManifest | undefined = record.manifest;
    if (manifest !== undefined) {
      out.declaredComponents = manifest.components.length;
      out.declaredTriggers = manifest.triggers.length;
      out.declaredActions = manifest.actions.length;
      out.declaredProviders = manifest.notificationProviders.length;
      out.declaredThemes = manifest.themes.length;
    }
    return out;
  }

  /** 列表上显示的名字：没名字时用 id，别留一个空行。 */
  displayName(): string {
    return this.name.length > 0 ? this.name : this.pluginId;
  }

  /** 副标题：版本 + 作者。两者都没有时给状态，那一行此时更有信息量。 */
  subtitle(): string {
    const parts: string[] = [];
    if (this.version.length > 0) {
      parts.push(`v${this.version}`);
    }
    if (this.author.length > 0) {
      parts.push(this.author);
    }
    if (parts.length > 0) {
      return parts.join(' · ');
    }
    return this.statusText();
  }

  /** 状态行：装上了几条 / 为什么没装上。 */
  statusText(): string {
    if (!this.loaded) {
      return this.reason.length > 0 ? this.reason : t('plrow_not_loaded');
    }
    if (this.entryCount === 0) {
      return t('plrow_no_entries');
    }
    return tf('plrow_installed', `${this.entryCount}`);
  }

  /** 问题明细（装载期 + 校验/冲突），给展开区用。 */
  issueLines(): string[] {
    const out: string[] = [];
    if (this.loadIssue.length > 0) {
      out.push(this.loadIssue);
    }
    for (const issue of this.issues) {
      const where: string = issue.path.length > 0 ? `${issue.path}：` : '';
      out.push(`${where}${issue.message}`);
    }
    return out;
  }

  /** 「声明了什么」明细。 */
  declaredText(): string {
    const parts: string[] = [];
    if (this.declaredComponents > 0) {
      parts.push(tf('plrow_declared_components', `${this.declaredComponents}`));
    }
    if (this.declaredTriggers > 0) {
      parts.push(tf('plrow_declared_triggers', `${this.declaredTriggers}`));
    }
    if (this.declaredActions > 0) {
      parts.push(tf('plrow_declared_actions', `${this.declaredActions}`));
    }
    if (this.declaredProviders > 0) {
      parts.push(tf('plrow_declared_providers', `${this.declaredProviders}`));
    }
    if (this.declaredThemes > 0) {
      parts.push(tf('plrow_declared_themes', `${this.declaredThemes}`));
    }
    return parts.length === 0 ? t('plrow_declared_none') : parts.join('、');
  }
}
