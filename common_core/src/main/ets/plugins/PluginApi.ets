/*
 * 声明式扩展的 API 版本口径。
 *
 * 为什么要有版本，而桌面版那套「加载 dll 就完事」不需要
 * -------------------------------------------------
 * 桌面版插件是程序集：它自己带全套类型，系统不关心它按哪个版本的 API 写的，
 * 缺什么就在编译期炸了。鸿蒙侧插件是一份 JSON 声明 —— 它没法在编译期证明自己
 * 只用了认识的东西，于是「这份声明我认不认」必须变成一个**运行期可判定**的问题，
 * 判定依据就是 apiVersion。
 *
 * 兼容规则：同主版本且不低于下限
 * --------------------------
 * 主版本相同 = 「这份声明用的字段名与语义没变」。跨主版本时字段可能被重命名或
 * 改语义，硬读会把用户配置写成另一种意思 —— 那比拒绝加载糟糕得多。
 * 所以跨主版本一律拒，给出明确理由让用户去装新版扩展。
 *
 * 下限存在的原因
 * --------------
 * 往后长出来的字段（本版本还没有的）不可能被旧清单用到，但反过来：某个字段在
 * 1.1 才被「收紧」，而 1.0 的清单正好踩在收紧后的非法值上时，只有下限能挡住。
 * 所以下限是「低于此版本一律不认」，不是「高于此版本一律不认」。
 *
 * 短版本号
 * --------
 * `2`、`2.1` 也接受，缺的部分按 0 补 —— 桌面版的 PluginManifest.ApiVersion 是
 * 手填的自由文本，实际见过 `1.0`、`1.0.0`、`v1.0.0`。解析器容忍 `v` 前缀就是
 * 为了这些手填值，写清单的人不该因为少打两个数字而装不上。
 */

import { t } from '../i18n/I18n';
/** 本实现认的扩展 API 版本。清单里写的必须是同主版本且不低于下限。 */
export const PLUGIN_API_VERSION: string = '1.0.0';

/** 最低接受的 apiVersion。低于它一律拒收。 */
export const PLUGIN_API_MIN_VERSION: string = '1.0.0';

/**
 * 语义化版本。
 *
 * 预发布段（`1.0.0-beta.2`）保留为原文本并参与比较：`1.0.0-beta` < `1.0.0`。
 * 这条规则来自 semver 本身，实现它不是为了严谨，而是为了「beta 版扩展不会被
 * 当成正式版一起加载」—— 用户装了个测试版，不该和正式版抢同一个注册位。
 */
export class SemVer {
  major: number = 0;
  minor: number = 0;
  patch: number = 0;
  /** 预发布段原文（含前导 `-`）。无预发布段为空串。 */
  prerelease: string = '';

  static create(major: number, minor: number, patch: number, prerelease: string): SemVer {
    const out: SemVer = new SemVer();
    out.major = major;
    out.minor = minor;
    out.patch = patch;
    out.prerelease = prerelease;
    return out;
  }

  /**
   * 解析版本串。解不出来返回 undefined。
   *
   * 接受的形态：1 / 1.2 / 1.2.3 / v1.2.3 / 1.2.3-beta.1。段内必须是纯数字，
   * 前导零允许（`01` 就是 1）—— 手填的版本号里前导零不罕见，为它报错不值当。
   */
  static tryParse(text: string): SemVer | undefined {
    const trimmed: string = SemVer.trim(text);
    if (trimmed.length === 0) {
      return undefined;
    }
    const dash: number = trimmed.indexOf('-');
    let core: string = trimmed;
    let prerelease: string = '';
    if (dash >= 0) {
      core = trimmed.substring(0, dash);
      prerelease = trimmed.substring(dash);
    }
    const parts: string[] = core.split('.');
    if (parts.length === 0 || parts.length > 3) {
      return undefined;
    }
    let major: number = -1;
    let minor: number = 0;
    let patch: number = 0;
    for (let i = 0; i < parts.length; i++) {
      const value: number = SemVer.parseSegment(parts[i]);
      if (value < 0) {
        return undefined;
      }
      if (i === 0) {
        major = value;
      } else if (i === 1) {
        minor = value;
      } else {
        patch = value;
      }
    }
    return SemVer.create(major, minor, patch, prerelease);
  }

  /** 去空白与 `v` 前缀。 */
  private static trim(text: string): string {
    let out: string = text.trim();
    if (out.length > 0 && (out.charAt(0) === 'v' || out.charAt(0) === 'V')) {
      out = out.substring(1);
    }
    return out;
  }

