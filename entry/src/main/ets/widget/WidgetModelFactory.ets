/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 小组件数据的构建。FormExtensionAbility 与主应用共用这一条路径。
 *
 * 为什么单独抽出来
 * ----------------
 * 「读档案 -> 刷派生量 -> 建引擎参数 -> 算模型」这四步只要有一处漏了，
 * 小组件显示的内容就会和主界面对不上，而两边的代码在不同文件里、也没有任何
 * 编译期约束把它们绑在一起。所以这里给唯一的一份实现，谁需要谁调。
 *
 * 为什么每次都从文件重读
 * --------------------
 * FormExtensionAbility 是独立运行时，10 秒不活动就被回收，下次拉起是全新进程。
 * 内存里没有任何东西可以「留着」。这不是性能取舍，是这个运行时的基本形状：
 * 把档案缓存在模块级变量里看着省事，但一旦某次是主应用改了档案、
 * 这次拉起拿到旧缓存，用户看到的就是旧课表，而且只在「手速够快」时复现。
 */

import { DateTimeValue, Profile } from 'common_shared';
import { EngineSettings, WidgetBuilder, WidgetDimension, WidgetModel } from 'common_core';
import { ProfileRepository } from '../data/ProfileRepository';
import { defaultEngineSettings } from '../common/AppSettings';

export class WidgetModelFactory {
  /**
   * 算一份小组件模型。
   *
   * 读档案失败时返回一个说清原因的占位模型，而不是抛异常：卡片是在渲染路径上
   * 被拉起来的，抛异常的表现是桌面上多出一张白卡片，而「档案读不出来」这件事
   * 恰恰是最需要让用户看到的。
   *
   * @param filesDir 沙箱内可写的目录，档案落在其下。
   * @param dimension 卡片规格，来自 form_config 与 want 参数。
   * @param now 当前时刻。默认取系统本地时间。
   */
  static build(filesDir: string, dimension: string,
    now: DateTimeValue = DateTimeValue.now()): WidgetModel {
    const model: WidgetModel = new WidgetModel();
    model.dimension = WidgetModelFactory.normalizeDimension(dimension);

    const repository: ProfileRepository = new ProfileRepository(filesDir);
    let profile: Profile;
    try {
      profile = repository.load();
    } catch (err) {
      model.isEmpty = true;
      model.emptyHint = '课表读不出来';
      model.dateText = `${now.month}月${now.day}日`;
      return model;
    }

    // 派生量（时间点预置科目、换课标记、课次重绑）必须刷，否则算出来的排课
    // 与主界面不同。同一个进程里主界面已经刷过一遍，但这里的 profile 是新读的。
    profile.refreshDerivedState();

    const settings: EngineSettings = defaultEngineSettings(now);
    return WidgetBuilder.build(profile, settings, now, model.dimension);
  }

  /**
   * 把 want 里传过来的规格归一成我们认识的几种。
   *
   * 平台的 formDimension 是数字枚举（2*4 -> 3），而 form_config.json 与
   * 卡片自身用的都是带星号的字符串，两边对不上时统一落到 2*4 —— 那是默认规格，
   * 也是排 3 节的那档，容量偏大，最坏情况是多显示一节课而不是少显示。
   */
  static normalizeDimension(raw: string): string {
    if (raw === WidgetDimension.ROOMY || raw === WidgetDimension.SMALL ||
      raw === WidgetDimension.TINY || raw === WidgetDimension.COMPACT) {
      return raw;
    }
    if (raw === '4*4' || raw === '4x4') {
      return WidgetDimension.ROOMY;
    }
    return WidgetDimension.COMPACT;
  }

  /**
   * want 的 formDimension（数字）翻成规格字符串。
   *
   * 平台在 onAddForm 传的是数字枚举，直接当字符串用会走到默认分支，
   * 于是用户明明选了 4*4 却按 2*4 排课。宁可猜错成 2*4，也不能排到 6 节
   * 却被裁成 3 节之外的东西。
   */
  static dimensionFromNumber(value: number): string {
    if (value === 4) {
      return WidgetDimension.ROOMY;
    }
    if (value === 2) {
      return WidgetDimension.SMALL;
    }
    if (value === 6) {
      return WidgetDimension.TINY;
    }
    if (value === 3) {
      return WidgetDimension.COMPACT;
    }
    return WidgetDimension.COMPACT;
  }
}
