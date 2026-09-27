/*
 * 精确时间测试台（NTP 对时 + 时钟）。
 *
 * 这一套东西最恶劣的失败模式是「错了但不报错」：位序错一个字节，纪元差
 * 2208988800 秒，偏差算出来是 24 万年 —— 但 `Math.abs()` 照样是个数，界面
 * 照样显示一行字，只是课表高亮永远差着半拍。没有任何异常能提示你。
 *
 * 所以这里把「静默出错」当主要目标来覆盖：
 *
 *   1. 纪元换算是**减**不是加。1900 在 1970 之前，符号错一次整个时间落到
 *      1754 年。断言用的是往返构造（把已知毫秒编进报文再解出来），而不是
 *      「解出来接近现在」——后者在符号错时会给出天文数字，一眼就能看出，
 *      根本测不到「差一点点」这种真正危险的情况。
 *   2. 小数部分是秒的 2⁻³² 分之一，不是 1e9（100 纳秒刻度）。两套刻度差
 *      4.29 倍，用错的话毫秒级精度直接变分钟级。
 *   3. Mode 必须是 4。收到自己的请求回显（Mode 3）当成响应，会得到一个
 *      「服务器转��时刻 = 0」的荒谬结果。Stratum 0 与 Leap 3 同样必须拒。
 *   4. 拒绝而不是尽力返回：宁可显示系统时间（通常够用），也不要显示一个
 *      看起来正常实际偏了 30 秒的时间。
 *   5. 偏差公式 ((T2−T1)+(T3−T4))/2 在「本机慢 5 秒」与「本机快 5 秒」两
 *      个方向上的符号都验。符号错的表现是「校时之后偏得更多了」，而这在
 *      界面上和「校时之前本来就偏」长得一模一样。
 *   6. 延迟为负（请求期间本机时钟往回走）必须拒。采纳它等于把跳变当成偏差。
 *   7. 冻结解除后基线必须重建。不重建就是永久冻结 —— 每次 now() 都拿跳变
 *      前的基线去比，判定永远成立。这条是本模块最容易犯且最难发现的错。
 *   8. 拿不到单调时钟时不做跳变检测（传 -1），而不是当成检测到跳变。后者
 *      会让时钟在某些设备上永久冻结，且没有任何恢复路径。
 *   9. 反向跳「保持」与系统跳变「冻结」是两种机制，阈值不同（30s vs 5s），
 *      解除条件也不同（真实时间追上 vs 一次新同步）。
 *  10. 手动偏移加在最后，且不受冻结/保持影响 —— 它是用户表达偏好，不是
 *      「现在几点」，冻结的语义是「钟停住」，不是「偏好也停住」。
 */

import { DateTimeValue } from '../../common_shared/src/main/ets/json/DateTimeValue';
import {
  NTP_EPOCH_OFFSET_SECONDS,
  NTP_PACKET_SIZE,
  NtpReject,
  NtpResponse,
  buildNtpRequest,
  ntpDelayMillis,
  ntpOffsetMillis,
  parseNtpResponse
} from '../../common_core/src/main/ets/time/NtpProtocol';
import {
  BACKWARD_HOLD_LIMIT_MS,
  ExactClock,
  MAX_ACCEPTABLE_DELAY_MS,
  SYSTEM_JUMP_THRESHOLD_MS,
  SyncOutcome
} from '../../common_core/src/main/ets/time/ExactClock';
import {
  DailyAutoAdjustPlan,
  elapsedWholeDays,
  planDailyAutoAdjust
} from '../../common_core/src/main/ets/time/DailyAutoAdjust';

let passed: number = 0;
const failures: string[] = [];

function check(name: string, condition: boolean, detail: string = ''): void {
  if (condition) {
    passed++;
  } else {
    failures.push(detail.length === 0 ? name : `${name} —— ${detail}`);
  }
}

function checkEqual(name: string, actual: string, expected: string): void {
  check(name, actual === expected, `实际 ${actual}，期望 ${expected}`);
}

function checkNum(name: string, actual: number, expected: number): void {
  check(name, actual === expected, `实际 ${actual}，期望 ${expected}`);
}

/** 时间戳误差容忍（毫秒）。浮点换算在 2³² 分之一上必然有舍入。 */
const TOLERANCE_MS: number = 0.001;

// --------------------------------------------------------------- 构造夹具

/**
 * 造一个 48 字节响应。
 *
 * @param unixMillis 服务器给出的时刻（Unix 纪元毫秒）。0 会被当作「未填」。
 * @param mode Mode 字段，默认 4（服务器）
 * @param leap Leap Indicator，默认 0
 * @param stratum Stratum，默认 2
 */
function buildResponse(unixMillis: number, mode: number = 4, leap: number = 0,
  stratum: number = 2): ArrayBuffer {
  const buf: ArrayBuffer = new ArrayBuffer(NTP_PACKET_SIZE);
  const view: DataView = new DataView(buf);
  // LI(2) | VN(4) | Mode(3)。版本填 4 只是让 version 字段有值可断言。
  view.setUint8(0, (leap << 6) | (4 << 3) | mode);
  view.setUint8(1, stratum);
  writeTimestamp(view, 32, unixMillis);
  writeTimestamp(view, 40, unixMillis);
  return buf;
}

/** 往报文 offset 处写一个 Unix 纪元毫秒的时间戳。 */
function writeTimestamp(view: DataView, offset: number, unixMillis: number): void {
  // 毫秒 → 秒 + 2⁻³² 分之一。整数秒与小数分开算，避免大数相减丢精度。
  const seconds: number = Math.floor(unixMillis / 1000) + NTP_EPOCH_OFFSET_SECONDS;
  const fraction: number = Math.round((unixMillis % 1000) * (4294967296 / 1000));
  view.setUint32(offset, seconds);
  view.setUint32(offset + 4, fraction);
}

/** 造一份已通过校验的响应，省掉每个用例的 parse 断言。 */
function okResponse(unixMillis: number): NtpResponse {
  const parsed = parseNtpResponse(buildResponse(unixMillis));
  if (!parsed.ok || parsed.response === undefined) {
    throw new Error(`夹具构造失败：${parsed.reason}`);
  }
  return parsed.response;
}

/**
 * 造一个「本机慢 offsetMs、往返延迟 roundTripMs」的测量。
 *
 * 服务器看到的发送时刻 = 本机发出 + 真实偏差 + 上行延迟。
 * 这里 uplink = roundTrip / 2，downlink = roundTrip / 2，服务器时刻不动，
 * 于是公式算出来的偏差恰好等于传入的 offsetMs。
 */
function measure(t1: number, offsetMs: number, roundTripMs: number): NtpResponse {
  return okResponse(t1 + offsetMs + roundTripMs / 2);
}

// --------------------------------------------------------------- 请求报文

