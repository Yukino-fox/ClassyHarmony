/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 后台保活：长时任务（ContinuousTask）的申请与释放。
 *
 * 为什么需要它
 * ----------
 * 应用退到后台后会被系统冻结：定时器停、网络停、分布式会话断。课表最核心的
 * 两个提醒场景（上下课、课前）恰恰都发生在应用不在前台的时候。不申请长时
 * 任务的话，自动化只在用户盯着屏幕时才跑，等于把提醒功能废掉。
 *
 * 为什么类型要挑
 * ------------
 * 长时任务每个类型都绑一个使用场景，乱报属于违规使用。具体挑哪一种、以及
 * 「什么时候干脆不申请」的判定全在 core 的 `planKeepAlive()` 里（纯函数、
 * 可在 Node 测试台全量枚举），这里只做三件事：
 *   1. 把 core 的字符串类型翻译成 `BackgroundMode`；
 *   2. 调 `startBackgroundRunning` / `stopBackgroundRunning`；
 *   3. 把结果翻译成一句人话存进 status，供设置页显示。
 *
 * 申请失败是正常路径
 * ----------------
 * 手机上的「任务保持」需要受限权限，普通应用拿不到，`startBackgroundRunning`
 * 会直接抛错。这不是 bug，也不该打扰用户 —— 存进 status，回落成「仅前台」，
 * 其余功能照常。
 *
 * 为什么 start/stop 要串行化
 * ------------------------
 * 前台/后台切换、设置页拨开关、功能开关变化都会触发 start/stop，这几次调用
 * 可能重叠（都带 await）。两个并发的 `startBackgroundRunning` 会留下两条
 * 任务记录，只在其中一条上 stop 是漏；先 start 后 stop 的乱序则会让本该停的
 * 任务继续挂着。所以这里把请求收进一条串行链，并允许「串行期间又来一次」
 * 重跑一遍。
 */

import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { t, tf } from 'common_core';
import {
  KEEP_ALIVE_MODE_MULTI_DEVICE,
  KeepAlivePlan,
  keepAliveErrorText,
  planKeepAlive
} from 'common_core';
import {
  AppPreferences,
  DEFAULT_BACKGROUND_KEEP_ALIVE,
  PrefKeys
} from '../common/AppPreferences';
import { AutomationSettings } from '../automation/AutomationSettings';
import { resolveDistributedStateService } from '../ipc/DistributedStateService';

const DOMAIN: number = 0x0000;
const TAG: string = 'BackgroundTask';