  /** 段内纯数字则返回数值，否则 -1。空段返回 -1。 */
  private static parseSegment(text: string): number {
    if (text.length === 0) {
      return -1;
    }
    let value: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code < 48 || code > 57) {
        return -1;
      }
      value = value * 10 + (code - 48);
    }
    return value;
  }

  /**
   * 比较：a<b 返回 -1，相等 0，a>b 返回 1。
   *
   * 先比三段数字，再比预发布段。预发布段的比较逐个标识符做字典序，标识符里
   * 数字小的在前（semver 规定），这里不做那套细化 —— 预发布段只用来区分
   * 「有没有」，具体谁新谁旧不影响加载与否。
   */
  static compare(a: SemVer, b: SemVer): number {
    if (a.major !== b.major) {
      return a.major < b.major ? -1 : 1;
    }
    if (a.minor !== b.minor) {
      return a.minor < b.minor ? -1 : 1;
    }
    if (a.patch !== b.patch) {
      return a.patch < b.patch ? -1 : 1;
    }
    if (a.prerelease === b.prerelease) {
      return 0;
    }
    // 无预发布段 > 有预发布段（1.0.0 > 1.0.0-beta）。
    if (a.prerelease.length === 0) {
      return 1;
    }
    if (b.prerelease.length === 0) {
      return -1;
    }
    return a.prerelease < b.prerelease ? -1 : 1;
  }

  /** 与常量版本比较（供兼容判定用）。 */
  static equalsText(text: string, other: string): boolean {
    const a: SemVer | undefined = SemVer.tryParse(text);
    const b: SemVer | undefined = SemVer.tryParse(other);
    if (a === undefined || b === undefined) {
      return false;
    }
    return SemVer.compare(a, b) === 0;
  }

  toString(): string {
    const base: string = `${this.major}.${this.minor}.${this.patch}`;
    return this.prerelease.length === 0 ? base : `${base}${this.prerelease}`;
  }
}

/** apiVersion 判定结果。 */
export class ApiCompatibility {
  /** 认不认这份清单。 */
  supported: boolean = false;
  /** 认不了时给用户看的一句话。 */
  reason: string = '';
  /** 解析出来的主版本号；解析失败为 -1。 */
  parsedMajor: number = -1;
}

/**
 * 判定一份清单声明的 apiVersion 能不能用。
 *
 * 四种拒绝，各自给不同的理由 —— 用户要照着理由去决定「升应用」还是「降扩展」，
 * 一句笼统的「不兼容」没法指导任何动作。
 */
export function checkPluginApiVersion(apiVersion: string): ApiCompatibility {
  const out: ApiCompatibility = new ApiCompatibility();
  if (apiVersion.trim().length === 0) {
    out.reason = t('plugin_api_version_missing');
    return out;
  }
  const parsed: SemVer | undefined = SemVer.tryParse(apiVersion);
  if (parsed === undefined) {
    out.reason = `apiVersion「${apiVersion}」不是能认的版本号。写成 1.0 或 1.0.0 这样的形式。`;
    return out;
  }
  out.parsedMajor = parsed.major;
  const current: SemVer = SemVer.tryParse(PLUGIN_API_VERSION) as SemVer;
  const floor: SemVer = SemVer.tryParse(PLUGIN_API_MIN_VERSION) as SemVer;
  if (parsed.major !== current.major) {
    out.reason = `扩展要的是 API ${parsed.major}.x，当前应用是 ${current.major}.x。` +
      `跨主版本的字段含义可能不同，硬读会把设置写成另一种意思，所以不加载。`;
    return out;
  }
  if (SemVer.compare(parsed, floor) < 0) {
    out.reason = `扩展要的是 API ${parsed.toString()}，当前应用最低支持 ${floor.toString()}。`;
    return out;
  }
  out.supported = true;
  return out;
}

/** 扩展 id 的合法性：小写字母、数字、点、横线，1~64 位，必须以字母或数字开头。 */
export function isValidPluginId(id: string): boolean {
  if (id.length === 0 || id.length > 64) {
    return false;
  }
  const first: number = id.charCodeAt(0);
  if (!isIdChar(first) || isIdDash(first)) {
    return false;
  }
  for (let i = 1; i < id.length; i++) {
    const code: number = id.charCodeAt(i);
    if (!isIdChar(code) && !isIdDash(code)) {
      return false;
    }
  }
  return true;
}

/** 小写字母 / 数字 / 点。 */
function isIdChar(code: number): boolean {
  if (code >= 97 && code <= 122) {
    return true;
  }
  return code >= 48 && code <= 57;
}

function isIdDash(code: number): boolean {
  return code === 45 || code === 46;
}