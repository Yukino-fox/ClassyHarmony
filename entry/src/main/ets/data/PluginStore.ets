/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 扩展清单的落盘仓库：一个扩展一个目录。
 *
 * 目录形状
 * --------
 *   filesDir/plugins/<扩展 id>/manifest.json   清单本体（camelCase，与桌面版 .cipx 里的字段同义不同名）
 *   filesDir/plugins/<扩展 id>/manifest.json.bak
 *   filesDir/plugins/<扩展 id>/state.json      开关状态（我们自己的，不属于清单）
 *
 * 为什么每个扩展一个目录而不是一张 plugins.json
 * --------------------------------------------
 * 汇总成一张表的话，装/卸都要「读整表 → 改一个键 → 写整表」。装扩展和自动化
 * 每秒 tick 走的是不同的线程（后者还会在读档案的间隙里跑），一张表就意味着
 * 一处写坏全丢：装第三个扩展时手滑，用户的两个也没了。一个扩展一个文件，写坏
 * 只坏那一个，而那个扩展的表现是「它不见了」，用户重装一次就回来了。
 *
 * state.json 为什么不写进清单
 * --------------------------
 * 清单是扩展作者写的东西，我们会原样导出给他。掺进一个 `enabled` 字段，导出
 * 出去的文件就带着别人机器上的开关状态，而下次再导入时那个字段还在 —— 于是
 * 「导入一个在别人机器上被关掉的扩展」会得到一个装上但不生效的东西。分开写，
 * 导入的永远是干净的启用状态。
 *
 * 清单读不出来时不静默跳过
 * ------------------------
 * 别的仓库（档案、面板）在这件事上会回退 .bak。这里也回退，但**必须让用户
 * 知道用了备份**：一份被截断的清单和一个多版本前的清单，症状都是「我改的文案
 * 变了回去」，而用户不会去猜这两件事的区别。所以 readManifest 除了清单本身还
 * 给一句人话说明，由 PluginService 记进装载问题里显示在设置页。
 *
 * 目录名就是扩展 id
 * ----------------
 * 于是目录名天然受 isValidPluginId 约束（只允许小写字母数字点横线），`/../`
 * 这类内容进不来 —— 这与「id 会出现在路径上」是同一件事的两面，所以过滤放在
 * 读目录名的那一步，不放在拼路径的那一步。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { JsonBoolean, JsonObject, JsonReader, JsonValue, JsonWriter } from 'common_shared';
import { ExtensionManifest, ExtensionManifestCodec, isValidPluginId, t, tf } from 'common_core';

/** plugins 目录名。与桌面版 AppConfigPath/Plugins 的角色对应，但布局是本端自己的。 */
const DIR_NAME: string = 'plugins';
/** 清单文件名。 */
const MANIFEST_NAME: string = 'manifest.json';
/** 开关状态文件名。 */
const STATE_NAME: string = 'state.json';
const TEMP_SUFFIX: string = '.tmp';
const BACKUP_SUFFIX: string = '.bak';

/**
 * 读清单的结果。
 *
 * 之所以不只返回清单，是因为「这份清单是从 .bak 读出来的」这件事必须能传给
 * 用户 —— 返回类型里少一个出口，调用方就只好假装没这回事。
 */
export class ManifestReadResult {
  /** 读出来的清单；主文件与备份都不可用时为 undefined。 */
  manifest: ExtensionManifest | undefined = undefined;
  /** 需要让用户知道的情况；一切正常时是空串。 */
  note: string = '';
}

export class PluginStore {
  private readonly filesDir: string;

  constructor(filesDir: string) {
    this.filesDir = filesDir;
  }

  /** plugins 根目录。 */
  rootDir(): string {
    return `${this.filesDir}/${DIR_NAME}`;
  }

  /** 某个扩展的目录。 */
  dirOf(pluginId: string): string {
    return `${this.rootDir()}/${pluginId}`;
  }

  /** 某个扩展的清单路径。 */
  manifestPathOf(pluginId: string): string {
    return `${this.dirOf(pluginId)}/${MANIFEST_NAME}`;
  }