function testRequest(): void {
  const req: ArrayBuffer = buildNtpRequest();
  checkNum('请求报文是 48 字节', req.byteLength, NTP_PACKET_SIZE);
  const view: DataView = new DataView(req);
  // 0x1B = 0b00_011_011：LI=0（无警告）VN=3（版本 3）Mode=3（客户端）。
  // 与桌面版 GuerrillaNtp 同为 VN3，两端版本一致，服务端才会按同一宽度解析。
  checkNum('请求首字节 0x1B（VN3 客户端）', view.getUint8(0), 0x1b);
  checkNum('请求首字节 Mode = 3', view.getUint8(0) & 0x07, 3);
  checkNum('请求首字节 VN = 3', (view.getUint8(0) >> 3) & 0x07, 3);
  checkNum('请求首字节 LI = 0', (view.getUint8(0) >> 6) & 0x03, 0);

  // 请求里不带时间戳：带上就等于把自己的（可能不准的）时钟写进 originate，
  // 污染回显字段。剩下 47 字节必须全 0。
  let allZero: boolean = true;
  for (let i: number = 1; i < NTP_PACKET_SIZE; i++) {
    if (view.getUint8(i) !== 0) {
      allZero = false;
    }
  }
  check('请求其余 47 字节全 0', allZero);

  // 请求不能被当成响应解析：Mode 是 3 不是 4。
  const parsed = parseNtpResponse(req);
  check('请求自身被拒（Mode 非 4）', !parsed.ok && parsed.reason === NtpReject.NotServer,
    `reason=${parsed.reason}`);
}

// --------------------------------------------------------------- 纪元换算

function testEpochRoundTrip(): void {
  // 往返构造：已知毫秒 → 报文 → 解回。符号错、刻度错都测得到，
  // 而且不依赖「现在几点」。
  //
  // 样本全部落在 32 位秒字段内（1900-01-01 ~ 2036-02-07）。NTP 的秒数
  // 是无符号 32 位，2036 年会回绕 —— 那是协议本身的性质，见下面那条
  // 专门的回绕用例，不是本实现的缺陷。
  const samples: number[] = [
    0,                          // Unix 纪元
    1000,                       // 整秒
    1,                          // 1 毫秒
    999,                        // 不到一秒
    1767225599000,              // 2026-01-01 前后
    946684800000,               // 2000-01-01
    2085978495000               // 2036-02-07 06:28:15Z，最后一个可表示秒
  ];
  for (const sample of samples) {
    const view: DataView = new DataView(new ArrayBuffer(NTP_PACKET_SIZE));
    writeTimestamp(view, 40, sample);
    const buf: ArrayBuffer = view.buffer as ArrayBuffer;
    const parsed = parseNtpResponse(buildWithStamp(buf));
    if (!parsed.ok || parsed.response === undefined) {
      check(`纪元往返 ${sample}`, false, `解析失败 reason=${parsed.reason}`);
      continue;
    }
    const got: number = parsed.response.transmitMillis;
    check(`纪元往返 ${sample}`,
      Math.abs(got - sample) < TOLERANCE_MS, `实际 ${got}`);
  }

  // 纪元常数本身：1900-01-01 到 1970-01-01。
  checkNum('纪元偏移常数 2208988800', NTP_EPOCH_OFFSET_SECONDS, 2208988800);

  // 符号方向：秒数为 0（1900-01-01）时，解出来必须是**负**的 Unix 毫秒。
  // 写成加号会得到 1970 年之后 —— 这条单独钉住，因为它是唯一一个
  // 「看起来能跑」的符号错误。
  const view: DataView = new DataView(new ArrayBuffer(NTP_PACKET_SIZE));
  const v0: DataView = view;
  v0.setUint8(0, (4 << 3) | 4);
  v0.setUint8(1, 1);
  const parsed1900 = parseNtpResponse(view.buffer as ArrayBuffer);
  check('1900 纪元解出负的 Unix 毫秒',
    parsed1900.ok && parsed1900.response !== undefined &&
    parsed1900.response.transmitMillis < 0,
    parsed1900.ok && parsed1900.response !== undefined
      ? `实际 ${parsed1900.response.transmitMillis}` : '解析失败');
  checkNum('1900 纪元恰为 -2208988800000 毫秒',
    parsed1900.ok && parsed1900.response !== undefined
      ? parsed1900.response.transmitMillis : 0, -2208988800000);

  // 32 位秒字段的上界。0xFFFFFFFF 是**最后一个可表示的秒**
  // （2036-02-07T06:28:15Z），再加 1 秒就回绕到 1900-01-01 —— NTP 用
  // Era 号区分两段 136 年，协议里没有传输 Era，所以本实现也无从区分。
  // 这不是本实现的 bug；把边界值钉成断言，是为了让「加偏移后变成
  // 负数」这种改法立刻暴露出来。
  const rollView: DataView = new DataView(new ArrayBuffer(NTP_PACKET_SIZE));
  rollView.setUint8(0, (4 << 3) | 4);
  rollView.setUint8(1, 2);
  rollView.setUint32(32, 0xffffffff);
  rollView.setUint32(40, 0xffffffff);
  const rolled = parseNtpResponse(rollView.buffer as ArrayBuffer);
  checkNum('秒字段 0xFFFFFFFF = 2085978495000（2036 回绕上界）',
    rolled.ok && rolled.response !== undefined
      ? rolled.response.transmitMillis : 0, 2085978495000);

  // 越界一秒就回绕到 1900 纪元。记下来是为了说明「为什么样本不能超过
  // 2036」：越界不是报错，是静悄悄地给出 1900 年的一个时刻。
  const overView: DataView = new DataView(new ArrayBuffer(NTP_PACKET_SIZE));
  overView.setUint8(0, (4 << 3) | 4);
  overView.setUint8(1, 2);
  overView.setUint32(40, 0x00000000);   // 秒字段写 0 = 1900-01-01
  const over = parseNtpResponse(overView.buffer as ArrayBuffer);
  checkNum('秒字段 0 = 1900-01-01（纪元起点）',
    over.ok && over.response !== undefined
      ? over.response.transmitMillis : 0, -2208988800000);

  // 小数刻度是 2⁻³² 秒而非 100 纳秒。半秒（500ms）是个能分辨两套刻度的值：
  // 2⁻³² 记作 0x80000000；按 100 纳秒刻度算会得到 5000000 而不是 0x80000000。
  const halfView: DataView = new DataView(new ArrayBuffer(NTP_PACKET_SIZE));
  halfView.setUint8(0, (4 << 3) | 4);
  halfView.setUint8(1, 2);
  // seconds 取 0xE0000000 = 2208988800 → Unix 0
  halfView.setUint32(32, 2208988800);
  halfView.setUint32(36, 0x80000000);
  halfView.setUint32(40, 2208988800);
  halfView.setUint32(44, 0x80000000);
  const halfParsed = parseNtpResponse(halfView.buffer as ArrayBuffer);
  check('半秒的小数部分是 0x80000000（2⁻³² 刻度）',
    halfParsed.ok && halfParsed.response !== undefined &&
    Math.abs(halfParsed.response.transmitMillis - 500) < TOLERANCE_MS,
    halfParsed.ok && halfParsed.response !== undefined
      ? `实际 ${halfParsed.response.transmitMillis}` : '解析失败');
}

