/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 档案仓库：JSON 文件是唯一真源，内存里不持有权威副本。
 *
 * 这条约束是被小组件逼出来的：FormExtensionAbility 在 10 秒不活动后就被回收，
 * 下次拉起是一个全新进程，内存里什么都没有。所以任何跨进程的读取都必须
 * 「从文件读 -> 算 -> 用完丢」，而不是「读一次留着」。
 *
 * 容错模型照搬桌面版 ConfigureFileHelper.LoadConfigUnWrapped：
 *   - 主文件读成功 -> 复制一份 .bak（下次的备份基准）
 *   - 主文件读失败 -> 试 .bak；.bak 也成功则用它覆盖回主文件
 *   - 两份都坏     -> 抛错，由调用方决定是提示用户还是开新档
 * 绝不把「解析失败」静默降级成空档案：那会用一份空数据覆盖掉用户的真实数据。
 *
 * 写盘走「临时文件 + rename」的原子替换：直接覆写的话，掉电或进程被杀会留下
 * 半截 JSON，而档案是用户几年积累的数据，损坏不可接受。rename 在同一文件系统内
 * 是原子的，所以正式文件要么是旧的完整内容，要么是新的完整内容，不存在中间态。
 *
 * 序列化用不缩进形式，对齐桌面版 SaveConfig(path, obj) 的 writeIndented: false ——
 * 鸿蒙侧写出的字节与桌面版写出的字节一致，双向同步不会产生无谓的 diff。
 *
 * 路径由调用方传入而不是从 context 取，这样 FormExtensionAbility 也能用同一份
 * 仓库实现 —— 它传自己的 context.filesDir 即可。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { Profile } from 'common_shared';

const FILE_NAME: string = 'profile.json';
const TEMP_NAME: string = 'profile.json.tmp';
const BACKUP_SUFFIX: string = '.bak';

export class ProfileRepository {
  private readonly dir: string;

  constructor(filesDir: string) {
    this.dir = filesDir;
  }

  /** 档案完整路径。 */
  filePath(): string {
    return `${this.dir}/${FILE_NAME}`;
  }

  private backupPath(): string {
    return `${this.dir}/${FILE_NAME}${BACKUP_SUFFIX}`;
  }

  /**
   * 档案是否已存在。
   *
   * accessSync 正常路径返回布尔值，但路径非法一类情况仍会抛错；「读不到」与
   * 「不存在」对上层是同一件事，所以都归成 false，不让异常漏到界面层。
   */
  exists(): boolean {
    return this.fileReadable(this.filePath());
  }

  private fileReadable(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (err) {
      return false;
    }
  }

  /**
   * 读档案，失败时回退到 .bak。
   *
   * @throws 主文件与 .bak 都不可读或都解析失败时抛出。
   */
  load(): Profile {
    if (!this.exists()) {
      // 与桌面版一致：首次读不到就落一份空档案，让后续写盘有基准文件。
      const fresh: Profile = new Profile();
      this.save(fresh);
      return fresh;
    }

    try {
      const profile: Profile = this.readFile(this.filePath());
      this.refreshBackup();
      return profile;
    } catch (primaryError) {
      if (!this.fileReadable(this.backupPath())) {
        // 主文件坏了、备份也不存在：只能报错。ArkTS 不允许原样抛出捕获到的
        // 任意类型（catch 变量是 any），所以把路径信息并进一个新 Error ——
        // 消息里带了路径，用户截图反馈时能直接定位到是哪个文件。
        throw new Error(`课表档案无法读取：${this.filePath()}`);
      }
      const profile: Profile = this.readFile(this.backupPath());
      // .bak 能用就把它写回主文件，避免下次启动又撞上同一份坏数据。
      this.save(profile);
      return profile;
    }
  }

  /**
   * 原子写档案。
   *
   * 步骤：写临时文件 -> rename 覆盖正式文件。任一步失败都保留原有正式文件不变。
   *
   * @throws 磁盘写入失败（空间不足、权限、目录不存在）时抛出。
   */
  save(profile: Profile): void {
    const tempPath: string = `${this.dir}/${TEMP_NAME}`;
    const finalPath: string = this.filePath();
    const file: fs.File = fs.openSync(tempPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, Profile.stringify(profile), { encoding: 'utf-8' });
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(tempPath, finalPath);
  }

  /**
   * 删除档案与其备份。用于「重置」功能。
   *
   * @throws 删除失败（权限、文件被占用）时抛出。
   */
  remove(): void {
    if (this.exists()) {
      fs.unlinkSync(this.filePath());
    }
    if (this.fileReadable(this.backupPath())) {
      fs.unlinkSync(this.backupPath());
    }
  }

  /**
   * @throws 文件不可读或内容不是合法档案 JSON 时抛出。
   */
  private readFile(path: string): Profile {
    const text: string = fs.readTextSync(path, { encoding: 'utf-8' });
    return Profile.parse(text);
  }

  /**
   * 把当前主文件复制为 .bak。
   *
   * 复制失败不算错误：备份是兜底而非主路径，为此打断一次正常读取不值得。
   */
  private refreshBackup(): void {
    try {
      fs.copyFileSync(this.filePath(), this.backupPath());
    } catch (err) {
      // 备份不可用时下次读失败就没有回退路径，但本次读取的结果是好的，不该因此失败。
    }
  }
}
