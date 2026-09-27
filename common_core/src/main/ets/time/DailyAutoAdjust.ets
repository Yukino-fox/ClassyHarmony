/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 每日时钟补偿的纯计算。
 *
 * 这是桌面版 ExactTimeService 构造函数末尾那六行的抽出：
 *
 *   if (IsTimeAutoAdjustEnabled)
 *       TimeOffsetSeconds += TimeAutoAdjustSeconds *
 *                            floor((Today - LastTimeAdjustDateTime.Date).TotalDays);
 *       TimeOffsetSeconds = round(TimeOffsetSeconds, 3);
 *   LastTimeAdjustDateTime = Today;
 *
 * 为什么单独抽一层
 * --------------
 * 桌面版那六行没有任何测试，测不到的地方就已经出过一次错：它算的是
 * 「距离上次补偿过了几个整天」，但这个「上次」只有等真机跑满 24 小时才
 * 观察得到，而 -1 天与 +1 天在功能上完全等价（没人看得出来），只有单元
 * 测试能把符号钉住。这里把 days 的算法、舍入、非法输入三条都摊开成纯函数。
 *
 * 抽出来之后有个额外好处：它成了「设置值 → 落盘值」的唯一出口。桌面版是
 * 原地改 TimeOffsetSeconds 字段，鸿蒙侧是改 JSON 里的同一个键；两边都走
 * 同一个函数，将来发现舍入口径不一致时只改一处。
 *
 * 与桌面版的一处刻意分歧
 * --------------------
 * 桌面版不钳负数：LastTimeAdjustDateTime 落在未来（用户把系统钟往回拨过，
 * 或者换了时区）时 floor 得到负数，于是从偏移里**减**回去。这里钳到 0。
 * 理由是这个偏移的语义是「本机每天慢 X 秒，补回来」；本机时间往回走不构成
 * 「又多慢了一天」，减回去只会让时间再错一次，而这类输入恰好是本模块
 * 存在的意义（校时）所要处理的场景之一。其余口径（天数算法、舍入到 3 位、
 * 未开启时也要推进基准日）与桌面版一致。
 */

import { DateTimeValue } from 'common_shared';

/** 落盘精度。桌面版 Math.Round(x, 3)，这里沿用。 */
const OFFSET_DECIMALS: number = 3;

/** 一次补偿的结论。 */
export interface DailyAutoAdjustPlan {
  /** 是否真的动了偏移。关闭开关、或天数与偏移都为 0 时为 false。 */
  applied: boolean;
  /** 本次计入的天数。已钳到 >= 0。 */
  days: number;
  /** 应落盘的 TimeOffsetSeconds。 */
  offsetSeconds: number;
  /**
   * 是否需要把 LastTimeAdjustDateTime 推进到今天。
   *
   * 桌面版是无条件推进的（第 93 行在 if 之外）。这条语义容易读漏：关着
   * 自动补偿的那段时间也会被「记成已经补偿过」，所以用户中途打开开关时
   * 不会把之前那些天一次性补上。保持这个行为。
   */
  advanceBaseline: boolean;
}

/**
 * 算出本次启动应当落盘的偏移。
 *
 * @param enabled 自动补偿总开关（TimeAutoAdjustEnabled）
 * @param currentOffsetSeconds 当前 TimeOffsetSeconds
 * @param perDaySeconds 每天补偿秒数（TimeAutoAdjustSeconds）
 * @param today 今天（只取日期分量，时分秒不参与）
 * @param lastAdjustBaseline 上次补偿的基准时刻。undefined 当作「今天」——
 *        即首次运行、键还没落盘的情形，与桌面版默认 DateTime.Now 同义。
 */
export function planDailyAutoAdjust(enabled: boolean, currentOffsetSeconds: number,
  perDaySeconds: number, today: DateTimeValue,
  lastAdjustBaseline: DateTimeValue | undefined): DailyAutoAdjustPlan {
  const current: number = finite(currentOffsetSeconds);
  const perDay: number = finite(perDaySeconds);

  if (!enabled) {
    // 开关关着：偏移不动，但基准日仍要推进（桌面版无条件推进）。
    return { applied: false, days: 0, offsetSeconds: current, advanceBaseline: true };
  }

  // 天数是两个日历日的差，不是两个时刻的差。用 dateOnly() 之前算的话，
  // 今天 00:30 对昨天 23:30 会算出 0.02 天，floor 成 0 —— 看起来对，
  // 但今天 23:30 对昨天 00:30 就会算出 0.97 天，同样 floor 成 0，
  // 而按「隔了几个整天」的口径这明明是 1 天。少补一天不会有人发现，
  // 补了错的那天要等用户对账才发现。
  const days: number = elapsedWholeDays(today, lastAdjustBaseline);
  if (days <= 0) {
    return { applied: false, days: 0, offsetSeconds: current, advanceBaseline: true };
  }

  const next: number = round(current + perDay * days, OFFSET_DECIMALS);
  return { applied: next !== current, days: days, offsetSeconds: next, advanceBaseline: true };
}