/** 给报文补上服务器标志，让它能通过 Mode 校验（writeTimestamp 只填时间戳）。 */
function buildWithStamp(buf: ArrayBuffer): ArrayBuffer {
  const view: DataView = new DataView(buf);
  view.setUint8(0, (4 << 3) | 4);
  view.setUint8(1, 2);
  return buf;
}

// --------------------------------------------------------------- 响应校验

function testRejection(): void {
  const short: ArrayBuffer = new ArrayBuffer(47);
  const shortParsed = parseNtpResponse(short);
  check('短于 48 字节被拒', !shortParsed.ok && shortParsed.reason === NtpReject.Short,
    `reason=${shortParsed.reason}`);
  check('被拒时 response 为 undefined', shortParsed.response === undefined);

  // 空包最容易被当成「全 0 时间戳 = 1970 年」而静默通过。
  const empty: ArrayBuffer = new ArrayBuffer(0);
  check('空包被拒', !parseNtpResponse(empty).ok);

  const mode3 = parseNtpResponse(buildResponse(1767225600000, 3));
  check('Mode 3（客户端）被拒', !mode3.ok && mode3.reason === NtpReject.NotServer,
    `reason=${mode3.reason}`);

  const mode5 = parseNtpResponse(buildResponse(1767225600000, 5));
  check('Mode 5（广播）被拒', !mode5.ok && mode5.reason === NtpReject.NotServer,
    `reason=${mode5.reason}`);

  // Stratum 0 = 退化源：服务器自己也拿不到准时间（通常 GPS 未锁定）。
  // 单看「stratum >= 1」会漏掉这一种。
  const degraded = parseNtpResponse(buildResponse(1767225600000, 4, 0, 0));
  check('Stratum 0（退化源）被拒', !degraded.ok && degraded.reason === NtpReject.Degraded,
    `reason=${degraded.reason}`);

  // Leap 3 = 源已失效。
  const unusable = parseNtpResponse(buildResponse(1767225600000, 4, 3, 1));
  check('Leap 3（源失效）被拒', !unusable.ok && unusable.reason === NtpReject.Unusable,
    `reason=${unusable.reason}`);

  // Leap 1（闰秒将发生）与 2（已进入闰秒）都要**放行** —— 它们不是错误，
  // 只是提示。误拒会让闰秒那天完全对不上时。
  const leap1 = parseNtpResponse(buildResponse(1767225600000, 4, 1, 1));
  check('Leap 1 放行', leap1.ok);
  const leap2 = parseNtpResponse(buildResponse(1767225600000, 4, 2, 1));
  check('Leap 2 放行', leap2.ok);

  // Stratum 1（一级时钟）必须放行。
  const s1 = parseNtpResponse(buildResponse(1767225600000, 4, 0, 1));
  check('Stratum 1 放行', s1.ok);
  check('Stratum 1 记下层数', s1.response !== undefined && s1.response.stratum === 1);

  // 字段落位
  const good = parseNtpResponse(buildResponse(1767225600000, 4, 1, 3));
  check('Mode 记为 4', good.response !== undefined && good.response.mode === 4);
  check('Leap 记下', good.response !== undefined && good.response.leap === 1);
  check('Stratum 记下', good.response !== undefined && good.response.stratum === 3);
  check('VN 记下', good.response !== undefined && good.response.version === 4);

  // 超长包（有些实现会带扩展字段）不该被拒，只要前 48 字节对。
  const long: ArrayBuffer = new ArrayBuffer(68);
  const longView: DataView = new DataView(long);
  const src: DataView = new DataView(buildResponse(1767225600000));
  for (let i: number = 0; i < NTP_PACKET_SIZE; i++) {
    longView.setUint8(i, src.getUint8(i));
  }
  const longParsed = parseNtpResponse(long);
  check('超长包不拒（取前 48 字节）', longParsed.ok);

  // 成功时 reason 无意义，固定为 0 而不是某个枚举成员 —— 免得调用方误判
  // 「reason 是 Short 就说明失败」。
  check('成功时 reason 归零', good.ok && good.reason === 0);
}

// --------------------------------------------------------------- 偏差公式

function testOffsetFormula(): void {
  // 对称延迟下，公式应精确还原传入的偏差。两个方向都验。
  const cases: number[] = [0, 1, -1, 1000, -1000, 5000, -5000, 60000, -60000];
  for (const offset of cases) {
    const t1: number = 1767225600000;
    const roundTrip: number = 40;
    const response: NtpResponse = measure(t1, offset, roundTrip);
    const t4: number = t1 + roundTrip;
    const got: number = ntpOffsetMillis(t1, response, t4);
    check(`偏差还原 ${offset} ms`, Math.abs(got - offset) < 1,
      `实际 ${got}`);
    // 延迟 = 往返 - 服务器处理时间；夹具里服务器时刻两戳相同 → 处理 0。
    const delay: number = ntpDelayMillis(t1, response, t4);
    check(`延迟还原 ${roundTrip} ms`, Math.abs(delay - roundTrip) < 1,
      `实际 ${delay}`);
  }

  // 非对称延迟：上行 10ms、下行 90ms。偏差公式对上下行不对称是**有偏**的，
  // 误差界是 (下行 − 上行) / 2。这里验证的是「偏差量级仍然正确」——
  // 也就是不对称没有把结果推到天差地远，那才是公式写错的表现。
  const t1b: number = 1767225600000;
  // 服务器 T2 = t1 + offset + uplink；T3 = T2（服务器处理 0）
  const offset: number = 2000;
  const uplink: number = 10;
  const downlink: number = 90;
  const server: number = t1b + offset + uplink;
  const resp: NtpResponse = okResponse(server);
  const t4b: number = t1b + uplink + downlink;
  const got: number = ntpOffsetMillis(t1b, resp, t4b);
  // 理想值 2000 ± (downlink-uplink)/2 = 2000 ± 40
  check('非对称延迟下偏差量级正确', Math.abs(got - 2000) <= 41,
    `实际 ${got}，理想 2000±41`);
  checkNum('非对称延迟下往返仍是 100ms',
    ntpDelayMillis(t1b, resp, t4b), 100);

  // 服务器处理时间不为 0：延迟必须扣掉它。T3 - T2 = 20ms 时往返 100ms
  // 意味着网络只用了 80ms。
  //
  // 偏差这一侧要特别小心：服务器处理时间**不会**被公式对消掉。
  //   offset = ((T2−T1) + (T3−T4)) / 2
  // 上下行分别传播 p 毫秒时，偏差被偏置 (上行 − 下行) / 2，与 p 无关。
  // 这个用例里上行 10ms、下行 70ms，所以理想值 0 会被读成 -30。
  //
  // 写这条是因为很容易误以为「服务器慢一点不影响结果」—— 那样会在网
  // 络拥塞（正是 p 变大的时候）悄悄引入几十毫秒的系统性偏差。
  const t1c: number = 1767225600000;
  const serverIn: number = t1c + 0 + 10;
  const respC: NtpResponse = buildTwoStamp(serverIn, serverIn + 20);
  checkNum('服务器处理 20ms 时延迟为 80ms',
    ntpDelayMillis(t1c, respC, t1c + 100), 80);
  checkNum('偏差被 (上行−下行)/2 偏置为 -30',
    ntpOffsetMillis(t1c, respC, t1c + 100), -30);

  // 服务器处理时间只影响延迟、不影响「延迟里扣掉 p 之后剩下的网络耗时」
  // 这件事本身：把 p 加倍，延迟应等量减少。
  const respD: NtpResponse = buildTwoStamp(t1c + 10, t1c + 210);
  checkNum('服务器处理 200ms 时延迟为 -100（网络耗时不抵）',
    ntpDelayMillis(t1c, respD, t1c + 100), -100);
}

