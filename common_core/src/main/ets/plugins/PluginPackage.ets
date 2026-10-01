/*
 * 桌面版插件包（.cipx）里的 manifest.yml 解析。
 *
 * .cipx 是什么
 * ------------
 * 桌面版的 ClassIsland.PluginSdk.targets 在 Build 之后把插件的**输出目录**整个
 * 压成 zip：里面有 manifest.yml、EntranceAssembly 指向的 .dll、以及它的依赖。
 * 所以一份 .cipx 里能被本端拿走的东西只有 manifest.yml 里的元信息 —— 那份 dll
 * 是 .NET 程序集，鸿蒙上跑不了。
 *
 * 仍然要读它，是为了把「我电脑上装过的插件」在鸿蒙侧也列出来，并说清它为什么
 * 不生效。用户在设置页里看到一个自己认得的名字、点开看到「.NET 程序集，本端不
 * 加载」，比在导入时弹一个「不支持的格式」有用得多 —— 后者只告诉他失败了，
 * 前者告诉他「这东西我认识，但它在这台机器上跑不了」。
 *
 * YAML 子集的边界
 * ---------------
 * YamlDotNet 序列化出来的是完整 YAML，而本端只实现一个**子集**。认得的：
 *
 *   - 顶格的 `键: 值`（顶格才认：缩进的都是嵌套结构或列表，与要迁的字段无关）
 *   - 值的四种写法：裸量、单引号（'' 转义成 '）、双引号（\ 与 " 反斜杠转义）、
 *     以及 `~` / `null` / 空（都归成空串）
 *   - 块标量 `|` 与 `>`（描述常常是多行的，这一项不实现就会静默丢描述）
 *   - 空行、`---` / `...` 文档分隔、整行注释
 *   - 裸量后面跟 ` #` 时的行尾注释（必须前面有空格，否则那是值的一部分）
 *
 * 不认得（值按空处理，并把字段名记进 unreadableFields）：
 *
 *   - 流式集合 `[a, b]` / `{a: 1}`（本端不迁列表与字典）
 *   - 锚点 / 别名（`&a` / `*a`）与 `!tag`
 *   - 键本身带引号
 *   - 一份文件里多份 YAML 文档（只读第一份，且 `---` 之后的内容会被当成另一份
 *     文档的开头，不会与第一份混在一起）
 *
 * 刻意不实现完整 YAML：为了读 7 个字符串而引入一个带锚点/标签/多文档的解析器，
 * 引入的那部分代码就成了「也要测」的代码，而它服务不了任何用户看得见的功能。
 * 认不出来时值是空串，界面上那一项就没内容 —— 明显缺失，不会被当成真的没有。
 */

import { ExtensionManifest } from './PluginManifest';
import { PLUGIN_API_VERSION } from './PluginApi';

/** 桌面版 manifest.yml 里本端要迁的字段。全 PascalCase，与 YamlDotNet 序列化出的键名一致。 */
export const DESKTOP_FIELD_ENTRANCE_ASSEMBLY: string = 'EntranceAssembly';
export const DESKTOP_FIELD_NAME: string = 'Name';
export const DESKTOP_FIELD_ID: string = 'Id';
export const DESKTOP_FIELD_DESCRIPTION: string = 'Description';
export const DESKTOP_FIELD_URL: string = 'Url';
export const DESKTOP_FIELD_VERSION: string = 'Version';
export const DESKTOP_FIELD_API_VERSION: string = 'ApiVersion';
export const DESKTOP_FIELD_AUTHOR: string = 'Author';

/** 桌面版 manifest.yml 的解析结果。字段全空串表示「文件里没有这一项」。 */
export class DesktopPluginMeta {
  /** 入口程序集名（如 MyPlugin.dll）。只用于在界面上说明「它是程序集」。 */
  entranceAssembly: string = '';
  name: string = '';
  id: string = '';
  description: string = '';
  url: string = '';
  version: string = '';
  /** 桌面版的目标 ClassIsland 版本（2.x 之类）。本端不拿它当闸门。 */
  apiVersion: string = '';
  author: string = '';
  /**
   * 认出来了、但值用了本子集不支持的写法（于是值是空串）的字段名。
   *
   * 单独列出来是因为「描述是空的」有两种很不同的原因：作者没写，和本端读不懂。
   * 后者不该让作者以为自己没写。
   */
  unreadableFields: string[] = [];
}

/** 清单里一个都没读到时用（文件不是一份顶层映射，或全是注释）。 */
export const EMPTY_DESKTOP_META: string = '';

