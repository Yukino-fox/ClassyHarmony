/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 布局分档。
 *
 * 为什么是 core 里的纯函数
 * -----------------------
 * 原本打算用 GridRow 的 breakpoints + onBreakpointChange 取档位，问题是
 * GridRow 不给 columns 时会用默认列数（API 20 起是 {xs:2, sm:4, md:8, ...}），
 * 两栏布局的每个 GridCol 只能占到一半宽度。于是必须同时维护 columns 与 span
 * 两张表，而这两张表唯一的耦合是「横幅要占满整行」—— 改断点时漏改一张，
 * 布局就错，而且错法很隐晦（表现为宽度对不上，不报错）。
 *
 * 改成「根容器量出宽度 -> 纯函数归约成一种形态」，耦合就没了：
 *   - 一个阈值对应一条明确的布局决定，不存在两张表要同步
 *   - 归约逻辑是纯函数，能在 Node 测试里穷举边界（Node 侧不引 ArkUI）
 *   - 量的是页面实际可用区域而不是窗口，分屏 / 悬浮窗下自动跟着变
 *
 * 档位命名按布局形态而不是按设备名：「双栏宽屏」既可能是平板横屏也可能是
 * 2in1，用尺寸说话比枚举设备可靠。
 */

/** 页面布局形态。 */
export enum LayoutForm {
  /** 单栏：日期条 + 选中那一天的竖排课程。手机竖屏。 */
  Single = 0,
  /** 双栏：左边单日、右边整周网格，网格按最小宽度横向滚动。平板。 */
  Dual = 1,
  /** 双栏 + 网格列均分吃满宽度。平板横屏 / 2in1。 */
  DualWide = 2
}

/**
 * 窄于此宽度（vp）用单栏。
 *
 * 600vp 来自竖屏手机与展开态折叠屏的实际可用宽度：再宽一点，竖排的单日列表
 * 两侧就开始留出大片空白，而一周七天的对比需求还没到非看不可的程度。
 */
export const SINGLE_COLUMN_MAX_WIDTH: number = 600;

/**
 * 宽于此宽度（vp）让网格列均分吃满。
 *
 * 阈值是算出来的：双栏下网格那一栏拿到 (窗口宽 - 外边距 - 间距) / 2，
 * 要让 7 列以最小宽度 68vp 自然排开不被压缩，需要 ≥ 7×68+62 = 538vp，
 * 反推窗口宽 ≥ 1124vp，取整到 1100。低于它就让网格横滑，而不是把格子拉变形。
 */
export const GRID_FILL_MIN_WIDTH: number = 1100;

/**
 * 由可用宽度（vp）归约出布局形态。
 *
 * 边界按「窄于此」处理：600vp 本身仍算单栏，1100vp 本身算双栏宽网格。
 *
 * @param windowWidthVp 页面可用宽度（vp）。负数与非有限值都归到最窄的一档 ——
 *        布局宁可信「窄」也不要信「宽」：按宽排会显示一个横向溢出屏幕的界面。
 */
export function layoutFormOf(windowWidthVp: number): LayoutForm {
  if (!(windowWidthVp > 0)) {
    return LayoutForm.Single;
  }
  if (windowWidthVp < SINGLE_COLUMN_MAX_WIDTH) {
    return LayoutForm.Single;
  }
  if (windowWidthVp < GRID_FILL_MIN_WIDTH) {
    return LayoutForm.Dual;
  }
  return LayoutForm.DualWide;
}
