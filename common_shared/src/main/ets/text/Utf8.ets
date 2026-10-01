/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * UTF-8 编码。
 *
 * 为什么要自己写而不用 TextEncoder
 * ------------------------------
 * TextEncoder 在 @kit.ArkTS 里，属于平台 API。而 common_shared 的约定是
 * 「不依赖任何 kit」—— 它要能被 Node 测试台直接 import 跑（那套测试有
 * 2700 多项，跑一次两秒；而把平台 API 引进这一层就得在测试台里补全套桩，
 * 反而更容易出「测试环境能过、真机不行」这种事）。所以基础编码留在这一层。
 *
 * 与平台实现、与 .NET 的口径都一致
 * --------------------------------
 * 具体的口径只有两条容易踩：
 *   - 代理对要合成成一个码点（4 字节），不能按两个 UTF-16 码元各编一个
 *     3 字节序列（那是 CESU-8，emoji 在两种实现下会得到完全不同的字节）；
 *   - 落单的代理（高位后面不是低位、或单独一个低位）编码成 U+FFFD 的
 *     三字节序列，而不是报错或丢弃。TextEncoder 与 .NET 的
 *     Encoding.UTF8.GetBytes 都是这个行为。
 * 这两条对「同一个字符串在两端得到同一串字节」是必要的 —— 语音缓存的键
 * 就是这串字节的摘要，两端口径不同会让同一个提醒算出两个键。
 */

/** 替换字符的码点。落单代理按它编码。 */
const REPLACEMENT: number = 0xfffd;

/**
 * 把字符串编成 UTF-8 字节。
 *
 * 用 number[] 收集再转 Uint8Array：结果长度最多是字符数的三倍，先估一个
 * 容量（中文三字节、ASCII 一字节，混排时估不足）也不划算，而 push 在这个
 * 量级（提醒文本几百字节）上完全不是瓶颈。
 */
export function encodeUtf8(text: string): Uint8Array {
  const out: number[] = [];
  for (let i: number = 0; i < text.length; i++) {
    const cp: number = codePointAt(text, i);
    // 合成过代理对时 i 被推进了一格，这里跟着推进。
    if (cp > 0xffff) {
      i++;
    }
    if (cp < 0x80) {
      out.push(cp);
    } else if (cp < 0x800) {
      out.push(0xc0 | (cp >> 6));
      out.push(0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
      out.push(0xe0 | (cp >> 12));
      out.push(0x80 | ((cp >> 6) & 0x3f));
      out.push(0x80 | (cp & 0x3f));
    } else {
      out.push(0xf0 | (cp >> 18));
      out.push(0x80 | ((cp >> 12) & 0x3f));
      out.push(0x80 | ((cp >> 6) & 0x3f));
      out.push(0x80 | (cp & 0x3f));
    }
  }
  return new Uint8Array(out);
}

/**
 * 取第 index 个字符的码点。
 *
 * 返回大于 0xffff 时说明这是一个代理对的高位，调用方要负责把 index 加一。
 * 落单的高位、落单的低位都直接给 U+FFFD。
 */
function codePointAt(text: string, index: number): number {
  const unit: number = text.charCodeAt(index);
  if (unit < 0xd800 || unit > 0xdfff) {
    return unit;
  }
  if (unit > 0xdbff) {
    // 落单低位代理。
    return REPLACEMENT;
  }
  const low: number = index + 1 < text.length ? text.charCodeAt(index + 1) : 0;
  if (low < 0xdc00 || low > 0xdfff) {
    return REPLACEMENT;
  }
  return 0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00);
}

/** 把 UTF-8 字节解回字符串的逆向不提供：这一层没有任何解码需求。 */