/**
 * 解析一份桌面版 manifest.yml。
 *
 * 不抛：任何看不懂的输入都给一个全空的 meta，调用方靠 id 为空判断「这份文件里
 * 没有可用的清单」。清单一律不让一份坏文件把整个导入流程带崩。
 */
export function parseDesktopPluginYaml(text: string): DesktopPluginMeta {
  const out: DesktopPluginMeta = new DesktopPluginMeta();
  const lines: string[] = splitLines(text);
  let i: number = 0;
  let sawEntry: boolean = false;
  // 只读第一份文档。`---` 有两个角色：出现在任何内容之前是「文档开头」，
  // 出现在内容之后是「文档分隔」。把开头那个也当分隔会读到一份空清单 ——
  // 而 YamlDotNet 序列化出来的文件**就是**以 `---` 开头，这是最常见的一种输入。
  while (i < lines.length) {
    const line: string = lines[i];
    const trimmed: string = line.trim();
    if (trimmed === '---') {
      if (sawEntry) {
        break;
      }
      i++;
      continue;
    }
    if (trimmed.length === 0 || trimmed === '...' || trimmed.charAt(0) === '#') {
      i++;
      continue;
    }
    // 缩进行不是我们要的字段：它属于上一项的嵌套结构或一个列表。跳到下一个
    // 顶格行为止，而不是逐行处理 —— 逐行处理会把嵌套里的 `Name: x` 误当成
    // 顶层字段，而那才是真会读错值的情况。
    if (line.length > 0 && isSpace(line.charAt(0))) {
      i++;
      continue;
    }
    const colon: number = findKeySeparator(line);
    if (colon < 0) {
      i++;
      continue;
    }
    sawEntry = true;
    const key: string = line.substring(0, colon).trim();
    const rest: string = line.substring(colon + 1).trim();
    if (key.length === 0 || key.charAt(0) === '"' || key.charAt(0) === '\'') {
      i++;
      continue;
    }
    if (rest.length === 0 || rest.charAt(0) === '#') {
      // `键:` 后面什么都没有：要么是空值，要么是下面缩进块。
      //
      // 块标量一定带 `|` 或 `>`，所以这里**不能**去试 readBlockScalar：空行
      // 的缩进块（列表/嵌套映射）会被它当成一个保留块读出来，于是
      // `Dependencies:` 后面的列表就成了「读出来了」，而它其实一个字都不该给。
      if (hasIndentedContinuation(lines, i + 1)) {
        markUnreadable(out, key);
        i = skipIndented(lines, i + 1);
        continue;
      }
      assign(out, key, EMPTY_DESKTOP_META);
      i++;
      continue;
    }
    if (rest.charAt(0) === '|' || rest.charAt(0) === '>') {
      // 带数字的块标记（`|2`、`>-1`）本子集不认，按整块不支持处理 ——
      // 认错的话症状是描述里多几个空行或少几行，看不出来。
      if (rest !== '|' && rest !== '|-' && rest !== '|+' && rest !== '>' && rest !== '>-' &&
        rest !== '>+') {
        markUnreadable(out, key);
        i = skipIndented(lines, i + 1);
        continue;
      }
      const block: string | undefined = readBlockScalar(lines, i + 1, rest);
      if (block === undefined) {
        markUnreadable(out, key);
        i = skipIndented(lines, i + 1);
        continue;
      }
      assign(out, key, block);
      i = skipIndented(lines, i + 1);
      continue;
    }
    if (rest.charAt(0) === '[' || rest.charAt(0) === '{') {
      markUnreadable(out, key);
      i++;
      continue;
    }
    if (rest.charAt(0) === '&' || rest.charAt(0) === '*' || rest.charAt(0) === '!') {
      markUnreadable(out, key);
      i++;
      continue;
    }
    const value: string = scalarOf(rest, out, key);
    assign(out, key, value);
    i++;
  }
  return out;
}

/**
 * 桌面版插件元信息 → 本端的扩展清单。
 *
 * 三个刻意选择
 * ------------
 * 1. apiVersion 填**本端**的版本，不填桌面版的那个。桌面版是 2.x，而本端的
 *    PLUGIN_API_VERSION 是 1.0.0 且兼容判据是「同主版本」—— 照抄过来必然被
 *    版本闸拒掉，于是导入永远失败。填自己的版本才说得通：这份清单是**本端**
 *    在解释，它该向谁声明兼容，就声明谁的版本。桌面版的原值写进描述里。
 * 2. 不迁任何条目。.cipx 里的 dll 是 .NET 程序集，本端没有运行时去加载它；
 *    凭空造出几个条目只会在面板上留下「点了没反应」的位置。
 * 3. 描述后面接一段说明。清单从 zip 里来这件事，界面上要能看出来 —— 否则用户
 *    会以为这个扩展是他在手机上装的，而它其实一个条目都不提供。
 */
