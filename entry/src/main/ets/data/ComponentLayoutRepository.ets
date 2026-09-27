/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 信息面板布局的仓库。
 *
 * 落点不是档案
 * ------------
 * 桌面版把组件布局单独放在 AppConfigPath/ComponentLayouts/{方案名}.json，
 * 当前用哪一份记在 settings.json 的 CurrentComponentConfig。鸿蒙侧照抄这个
 * 形状：布局归布局，课表归课表。
 *
 * 这么分开在 P7 省下的力气比看上去大。布局里有一堆我们没建模的字段（规则集、
 * 插件私有数据），它们只能以裸节点透传；要是布局混在 profile.json 里，每做
 * 一次布局改动都会让整个档案参与比对，档案是用户几年积累的数据，赌不起。
 *
 * 容错与原子写
 * ------------
 * 与 ProfileRepository 同一套模型：主文件读成功就复制一份 .bak，主文件坏了
 * 就回退 .bak，两份都坏才报错。绝不把解析失败静默降级成默认布局 —— 那会用
 * 一份默认数据覆盖掉用户排好的面板，而且面板排错不报错，下次打开一切正常，
 * 用户根本不会发现。
 *
 * 方案名先过滤再拼路径
 * ------------------
 * 方案名会出现在文件路径上，是外部可写的一侧（preferences 里的键值，也能从
 * 同步进来的设置里来）。`/../` 之类的内容能写到 filesDir 外面去。这里不静默
 * 替换成默认名，而是判定为非法并退回默认方案：改名失败与改名被忽略，用户都
 * 看得见；写到别的目录则完全看不见。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { ComponentProfile } from 'common_shared';

/** 子目录名。与桌面版的 AppConfigPath/ComponentLayouts 一致。 */
const DIR_NAME: string = 'ComponentLayouts';
const TEMP_SUFFIX: string = '.tmp';
const BACKUP_SUFFIX: string = '.bak';

/** 方案名的默认��。桌面版 ComponentsService 的初始值同样是 "Default"。 */
export const DEFAULT_PANEL_SCHEME: string = 'Default';

/**
 * 方案名是否可用。
 *
 * 只允许字母、数字、下划线、连字符、空格，且长度 1..64。这些字符在桌面版
 * 的 Windows 文件系统上同样安全，所以同一份配置从桌面版同步过来不会因为
 * 平台差异而被判非法。
 */
export function isValidPanelScheme(name: string): boolean {
  if (name.length < 1 || name.length > 64) {
    return false;
  }
  for (let i: number = 0; i < name.length; i++) {
    const c: string = name.charAt(i);
    const isLetter: boolean = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    const isDigit: boolean = c >= '0' && c <= '9';
    if (!isLetter && !isDigit && c !== '_' && c !== '-' && c !== ' ') {
      return false;
    }
  }
  return true;
}

export class ComponentLayoutRepository {
  private readonly root: string;

  constructor(filesDir: string) {
    this.root = `${filesDir}/${DIR_NAME}`;
  }

  /** 布局目录。不存在时返回它该在的路径（调用方负责创建）。 */
  dirPath(): string {
    return this.root;
  }

  /**
   * 布局文件完整路径。
   *
   * 非法方案名一律按默认方案处理，理由见文件头。
   */
  filePath(scheme: string): string {
    return `${this.root}/${isValidPanelScheme(scheme) ? scheme : DEFAULT_PANEL_SCHEME}.json`;
  }

  private backupPath(scheme: string): string {
    return `${this.filePath(scheme)}${BACKUP_SUFFIX}`;
  }

  /**
   * 目录是否可用。读写之前都要先确认它能建出来。
   *
   * mkdirSync 不递归是刻意的：父目录（filesDir）一定存在，递归创建只会掩盖
   * 「路径指向了一个已存在的普通文件」这种真正需要报错的情况。
   */
  private ensureDir(): boolean {
    try {
      if (!fs.accessSync(this.root)) {
        fs.mkdirSync(this.root);
      }
      return fs.accessSync(this.root);
    } catch (err) {
      return false;
    }
  }

  /** 方案是否已存在。 */
  exists(scheme: string): boolean {
    return this.readable(this.filePath(scheme));
  }