export class BackgroundTaskService {
  private readonly context: common.UIAbilityContext;
  private readonly prefs: AppPreferences;
  /** 当前是否真的有一条长时任务在跑。 */
  private running: boolean = false;
  /** 正在跑的那条任务的类型；没跑时为空串。 */
  private activeMode: string = '';
  /** 调用方希望它跑（前台/开关打开）还是停（后台/开关关闭）。 */
  private desiredRunning: boolean = false;
  /** 串行链正在执行。 */
  private reconciling: boolean = false;
  /** 串行期间又来了请求，跑完这一轮要再算一次。 */
  private dirty: boolean = false;
  /** status 文案。空串 = 还没算过。 */
  private status: string = '';
  /** WantAgent 只建一次：内容不变，重复建是浪费。 */
  private agent: WantAgent | undefined = undefined;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.prefs = new AppPreferences(context);
  }

  /** 用户开关（落盘值）。 */
  isEnabled(): boolean {
    return this.prefs.getBoolean(PrefKeys.BACKGROUND_KEEP_ALIVE, DEFAULT_BACKGROUND_KEEP_ALIVE);
  }

  /** 当前是否真有一条长时任务在跑。 */
  isRunning(): boolean {
    return this.running;
  }

  /**
   * 同步判断「现在有没有值得在后台继续跑的功能」。
   *
   * 与 isRunning() 的区别：这个不看系统批没批，只看用户设置与功能开关。
   * onBackground 需要同步决定停不停轮询，而申请是异步的 —— 用它来判，
   * 不会因为「申请还没返回」而误停。
   */
  shouldKeepAlive(): boolean {
    return this.plan().request;
  }

  /** 给设置页显示的文案。 */
  statusText(): string {
    if (!this.isEnabled()) {
      return t('bt_off');
    }
    return this.status.length === 0 ? t('bt_not_started') : this.status;
  }

  /** 拨开关：写盘，然后立刻按新状态申请或释放。 */
  setEnabled(on: boolean): void {
    this.prefs.put(PrefKeys.BACKGROUND_KEEP_ALIVE, on);
    if (on) {
      this.start();
    } else {
      this.stop();
    }
  }

  /** 请求保活（前台、或开关刚打开）。幂等，可重复调用。 */
  start(): void {
    this.desiredRunning = true;
    this.dirty = true;
    void this.reconcile();
  }

  /** 释放保活（后台、或开关关掉）。幂等。 */
  stop(): void {
    this.desiredRunning = false;
    this.dirty = true;
    void this.reconcile();
  }

  // ------------------------------------------------------------ 内部

  /**
   * 当前该不该申请、申请哪种。
   *
   * 每次都现读设置：跨设备/自动化开关可能在两次 start 之间被改过，
   * 缓存下来就会用旧类型去申请。
   */
  private plan(): KeepAlivePlan {
    const automationOn: boolean =
      new AutomationSettings(this.context.filesDir).getIsAutomationEnabled();
    const distributedOn: boolean = resolveDistributedStateService(this.context).isEnabled();
    return planKeepAlive(this.isEnabled(), distributedOn, automationOn);
  }

  private async reconcile(): Promise<void> {
    if (this.reconciling) {
      return;
    }
    this.reconciling = true;
    try {
      // dirty 在 applyOnce 的 await 期间可能被再次置位（例如请求还在飞的时候
      // 用户退到了后台），循环保证最终状态收敛到「最后一次请求」。
      while (this.dirty) {
        this.dirty = false;
        await this.applyOnce();
      }
    } finally {
      this.reconciling = false;
    }
  }

  private async applyOnce(): Promise<void> {
    const plan: KeepAlivePlan = this.plan();
    if (!this.desiredRunning || !plan.request) {
      if (this.running) {
        await this.release();
      }
      this.status = plan.reason;
      return;
    }
    if (this.running && this.activeMode === plan.mode) {
      this.status = tf('bt_running_in', this.modeLabel(plan.mode));
      return;
    }
    if (this.running) {
      // 类型变了（例如刚开了跨设备同步）：先退旧的，再按新类型申请。
      await this.release();
    }
    await this.request(plan);
  }

  private async request(plan: KeepAlivePlan): Promise<void> {
    try {
      const agent: WantAgent = await this.buildWantAgent();
      const mode: backgroundTaskManager.BackgroundMode = this.toBackgroundMode(plan.mode);
      await backgroundTaskManager.startBackgroundRunning(this.context, mode, agent);
      this.running = true;
      this.activeMode = plan.mode;
      this.status = tf('bt_running_in', this.modeLabel(plan.mode));
      hilog.info(DOMAIN, TAG, 'continuous task started: %{public}s', plan.mode);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.running = false;
      this.activeMode = '';
      this.status = tf('bt_request_failed', keepAliveErrorText(be.code));
      hilog.warn(DOMAIN, TAG, 'startBackgroundRunning failed: code=%{public}d', be.code);
    }
  }

  private async release(): Promise<void> {
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
    } catch (err) {
      // 没在跑、或系统已经回收了这条任务时 stop 会抛。这里的目的是「确保不跑」，
      // 抛错说明它本来就没跑，忽略即可。
      hilog.debug(DOMAIN, TAG, 'stopBackgroundRunning: %{public}s', `${err}`);
    }
    this.running = false;
    this.activeMode = '';
  }

  /** 系统通知栏那条常驻通知点下去要回到应用，所以需要一个指向本 Ability 的 WantAgent。 */
  private async buildWantAgent(): Promise<WantAgent> {
    if (this.agent !== undefined) {
      return this.agent;
    }
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    this.agent = await wantAgent.getWantAgent(info);
    return this.agent;
  }

  private toBackgroundMode(mode: string): backgroundTaskManager.BackgroundMode {
    if (mode === KEEP_ALIVE_MODE_MULTI_DEVICE) {
      return backgroundTaskManager.BackgroundMode.MULTI_DEVICE_CONNECTION;
    }
    return backgroundTaskManager.BackgroundMode.TASK_KEEPING;
  }

  private modeLabel(mode: string): string {
    return mode === KEEP_ALIVE_MODE_MULTI_DEVICE ? t('bt_mode_multi') : t('bt_mode_task');
  }
}

let instance: BackgroundTaskService | undefined = undefined;

/** 取进程内唯一的后台保活服务，首次调用时装配。 */
export function resolveBackgroundTaskService(
  context: common.UIAbilityContext): BackgroundTaskService {
  if (instance === undefined) {
    instance = new BackgroundTaskService(context);
  }
  return instance;
}

/** 丢掉单例；调用方负责先 stop。 */
export function resetBackgroundTaskService(): void {
  instance?.stop();
  instance = undefined;
}
