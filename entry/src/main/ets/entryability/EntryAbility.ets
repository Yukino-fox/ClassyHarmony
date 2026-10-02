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

import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { resolveClassTableViewModel, resetAutomationScheduler, resolveAutomationScheduler,
  syncClassReminders } from '../common/AppServices';
import { ThemeService } from '../common/ThemeService';
import { resolveExactTimeService } from '../time/ExactTimeService';
import { shutdownSpeechService } from '../speech/SpeechService';
import { resolveWeatherService, resetWeatherService } from '../weather/WeatherService';
import {
  resolveDistributedStateService,
  resetDistributedStateService
} from '../ipc/DistributedStateService';
import {
  BackgroundTaskService,
  resetBackgroundTaskService,
  resolveBackgroundTaskService
} from '../background/BackgroundTaskService';
import { clearCache } from 'common_core';
import { resolvePluginService } from '../plugin/PluginService';
import { buildPublicQueryResult, isPublicQuery } from '../ipc/PublicQueryService';
import { ClassTableViewModel } from '../viewmodel/ClassTableViewModel';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassyHarmony';

export default class EntryAbility extends UIAbility {
  /** 进程内唯一的课表页 ViewModel。onCreate 里装配一次，之后只做启停。 */
  private vm: ClassTableViewModel | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 外部应用用 startAbilityForResult 查询公开状态时，是本应用**冷启动**
    // 走到这里。此时不做页面装配，直接回答后退出：查询是「一问一答」，
    // 弹出一个空窗口再自己关掉只会闪一下。
    if (isPublicQuery(want)) {
      this.respondToPublicQuery(want);
      return;
    }
    // 在 onCreate 就装配而不是等页面：页面首帧就能拿到已重算好的网格，
    // 不会先闪一下「正在读取课表」。
    this.vm = resolveClassTableViewModel(this.context);
    // 天气服务也在这里建：它要在页面首帧之前就存在，否则面板第一次 refreshPreview
    // 拿到的是 undefined 快照，天气组件会先闪一下「还没取到」。真正的刷新在
    // onForeground 的 start()，那里才起定时器。
    resolveWeatherService(this.context);
    // 跨设备同步服务也在 onCreate 建：设置页与自动化 tick 都按单例去取，
    // 不在这里建的话，第一次读它的人会拿到一个还没 reload 过的实例。
    // 真正的入会话在 onForeground 的 start()。
    resolveDistributedStateService(this.context);
    // 自动化调度器在这里建（但不 start）：它每秒读档案算快照，必须与
    // ViewModel 分开持有 —— 页面的生命周期与「该不该弹通知」无关。
    resolveAutomationScheduler(this.context);
    // 扩展在这里装载。必须早于自动化调度器的第一次 tick：调度器每秒都会按
    // ActionCatalog 找行动，扩展的条目晚一拍注册的话，头一秒会把它判成
    // 「未知行动 id」并在自动化里留下一条失败记录 —— 而用户什么都没做错。
    resolvePluginService(this.context);
    // 后台保活服务同理：设置页要读它的状态，先建出来。
    resolveBackgroundTaskService(this.context);
    hilog.info(DOMAIN, TAG, 'onCreate: viewModel ready');
  }

  /**
   * 应用已经在运行时又收到一个 Want（外部应用再次发起查询）。
   *
   * 非公开查询的 Want 一律不接管 —— 只回答我们声明的那两个 action，
   * 别的交给系统默认行为，免得把普通唤起也吞掉。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (isPublicQuery(want)) {
      this.respondToPublicQuery(want);
    }
  }

  /**
   * 回答一条公开查询并退出。
   *
   * `terminateSelfWithResult` 把结果 Want 送回调用方的
   * `startAbilityForResult` 回调。失败只记日志：调用方要么超时、要么收到
   * 我们构造的失败结果（见 buildPublicQueryResult），两条路都不会崩。
   */
  private respondToPublicQuery(want: Want): void {
    const result: Want | undefined = buildPublicQueryResult(this.context, want);
    if (result === undefined) {
      return;
    }
    this.context.terminateSelfWithResult({ resultCode: 0, want: result })
      .catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'terminateSelfWithResult failed: %{public}s', err.message);
      });
  }

  onDestroy(): void {
    // 进程要退了，定时器跟着一起停，免得 onDestroy 之后再有一次 tick。
    this.vm?.stop();
    this.vm = undefined;
    // 释放系统 TTS 引擎。引擎占着全设备三个实例名额之一，而且带 isBackStage
    // 创建的那个会让进程晚一点才能被回收 —— 不释放的话，反复冷启动几次之后
    // 别的应用也会建不出引擎。
    shutdownSpeechService();
    // 天气定时器与进程内快照一起丢掉。
    resetWeatherService();
    // 退出分布式会话并丢掉单例。
    resetDistributedStateService();
    // 自动化调度器与后台保活一起收掉：保活会挂一条常驻通知，进程都要退了
    // 还留着那条通知是错的。
    resetAutomationScheduler();
    resetBackgroundTaskService();
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
    // 天气：读缓存 + 起 5 分钟定时器 + 立刻刷一次。退后台会停掉定时器（见
    // onBackground），回前台这里重启 —— 天气是「看一眼」的数据，后台不刷
    // 也看不出差别，而少一个后台网络轮询就少一份耗电与被冻结的风险。
    resolveWeatherService(this.context).start();
    // 跨设备：进前台才入会话。退后台会 stop()（见 onBackground）—— 后台既不
    // 推状态也没人看，挂着一个分布式会话只会费电。
    resolveDistributedStateService(this.context).start();
    // 自动化：前台开始每秒 tick。退后台是否继续跑由保活决定（见 onBackground）。
    resolveAutomationScheduler(this.context).start();
    // 保活：在**前台**就申请长时任务。系统要求「申请时应用可见」，
    // 退到后台再申请会被拒。申请不成功只影响状态文案，不影响其余功能。
    resolveBackgroundTaskService(this.context).start();
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
    const keepAlive: BackgroundTaskService = resolveBackgroundTaskService(this.context);
    if (keepAlive.shouldKeepAlive()) {
      // 有长时任务撑着，进程不会被冻结：所有轮询继续跑。这正是保活的目的 ——
      // 上下课通知、课前朗读都发生在应用不在前台的时候。申请失败（手机上
      // 的「任务保持」需要受限权限）时这里仍然继续跑，只是进程会被系统冻结，
      // 冻结期间定时器不触发，回前台时 start() 幂等重启 —— 不做特判是因为
      // 「申请中」与「申请失败」在这里分不出来，而两者都该保持同一套语义。
      hilog.info(DOMAIN, TAG, 'onBackground: keep-alive active, polling continues');
      return;
    }
    // 没有值得后台跑的功能，或用户关了保活：按老规矩全停，省电也省得被冻结。
    keepAlive.stop();
    this.vm?.stop();
    resolveAutomationScheduler(this.context).stop();
    // 朗读**不**停：引擎是以 isBackStage 创建的，退到后台会继续把当前这一句
    // 念完 —— 而课前一分钟提醒最可能发生在应用不在前台的时候，那正是它该
    // 起作用的时候。停掉引擎就等于把语音功能限制在「用户正盯着屏幕」的场景，
    // 那个场景里用户本来也不需要有人念给他听。
    // 后台不查 NTP。10 分钟一次的间隔意味着最多丢 10 分钟精度，用户切回来
    // 时 onForeground 会补查；而一个在后台还挂着的 UDP socket 既费电又可能
    // 被系统在后台冻结时杀掉，白白产生一次「同步失败」的状态文案。
    resolveExactTimeService(this.context).stop();
    // 天气同样停：定时器与快照留在单例里（回前台时 start() 会接着用），
    // 只把 5 分钟的轮询停掉。
    resolveWeatherService(this.context).stop();
    // 跨设备同步同样退后台就停：对方要的是「现在上什么课」，而这台设备都退到
    // 后台了，继续广播也没有观众。回前台 start() 会重新入会话。
    resolveDistributedStateService(this.context).stop();
    hilog.info(DOMAIN, TAG, 'onBackground: polling stopped');
  }

  /**
   * 配置变化（语言、深色模式、字号…）。
   *
   * 语言切换时清掉 i18n 缓存：`$r` 每次都会按当前语言解析，但 I18n.t 的结果
   * 有缓存（避免每秒 tick 里的天气/状态文案反复查资源）。不清的话，切换语言后
   * 界面会一直显示旧语言，直到进程被系统重建 —— 而进程重建的时机不可控，
   * 用户会以为「切语言没生效」。
   *
   * 其余配置变化（深色模式等）不需要处理：颜色走 `$r('app.color.*')` 是系统
   * 实时解析的，不经过这里的缓存。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    clearCache();
    // 主题跟着系统走时，深色切换要刷新页面配色。ThemeService 内部有监听，
    // 这里只清文案缓存；界面刷新由 ArkUI 的资源订阅自动触发。
    super.onConfigurationUpdate(newConfig);
  }
}
