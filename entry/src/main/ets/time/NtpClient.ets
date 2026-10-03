/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * NTP 客户端：UDP 收发。
 *
 * 只做 I/O，一行判断都不做
 * ----------------------
 * 报文编解码、偏差公式、是否采纳全在 common_core 的 NtpProtocol / ExactClock
 * 里，那两个文件能在 Node 测试台里穷举边界。这里若顺手写个「if (retcode)
 * 抛错」之类的判断，等于把已经测过的东西在这里重写一遍，且这次没人测。
 *
 * 每次查询新建 socket 的理由
 * ------------------------
 * UDP 无连接，socket 建了不 bind 也能发（系统随机分配源端口）。复用单个
 * socket 看着省资源，实则有两个坑：
 *   - 上一轮的 message 监听必须先摘掉再挂新的，否则两个回调同时在列，
 *     迟到一个包会被算成本轮的响应；
 *   - 上轮超时后残留的 in-flight 状态要手动清，而这个状态藏在一个
 *     Promise 的闭包里，清起来很容易漏。
 * 一次同步 10 分钟一次，一次 socket 的开销可以忽略，换来的是「没有跨调用
 * 状态」——和 core 层可重入的约束是同一个道理。
 *
 * 超时自己实现
 * ------------
 * UDPSocket 的 socketTimeout 只作用在 bind 上，不覆盖「发出去之后等回包」
 * 这段时间。UDP 丢包是常态（禁火墙、基站切换、NAT 超时），不设超时的
 * Promise 会永远挂着，10 分钟的定时器就会一轮轮堆新的挂起任务。
 *
 * 精度上的取舍
 * ------------
 * T1/T4 都取 Date.now()，毫秒精度。对一个课表应用足够：NTP 协议本身的
 * 网络抖动就有几毫秒，亚毫秒精度的报文在 4G 上拿不到。桌面版能做得更细
 * 是因为它跑在桌面上网路径稳定，两端的差异不会反映到用户的观感上。
 */

import { socket } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { NTP_PACKET_SIZE, NtpParseResult, NtpResponse, buildNtpRequest, parseNtpResponse, t, tf } from 'common_core';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'NtpClient';

/** NTP 标准端口。 */
const NTP_PORT: number = 123;

/** 一次查询的超时（毫秒）。 */
const QUERY_TIMEOUT_MS: number = 3000;

/** 一次查询的完整结果。 */
export interface NtpQueryResult {
  /** 是否拿到了可用的响应。false 时下面三个字段无意义。 */
  ok: boolean;
  /** 我们发出请求的时刻（本地纪元毫秒），失败时为 0。 */
  t1Millis: number;
  /** 收到的响应。 */
  response: NtpResponse | undefined;
  /** 我们收到响应的时刻（本地纪元毫秒），失败时为 0。 */
  t4Millis: number;
  /** 失败原因，仅供日志。 */
  detail: string;
}

/**
 * 向一台 NTP 服务器发一次查询。
 *
 * 永不抛异常：调用方是 10 分钟一次的定时器，抛出去要么变成未处理的
 * Promise 拒绝，要么被 catch 住然后没人知道发生了什么。所有失败都收在
 * ok=false 与 detail 里。
 *
 * @param host 服务器域名或 IP。不含端口（固定 123）。
 */
export async function queryNtp(host: string): Promise<NtpQueryResult> {
  const trimmed: string = host.trim();
  if (trimmed.length === 0) {
    return { ok: false, t1Millis: 0, response: undefined, t4Millis: 0, detail: t('ntp_empty_server') };
  }

  const client: socket.UDPSocket = socket.constructUDPSocketInstance();
  // T1 只在 send 的那一刻有意义，所以它必须在闭包外声明 —— 放进 Promise
  // 里就只能靠外层的可变变量带出来，那等于引入跨调用状态，与本文件的
  // 「每次查询自带全部状态」前提冲突。
  let t1: number = 0;
  try {
    // 只监听首个包。多余的包（重传、伪造）直接丢掉：NTP 无连接，无法按
    // 事务配对，「第一个到达的就是我要的」是协议在这里能给的最好保证。
    const received: ArrayBuffer = await new Promise<ArrayBuffer>((resolve, reject) => {
      let settled: boolean = false;
      const timer: number = setTimeout(() => {
        if (!settled) {
          settled = true;
          reject(new Error('NTP 查询超时'));
        }
      }, QUERY_TIMEOUT_MS) as number;

      client.on('message', (info: socket.SocketMessageInfo): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(info.message);
      });
      client.on('error', (err: Error): void => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          reject(err);
        }
      });

      // 记在 send 的紧前一行：这里取的时间就是偏差公式的 T1。
      t1 = Date.now();
      const address: connection.NetAddress = {
        address: trimmed,
        port: NTP_PORT,
        family: 1
      };
      client.send({ data: buildNtpRequest(), address: address })
        .then((): void => {
          // 发出去了。T1 已在上面记下，这里不用做什么 —— 响应可能在
          // .then 挂上之前就到了，on('message') 已经能收到。
        })
        .catch((err: Error): void => {
          if (!settled) {
            settled = true;
            clearTimeout(timer);
            reject(err);
          }
        });
    });

    // 收到即记 T4。必须紧贴收包时刻取：多等一帧，偏差公式里就多出
    // 一帧的误差，弱网下这一帧可能是几百毫秒。
    const t4: number = Date.now();
    const parsed: NtpParseResult = parseNtpResponse(received);
    if (!parsed.ok || parsed.response === undefined) {
      return {
        ok: false,
        t1Millis: 0,
        response: undefined,
        t4Millis: 0,
        detail: tf('ntp_bad_response', `${parsed.reason}`)
      };
    }
    return { ok: true, t1Millis: t1, response: parsed.response, t4Millis: t4, detail: '' };
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'queryNtp failed: %{public}s', `${err}`);
    return { ok: false, t1Millis: 0, response: undefined, t4Millis: 0, detail: `${err}` };
  } finally {
    // 无论如何都关掉。不关的话 socket 与它的监听器会一直挂着，直到
    // GC —— 而 GC 时机不可控，10 分钟一轮的话一周就能攒出几十个。
    try {
      await client.close();
    } catch (err) {
      hilog.debug(DOMAIN, TAG, 'close failed: %{public}s', `${err}`);
    }
  }
}