/**
 * 两个日历日之间已经过了几个整天。
 *
 * 首次运行（lastAdjustBaseline 为 undefined）返回 0：桌面版此时
 * LastTimeAdjustDateTime 的默认值是 DateTime.Now，算出来也是 0。
 */
export function elapsedWholeDays(today: DateTimeValue,
  lastAdjustBaseline: DateTimeValue | undefined): number {
  if (lastAdjustBaseline === undefined) {
    return 0;
  }
  const delta: number = today.dateOnly().epochDay() - lastAdjustBaseline.dateOnly().epochDay();
  // 未来时刻钳到 0，见文件头「与桌面版的一处刻意分歧」。
  return delta > 0 ? delta : 0;
}

/** 非法数值（NaN / ±Inf）一律当 0，不让设置被手改成 NaN 后把时钟变成 NaN。 */
function finite(value: number): number {
  return Number.isFinite(value) ? value : 0;
}

/**
 * 舍入到指定位数，**中点取偶**。
 *
 * 为什么不能直接用 Math.round
 * --------------------------
 * Math.round 是「四舍五入、逢五进一」，而且只往 +∞ 方向进；C# 的
 * Math.Round(double, int) 默认是 MidpointRounding.ToEven，逢五取偶。
 * 两者在中点上不一致，而且不一致的方向不对称：
 *
 *     Math.round( 1.5) =  2      Math.Round( 1.5, 0) =  2   一致
 *     Math.round( 2.5) =  3      Math.Round( 2.5, 0) =  2   不一致
 *     Math.round(-1.5) = -1      Math.Round(-1.5, 0) = -2   不一致
 *     Math.round(-2.5) = -2      Math.Round(-2.5, 0) = -2   一致
 *
 * 桌面版那段代码写的是 Math.Round(TimeOffsetSeconds, 3)，是 C#。这里若用
 * Math.round，两个平台在中点上会算出差 1e-3 的偏移，落进同一个 settings.json
 * 之后两边的显示会差 1 毫秒 —— 这种量级的差异没人会去查，只会让人觉得
 * 「跨端同步把时间改坏了一点」。
 *
 * 浮点缩放误差不在修正范围内
 * --------------------------
 * .NET 对 Math.Round(x, n) 的缩放误差有一套额外修正（针对 x*10^n 与真值
 * 差一个 ulp 的情况）。这里不跟：偏移值上的中点都是 1e-3 的整数倍，
 * 0.0015*1000 在双精度下正好等于 1.5（已实测），中点判定是精确比较而不是
 * 「约等于」，不存在需要修正的情形。为了一个观察不到的收益引入一套只在
 * 特定量级才生效的修正算法，风险比收益大。
 *
 * 极大值直接原样返回：x 接近 1e15 时乘 1000 已越过双精度整数精确表示的上限
 * （约 9e15），结果会被舍成 10 的倍数，再除回去就得到一个以 10 为步长的值。
 */
function round(value: number, decimals: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  const factor: number = Math.pow(10, decimals);
  const scaled: number = value * factor;
  if (!Number.isFinite(scaled) || Math.abs(scaled) > 9e15) {
    return value;
  }
  // 用 floor 而不是 Math.round：floor 对负数是向 -∞ 取整，于是
  // 「小数部分」始终落在 [0, 1)，中点就是精确的 0.5，两侧对称。
  const floor: number = Math.floor(scaled);
  const fraction: number = scaled - floor;
  let rounded: number;
  if (fraction > 0.5) {
    rounded = floor + 1;
  } else if (fraction < 0.5) {
    rounded = floor;
  } else {
    // 恰好半位：取偶。floor 为偶则不动，否则 +1（此时 floor 必为奇数，
    // floor+1 必为偶数；负数同样成立：floor=-3 → -2）。
    rounded = (floor % 2 === 0) ? floor : floor + 1;
  }
  return rounded / factor;
}
