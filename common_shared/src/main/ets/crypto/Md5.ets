/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * MD5。
 *
 * 用途与「为什么用 MD5」
 * --------------------
 * 只用来做语音缓存的内容寻址：`MD5(UTF-8(文本))` 当文件名。这是桌面版的
 * 口径（EdgeTtsService.GetCachePath / GptSoVitsService.GetCachePath 都是
 * MD5.HashData + 小写十六进制），照抄的理由是同一条提醒在两端算出的键相同，
 * 将来把缓存目录同步过去就能直接命中，而不必重新合成一遍。
 *
 * 不是为了安全。做内容寻址时 MD5 的碰撞代价是「缓存里两个文本共享一份音频」，
 * 而这里的文本是提醒文案（短、来自用户自己的课表），构造碰撞需要刻意为之。
 * 换成 SHA-256 只会让结果与桌面版对不上。
 *
 * 为什么不用 kit 里的摘要
 * ----------------------
 * @kit.CryptoArchitectureKit 有 md5，但那是异步的（createMd5 → update →
 * digest 都返回 Promise），而它承担的工作是给一个几百字节的字符串算文件名。
 * 更要紧的是：common_shared 的约定是不依赖 kit，这一层要能被 Node 测试台
 * 直接 import 跑。一个能拿 RFC 1321 官方向量逐条对答案的纯函数，比一个需要
 * 在测试台里搭桩的异步调用更可信。
 *
 * 实现上没有用 Math.sin 现算 K 表：不同引擎的 sin 末位可能差一个 ulp，
 * 乘 2³² 之后就是一个完全不同的 32 位常数，而错一位就要等用户发现「同一条
 * 文本在两端算出不同文件名」。K 与移位数都是硬编码的表。
 *
 * 字节口径见 ../text/Utf8.ets。同一个字符串必须编出同一串字节，否则摘要
 * 不同、缓存不命中，而这种不命中是静默的 —— 只表现为每次都重新合成一遍，
 * 慢一点，没人会去查。
 */

import { encodeUtf8 } from '../text/Utf8';

/** 每轮的循环左移位数。 */
const SHIFTS: number[] = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
];

/** K[i] = floor(abs(sin(i + 1)) * 2³²)，硬编码见文件头。 */
const K: number[] = [
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
];

/** 摘要的十六进制表示，小写 32 位。 */
export function md5Hex(input: Uint8Array): string {
  const padded: Uint8Array = pad(input);
  let a0: number = 0x67452301;
  let b0: number = 0xefcdab89;
  let c0: number = 0x98badcfe;
  let d0: number = 0x10325476;

  const words: Uint32Array = new Uint32Array(16);
  for (let offset: number = 0; offset < padded.length; offset += 64) {
    for (let j: number = 0; j < 16; j++) {
      words[j] = readUint32Le(padded, offset + j * 4);
    }
    let a: number = a0;
    let b: number = b0;
    let c: number = c0;
    let d: number = d0;

    for (let i: number = 0; i < 64; i++) {
      // 显式初始化：四段 if/else 覆盖了全部 i，但 ArkTS 对「声明后经分支
      // 赋值」的确定性判定比 TS 严，写死初值可以不依赖分析器的能力。
      let f: number = 0;
      let g: number = 0;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }
      const prevD: number = d;
      d = c;
      c = b;
      // 四者相加可能越过 32 位，| 0 截回 int32 —— 后面每步都依赖这个截断。
      const sum: number = (a + f + K[i] + words[g]) | 0;
      b = (b + rotateLeft(sum, SHIFTS[i])) | 0;
      a = prevD;
    }

    a0 = (a0 + a) | 0;
    b0 = (b0 + b) | 0;
    c0 = (c0 + c) | 0;
    d0 = (d0 + d) | 0;
  }

  return hex32(a0) + hex32(b0) + hex32(c0) + hex32(d0);
}

/** 文本的 MD5，小写十六进制。内部按 UTF-8 取字节。 */
export function md5HexOfText(text: string): string {
  return md5Hex(encodeUtf8(text));
}

/**
 * 填充到 64 字节的整数倍。
 *
 * 布局：原文 + 0x80 + 若干 0x00 + 8 字节小端消息长度（**比特**数）。
 * 「补 0x80」这一位是无条件的 —— 原文长度恰好是 56 mod 64 时也要补，
 * 于是多出一整个块。少补这一位是最常见的实现错误，且只在特定长度上出错，
 * 所以测试里专门钉了 55 / 56 / 57 三个长度。
 */
function pad(input: Uint8Array): Uint8Array {
  const total: number = paddedLength(input.length);
  const out: Uint8Array = new Uint8Array(total);
  out.set(input);
  out[input.length] = 0x80;
  const bits: number = input.length * 8;
  // 64 位长度，小端。长度超过 2⁵³ 才会用到高 32 位，那时 Number 已经不能
  // 精确表示字节数了；这里仍然算对，只是调用方不可能走到。
  writeUint32Le(out, total - 8, bits >>> 0);
  writeUint32Le(out, total - 4, Math.floor(bits / 4294967296) | 0);
  return out;
}

/** 填充后的总长度：至少留出 0x80 与 8 字节长度。 */
function paddedLength(length: number): number {
  const withMarker: number = length + 1 + 8;
  const blocks: number = Math.floor((withMarker + 63) / 64);
  return blocks * 64;
}

function writeUint32Le(target: Uint8Array, offset: number, value: number): void {
  target[offset] = value & 0xff;
  target[offset + 1] = (value >>> 8) & 0xff;
  target[offset + 2] = (value >>> 16) & 0xff;
  target[offset + 3] = (value >>> 24) & 0xff;
}

/** 读成无符号。返回 signed 也等价 —— 参与运算前都会被 | 0 截断。 */
function readUint32Le(source: Uint8Array, offset: number): number {
  return source[offset] | (source[offset + 1] << 8) |
    (source[offset + 2] << 16) | (source[offset + 3] << 24);
}

function rotateLeft(value: number, bits: number): number {
  return (value << bits) | (value >>> (32 - bits));
}

/**
 * 32 位寄存器的定长小写十六进制。
 *
 * 必须**小端**输出。RFC 1321 规定摘要是 a、b、c、d 四个寄存器各自「低位
 * 字节在前」地拼起来，而不是把寄存器当一个整数写成十六进制。搞反的后果
 * 很隐蔽：算法完全正确、任何圆整性检查都通不过去，只是每个字内部字节倒序，
 * 于是拿到的 32 位十六进制看着像模像样，却和任何标准实现都对不上 —— 缓存
 * 键永远不命中，也不会有任何报错。
 *
 * 这一条是被测试抓出来的：`md5HexOfText('中文')` 曾得到 23c2baa7…，而期望
 * 是 a7bac223…，正好是每 4 字节一组倒序。不要「优化」成 toString(16)。
 */
function hex32(value: number): string {
  const unsigned: number = value >>> 0;
  return hexByte(unsigned & 0xff) + hexByte((unsigned >>> 8) & 0xff) +
    hexByte((unsigned >>> 16) & 0xff) + hexByte((unsigned >>> 24) & 0xff);
}

/** 单字节的两位小写十六进制。 */
function hexByte(value: number): string {
  const text: string = (value & 0xff).toString(16);
  return text.length < 2 ? `0${text}` : text;
}