export function desktopPluginManifest(meta: DesktopPluginMeta): ExtensionManifest {
  const out: ExtensionManifest = new ExtensionManifest();
  out.id = normalizeDesktopPluginId(meta.id);
  out.name = meta.name.length > 0 ? meta.name : out.id;
  out.version = meta.version;
  out.apiVersion = PLUGIN_API_VERSION;
  out.author = meta.author;
  out.homepage = meta.url;
  out.description = desktopImportNote(meta, out.id);
  return out;
}

/** 桌面版 id 不合法时用的兜底 id。只在「id 完全无法救」时出现。 */
export const FALLBACK_DESKTOP_PLUGIN_ID: string = 'desktop.plugin';

/**
 * 把桌面版 id 改成本端认的形式（小写字母数字点横线）。
 *
 * 桌面版的 id 是自由文本：作者写 `MyPlugin` 之类的大写 id 是常见的，而本端的
 * isValidPluginId 只认小写。改成小写是无损且可逆的（作者对上大小写就回来了），
 * 所以做了并在描述里说明；换成别的字符就不可逆了，只在完全没法救时才做。
 */
export function normalizeDesktopPluginId(id: string): string {
  const trimmed: string = id.trim().toLowerCase();
  let out: string = '';
  let lastWasDash: boolean = false;
  for (let i = 0; i < trimmed.length; i++) {
    const c: string = trimmed.charAt(i);
    const keep: boolean = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c === '.';
    if (keep) {
      out += c;
      lastWasDash = false;
      continue;
    }
    // 连续的分隔符合成一个 '-'：'my_plugin' → 'my-plugin'，而不是 'my--plugin'
    // （后者也能过闸，但读起来像坏了）
    if (!lastWasDash) {
      out += '-';
      lastWasDash = true;
    }
  }
  // 掐掉首尾的 '-' 与 '.'：isValidPluginId 不许首字符是横线或点
  while (out.length > 0 && (out.charAt(0) === '-' || out.charAt(0) === '.')) {
    out = out.substring(1);
  }
  while (out.length > 0 &&
    (out.charAt(out.length - 1) === '-' || out.charAt(out.length - 1) === '.')) {
    out = out.substring(0, out.length - 1);
  }
  if (out.length > 0 && out.length <= 64) {
    return out;
  }
  return FALLBACK_DESKTOP_PLUGIN_ID;
}

/** 导入说明的前缀。单独一个常量是为了让测试能断言它。 */
export const DESKTOP_IMPORT_NOTE: string = '由桌面版插件包导入';

/** 描述后面追加的那段说明。 */
export function desktopImportNote(meta: DesktopPluginMeta, normalizedId: string): string {
  let out: string = `${DESKTOP_IMPORT_NOTE}。桌面版插件是 .NET 程序集，本端不加载它，` +
    '所以这个扩展不提供任何可用条目；这里只留了元信息，方便认出它。';
  if (meta.entranceAssembly.length > 0) {
    out += `（程序集 ${meta.entranceAssembly}）`;
  }
  if (meta.apiVersion.length > 0) {
    out += `（桌面版 API 版本 ${meta.apiVersion}）`;
  }
  if (meta.id.trim().length > 0 && meta.id.trim() !== normalizedId) {
    out += `（原 id ${meta.id.trim()}，已改成小写形式）`;
  }
  if (meta.unreadableFields.length > 0) {
    out += `（有 ${meta.unreadableFields.length} 个字段本端读不出来：` +
      `${meta.unreadableFields.join('、')}）`;
  }
  if (meta.description.length > 0) {
    out += ` 原描述：${meta.description}`;
  }
  return out;
}

// ------------------------------------------------------------ 内部

/**
 * 按行切开并去掉行尾的 \r。
 *
 * 不用 split(/\r?\n/)：ArkTS 对正则字面量的支持不完整，逐字符扫更稳（这个取舍
 * 在 PanelView / 天气排除词的切分处已经付过一次代价）。
 */
function splitLines(text: string): string[] {
  const out: string[] = [];
  let current: string = '';
  for (let i = 0; i < text.length; i++) {
    const c: string = text.charAt(i);
    if (c === '\n') {
      out.push(current);
      current = '';
      continue;
    }
    if (c === '\r') {
      continue;
    }
    current += c;
  }
  if (current.length > 0) {
    out.push(current);
  }
  return out;
}

