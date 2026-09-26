/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 编辑页的路由名。
 *
 * 单独一个文件而不是挂在 Editor.ets 上：Editor 要 import 各个分页，分页又要
 * import Editor 里的常量，那是循环依赖。ArkTS 遇到循环 import 时的初始化顺序
 * 不可靠，表现为「某个常量在某个时机是 undefined」，而不是编译期报错 ——
 * 极难查。路由名集中在一处，各方单向依赖它。
 */

/** 科目。 */
export const ROUTE_SUBJECTS: string = 'subjects';
/** 时间表。 */
export const ROUTE_LAYOUTS: string = 'layouts';
/** 课表（含排课）。 */
export const ROUTE_PLANS: string = 'plans';
/** 课表群。 */
export const ROUTE_GROUPS: string = 'groups';
/** 临时课表 / 叠加 / 预定。 */
export const ROUTE_TEMP: string = 'temp';
/** 课前提醒设置。 */
export const ROUTE_REMINDER: string = 'reminder';