/** 造一份 receive 与 transmit 不同的响应。 */
function buildTwoStamp(receiveMillis: number, transmitMillis: number): NtpResponse {
  const buf: ArrayBuffer = new ArrayBuffer(NTP_PACKET_SIZE);
  const view: DataView = new DataView(buf);
  view.setUint8(0, (4 << 3) | 4);
  view.setUint8(1, 2);
  writeTimestamp(view, 32, receiveMillis);
  writeTimestamp(view, 40, transmitMillis);
  const parsed = parseNtpResponse(buf);
  if (!parsed.ok || parsed.response === undefined) {
    throw new Error(`夹具构造失败：${parsed.reason}`);
  }
  return parsed.response;
}

// --------------------------------------------------------------- 时钟

/*
 * 系统时间与单调时间是两个独立的量纲。夹具里必须成对推进：
 * 每过 1000 毫秒真实时间，system 加 1000 且 uptime 也加 1000；
 * 只有刻意制造「系统钟被拨」时，才让 system 单独跳而 uptime 不动。
 *
 * 之前把 uptime 直接写成和 system 同一个数量级，导致首次 now() 就被判定成
 * 跳变 —— 冻结分支返回 lastReturned，而它此时还是 0，于是满屏「实际 0」。
 * 判据本身没错，是尺子没对齐。
 */

/** 系统时间基准：2026-01-01T00:00:00Z 附近。 */
const T0: number = 1767225600000;

/** 单调时间基准。与系统时间无任何关系，纯作配对的另一端。 */
const U0: number = 500000;

/** 装好设置的时钟。 */
function newClock(offsetSeconds: number = 0): ExactClock {
  const clock: ExactClock = new ExactClock();
  clock.setEnabled(true);
  clock.setOffsetSeconds(offsetSeconds);
  return clock;
}

/**
 * 装好一次同步的时钟。
 *
 * 同步发生在 (T0, U0) 这一对上，所以调用方之后的 now() 应当从 (T0, U0)
 * 起步同时推进两个量纲。
 *
 * @param offsetMs 本机相对服务器的偏差
 * @param offsetSeconds 用户手动偏移（秒）
 * @param roundTripMs 本次往返延迟
 */
function syncedClock(offsetMs: number, offsetSeconds: number = 0,
  roundTripMs: number = 40): ExactClock {
  const clock: ExactClock = newClock(offsetSeconds);
  const t1: number = T0 - roundTripMs;
  clock.applySync(t1, measure(t1, offsetMs, roundTripMs), T0, T0, U0);
  return clock;
}

/**
 * 在指定的 (系统时间, 单调时间) 上做一次同步。
 *
 * 往返延迟显式传 —— 早先把往返写死 40ms，于是「模拟慢网络」那个用例
 * 无论把 t4 传多大往返都是 40ms，测了个寂寞。
 */
function syncAt(clock: ExactClock, offsetMs: number, t4: number, u4: number,
  roundTripMs: number = 40): SyncOutcome {
  const t1: number = t4 - roundTripMs;
  return clock.applySync(t1, measure(t1, offsetMs, roundTripMs), t4, t4, u4);
}

function testClockBasics(): void {
  // 未启用：就是系统时间。
  const off: ExactClock = new ExactClock();
  off.setEnabled(false);
  checkEqual('未启用时等于系统时间',
    off.now(T0, U0).toLocalMillis().toString(), T0.toString());
  check('未启用时未同步', !off.isSynced());
  checkEqual('未启用时状态文案', off.statusText(), '未启用精确时间，使用系统时间');

  // 启用但未同步：也是系统时间（不猜）。
  const pending: ExactClock = newClock();
  check('启用后未同步标记为未同步', !pending.isSynced());
  checkEqual('启用后未同步时等于系统时间',
    pending.now(T0, U0).toLocalMillis().toString(), T0.toString());
  checkEqual('启用后未同步时状态文案', pending.statusText(), '尚未同步时间');

  // 同步后叠加偏差。
  const slow: ExactClock = syncedClock(5000);
  checkNum('同步后偏差 5000ms', slow.ntpOffsetMillis(), 5000);
  check('同步后标记为已同步', slow.isSynced());
  checkEqual('本机慢 5 秒时取值 = 系统 + 5s',
    slow.now(T0 + 1000, U0 + 1000).toLocalMillis().toString(), (T0 + 6000).toString());
  check('本机慢时状态文案含「慢」', slow.statusText().indexOf('慢') >= 0, slow.statusText());

  // 负偏差：本机快。
  const fast: ExactClock = syncedClock(-5000);
  checkEqual('本机快 5 秒时取值 = 系统 - 5s',
    fast.now(T0, U0).toLocalMillis().toString(), (T0 - 5000).toString());
  check('本机快时状态文案含「快」', fast.statusText().indexOf('快') >= 0, fast.statusText());

  // 手动偏移叠加在最后。
  const shifted: ExactClock = syncedClock(5000, 30);
  checkEqual('手动偏移 +30s 叠加在偏差之上',
    shifted.now(T0, U0).toLocalMillis().toString(), (T0 + 35000).toString());
  checkNum('手动偏移可回读', shifted.offsetSecondsValue(), 30);

  // 非法偏移归零（设置项被手改成 NaN 时不能把时钟变成 NaN）。
  const bad: ExactClock = syncedClock(0);
  bad.setOffsetSeconds(Number.NaN);
  checkNum('非法手动偏移归零', bad.offsetSecondsValue(), 0);
  checkEqual('非法偏移下取值仍正常',
    bad.now(T0, U0).toLocalMillis().toString(), T0.toString());

  // 关掉之后偏差不再生效 —— 用户关了就是不想被改时间。
  const turnedOff: ExactClock = syncedClock(5000);
  turnedOff.setEnabled(false);
  check('关闭后同步状态被清', !turnedOff.isSynced());
  checkNum('关闭后偏差被清', turnedOff.ntpOffsetMillis(), 0);
  checkEqual('关闭后取值 = 纯系统时间',
    turnedOff.now(T0, U0).toLocalMillis().toString(), T0.toString());

  // 重新打开不自动恢复旧偏差：必须重新同步。
  const reon: ExactClock = syncedClock(5000);
  reon.setEnabled(false);
  reon.setEnabled(true);
  checkEqual('重开后不沿用旧偏差',
    reon.now(T0, U0).toLocalMillis().toString(), T0.toString());

  // 同秒内多次取值必须一致（桌面版每秒轮询一次；同一个秒里重复取值
  // 出现毫秒级抖动会让秒表看起来在跳）。
  const stable: ExactClock = syncedClock(0);
  const first: number = stable.now(T0, U0).toLocalMillis();
  const second: number = stable.now(T0, U0).toLocalMillis();
  check('同一读数两次取值一致', first === second, `${first} vs ${second}`);
}

