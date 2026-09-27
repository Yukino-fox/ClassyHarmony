/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * NTP 协议编解码与偏差计算（RFC 5905）。
 *
 * 为什么放 core
 * -------------
 * 这里的位运算与纪元换算最容易错，而错了不会报错 —— 只会让时间静悄悄地偏
 * 几十秒，表现为「课表高亮总是慢半拍」，极难从界面上看出是这里的问题。
 * 放进 Node 测试台就能把边界（跨秒、跨天、纪元前、服务器不可信）全部钉死。
 * 真正的 socket I/O 在 entry 侧的 NtpClient，只负责收发。
 *
 * 报文布局（48 字节）
 * -------------------
 *   0      LI/VN/Mode
 *   1      Stratum
 *   2–3    Poll
 *   4      Precision
 *   5–7    Root Delay
 *   8–11   Root Dispersion
 *   12–15  Reference ID
 *   16–23  Reference Timestamp
 *   24–31  Originate Timestamp（回显我们的发送时刻）
 *   32–39  Receive  Timestamp（服务器收到）
 *   40–47  Transmit Timestamp（服务器发出）
 *
 * 时间戳格式：距 1900-01-01 的秒数（32 位）+ 小数部分（32 位，秒的
 * 2⁻³² 分之一）。1900 到 1970 差 2208988800 秒，这个常数是全部换算的支点。
 */

/** NTP 报文长度。短于此长度的响应一律判为无效。 */
export const NTP_PACKET_SIZE: number = 48;

/** 1900-01-01 到 1970-01-01 的秒数。NTP 与 Unix 两套纪元的换算常数。 */
export const NTP_EPOCH_OFFSET_SECONDS: number = 2208988800;

/** 2³²。NTP 小数部分的除数。 */
const FRACTION_SCALE: number = 4294967296;

/**
 * 一次 NTP 响应里我们真正用到的字段。
 *
 * 只解这四个：originate 是回显，拿它核对「这个包确实是回应我们那次的」；
 * receive/transmit 是偏差公式的输入；stratum 与 leap 是可信度判断。
 * root delay / dispersion / reference id 全都不看 —— 桌面版也没看，
 * 那些字段只有在要做严格的服务质量统计时才有用，而这里只要一个「够准的
 * 现在」，不做一个「权威的时间源」。
 */
export interface NtpResponse {
  /** 服务器发出时刻，本地纪元毫秒。 */
  transmitMillis: number;
  /** 服务器收到时刻，本地纪元毫秒。 */
  receiveMillis: number;
  /** 服务器回显的我们的发送时刻，本地纪元毫秒。0 表示没有有效回显。 */
  originateMillis: number;
  /** Stratum。0 = 退化源（不可用），1 = 一级时钟。 */
  stratum: number;
  /** Leap Indicator：0 正常，1 闰秒将发生，2 已进入闰秒，3 不可用。 */
  leap: number;
  /** Version。 */
  version: number;
  /** Mode：4 = 服务器，3 = 客户端。 */
  mode: number;
}

/** 解析失败的原因。用来区分「网络没通」与「服务器在说胡话」。 */
export enum NtpReject {
  /** 报文比 48 字节短。 */
  Short = 0,
  /** 不是服务器回应的包（Mode 不是 4）。 */
  NotServer = 1,
  /** Stratum 为 0，退化源。 */
  Degraded = 2,
  /** Leap Indicator 为 3，源已失效。 */
  Unusable = 3,
  /** 时间戳换算出来不是有限数。 */
  NotFinite = 4
}

/** 解析结果。ok 为 false 时 reason 有值、其余字段无意义。 */
export interface NtpParseResult {
  ok: boolean;
  reason: NtpReject;
  response: NtpResponse | undefined;
}

/**
 * 造一个 48 字节的 NTP 请求。
 *
 * 第一个字节 0x1B = LI(0) | VN(3) | Mode(3)：无警告、版本 3、客户端。
 * 桌面版用的 GuerrillaNtp 也是 VN3，两端同一个版本，避免服务端按不同
 * 版本解析出不同的字段宽度。
 *
 * 剩下的 47 字节全 0：请求里不携带任何时间信息（时间在响应里由服务器填
 * receive/transmit，再由我们自己的 T1/T4 参与偏差计算）。带上发送时刻
 * 反而多一个「客户端时钟不准就污染了 originate」的坑。
 */
