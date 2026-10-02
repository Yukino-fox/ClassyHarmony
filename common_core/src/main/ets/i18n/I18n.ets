/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 多语言文案的读取口。
 *
 * 为什么 core 层也要 i18n
 * ----------------------
 * core 层有一批用户直接看得到的文案：天气码的中文描述、触发器/行动的名字、
 * 面板空状态提示、插件装载失败原因。这些不是「开发者的注释」，是用户界面上
 * 真会显示出来的字，所以它们必须能跟着系统语言变。
 *
 * 为什么用 $r 而不是自己读 JSON
 * ------------------------------
 * $r 是 HarmonyOS 的资源查找机制：系统按当前语言在 resources/<lang>/ 下找，
 * 找不到就回落到 resources/base/。自己读 JSON 的话，语言切换要自己监听、
 * 自己缓存、自己处理回落 —— 那三件事系统已经做对了，重写一遍只会更差。
 *
 * 为什么结果要缓存
 * --------------
 * $r 每次都要走一次资源查找（读表、匹配语言、返回 Resource 对象）。core 层
 * 有些文案在每次 tick 时都要读（如天气描述），不缓存的话每秒几十次查找，
 * 而语言在运行期几乎不会变。缓存之后只有第一次真的查，后面都是 Map 命中。
 *
 * 缓存的失效
 * ----------
 * 语言切换时缓存会留着旧语言的值。这是刻意的：语言切换在 HarmonyOS 上会
 * 重建 Ability（走 onConfigurationUpdate 或重启进程），进程重建后缓存自然
 * 清空。而运行期不重建的情况（onConfigurationUpdate 里改了语言），用户会
 * 看到旧语言的文案直到下次启动 —— 这比「每次读都错」好，且系统会在配置
 * 变化时给一次 onConfigurationUpdate，在那里调 I18n.clearCache() 即可。
 */

/** 文案缓存。key 是资源名，value 是已经转成 string 的文案。 */
const cache: Map<string, string> = new Map<string, string>();

/**
 * 取一条文案。
 *
 * @param key string.json 里的 name（不含 app.string. 前缀）
 * @returns 当前语言下的文案；资源不存在时返回 key 本身（让调用方看到
 *   「这里该有一条文案」而不是空白）
 */
export function t(key: string): string {
  const cached: string | undefined = cache.get(key);
  if (cached !== undefined) {
    return cached;
  }
  let value: string = key;
  try {
    value = $r(`app.string.${key}`).toString();
  } catch (err) {
    // 资源不存在时返回 key 本身。不抛：一条文案缺失不该让整条链路崩掉，
    // 而返回 key 能让用户在界面上看到「这里该有东西」，比空白好排查。
    value = key;
  }
  cache.set(key, value);
  return value;
}

/**
 * 取一条带占位符的文案并替换。
 *
 * 占位符形如 {0} {1}，按 args 顺序替换。文案里写「还有 {0} 分钟」，
 * 调用 t('countdown_connector', '5') 得到「还有 5 分钟」。
 *
 * @param key string.json 里的 name
 * @param args 按顺序替换 {0} {1}… 的值
 * @returns 替换后的文案
 */
export function tf(key: string, ...args: string[]): string {
  let text: string = t(key);
  for (let i: number = 0; i < args.length; i++) {
    text = text.replace(`{${i}}`, args[i]);
  }
  return text;
}

/**
 * 清空文案缓存。
 *
 * 语言切换时由 entry 层调用（在 onConfigurationUpdate 里）。不清的话，
 * 切换语言后界面会留着旧语言的文案，直到进程重建。
 */
export function clearCache(): void {
  cache.clear();
}