// --------------------------------------------------------------- 同步采纳

function testSyncAdmission(): void {
  // 正常往返采纳。
  const clock: ExactClock = newClock();
  const outcome: SyncOutcome = syncAt(clock, 1234, T0, U0);
  check('正常往返被采纳', outcome.accepted);
  checkNum('采纳时回报偏差', outcome.offsetMillis, 1234);
  checkNum('采纳时回报延迟', outcome.delayMillis, 40);

  // 往返过大：丢弃。宁可继续用系统时间，也不要一个误差达秒级的偏移。
  const slowNet: ExactClock = newClock();
  const slowOutcome: SyncOutcome = syncAt(slowNet, 1234, T0, U0,
    MAX_ACCEPTABLE_DELAY_MS + 1);
  check('往返超阈值不采纳', !slowOutcome.accepted, `延迟 ${slowOutcome.delayMillis}`);
  check('未采纳时偏差不写入', slowNet.ntpOffsetMillis() === 0);
  check('未采纳时不算已同步', !slowNet.isSynced());
  checkEqual('未采纳时仍用系统时间',
    slowNet.now(T0, U0).toLocalMillis().toString(), T0.toString());

  // 阈值边界：恰好等于阈值应当采纳（判据是「超过」不是「达到」）。
  const edge: ExactClock = newClock();
  const edgeOutcome: SyncOutcome = syncAt(edge, 0, T0, U0, MAX_ACCEPTABLE_DELAY_MS);
  check('往返恰等于阈值被采纳', edgeOutcome.accepted,
    `实际延迟 ${edgeOutcome.delayMillis}`);

  // 负延迟：请求期间本机时钟往回走过，测量无效。
  const back: ExactClock = newClock();
  const lateT1: number = T0 + 100;   // T1 比 T4 还晚
  const backOutcome: SyncOutcome = back.applySync(lateT1, okResponse(lateT1 + 10),
    T0, T0, U0);
  check('负延迟不采纳', !backOutcome.accepted, `延迟 ${backOutcome.delayMillis}`);
  check('负延迟不写入偏差', back.ntpOffsetMillis() === 0);

  // 偏差极大也采纳：用户本机时间差几年正是 NTP 要修的，不该在这里拒。
  const wayOff: ExactClock = newClock();
  const wayOutcome: SyncOutcome = syncAt(wayOff, 86400000, T0, U0);
  check('巨大偏差仍采纳', wayOutcome.accepted);
  checkNum('巨大偏差如实写入', wayOff.ntpOffsetMillis(), 86400000);
}

// --------------------------------------------------------------- 冻结

function testSystemJumpFreeze(): void {
  const clock: ExactClock = syncedClock(0);
  let t: number = T0;
  let u: number = U0;

  // 正常推进：系统与单调一起走，不冻结。
  for (let i: number = 0; i < 4; i++) {
    clock.now(t, u);
    t += 1000;
    u += 1000;
  }
  check('稳定推进时不冻结', !clock.isFrozen());
  const stableAt: number = t;
  checkEqual('稳定推进时取值跟随',
    clock.now(t, u).toLocalMillis().toString(), t.toString());

  // 系统钟被拨快 1 小时：uptime 照常推进（说明进程没重启、没休眠）。
  t += 3600000;
  u += 1000;
  clock.now(t, u);
  check('系统时间跳变后冻结', clock.isFrozen());
  check('冻结状态文案', clock.statusText().indexOf('重新校时') >= 0, clock.statusText());

  // 冻结期间一直返回冻结前的值 —— 界面上的钟停住，而不是跳 1 小时。
  checkEqual('冻结期间返回冻结前的值',
    clock.now(t + 5000, u + 5000).toLocalMillis().toString(), stableAt.toString());
  checkEqual('冻结期间再调仍返回同一个值',
    clock.now(t + 60000, u + 60000).toLocalMillis().toString(), stableAt.toString());

  // 重新同步后解冻。
  const outcome: SyncOutcome = syncAt(clock, 0, t + 61000, u + 61000);
  check('同步解除冻结', outcome.releasedFreeze);
  check('解冻后不再是冻结态', !clock.isFrozen());
  checkEqual('解冻后取值跟随新的系统时间',
    clock.now(t + 62000, u + 62000).toLocalMillis().toString(),
    (t + 62000).toString());

  // 关键：解冻后不能立刻再次判定跳变。基线已在 applySync 里重建，
  // 否则这次 now() 就会拿跳变前的基线比，判定再次成立 → 永久冻结。
  for (let i: number = 1; i <= 5; i++) {
    clock.now(t + 62000 + i * 1000, u + 62000 + i * 1000);
  }
  check('解冻后不再重复判定跳变', !clock.isFrozen());

  // 阈值边界。判据是「超过」不是「达到」，所以恰好等于阈值时不冻结 ——
  // 放在边界上判是为了让 5 秒这个值本身有确定含义。
  /*
   * 制造跳变的方式：uptime 按真实流逝推进（1000ms），系统时间额外多走
   * 注入的跳变量。两个一起动就是正常流逝，差值才是跳变。
   *
   * 用 1000ms 而不是 0：uptime 差为 0 虽然在数学上也成立，但读起来像是
   * 在测「单调时钟卡死」，容易误读。用真实的 1 秒流逝，drift 就精确等于
   * 注入的跳变量，边界值（恰好等于阈值 / 超过 1 毫秒）才有意义。
   */
  const atThreshold: ExactClock = syncedClock(0);
  atThreshold.now(T0, U0);
  atThreshold.now(T0 + 1000 + SYSTEM_JUMP_THRESHOLD_MS, U0 + 1000);
  check('跳变恰等于阈值不冻结', !atThreshold.isFrozen());

  const overThreshold: ExactClock = syncedClock(0);
  overThreshold.now(T0, U0);
  overThreshold.now(T0 + 1000 + SYSTEM_JUMP_THRESHOLD_MS + 1, U0 + 1000);
  check('跳变超过阈值 1 毫秒即冻结', overThreshold.isFrozen());

  // 判据是绝对值：往后拨同样要抓。
  const behind: ExactClock = syncedClock(0);
  behind.now(T0, U0);
  behind.now(T0 + 1000 - SYSTEM_JUMP_THRESHOLD_MS - 1, U0 + 1000);
  check('系统时间往回跳超过阈值也冻结', behind.isFrozen());

  // 冻结是持续的：不是判一次就放行。
  const persist: ExactClock = syncedClock(0);
  persist.now(T0, U0);
  persist.now(T0 + 10000, U0 + 1000);
  for (let i: number = 0; i < 5; i++) {
    persist.now(T0 + 10000 + (i + 1) * 1000, U0 + 1000 + (i + 1) * 1000);
  }
  check('冻结持续到重新同步为止', persist.isFrozen());
}

