/*
 * 桌面版插件包（.cipx）的导入。
 *
 * .cipx 是什么
 * ------------
 * 桌面版 ClassIsland.PluginSdk.targets 在 Build 之后把插件的**输出目录**压成
 * zip：manifest.yml + EntranceAssembly 指向的 .dll + 依赖。所以包里能拿走的东西
 * 只有 manifest.yml 里的元信息 —— 那份 dll 是 .NET 程序集，鸿蒙上没有运行时
 * 去加载它。
 *
 * 仍然要读它，是为了把「我电脑上装过的插件」在鸿蒙侧也列出来，并说清它为什么
 * 不生效。用户在设置页里看到一个自己认得的名字、点开看到「.NET 程序集，本端不
 * 加载」，比在导入时弹一句「不支持的格式」有用得多。
 *
 * 三处必须绕一下的坑
 * ----------------
 * 1. decompressFile 的 inFile **必须是应用沙箱内路径**，不能是 picker 给的 URI。
 *    所以先把 URI 复制进 filesDir。
 * 2. 同一个 API 写死「inFile 的扩展名必须是 .zip」。.cipx 会被拒（900001），
 *    所以临时文件按 .zip 命名。
 * 3. outFile 必须是**已经存在**的目录。所以先建目录再解压。
 *
 * 解压目标目录
 * ------------
 * 桌面版压的是 OutputPath 目录本身，manifest.yml 在根。但构建脚本与打包脚本
 * 偶尔会在里面再套一层（`SdkDirectory/…`），所以根目录找不到清单时向下找两层，
 * 最多只认「唯一的一个子目录」—— 认不唯一就不猜，宁可报「包里没找到清单」，
 * 也不要挑一个目录然后把别人的清单当成这个插件的。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import zlib from '@ohos.zlib';
import { t } from 'common_core';
import {
  DesktopPluginMeta,
  ExtensionManifest,
  ExtensionManifestCodec,
  MAX_MANIFEST_TEXT_LENGTH,
  desktopPluginManifest,
  parseDesktopPluginYaml
} from 'common_core';
import { ProfileTransfer, TransferOutcome } from '../data/ProfileTransfer';

/** 临时工作目录。解压与读清单都在这里做，做完整个删掉。 */
const TEMP_DIR_NAME: string = 'cipx-import';
/** 桌面版清单在包里的文件名。 */
const MANIFEST_FILE_NAME: string = 'manifest.yml';
/** 往下找清单的层数上限。 */
const MAX_NESTING: number = 2;

export class CipxImportResult {
  /** 用户取消。 */
  canceled: boolean = false;
  /** 转成 JSON 的清单文本，交给 PluginService.installFromText。取消时是空串。 */
  manifestText: string = '';
  /** 一句话说明，装完之后显示给用户。取消时是空串。 */
  summary: string = '';
}

export class PluginPackageImporter {
  /**
   * 读一个 .cipx，转成本端的清单文本。
   *
   * 这一层**只**做转换，不落盘也不装载：装不装、装成什么样由调用方决定
   * （installFromText）。分开是因为「转换成功但装不上」是一句要说的话，
   * 混在一个函数里就没法把它和「包本身有问题」区分开。
   *
   * @param context UIAbility 的 context
   * @param uri picker 给出的 .cipx 的 URI
   * @returns 转换结果；用户取消时 canceled 为 true
   * @throws 复制、解压、找清单、读清单任一步失败时抛出
   */
  static async convertCipx(context: common.UIAbilityContext,
    uri: string): Promise<CipxImportResult> {
    const tempDir: string = `${context.filesDir}/${TEMP_DIR_NAME}`;
    const zipPath: string = `${tempDir}/package.zip`;
    const outDir: string = `${tempDir}/out`;
    // 先清掉上一轮的残留：解压不会因为目标已存在而失败（会覆盖），但上一轮
    // 解出来的东西会留在那儿，而我们会去里面找清单 —— 于是「这次包里没有清单」
    // 会被上一次的一份清单顶替。
    removeDirQuietly(tempDir);
    try {
      fs.mkdirSync(tempDir);
      fs.mkdirSync(outDir);
      fs.copyFileSync(uri, zipPath);
      await zlib.decompressFile(zipPath, outDir);
      const manifestPath: string = PluginPackageImporter.findManifest(outDir);
      if (manifestPath.length === 0) {
        throw new Error(t('imp_no_manifest'));
      }
      const size: number = fileSizeOf(manifestPath);
      if (size > MAX_MANIFEST_TEXT_LENGTH) {
        throw new Error(`manifest.yml 太大（${size} 字符），不像是一份清单。`);
      }
      const text: string = fs.readTextSync(manifestPath, { encoding: 'utf-8' });
      const meta: DesktopPluginMeta = parseDesktopPluginYaml(text);
      if (meta.id.trim().length === 0) {
        throw new Error(t('imp_no_id'));
      }
      const manifest: ExtensionManifest = desktopPluginManifest(meta);
      const out: CipxImportResult = new CipxImportResult();
      out.canceled = false;
      out.manifestText = ExtensionManifestCodec.writeText(manifest, 2);
      out.summary = PluginPackageImporter.summaryOf(meta, manifest);
      return out;
    } finally {
      removeDirQuietly(tempDir);
    }
  }

