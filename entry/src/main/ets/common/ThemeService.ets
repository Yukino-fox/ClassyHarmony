/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 主题：把用户选的主题档位落到窗口的配色模式上。
 *
 * 配色资源本身是 P0 就备好的（base/element/color.json 浅色、
 * dark/element/color.json 深色，两边各 12 项一一对应），这一层只负责
 * 「现在该用哪一套」。
 *
 * 两个枚举值不同，必须显式映射
 * ----------------------------
 * 落盘的 ThemeMode（跟桌面版 Settings.Theme 对齐）：System=0 / Light=1 / Dark=2
 * 平台的 ConfigurationConstant.ColorMode：NOT_SET=-1 / DARK=0 / LIGHT=1
 *
 * 两组值既不等价也不同序 —— 直接 `as` 转换会得到「选深色变成跟随系统、
 * 选浅色变成深色」。所以这里逐个分支显式写出来，不做算术。
 * 这也是为什么 ThemeMode 保持与桌面版一致而不改成平台的值：settings.json
 * 要跨端读，键值口径不能为了迁就平台 API 而改。
 *
 * 优先级
 * ------
 * 平台文档给的优先级是 UIAbility 级 > Application 级 > 系统。我们只设
 * UIAbility 级，Application 级从不设，所以「跟随系统」= NOT_SET，
 * 它会自然落到系统级。
 *
 * 调用时机
 * --------
 * setColorMode 要求「窗口已创建且页面已 loadContent」，也就是
 * onWindowStageCreate 的 loadContent 回调之后。提前调会抛 16000011。
 * 所以入口在 EntryAbility，而不是 onCreate。
 */

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppPreferences, ThemeMode } from './AppPreferences';

const DOMAIN: number = 0x0000;
const TAG: string = 'ThemeService';

export class ThemeService {
  /**
   * 档位 → 平台配色模式。
   *
   * 越界值当跟随系统：桌面版加了一档新主题时，老版本读到 3 不该崩，
   * 而「跟随系统」是所有取值里最不会出事的。
   */
  static toColorMode(mode: ThemeMode): ConfigurationConstant.ColorMode {
    if (mode === ThemeMode.Light) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    if (mode === ThemeMode.Dark) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  }

  /**
   * 切到指定档位。
   *
   * 同步 void，不抛：调用点有两个（Ability 启动、设置页改选项），两个都
   * 处在「配色切不过去也该继续跑」的处境 —— 抛出去只会让设置页点一下就
   * 白屏，或者让应用起不来。失败只记日志。
   */
  static apply(context: common.UIAbilityContext, mode: ThemeMode): void {
    try {
      context.setColorMode(ThemeService.toColorMode(mode));
      hilog.info(DOMAIN, TAG, 'colorMode applied: %{public}d', mode);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setColorMode failed: %{public}s', `${err}`);
    }
  }

  /**
   * 按盘上的设置切一次。
   *
   * 启动时调。读 preferences 走 AppPreferences，与设置页写的是同一个文件，
   * 所以用户在设置页改完直接退到后台再回来，不用重启也能生效。
   */
  static applyStored(context: common.UIAbilityContext): void {
    const prefs: AppPreferences = new AppPreferences(context);
    ThemeService.apply(context, prefs.theme());
  }
}