  /**
   * 读布局。不存在时落一份默认布局再返回。
   *
   * 落默认布局而不是只在内存里给默认值：桌面版也是这么做的（LoadConfig 里
   * CopyObject(DefaultComponentProfile) 之后立刻 SaveConfig），这样用户第一次
   * 打开就有了一个可以导出的文件，双向同步不会因为「我这没有文件」而卡住。
   *
   * @throws 主文件与 .bak 都不可读或都解析失败时抛出。
   */
  load(scheme: string): ComponentProfile {
    if (!this.ensureDir()) {
      throw new Error(`信息面板目录不可用：${this.root}`);
    }
    if (!this.exists(scheme)) {
      const fresh: ComponentProfile = ComponentProfile.defaultProfile();
      this.save(scheme, fresh);
      return fresh;
    }

    const path: string = this.filePath(scheme);
    try {
      const profile: ComponentProfile = this.readFile(path);
      this.refreshBackup(path);
      return profile;
    } catch (primaryError) {
      const backup: string = this.backupPath(scheme);
      if (!this.readable(backup)) {
        // 与档案仓库同一条路：两份都坏只能报错。catch 变量在 ArkTS 里是
        // any，不能原样抛，所以把路径并进消息里。
        throw new Error(`信息面板布局无法读取：${path}`);
      }
      const profile: ComponentProfile = this.readFile(backup);
      this.save(scheme, profile);
      return profile;
    }
  }

  /**
   * 原子写布局。写临时文件再 rename 覆盖。
   *
   * @throws 目录不可用或磁盘写入失败时抛出。
   */
  save(scheme: string, profile: ComponentProfile): void {
    if (!this.ensureDir()) {
      throw new Error(`信息面板目录不可用：${this.root}`);
    }
    const path: string = this.filePath(scheme);
    const temp: string = `${path}${TEMP_SUFFIX}`;
    const file: fs.File =
      fs.openSync(temp, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, ComponentProfile.stringify(profile), { encoding: 'utf-8' });
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(temp, path);
    // 写完新的就把 .bak 换成刚写的这一份。下次主文件坏了，回退到的就是最新
    // 的好数据，而不是「上一份好数据」—— 后者意味着用户会发现自己的改动
    // 凭空少了几次。
    this.refreshBackup(path);
  }

  /**
   * 删除一个方案与其备份。
   *
   * @throws 删除失败时抛出。
   */
  remove(scheme: string): void {
    const path: string = this.filePath(scheme);
    if (this.exists(scheme)) {
      fs.unlinkSync(path);
    }
    const backup: string = this.backupPath(scheme);
    if (this.readable(backup)) {
      fs.unlinkSync(backup);
    }
  }

  /**
   * 列出全部方案名，按名称升序。
   *
   * 目录不存在时返回空数组而不是报错：用户还没建过任何方案，这是正常状态。
   * 同名不同大小写的文件只留一个（键冲突时后来者不覆盖），免得列表里出现
   * 「Default」和「default」两条而其中一条打不开。
   */
  list(): string[] {
    if (!this.ensureDir()) {
      return [];
    }
    const names: string[] = [];
    let files: string[] = [];
    try {
      files = fs.listFileSync(this.root);
    } catch (err) {
      return [];
    }
    for (const name of files) {
      if (!name.endsWith('.json') || name.endsWith('.bak')) {
        continue;
      }
      const scheme: string = name.substring(0, name.length - '.json'.length);
      if (isValidPanelScheme(scheme) && names.indexOf(scheme) < 0) {
        names.push(scheme);
      }
    }
    names.sort();
    return names;
  }

  private readable(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (err) {
      return false;
    }
  }

  /**
   * @throws 文件不可读或内容不是合法布局 JSON 时抛出。
   */
  private readFile(path: string): ComponentProfile {
    const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
    return ComponentProfile.parse(text);
  }

  /** 复制为 .bak。复制失败不算错误：备份是兜底而非主路径。 */
  private refreshBackup(path: string): void {
    try {
      fs.copyFileSync(path, `${path}${BACKUP_SUFFIX}`);
    } catch (err) {
      // 与 ProfileRepository 同一处取舍：备份不可用只是少了一条退路，
      // 不该让一次正常保存失败。
    }
  }
}