// --------------------------------------------------------------- 单调时钟

function testMonotonicUnavailable(): void {
  const clock: ExactClock = syncedClock(0);

  // 拿不到单调时钟（传 -1）：不判跳变。判成跳变会让时钟永久冻结且无恢复。
  clock.now(T0, -1);
  check('无单调时钟时不冻结', !clock.isFrozen());
  checkEqual('无单调时钟时取值正常',
    clock.now(T0 + 1000, -1).toLocalMillis().toString(), (T0 + 1000).toString());

  // 系统时间真的跳了 1 小时，但因为没有单调时钟可比，不判。
  clock.now(T0 + 3600000, -1);
  check('无单调时钟时系统跳变也不冻结', !clock.isFrozen());

  // 之后单调时钟恢复了：第一次只重建基线不判。
  // 若基线被错误地跨「无单调」阶段延续下来，这里会立刻判成跳变。
  clock.now(T0 + 3601000, U0);
  check('单调时钟恢复后首次只重建基线', !clock.isFrozen());
  for (let i: number = 1; i <= 5; i++) {
    clock.now(T0 + 3601000 + i * 1000, U0 + i * 1000);
  }
  check('重建基线后持续步进不误判', !clock.isFrozen());

  // 反向：先没有单调时钟，后来有了。基线同样是重建的，不该误判。
  const late: ExactClock = newClock();
  late.now(T0, -1);
  late.now(T0 + 100000, U0 + 1000);
  check('首次拿到单调时钟只重建基线', !late.isFrozen());
  late.now(T0 + 101000, U0 + 2000);
  check('拿到单调时钟后正常步进不误判', !late.isFrozen());
}

// --------------------------------------------------------------- 反向保持

function testBackwardHold(): void {
  /*
   * 倒退量的算法：applySync 拿 lastSystem（同步那一刻的系统时间）加上偏差
   * 算出新基准，再和 lastReturned（上次返回的值）比。所以
   *     倒退量 = lastReturned − (lastSystem + offset)
   * 要让倒退量恰好等于 −offset，必须让同步发生在 lastReturned 被取走的
   * 那一刻（系统时间不动）。下面两个用例都遵守这条，否则算出来的倒退量
   * 会比预期多出「同步时刻与取值时刻的差」，测的就不是想测的东西了。
   */

  // 先跑起来，取一个基准值，然后就在这一刻做同步。
  const clock: ExactClock = syncedClock(0);
  clock.now(T0, U0);
  const before: number = clock.now(T0 + 1000, U0 + 1000).toLocalMillis();

  // 同步把时间往回拉 3 秒（测量误差量级）。不应该倒着走。
  const outcome: SyncOutcome = syncAt(clock, -3000, T0 + 1000, U0 + 1000);
  check('小幅倒退被采纳为正常同步', outcome.accepted);
  check('小幅倒退触发保持而非冻结', outcome.startedHold);
  check('小幅倒退不冻结', !clock.isFrozen());

  // 保持：接下来一段时间返回旧值。
  checkEqual('保持期间返回旧值',
    clock.now(T0 + 2000, U0 + 2000).toLocalMillis().toString(), before.toString());
  checkEqual('保持期间再调仍返回旧值',
    clock.now(T0 + 2500, U0 + 2500).toLocalMillis().toString(), before.toString());

  // 真实时间追上 holdingAt 之后自动继续。
  const after: number = clock.now(T0 + 5000, U0 + 5000).toLocalMillis();
  check('追过之后继续推进', after > before, `before=${before} after=${after}`);

  // 倒退超过 30 秒：不保持，让它走 —— 这时候界面上的钟会真的倒一下，
  // 但那说明确实发生了 30 秒级的时间变化，保持 30 秒没有意义。
  const big: ExactClock = syncedClock(0);
  big.now(T0, U0);
  const bigBefore: number = big.now(T0 + 1000, U0 + 1000).toLocalMillis();
  // 倒退量 30001，刚过阈值 1 毫秒。
  const bigOutcome: SyncOutcome = syncAt(big, -(BACKWARD_HOLD_LIMIT_MS + 1),
    T0 + 1000, U0 + 1000);
  check('超过 30 秒的倒退不触发保持', !bigOutcome.startedHold);
  const bigAfter: number = big.now(T0 + 1000, U0 + 1000).toLocalMillis();
  check('超过阈值的倒退照实生效', bigAfter < bigBefore,
    `before=${bigBefore} after=${bigAfter}`);

  // 阈值边界：倒退量恰好等于 30000 仍走保持（判据是「不超过」）。
  const edge: ExactClock = syncedClock(0);
  edge.now(T0, U0);
  edge.now(T0 + 1000, U0 + 1000);
  const edgeOutcome: SyncOutcome = syncAt(edge, -BACKWARD_HOLD_LIMIT_MS,
    T0 + 1000, U0 + 1000);
  check('倒退量恰等于 30 秒走保持', edgeOutcome.startedHold);

  // 前进方向的同步不触发保持。
  const fwd: ExactClock = syncedClock(0);
  fwd.now(T0, U0);
  fwd.now(T0 + 1000, U0 + 1000);
  const fwdOutcome: SyncOutcome = syncAt(fwd, 3000, T0 + 2000, U0 + 2000);
  check('前进方向不触发保持', !fwdOutcome.startedHold);
  checkEqual('前进方向照常生效',
    fwd.now(T0 + 2000, U0 + 2000).toLocalMillis().toString(), (T0 + 5000).toString());

  // 保持与冻结阈值不同：5s 判系统跳变走冻结，30s 才走保持。
  check('冻结阈值小于保持阈值',
    SYSTEM_JUMP_THRESHOLD_MS < BACKWARD_HOLD_LIMIT_MS,
    `${SYSTEM_JUMP_THRESHOLD_MS} vs ${BACKWARD_HOLD_LIMIT_MS}`);

  // 一次保持只能由「追过」解除，一次冻结只能由「重新同步」解除。
  // 混掉这两条会导致：系统跳变后时钟一直倒着走，或同步后时钟一直停住。
  const mixed: ExactClock = syncedClock(0);
  mixed.now(T0, U0);
  mixed.now(T0 + 1000, U0 + 1000);
  const mixedHold: SyncOutcome = syncAt(mixed, -3000, T0 + 2000, U0 + 2000);
  check('保持已建立', mixedHold.startedHold);
  mixed.now(T0 + 200000, U0 + 200000);
  check('保持不需重新同步即可解除', !mixed.isFrozen());
}

// --------------------------------------------------------------- 组合