/** 找 `键: 值` 里那个分隔冒号。跳过引号内的冒号。 */
function findKeySeparator(line: string): number {
  let quote: string = '';
  for (let i = 0; i < line.length; i++) {
    const c: string = line.charAt(i);
    if (quote.length > 0) {
      if (c === quote) {
        quote = '';
      }
      continue;
    }
    if (c === '"' || c === '\'') {
      quote = c;
      continue;
    }
    if (c === ':') {
      // 必须是「键: 值」的冒号：紧跟着空格或行尾。'Url:https://x' 这种写法
      // YAML 也接受，但键名里带冒号的字段名本端不认，认成 'Url' 反而可能
      // 读到错的字段。
      if (i + 1 >= line.length || isSpace(line.charAt(i + 1))) {
        return i;
      }
    }
  }
  return -1;
}

/**
 * 读块标量（`键: |` 或 `键: >` 之后的缩进块）。
 *
 * 折叠标记 `>` 把换行折成空格、保留标记 `|` 保留换行；行尾的 `-`（去掉末尾换行）
 * 与 `+`（保留）在值后面通常跟一个数字（keep 数量），这里只认没有数字的那几种，
 * 有数字的按不支持处理 —— 带数量的块在插件描述里不会出现，而认错会给出
 * 「描述多出几个空行」这种看不出错的偏差。
 *
 * @returns 从下一行起的缩进块；后面没有缩进行时返回 undefined。
 */
function readBlockScalar(lines: string[], start: number, marker: string): string | undefined {
  const folded: boolean = marker.charAt(0) === '>';
  const chomp: string = marker.length > 1 ? marker.charAt(1) : '';
  if (chomp.length > 0 && chomp !== '-' && chomp !== '+') {
    return undefined;
  }
  if (chomp === '-' && marker.length > 2) {
    return undefined;
  }
  if (chomp === '+' && marker.length > 2) {
    return undefined;
  }
  const collected: string[] = [];
  let i: number = start;
  while (i < lines.length) {
    const line: string = lines[i];
    if (line.trim().length === 0) {
      // 块里的空行：可能是块尾，也可能是块中间的空行。留到后面一起处理 ——
      // 块尾的空行不该进值里，所以先记着，遇到第一个非缩进行就丢掉。
      collected.push('');
      i++;
      continue;
    }
    if (line.length === 0 || !isSpace(line.charAt(0))) {
      break;
    }
    // 收**原样**的行（不去掉各自的缩进）：最小缩进要在所有行之间算，
    // 先各自去缩进的话最小值就永远是 0，作者故意留的相对缩进会一起被吃掉。
    collected.push(line);
    i++;
  }
  while (collected.length > 0 && collected[collected.length - 1].length === 0) {
    collected.pop();
  }
  if (collected.length === 0) {
    return undefined;
  }
  // 按块的最小缩进对齐，而不是每行各自去缩进：后者会把作者故意写的
  // 「第一行多空两格」也一起吃掉，读出来的段落层次就没了。
  const common: number = commonIndent(collected);
  for (let k = 0; k < collected.length; k++) {
    if (collected[k].length === 0) {
      continue;
    }
    collected[k] = collected[k].length >= common
      ? collected[k].substring(common)
      : collected[k];
  }
  if (folded) {
    const parts: string[] = [];
    for (let k = 0; k < collected.length; k++) {
      const piece: string = collected[k];
      parts.push(piece.length === 0 ? '' : piece);
    }
    return joinFolded(parts);
  }
  return collected.join('\n');
}

/** 折叠标量里的换行：空行变段落分隔，其余折成空格。 */
function joinFolded(parts: string[]): string {
  let out: string = '';
  let pendingBlank: boolean = false;
  for (let i = 0; i < parts.length; i++) {
    if (parts[i].length === 0) {
      pendingBlank = out.length > 0;
      continue;
    }
    if (out.length > 0) {
      out += pendingBlank ? '\n\n' : ' ';
    }
    out += parts[i];
    pendingBlank = false;
  }
  return out;
}

/** 一组行里最小的前导空白长度。空行不算（它们的缩进没有意义）。 */
function commonIndent(lines: string[]): number {
  let min: number = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].length === 0) {
      continue;
    }
    let n: number = 0;
    while (n < lines[i].length && isSpace(lines[i].charAt(n))) {
      n++;
    }
    if (min < 0 || n < min) {
      min = n;
    }
  }
  return min < 0 ? 0 : min;
}

