/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 档案的导入导出。
 *
 * 选 DocumentViewPicker 而不是自己写路径
 * --------------------------------------
 * DocumentViewPicker 走系统文件框架，用户在弹窗里看到的目录就是他手机上真实的
 * 目录（相册、下载、微信接收的文件…），且授权由框架在 URI 层面托管，不需要申请
 * 任何权限权限项。自己拼 StorageDirectory 路径的话，HarmonyOS 上沙箱外的目录
 * 根本不可写，绕权限的路子在应用市场也过不了审。
 *
 * 取消与失败是两回事
 * ----------------
 * 用户在弹窗里按返回，系统返回的是空数组，不是异常。那是「取消」，界面不该弹
 * 错误提示。而 URI 无效、写盘失败、JSON 解析失败都是真错误，必须报出来：
 * 尤其导入 —— 静默保留原样的话，界面看上去一切正常，用户会以为导入成功了，
 * 实际上他的课表纹丝没动，几天后才发现数据没换过来。
 *
 * 导出的内容是当前草稿，不是磁盘上的档案
 * --------------------------------------
 * 用户改了一堆还没保存就导出去，期望拿到的是他眼前看到的这一份。导出磁盘上的
 * 旧档案等于骗人。所以这个类只管字节的进出，导出哪一份由调用方决定。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { Profile } from 'common_shared';

/** 默认导出的文件名。 */
const DEFAULT_FILE_NAME: string = 'profile.json';

/** 档案内的时间都是字符串，UTF-8 足够。 */
const ENCODING: string = 'utf-8';

export class TransferOutcome {
  /** 选中的 URI。取消时为空串。 */
  uri: string = '';
  /** 用户是否主动取消了。取消时为 true，且没有后续动作发生。 */
  canceled: boolean = false;

  /** 已完成。 */
  static done(uri: string): TransferOutcome {
    const out: TransferOutcome = new TransferOutcome();
    out.uri = uri;
    out.canceled = false;
    return out;
  }

  /** 用户取消。 */
  static cancel(): TransferOutcome {
    const out: TransferOutcome = new TransferOutcome();
    out.uri = '';
    out.canceled = true;
    return out;
  }
}

export class ProfileTransfer {
  /**
   * 让用户挑一个保存位置。
   *
   * @param context UIAbility 的 context
   * @param fileName 建议的文件名，用户可以在弹窗里改
   * @returns 选好的 URI；用户取消时 canceled 为 true
   * @throws 打开系统弹窗失败（框架异常，例如无可用 Documents 提供者）
   */
  static async pickSaveUri(context: common.UIAbilityContext,
    fileName: string = DEFAULT_FILE_NAME): Promise<TransferOutcome> {
    const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    // .json 收窄可选项。写错后缀在桌面上无所谓，桌面上是自由路径
    const suffixes: string[] = ['JSON|.json'];
    options.fileSuffixChoices = suffixes;
    try {
      const uris: string[] = await view.save(options);
      if (uris.length === 0) {
        return TransferOutcome.cancel();
      }
      return TransferOutcome.done(uris[0]);
    } catch (err) {
      // arkts-limited-throw：catch 变量是 any，不能原样 rethrow，必须包成 Error
      throw new Error(`打开保存位置失败：${describe(err)}`);
    }
  }

  /**
   * 让用户挑一个要导入的文件。
   *
   * @param context UIAbility 的 context
   * @returns 选好的 URI；用户取消时 canceled 为 true
   * @throws 打开系统弹窗失败（框架异常）
   */
  static async pickOpenUri(context: common.UIAbilityContext): Promise<TransferOutcome> {
    const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    const filters: string[] = ['JSON|.json'];
    options.fileSuffixFilters = filters;
    // 单选：档案是整体替换语义，选多个的话「到底是哪一份」说不清
    options.maxSelectNumber = 1;
    try {
      const uris: string[] = await view.select(options);
      if (uris.length === 0) {
        return TransferOutcome.cancel();
      }
      return TransferOutcome.done(uris[0]);
    } catch (err) {
      throw new Error(`打开文件选择失败：${describe(err)}`);
    }
  }

