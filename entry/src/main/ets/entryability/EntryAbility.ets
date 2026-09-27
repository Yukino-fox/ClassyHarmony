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
import { resolveClassTableViewModel, syncClassReminders } from '../common/AppServices';
import { ThemeService } from '../common/ThemeService';
import { resolveExactTimeService } from '../time/ExactTimeService';
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
      // 主题放在 loadContent 回调里而不是 onWindowStageCreate 开头：
      // setColorMode 要求「窗口已创建且页面已加载」，提前调抛 16000011。
      // 代价是首帧可能按系统配色闪一下再切到用户选的档位 —— 只在「用户选了
      // 与系统相反的档位」时可见，而那本来就是用户自己设的，一帧的过渡
      // 换不来在这里做时序绕弯的复杂度。
      ThemeService.applyStored(this.context);
      hilog.info(DOMAIN, TAG, 'loadContent ok');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    // start() 幂等：定时器已在跑时不会叠加，只多一次重读档案。
    this.vm?.start();
    // 校时同理。start() 里会重读设置、跑一次每日补偿，并在距上次同步超过
    // 1 分钟时补一次查询。放在 onForeground 而不是 onCreate：应用在后台
    // 可能待很久，回前台补一次才准。
    resolveExactTimeService(this.context).start();
    hilog.info(DOMAIN, TAG, 'onForeground: polling resumed');
    // 课前提醒的周期重复挂在平台侧，不依赖本进程；这里同步是为了修正首次
    // 触发日（跨天之后它落在过去）与课表变更（可能来自设备间同步）。
    // 差异同步，绝大多数情况下这里一条都不会重发。
    void this.syncRemindersQuietly();
  }

  /**
   * 同步提醒，失败只记日志。
   *
   * 不给用户弹提示：进入前台是一个被动动作，在这里弹「提醒同步失败」会
   * 打断正在做的事，而同步是后台自愈的 —— 下次保存或下次进前台会自动重试。
   * 真正需要用户处理的两类问题（通知权限没开、额度不够）由设置页在用户
   * 主动去看的时候显示。
   */
  private async syncRemindersQuietly(): Promise<void> {
    try {
      const result = await syncClassReminders(this.context);
      if (result.failedCount > 0) {
        hilog.warn(DOMAIN, TAG, 'reminder sync partial: %{public}d failed',
          result.failedCount);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'reminder sync failed: %{public}s', `${err}`);
    }
  }

  onBackground(): void {
    this.vm?.stop();
    // 后台不查 NTP。10 分钟一次的间隔意味着最多丢 10 分钟精度，用户切回来
    // 时 onForeground 会补查；而一个在后台还挂着的 UDP socket 既费电又可能
    // 被系统在后台冻结时杀掉，白白产生一次「同步失败」的状态文案。
    resolveExactTimeService(this.context).stop();
    hilog.info(DOMAIN, TAG, 'onBackground: polling stopped');
  }
}