function testCombined(): void {
  // 一次完整生命周期：同步 → 正常运行 → 系统跳变 → 重新同步 → 继续。
  const clock: ExactClock = newClock(0);
  let t: number = T0;
  let u: number = U0;

  syncAt(clock, 1200, t, u);
  checkEqual('同步后取值含偏差',
    clock.now(t, u).toLocalMillis().toString(), (t + 1200).toString());

  // 跑 100 秒
  for (let i: number = 0; i < 100; i++) {
    t += 1000;
    u += 1000;
    clock.now(t, u);
  }
  check('长时间运行不冻结', !clock.isFrozen());
  checkEqual('长时间运行后取值正确',
    clock.now(t, u).toLocalMillis().toString(), (t + 1200).toString());

  // 系统跳变 30 秒：系统走 30 秒，uptime 只走 1 秒。
  t += 30000;
  u += 1000;
  clock.now(t, u);
  check('跳变 30 秒触发冻结', clock.isFrozen());
  const frozenAt: number = clock.now(t, u).toLocalMillis();
  checkEqual('冻结值等于跳变前的值', frozenAt.toString(), (t - 30000 + 1200).toString());

  // 重新同步
  u += 1000;
  syncAt(clock, 1200, t, u);
  check('重新同步解冻', !clock.isFrozen());
  t += 1000;
  u += 1000;
  checkEqual('解冻后继续正确推进',
    clock.now(t, u).toLocalMillis().toString(), (t + 1200).toString());

  // 手动偏移在整个生命周期里一直生效。
  const withOffset: ExactClock = newClock(-60);
  let t2: number = T0;
  let u2: number = U0;
  syncAt(withOffset, 0, t2, u2);
  checkEqual('手动偏移 -60s 全程生效',
    withOffset.now(t2 + 5000, u2 + 5000).toLocalMillis().toString(),
    (t2 + 5000 - 60000).toString());
}

// --------------------------------------------------------------- 展示口径

function testDateTimeValueIntegration(): void {
  const value: DateTimeValue = syncedClock(0).now(T0, U0);
  checkEqual('毫秒数可回读', value.toLocalMillis().toString(), T0.toString());
  // 日历分量应与毫秒数一致。这是纪元换算最直接的体检：分量对不上而毫秒
  // 数对得上，说明 fromLocalMillis 与 toLocalMillis 不是互逆的（时区处理
  // 出了岔子），而这种错在课程表上表现为「整体差一个时区」。
  check('年份是 2026', value.year === 2026, `实际 ${value.year}`);
  check('月是 1', value.month === 1, `实际 ${value.month}`);
  check('日是 1', value.day === 1, `实际 ${value.day}`);
  // 小时不写死：DateTimeValue 是墙上钟，fromLocalMillis 落到本地时区，
  // 本机在 UTC+8 时 1767225600000 换出来是 08:00。写死 0 会在别的时区
  // 的机器上误报。要断言的是「时区处理自洽」，不是某个具体钟点。
  check('小时在合法区间', value.hour >= 0 && value.hour <= 23, `实际 ${value.hour}`);
  checkEqual('墙上钟与纪元毫秒互逆',
    DateTimeValue.fromLocalMillis(value.toLocalMillis()).toLocalMillis().toString(),
    value.toLocalMillis().toString());

  // 跨过本地午夜：毫秒数加一天必须落到第二天的 0 点。
  // 在东八区这对应 08:00 跨到次日 08:00，所以只断言「日」变了且时刻
  // 与加一天后的 fromLocalMillis 一致，不写死小时。
  const base: DateTimeValue = DateTimeValue.fromLocalMillis(T0);
  const plus: DateTimeValue = DateTimeValue.fromLocalMillis(T0 + 86400000);
  const stepped: DateTimeValue = base.addDays(1);
  check('addDays(1) 与纪元毫秒 +1 天落在同一天',
    stepped.year === plus.year && stepped.month === plus.month &&
    stepped.day === plus.day,
    `addDays=${stepped.year}-${stepped.month}-${stepped.day} ` +
    `epoch=${plus.year}-${plus.month}-${plus.day}`);
}

// --------------------------------------------------------------- 每日补偿

/** 造一个当天时刻。 */
function at(year: number, month: number, day: number, hour: number = 0,
  minute: number = 0): DateTimeValue {
  return new DateTimeValue(year, month, day, hour, minute, 0, 0);
}