export function buildNtpRequest(): ArrayBuffer {
  const buf: ArrayBuffer = new ArrayBuffer(NTP_PACKET_SIZE);
  const view: DataView = new DataView(buf);
  view.setUint8(0, 0x1b);
  return buf;
}

/** 读 8 字节时间戳（offset 处的秒 + 小数），转成 Unix 纪元毫秒。 */
function readTimestamp(view: DataView, offset: number): number {
  const seconds: number = view.getUint32(offset);
  const fraction: number = view.getUint32(offset + 4);
  // 1900 纪元的 0 在 Unix 纪元里是负数（1900 在 1970 之前），
  // 所以这里必须用减号。写成加号会得到 1970 年之后的时间。
  return (seconds - NTP_EPOCH_OFFSET_SECONDS) * 1000 +
    (fraction * 1000) / FRACTION_SCALE;
}

/**
 * 解析 48 字节的 NTP 响应。
 *
 * 拒绝而不是尽量返回，理由是「时间错了但看起来对」比「时间没同步」危险
 * 得多：没同步时用户看到的是系统时间（通常够用），而解析错一个字节得到
 * 的时间会让课表高亮偏得莫名其妙且无从察觉。
 */
export function parseNtpResponse(packet: ArrayBuffer): NtpParseResult {
  if (packet.byteLength < NTP_PACKET_SIZE) {
    return { ok: false, reason: NtpReject.Short, response: undefined };
  }
  const view: DataView = new DataView(packet);
  const flags: number = view.getUint8(0);
  const leap: number = (flags >> 6) & 0x03;
  const version: number = (flags >> 3) & 0x07;
  const mode: number = flags & 0x07;

  // Mode 4 才是服务器。其余（3 客户端、2 对等、5 广播…）都不是我们要的回应。
  if (mode !== 4) {
    return { ok: false, reason: NtpReject.NotServer, response: undefined };
  }
  if (leap === 3) {
    return { ok: false, reason: NtpReject.Unusable, response: undefined };
  }
  const stratum: number = view.getUint8(1);
  // Stratum 0 = 退化源（服务器自己也拿不到准的时间，通常是 GPS 未锁定）。
  // 单看 stratum 1 会漏掉这一种。
  if (stratum === 0) {
    return { ok: false, reason: NtpReject.Degraded, response: undefined };
  }

  const originate: number = readTimestamp(view, 24);
  const receive: number = readTimestamp(view, 32);
  const transmit: number = readTimestamp(view, 40);
  if (!isFinite(originate) || !isFinite(receive) || !isFinite(transmit)) {
    return { ok: false, reason: NtpReject.NotFinite, response: undefined };
  }

  const response: NtpResponse = {
    transmitMillis: transmit,
    receiveMillis: receive,
    originateMillis: originate,
    stratum: stratum,
    leap: leap,
    version: version,
    mode: mode
  };
  return { ok: true, reason: 0, response: response };
}

/**
 * 四个时间戳算出的偏差（毫秒）。正数表示本机慢。
 *
 *     offset = ((T2 − T1) + (T3 − T4)) / 2
 *
 * T1 我们发出、T2 服务器收到、T3 服务器发出、T4 我们收到。公式把两个方向
 * 的单程延迟对消掉一半，剩下的就是两端时钟的差。
 *
 * @param t1Millis 我们发出请求的本地纪元毫秒
 * @param response 已解析的响应
 * @param t4Millis 我们收到响应的本地纪元毫秒
 */
export function ntpOffsetMillis(t1Millis: number, response: NtpResponse,
  t4Millis: number): number {
  return ((response.receiveMillis - t1Millis) + (response.transmitMillis - t4Millis)) / 2;
}

/**
 * 往返延迟（毫秒）。
 *
 *     delay = (T4 − T1) − (T3 − T2)
 *
 * 用来判断这次同步可不可信：延迟越大，偏差估计的误差范围越宽。超过
 * 阈值就该丢掉这次结果而不是拿去做偏移 —— 见 ExactClock 的采纳条件。
 */
export function ntpDelayMillis(t1Millis: number, response: NtpResponse,
  t4Millis: number): number {
  return (t4Millis - t1Millis) - (response.transmitMillis - response.receiveMillis);
}
