/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 多语言文案读取口（core 侧的转发）。
 *
 * 实现本体在 common_shared/src/main/ets/i18n/I18n.ets —— 那一层也有用户看得到
 * 的文案（新课表 / 新课表群 / 新时间表 / 课间休息 这些默认名，以及 JSON 解析
 * 失败的原话），而数据层不能反过来依赖 core。所以实现下沉到最底层，core 与
 * entry 都从这里转发：core 内部原有的 `import { t } from '../i18n/I18n'`
 * 一行都不用改。
 *
 * 为什么是 getStringByNameSync 而不是 $r、为什么要缓存、缓存何时失效，
 * 这些理由都写在实现文件的头注里，不在此重复。
 */

export { clearCache, t, tf } from 'common_shared';
