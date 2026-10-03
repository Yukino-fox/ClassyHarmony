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
 * 为什么是 getStringByNameSync 而不是 $r
 * --------------------------------------
 * `$r('app.string.x')` 返回的是 **Resource 对象**（bundleName / moduleName /
 * id 三个字段），不是文案本身。真机上实测 `$r(...).toString()` 得到的是
 * 「[object Object]」—— 界面上整页标题都变成这个，因为 ArkTS 的对象没有
 * 自定义 toString。要拿到字面量必须再走一次资源管理器，两条路：
 *
 *   getStringSync(resource)   // 已 deprecated（since 20）
 *   getStringByNameSync(name) // 按资源名取，不用先构造 Resource
 *
 * 取后者：一个字符串 key 直接换一条文案，不经过 `$r`，也就不需要 id 是否被
 * 框架填好这种前提。语言回落（en_US 没有就用 base）由资源管理器自己做。
 *
 * 上下文从哪来
 * -----------
 * 资源管理器挂在 Context 上，而这里是纯函数层，手上没有 UIAbility。用
 * `application.getApplicationContext()`：它在进程一启动就有，跟「谁先调了
 * t()」无关 —— 这一点很关键，core 里有模块级的 `t()` 调用（如 PanelModel 的
 * 空状态常量），它在 entry 的任何初始化代码之前就会跑。
 *
 * 为什么结果要缓存
 * --------------
 * 每次读都要走一遍资源查找（读表、匹配语言）。core 层有些文案在每次 tick
 * 时都要读（如天气描述），不缓存的话每秒几十次查找，而语言在运行期几乎不会
 * 变。缓存之后只有第一次真的查，后面都是 Map 命中。
 *
 * 缓存的失效
 * ----------
 * 只缓存**查到的**结果；查不到（资源不存在、平台不可用）时返回 key 且不进
 * 缓存 —— 否则一次早期失败会把「key」永久钉死在缓存里，之后就算环境正常了
 * 也再也不会去查。语言切换时清缓存由 entry 在 onConfigurationUpdate 里调
 * clearCache()，见 EntryAbility。
 */

import { application, common } from '@kit.AbilityKit';

/** 文案缓存。key 是资源名，value 是已经转成 string 的文案。 */
const cache: Map<string, string> = new Map<string, string>();

/**
 * 应用上下文。懒取一次：取不到就抛给调用方的 try/catch（Node 测试台里没有
 * AbilityKit，走到那里就当资源不可用，返回 key 本身）。
 */
let appContext: common.Context | undefined = undefined;

/** 取（并缓存）应用上下文。取不到时抛错，由 t() 的 try/catch 接住。 */
function context(): common.Context {
  if (appContext === undefined) {
    appContext = application.getApplicationContext();
  }
  const ctx: common.Context | undefined = appContext;
  if (ctx === undefined) {
    throw new Error('application context is not available');
  }
  return ctx;
}

/**
 * 按资源名查一条文案。
 *
 * @param key string.json 里的 name（不含任何前缀）
 * @returns 当前语言下的文案；资源不存在时资源管理器抛 9001004
 */
function lookup(key: string): string {
  return context().resourceManager.getStringByNameSync(key);
}

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
  try {
    const value: string = lookup(key);
    if (value.length > 0) {
      cache.set(key, value);
      return value;
    }
  } catch (err) {
    // 落到下面返回 key。不抛：一条文案缺失不该让整条链路崩掉，
    // 而返回 key 能让用户在界面上看到「这里该有东西」，比空白好排查。
  }
  return key;
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