  /**
   * 把文本写进 URI。
   *
   * @param uri picker 给出的 URI
   * @param text 内容
   * @throws 打开或写入失败
   */
  static writeText(uri: string, text: string): void {
    // openSync 返回的是 File 对象而不是裸 fd，写入要取它的 .fd
    let file: fs.File | undefined = undefined;
    try {
      // TRUNC：不截断的话，导出的档案比上一次短时，尾部会残留上一次的字节，
      // 写出来的文件是坏的 JSON，而用户完全看不出哪里出了问题
      file = fs.openSync(uri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
    } catch (err) {
      throw new Error(`写入失败：${describe(err)}`);
    } finally {
      if (file !== undefined) {
        // 关不上 fd 不改变任何结果：内容要么已经写完、要么已经失败，
        // 在这里抛出去只会盖掉前面那个真正的错误。
        closeQuietly(file);
      }
    }
  }

  /**
   * 读出 URI 里的文本。
   *
   * @param uri picker 给出的 URI
   * @returns 文件内容
   * @throws 打开或读取失败
   */
  static readText(uri: string): string {
    try {
      return fs.readTextSync(uri, { encoding: ENCODING });
    } catch (err) {
      throw new Error(`读取失败：${describe(err)}`);
    }
  }

  /**
   * 导出档案（草稿序列化后的字节由调用方给出）。
   *
   * @param context UIAbility 的 context
   * @param profile 要导出的档案
   * @param fileName 建议的文件名
   * @returns 写完了的 URI；用户取消时 canceled 为 true
   * @throws 弹窗失败、打开失败、写入失败
   */
  static async exportProfile(context: common.UIAbilityContext, profile: Profile,
    fileName: string = DEFAULT_FILE_NAME): Promise<TransferOutcome> {
    const picked: TransferOutcome = await ProfileTransfer.pickSaveUri(context, fileName);
    if (picked.canceled) {
      return picked;
    }
    // 不缩进，与桌面版 SaveConfig(writeIndented: false) 写出的字节一致，
    // 双向同步时不会产生无谓的 diff
    ProfileTransfer.writeText(picked.uri, Profile.stringify(profile));
    return picked;
  }

  /**
   * 导入档案。
   *
   * @param context UIAbility 的 context
   * @returns 解析出的档案；用户取消时 canceled 为 true 且 profile 未定义
   * @throws 弹窗失败、读取失败、JSON 格式错、结构不是对象
   */
  static async importProfile(context: common.UIAbilityContext): Promise<ImportOutcome> {
    const picked: TransferOutcome = await ProfileTransfer.pickOpenUri(context);
    if (picked.canceled) {
      const out: ImportOutcome = new ImportOutcome();
      out.canceled = true;
      return out;
    }
    const text: string = ProfileTransfer.readText(picked.uri);
    // 解析失败往上抛，绝不返回 undefined 让调用方「保持原样」——
    // 那会让用户以为导入成功了，而他的课表一行都没变
    const parsed: Profile = Profile.parse(text);
    const out: ImportOutcome = new ImportOutcome();
    out.canceled = false;
    out.uri = picked.uri;
    out.profile = parsed;
    return out;
  }
}

export class ImportOutcome {
  uri: string = '';
  canceled: boolean = false;
  /** 解析出的档案。仅在 canceled 为 false 时有意义。 */
  profile: Profile = new Profile();
}

/**
 * 尽力关掉文件描述符，失败也不报。
 *
 * 单独抽出来是因为 ArkTS 不允许空 catch 体（会被当成漏写），而这里真的没有
 * 什么可做的：内容要么已经写完、要么已经失败，关不上 fd 不改变任何结果，
 * 抛出去只会盖掉真正的错误。
 */
function closeQuietly(file: fs.File): void {
  try {
    fs.closeSync(file);
  } catch (err) {
    return;
  }
}

/**
 * 把框架异常转成一句话，供拼进提示文案。
 *
 * 不去读 `code` 字段：BusinessError 的 code 在不同 kit 里含义不同，把一串裸
 * 数字摆到用户面前既看不懂也不能自助解决，message 反而是人话。
 */
function describe(err: Error): string {
  return err.message.length > 0 ? err.message : '未知原因';
}
