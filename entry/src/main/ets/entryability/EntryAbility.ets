/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 应用入口 Ability。
 *
 * 这里只做三件事：装配 ViewModel、加载页面、随前后台切换启停轮询。
 * 页面的显示逻辑一律不写在这里 —— Ability 生命周期与页面生命周期是两套，
 * 混在一起会出现「页面还在但定时器停了」这类难查的状态。
 *
 * 为什么前后台切换要管轮询
 * ----------------------
 * 页面切走时 ArkUI 不一定调 aboutToDisappear（退后台就不调），15 秒一次的
 * 定时器会跟着进程在后台空转。课表高亮只有跨过时间点边界时才变，后台轮询
 * 一次也看不出差别，纯属耗电，所以在 onBackground 停、onForeground 启。
 * 顺带 onForeground 的 start() 会重读一次档案，切回来时能看到小组件那边
 * 改动过的内容。
 */

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { resolveClassTableViewModel } from '../common/AppServices';
import { ClassTableViewModel } from '../viewmodel/ClassTableViewModel';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassyHarmony';

export default class EntryAbility extends UIAbility {
  /** 进程内唯一的课表页 ViewModel。onCreate 里装配一次，之后只做启停。 */
  private vm: ClassTableViewModel | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 在 onCreate 就装配而不是等页面：页面首帧就能拿到已重算好的网格，
    // 不会先闪一下「正在读取课表」。
    this.vm = resolveClassTableViewModel(this.context);
    hilog.info(DOMAIN, TAG, 'onCreate: viewModel ready');
  }

  onDestroy(): void {
    // 进程要退了，定时器跟着一起停，免得 onDestroy 之后再有一次 tick。
    this.vm?.stop();
    this.vm = undefined;
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent ok');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    // start() 幂等：定时器已在跑时不会叠加，只多一次重读档案。
    this.vm?.start();
    hilog.info(DOMAIN, TAG, 'onForeground: polling resumed');
  }

  onBackground(): void {
    this.vm?.stop();
    hilog.info(DOMAIN, TAG, 'onBackground: polling stopped');
  }
}