/** 从 start 起跳到第一个顶格行。 */
function skipIndented(lines: string[], start: number): number {
  let i: number = start;
  while (i < lines.length) {
    const line: string = lines[i];
    if (line.trim().length > 0 && (line.length === 0 || !isSpace(line.charAt(0)))) {
      return i;
    }
    i++;
  }
  return i;
}

/** 后面有没有缩进行（即 `键:` 后面跟的是块结构）。 */
function hasIndentedContinuation(lines: string[], start: number): boolean {
  for (let i = start; i < lines.length; i++) {
    const line: string = lines[i];
    if (line.trim().length === 0) {
      continue;
    }
    return line.length > 0 && isSpace(line.charAt(0));
  }
  return false;
}

/** 标量文本 → 值。认不出来的写法按空串并记账。 */
function scalarOf(rest: string, out: DesktopPluginMeta, key: string): string {
  const first: string = rest.charAt(0);
  if (first === '\'') {
    return singleQuoted(rest, out, key);
  }
  if (first === '"') {
    return doubleQuoted(rest, out, key);
  }
  if (rest === '~' || rest === 'null' || rest === 'Null' || rest === 'NULL') {
    return EMPTY_DESKTOP_META;
  }
  return stripComment(rest);
}

/** 去掉裸量后面的行尾注释。 */
function stripComment(text: string): string {
  for (let i = 1; i < text.length; i++) {
    if (text.charAt(i) === '#' && isSpace(text.charAt(i - 1))) {
      return text.substring(0, i).trim();
    }
  }
  return text.trim();
}

/** 单引号标量：'' 是一个字面的 '。 */
function singleQuoted(text: string, out: DesktopPluginMeta, key: string): string {
  let value: string = '';
  let closed: boolean = false;
  for (let i = 1; i < text.length; i++) {
    const c: string = text.charAt(i);
    if (c === '\'') {
      if (i + 1 < text.length && text.charAt(i + 1) === '\'') {
        value += '\'';
        i++;
        continue;
      }
      closed = true;
      break;
    }
    value += c;
  }
  if (!closed) {
    markUnreadable(out, key);
    return EMPTY_DESKTOP_META;
  }
  return value;
}

/** 双引号标量：认识 \n \t \\ \" 四个转义。 */
function doubleQuoted(text: string, out: DesktopPluginMeta, key: string): string {
  let value: string = '';
  let closed: boolean = false;
  for (let i = 1; i < text.length; i++) {
    const c: string = text.charAt(i);
    if (c === '\\') {
      if (i + 1 >= text.length) {
        break;
      }
      const next: string = text.charAt(i + 1);
      i++;
      if (next === 'n') {
        value += '\n';
      } else if (next === 't') {
        value += '\t';
      } else if (next === '\\') {
        value += '\\';
      } else if (next === '"') {
        value += '"';
      } else {
        // 不认识的转义：YAML 规定报错，我们不引入错误通道，按原样留下反斜杠
        value += '\\' + next;
      }
      continue;
    }
    if (c === '"') {
      closed = true;
      break;
    }
    value += c;
  }
  if (!closed) {
    markUnreadable(out, key);
    return EMPTY_DESKTOP_META;
  }
  return value;
}

/** 把值塞进对应字段。不认识的键直接丢：YAML 里一堆本端不关心的键。 */
function assign(meta: DesktopPluginMeta, key: string, value: string): void {
  if (key === DESKTOP_FIELD_ENTRANCE_ASSEMBLY) {
    meta.entranceAssembly = value;
  } else if (key === DESKTOP_FIELD_NAME) {
    meta.name = value;
  } else if (key === DESKTOP_FIELD_ID) {
    meta.id = value;
  } else if (key === DESKTOP_FIELD_DESCRIPTION) {
    meta.description = value;
  } else if (key === DESKTOP_FIELD_URL) {
    meta.url = value;
  } else if (key === DESKTOP_FIELD_VERSION) {
    meta.version = value;
  } else if (key === DESKTOP_FIELD_API_VERSION) {
    meta.apiVersion = value;
  } else if (key === DESKTOP_FIELD_AUTHOR) {
    meta.author = value;
  }
}

/** 记一笔「这个字段本端读不出来」。 */
function markUnreadable(meta: DesktopPluginMeta, key: string): void {
  if (meta.unreadableFields.indexOf(key) < 0) {
    meta.unreadableFields.push(key);
  }
}

/** 空白判定。制表符也算空白：YAML 不许用制表符缩进，但「不许」意味着它会出现。 */
function isSpace(c: string): boolean {
  return c === ' ' || c === '\t';
}