  /** 转换完给用户看的一句话。 */
  private static summaryOf(meta: DesktopPluginMeta, manifest: ExtensionManifest): string {
    const name: string = manifest.name.length > 0 ? manifest.name : meta.id;
    let out: string = `已导入「${name}」的元信息。`;
    if (meta.id.trim() !== manifest.id) {
      out += `（原 id ${meta.id.trim()} 改成了 ${manifest.id}）`;
    }
    out += t('imp_dotnet_note');
    if (meta.unreadableFields.length > 0) {
      out += `有 ${meta.unreadableFields.length} 个字段本端读不出来。`;
    }
    return out;
  }

  /**
   * 在解压结果里找 manifest.yml。
   *
   * 根目录优先；没有就往下找，最多两层，且只在「该层恰好一个子目录」时往下走。
   *
   * @returns 找到的完整路径；没找到返回空串。
   */
  private static findManifest(dir: string): string {
    let current: string = dir;
    for (let depth: number = 0; depth <= MAX_NESTING; depth++) {
      const direct: string = `${current}/${MANIFEST_FILE_NAME}`;
      if (fileReadable(direct)) {
        return direct;
      }
      const next: string = onlySubDirectory(current);
      if (next.length === 0) {
        return '';
      }
      current = next;
    }
    return '';
  }
}

/**
 * 让用户挑一个扩展包或清单文件。
 *
 * 只放行 .cipx 与 .json 两种。放行「任意文件」的话，用户能挑到一张图片，然后
 * 得到一句「不支持的格式」—— 那句话没告诉他「你要找的是 .cipx」，而一个收窄
 * 的选择框里只有两种能用的文件，差别是用户不必先知道自己挑错了。
 */
export async function pickPluginFile(context: common.UIAbilityContext): Promise<TransferOutcome> {
  return ProfileTransfer.pickOpenUri(context, ['扩展包或清单|.cipx;.json']);
}

/**
 * 该目录下唯一的一个子目录的完整路径。
 *
 * 不是「第一个」子目录：包里同时有 manifest.yml 和 docs/ 时，随便挑一个会
 * 读到 docs 里的同名文件，而那读出来的清单属于另一个东西。挑不出来（没有子目录、
 * 或者有多个）就返回空串，让调用方报「没找到清单」—— 那句话比「读到了一个错的
 * 清单」有用。
 */
function onlySubDirectory(dir: string): string {
  let names: string[] = [];
  try {
    names = fs.listFileSync(dir);
  } catch (err) {
    return '';
  }
  let found: string = '';
  for (const name of names) {
    const path: string = `${dir}/${name}`;
    if (!isDirectory(path)) {
      continue;
    }
    if (found.length > 0) {
      return '';
    }
    found = path;
  }
  return found;
}

function isDirectory(path: string): boolean {
  try {
    return fs.statSync(path).isDirectory();
  } catch (err) {
    return false;
  }
}

function fileReadable(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (err) {
    return false;
  }
}

/** 文件字节数；读不到给 0（0 不会触发体积闸，让后面读文本那步去报错）。 */
function fileSizeOf(path: string): number {
  try {
    return fs.statSync(path).size;
  } catch (err) {
    return 0;
  }
}

/** 整个目录删掉。删不掉不算错误：临时目录留着只是下次进来先被清一次。 */
function removeDirQuietly(dir: string): void {
  try {
    if (isDirectory(dir)) {
      fs.rmdirSync(dir);
    }
  } catch (err) {
    return;
  }
}