function testDailyAutoAdjust(): void {
  const today: DateTimeValue = at(2026, 9, 27, 10, 30);

  // 首次运行：基准还没落盘。按「今天」算，天数 0，什么都不动。
  const first: DailyAutoAdjustPlan = planDailyAutoAdjust(true, 12, 1.5, today, undefined);
  check('首次运行不补天数', first.days === 0 && !first.applied);
  checkEqual('首次运行偏移不动', first.offsetSeconds.toString(), '12');
  check('首次运行也推进基准日', first.advanceBaseline);

  // 核心：隔了 3 个日历日，每天补 1.5 秒。
  const three: DailyAutoAdjustPlan = planDailyAutoAdjust(true, 0, 1.5, today, at(2026, 9, 24));
  checkNum('隔 3 天记 3 天', three.days, 3);
  check('补了天数即记为已应用', three.applied);
  checkEqual('3 天 × 1.5 秒', three.offsetSeconds.toString(), '4.5');

  // 跨月、跨年、闰年。
  checkNum('跨月天数', planDailyAutoAdjust(true, 0, 1, at(2026, 3, 2), at(2026, 2, 27)).days, 3);
  checkNum('跨年天数', planDailyAutoAdjust(true, 0, 1, at(2027, 1, 2), at(2026, 12, 30)).days, 3);
  // 2028 是闰年，2 月 29 日存在，2/27 → 3/1 是 3 天（含 29 日）。
  checkNum('闰年 2 月天数', planDailyAutoAdjust(true, 0, 1, at(2028, 3, 1), at(2028, 2, 27)).days, 3);

  // 时分秒不参与天数计算：今天 00:30 对昨天 23:30 算 1 天，不是 0.02 天。
  // 这条是桌面版那边最容易被改坏的一处 —— 按时刻差算 floor 会得到 0。
  checkNum('跨零点算 1 天（时分秒不参与）',
    elapsedWholeDays(at(2026, 9, 27, 0, 30), at(2026, 9, 26, 23, 30)), 1);
  // 反向：今天 23:30 对昨天 00:30，时刻差 0.97 天，日历差 1 天。
  checkNum('跨零点反向也算 1 天',
    elapsedWholeDays(at(2026, 9, 27, 23, 30), at(2026, 9, 26, 0, 30)), 1);
  // 同一时刻不同钟点：0 天。
  checkNum('同一天不补',
    elapsedWholeDays(at(2026, 9, 27, 23, 59), at(2026, 9, 27, 0, 0)), 0);

  // 开关关着：偏移与天数都不动，但基准日照旧推进（桌面版在 if 之外）。
  const off: DailyAutoAdjustPlan = planDailyAutoAdjust(false, 7, 5, today, at(2026, 9, 20));
  check('开关关着不补', off.days === 0 && !off.applied);
  checkEqual('开关关着偏移不动', off.offsetSeconds.toString(), '7');
  check('开关关着仍推进基准日', off.advanceBaseline);
  // 后果：中途打开开关时不会把之前的天一次性补上。
  const turnedOn: DailyAutoAdjustPlan = planDailyAutoAdjust(true, 7, 5, today, today);
  check('中途打开不会补之前的天数', turnedOn.days === 0);

  // 基准落在未来（本机钟被往回拨过 / 换过时区）：钳到 0，不减回去。
  // 桌面版不钳，会从偏移里减掉；见 DailyAutoAdjust.ets 文件头。
  const future: DailyAutoAdjustPlan = planDailyAutoAdjust(true, 100, 3, today, at(2026, 9, 30));
  checkNum('未来基准天数钳为 0', future.days, 0);
  checkEqual('未来基准不减偏移', future.offsetSeconds.toString(), '100');
  check('未来基准仍推进基准日', future.advanceBaseline);
  // 未来 3 天与未来 3 秒一样钳。
  checkNum('未来 3 天钳为 0',
    elapsedWholeDays(today, at(2026, 9, 30, 12, 0)), 0);

  // 负的每日补偿（每天补得比走的少）—— 这是设置页允许配的合法组合。
  const negative: DailyAutoAdjustPlan = planDailyAutoAdjust(true, 10, -2, today, at(2026, 9, 25));
  checkNum('负补偿的天数照样记', negative.days, 2);
  checkEqual('负补偿减去 4 秒', negative.offsetSeconds.toString(), '6');

  // 每日补偿为 0：天数照记，偏移不动。
  const zeroRate: DailyAutoAdjustPlan = planDailyAutoAdjust(true, 42, 0, today, at(2026, 9, 20));
  checkNum('补偿率为 0 时天数照记', zeroRate.days, 7);
  check('补偿率为 0 时不算已应用', !zeroRate.applied);
  checkEqual('补偿率为 0 时偏移不动', zeroRate.offsetSeconds.toString(), '42');

  // 舍入到 3 位：0.1 + 0.2 这类二进制浮点误差必须被抹掉。
  const rounded: DailyAutoAdjustPlan = planDailyAutoAdjust(true, 0.1, 0.2, today, at(2026, 9, 20));
  checkEqual('1/10 分的 7 倍舍入到 3 位', rounded.offsetSeconds.toString(), '1.5');
  const third: DailyAutoAdjustPlan = planDailyAutoAdjust(true, 0, 0.0004, today, at(2026, 9, 26));
  checkEqual('小于半位的增量被舍掉', third.offsetSeconds.toString(), '0');

  /*
   * 中点取偶（.NET 口径），不是 Math.round 的逢五进一。
   *
   * 这几条是本文件里唯一需要「和别的语言对齐」的断言。Math.round 与
   * Math.Round 在中点上不一致，且不一致的方向不对称（见 core 文件头），
   * 落到跨端读写的偏移上就是 1 毫秒的显示差。
   */
  // 1.5 → 2（1 已是奇，取偶为 2）
  checkEqual('中点 1.5 取偶为 2',
    planDailyAutoAdjust(true, 0, 0.0015, today, at(2026, 9, 26)).offsetSeconds.toString(), '0.002');
  // 2.5 → 2（2 已是偶，不动）。Math.round 会给 0.003。
  checkEqual('中点 2.5 取偶为 2（Math.round 会给 0.003）',
    planDailyAutoAdjust(true, 0, 0.0025, today, at(2026, 9, 26)).offsetSeconds.toString(), '0.002');
  // 3.5 → 4
  checkEqual('中点 3.5 取偶为 4',
    planDailyAutoAdjust(true, 0, 0.0035, today, at(2026, 9, 26)).offsetSeconds.toString(), '0.004');
  // 负数同规则。Math.round(-1.5) = -1，.NET 给 -2。
  checkEqual('负中点 -1.5 取偶为 -2（Math.round 会给 -0.001）',
    planDailyAutoAdjust(true, 0, -0.0015, today, at(2026, 9, 26)).offsetSeconds.toString(), '-0.002');
  checkEqual('负中点 -2.5 取偶为 -2',
    planDailyAutoAdjust(true, 0, -0.0025, today, at(2026, 9, 26)).offsetSeconds.toString(), '-0.002');
  checkEqual('负中点 -3.5 取偶为 -4',
    planDailyAutoAdjust(true, 0, -0.0035, today, at(2026, 9, 26)).offsetSeconds.toString(), '-0.004');

  // 中点判定是精确比较：0.0015*1000 在双精度下正好是 1.5（已实测），
  // 所以「恰好半位」这条分支真的会被走到，而不是永远落到 < 0.5 那支。
  check('中点判定走的是精确相等而非约等于', 0.0015 * 1000 === 1.5);

  // 非中点不受影响：常规四舍五入。
  checkEqual('中点之下按四舍五入',
    planDailyAutoAdjust(true, 0, 0.0014, today, at(2026, 9, 26)).offsetSeconds.toString(), '0.001');
  checkEqual('中点之上按四舍五入',
    planDailyAutoAdjust(true, 0, 0.0016, today, at(2026, 9, 26)).offsetSeconds.toString(), '0.002');

  // 非法输入：设置被手改成 NaN / Infinity 时不能让时钟变成 NaN。
  const nanIn: DailyAutoAdjustPlan = planDailyAutoAdjust(true, Number.NaN, Number.NaN, today,
    at(2026, 9, 20));
  checkEqual('NaN 偏移当 0', nanIn.offsetSeconds.toString(), '0');
  checkNum('NaN 每日值当 0 时天数照记', nanIn.days, 7);
  const infIn: DailyAutoAdjustPlan = planDailyAutoAdjust(true, 0, Number.POSITIVE_INFINITY, today,
    at(2026, 9, 20));
  checkEqual('Infinity 每日值当 0', infIn.offsetSeconds.toString(), '0');
  const infCurrent: DailyAutoAdjustPlan = planDailyAutoAdjust(true, Number.POSITIVE_INFINITY, 1,
    today, at(2026, 9, 26));
  checkEqual('Infinity 偏移当 0', infCurrent.offsetSeconds.toString(), '1');
  checkEqual('NaN 输入不产生 NaN', String(infIn.offsetSeconds), '0');

  // 极大值：不该被 ×1000 之后的精度损失改写成以 10 为步长的值。
  const huge: DailyAutoAdjustPlan = planDailyAutoAdjust(true, 1e15, 0, today, at(2026, 9, 20));
  check('极大偏移原样保留',
    huge.offsetSeconds === 1e15, `实际 ${huge.offsetSeconds}`);

  // 一次运行把偏移累加在既有值上，而不是覆盖。
  const cumulative: DailyAutoAdjustPlan = planDailyAutoAdjust(true, 100, 1.5, today, at(2026, 9, 25));
  checkEqual('累加在既有偏移上', cumulative.offsetSeconds.toString(), '103');
}

testRequest();
testEpochRoundTrip();
testRejection();
testOffsetFormula();
testClockBasics();
testSyncAdmission();
testSystemJumpFreeze();
testMonotonicUnavailable();
testBackwardHold();
testCombined();
testDateTimeValueIntegration();
testDailyAutoAdjust();

console.log(`精确时间 通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('');
  for (const failure of failures) {
    console.log(`✗ ${failure}`);
  }
  process.exit(1);
}