  /**
   * 建出某个扩展的目录。
   *
   * 不递归：父目录是 filesDir 下我们自己的一层，先建根再建子，顺序固定，
   * 「根建不出来」与「子建不出来」是两回事，混成一个递归调用就分不清了。
   *
   * @returns 目录可用返回 true。
   */
  ensureDirOf(pluginId: string): boolean {
    const root: string = this.rootDir();
    try {
      if (!this.isDir(root) && !fs.accessSync(root)) {
        fs.mkdirSync(root);
      }
    } catch (err) {
      return false;
    }
    const dir: string = this.dirOf(pluginId);
    try {
      if (!this.isDir(dir) && !fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      return this.isDir(dir);
    } catch (err) {
      return false;
    }
  }

  /**
   * 已装扩展的 id 列表，按 id 升序。
   *
   * 排序不是为了好看：目录遍历顺序由文件系统决定，而扩展的装载顺序会决定
   * 「清单内重名时谁赢」。不排序的话，同一份配置在两台设备上可能装出不同的
   * 赢家，而那种差异只有在用户对比两台机器时才显现。
   *
   * 目录不存在时返回空数组（还没装过任何扩展是正常状态，不是错误）。
   */
  installedIds(): string[] {
    const root: string = this.rootDir();
    if (!this.isDir(root)) {
      return [];
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(root);
    } catch (err) {
      return [];
    }
    const out: string[] = [];
    for (const name of names) {
      // 目录名就是扩展 id，所以这里的校验同时挡住了非法路径与不认识的目录
      if (isValidPluginId(name) && out.indexOf(name) < 0) {
        out.push(name);
      }
    }
    out.sort();
    return out;
  }

  /** 某个扩展是否已落盘。 */
  isInstalled(pluginId: string): boolean {
    return this.readable(this.manifestPathOf(pluginId));
  }

  /**
   * 读清单。主文件坏了就回退 .bak，并在 note 里说清用的是备份。
   *
   * 两份都读不出来时返回 manifest 为 undefined、note 说明原因，**不抛**：
   * 装载 N 个扩展时其中一个坏了，不该让另外 N-1 个也一起装不上。
   */
  readManifest(pluginId: string): ManifestReadResult {
    const out: ManifestReadResult = new ManifestReadResult();
    const path: string = this.manifestPathOf(pluginId);
    if (!this.readable(path)) {
      out.note = tf('ps_manifest_missing', path);
      return out;
    }
    try {
      out.manifest = this.readManifestFile(path);
      this.refreshBackup(path);
      return out;
    } catch (primaryError) {
      const backup: string = `${path}${BACKUP_SUFFIX}`;
      if (!this.readable(backup)) {
        out.note = tf('ps_manifest_unreadable', path);
        return out;
      }
      try {
        out.manifest = this.readManifestFile(backup);
        out.note = tf('ps_manifest_corrupt', pluginId);
        // 备份能用就把它写回主文件，免得下次启动又撞上同一份坏数据
        if (out.manifest !== undefined) {
          this.writeAtomic(path, ExtensionManifestCodec.writeText(out.manifest, 2));
        }
        return out;
      } catch (backupError) {
        out.note = tf('ps_manifest_both_fail', path);
        return out;
      }
    }
  }

  /**
   * 原子写清单（顺带建目录）。
   *
   * 用缩进 2 的形式而不是紧凑形式：这份文件是给人看、也给人手工改的
   * （用户可以直接往 plugins 目录里丢一份自己写的清单）。桌面版那边是 .yml，
   * 同样是人看的，所以这条不追求字节一致。
   *
   * @throws 目录建不出来或磁盘写入失败时抛出。
   */
  writeManifest(manifest: ExtensionManifest): void {
    if (!this.ensureDirOf(manifest.id)) {
      throw new Error(`扩展目录不可用：${this.dirOf(manifest.id)}`);
    }
    const path: string = this.manifestPathOf(manifest.id);
    this.writeAtomic(path, ExtensionManifestCodec.writeText(manifest, 2));
    this.refreshBackup(path);
  }

  /**
   * 某扩展是否启用。
   *
   * 缺 state.json 一律当启用：state.json 是我们自己写的，缺失只可能是第一次
   * 装（旧版本）或用户手工删过。两种情况下把扩展默认关掉，用户看到的是「装
   * 了但不生效」，而清单本身没问题 —— 默认开更符合「装上就是用的」这个预期。
   */
  isEnabled(pluginId: string): boolean {
    const path: string = `${this.dirOf(pluginId)}/${STATE_NAME}`;
    if (!this.readable(path)) {
      return true;
    }
    try {
      const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
      const root: JsonObject | undefined = JsonValue.asObject(JsonReader.parse(text));
      if (root === undefined) {
        return true;
      }
      return JsonValue.asBoolean(root.tryGet('enabled'), true);
    } catch (err) {
      return true;
    }
  }

  /**
   * 写开关状态。
   *
   * @throws 目录建不出来或磁盘写入失败时抛出。
   */
  writeEnabled(pluginId: string, enabled: boolean): void {
    if (!this.ensureDirOf(pluginId)) {
      throw new Error(`扩展目录不可用：${this.dirOf(pluginId)}`);
    }
    const state: JsonObject = new JsonObject();
    state.set('enabled', new JsonBoolean(enabled));
    this.writeAtomic(`${this.dirOf(pluginId)}/${STATE_NAME}`, JsonWriter.writeCompact(state));
  }

  /**
   * 删掉某个扩展的整个目录（含清单、备份、状态文件）。
   *
   * rmdirSync 本身是递归的，插件目录里目前也只有文件。
   *
   * @throws 删除失败时抛出。
   */
  remove(pluginId: string): void {
    const dir: string = this.dirOf(pluginId);
    if (this.isDir(dir)) {
      fs.rmdirSync(dir);
    }
  }

  // ------------------------------------------------------------ 内部

  /** 写临时文件再 rename 覆盖。任一步失败都保留原有文件不变。 */
  private writeAtomic(path: string, text: string): void {
    const temp: string = `${path}${TEMP_SUFFIX}`;
    const file: fs.File =
      fs.openSync(temp, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text, { encoding: 'utf-8' });
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(temp, path);
  }

  /** @throws 文件不可读或内容不是合法清单 JSON 时抛出。 */
  private readManifestFile(path: string): ExtensionManifest {
    const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
    const manifest: ExtensionManifest | undefined = ExtensionManifestCodec.parseText(text);
    if (manifest === undefined) {
      throw new Error(`清单顶层不是对象：${path}`);
    }
    return manifest;
  }

  /** 复制为 .bak。复制失败不算错误：备份是兜底而非主路径。 */
  private refreshBackup(path: string): void {
    try {
      fs.copyFileSync(path, `${path}${BACKUP_SUFFIX}`);
    } catch (err) {
      return;
    }
  }

  private readable(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (err) {
      return false;
    }
  }

  /**
   * 路径是否指向一个目录。
   *
   * 用 statSync 而不是 accessSync：accessSync 判不出「这是个目录」，而
   * 「路径上已经有一个同名普通文件」正是这里必须识别的情况。
   */
  private isDir(path: string): boolean {
    try {
      return fs.statSync(path).isDirectory();
    } catch (err) {
      return false;
    }
  }
}
