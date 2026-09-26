/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 应用设置的落点：preferences（沙箱内的键值库）。
 *
 * 为什么设置不进 profile.json
 * --------------------------
 * profile.json 要与桌面版字节级往返。往里加任何一个本应用私有的字段，两端的
 * 序列化结果就对不上了：桌面版读到不认识的字段会原样保留（System.Text.Json
 * 默认行为），于是我们写进去的设置会跟着档案一路同步到桌面版，在那边永远没有
 * 人读，而桌面版自己存进去的东西我们又读不认得。两边各自长出一堆死字段，
 * 冲突时还没有任何提示。所以设置归设置，档案归档案，两个文件各管一件事。
 *
 * 为什么用 preferences 而不是自己写一个 JSON 文件
 * ---------------------------------------------
 * 1. 原子写与落盘时机由平台管：进程被杀不会丢一半的设置。
 * 2. 它是系统备份/迁移（EntryBackupAbility）默认会带走的那一类数据，
 *    不用再单独写一套配置。
 * 3. 不必自己处理并发写。设置页与提醒同步可能同时写。
 *
 * 只暴露同步接口
 * --------------
 * 页面构建期要同步拿到值来填控件（@State 只能在构造期赋值），提醒同步也
 * 在回调链里读。为此让整套 API 都是 async 只会逼出一堆「先显示默认、再补一次
 * 刷新」的两段式界面。preferences 的 *Sync 系列从 API 10 起就有，够用。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** preferences 实例名。改名等于换一份设置，改之前要想到老用户会丢配置。 */
const STORE_NAME: string = 'classy_settings';

/**
 * 设置仓库。
 *
 * 构造会真的去开文件，所以只在拿到 context 之后建。构造失败（文件损坏、IO
 * 异常）不抛，而是退化成一份「只读默认值的」实例：设置读不到时表现为用
 * 默认值，而不是整个应用起不来。设置丢失是可容忍的，起不来不可容忍。
 *
 * 因此可以随手 new，不用做缓存：getPreferencesSync 按名字返回进程内同一份
 * 实例，多次构造不会各自持有互不可见的副本。要缓存就得额外管它何时失效，
 * 而这里要的语义只是「拿一个当前值」，没有失效这回事。
 */
export class AppPreferences {
  private readonly store: preferences.Preferences | undefined = undefined;

  constructor(context: common.Context) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    } catch (err) {
      this.store = undefined;
    }
  }

  /** 读布尔值。缺失、类型不符、或整个库打不开时都返回 fallback。 */
  getBoolean(key: string, fallback: boolean): boolean {
    if (this.store === undefined) {
      return fallback;
    }
    try {
      const value: preferences.ValueType = this.store.getSync(key, fallback);
      if (typeof value !== 'boolean') {
        return fallback;
      }
      return value;
    } catch (err) {
      return fallback;
    }
  }

  /** 读数值。缺失、类型不符（老版本存过字符串）或库打不开时都返回 fallback。 */
  getNumber(key: string, fallback: number): number {
    if (this.store === undefined) {
      return fallback;
    }
    try {
      const value: preferences.ValueType = this.store.getSync(key, fallback);
      if (typeof value !== 'number' || isNaN(value)) {
        return fallback;
      }
      return value;
    } catch (err) {
      return fallback;
    }
  }

  /**
   * 写值。同步写，落盘交给 preferences 自己做。
   *
   * 写失败不抛、不重试：设置写不进去的表现是「下次进来还是旧值」，而
   * 抛出去会打断当前正在做的操作（比如刚改完提前量就去同步提醒，同步失败
   * 了，界面还提示「保存失败」）。两个都是小问题，但后者会让人以为
   * 「改这个设置有风险」，于是干脆不敢改。
   */
  put(key: string, value: boolean | number): void {
    if (this.store === undefined) {
      return;
    }
    try {
      this.store.putSync(key, value);
      // flush 是异步的，不 await：preferences 会在进程正常退出前自行落盘，
      // 而这里等它完成只会让「改一下提前量」这种秒级操作变慢。
      this.store.flush().catch(() => {});
    } catch (err) {
      // 故意空着但要留注释：空 catch 会被 linter 当成漏写，见 tryWrite 里的说明。
    }
  }
}

/** 偏好键。集中在这里，避免各处硬编码字符串。 */
export class PrefKeys {
  /** 课前提醒总开关。 */
  static readonly REMINDER_ENABLED: string = 'reminder.enabled';
  /** 室内课提前量，秒。 */
  static readonly REMINDER_ADVANCE_INDOOR: string = 'reminder.advanceIndoor';
  /** 室外课提前量，秒。 */
  static readonly REMINDER_ADVANCE_OUTDOOR: string = 'reminder.advanceOutdoor';
  /**
   * 提醒形态：-1 自动 / 0 精确 / 1 折叠。
   *
   * 存数值而不是布尔，是因为「自动」与「强制折叠」都要能表达。
   */
  static readonly REMINDER_MODE: string = 'reminder.mode';
}
