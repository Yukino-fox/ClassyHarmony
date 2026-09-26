/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 主应用侧的小组件操作。
 *
 * 只有两件事：查桌面上有几张卡片、让它们重建。
 *
 * 为什么保存档案之后必须显式重建
 * ------------------------------
 * 卡片有自己的运行时，档案改了它不会自己知道。用户改完课表回到桌面，看到的
 * 还是旧课表 —— 而且卡片上有时间戳感（"正在上课 语文"），旧数据看起来完全可信，
 * 用户不会怀疑卡片，只会怀疑自己刚才的保存没生效。所以这条链路是必需品，不是优化。
 *
 * reloadAllForms 而不是 reloadForms
 * --------------------------------
 * reloadForms 要按 moduleName / abilityName / formName 三个键去匹配，全写对也能用，
 * 但这三个键一旦改了名字（比如 module 从 entry 挪走）就静默失效 —— 表现为
 * 「保存没生效」且没有任何报错。全量重建没有这个失配面，代价只是多重建几张
 * 同样的卡片，可以接受。
 */

import { common } from '@kit.AbilityKit';
import { formProvider } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x5701;
const LOG_TAG: string = 'FormWidget';

/** 结果类型：要么有值要么有原因，不让「静默失败」成为第三种可能。 */
export class FormWidgetReport {
  /** 桌面上的卡片数量。没查到时为 -1（区别于「确实一张都没有」）。 */
  count: number = -1;

  /** 本次触发重建的卡片数量。 */
  reloaded: number = 0;

  /** 没做成功时的原因。给用户看的，不是给日志看的。 */
  reason: string = '';
}

export class FormWidgetService {
  /**
   * 档案保存之后让所有卡片重建。
   *
   * 抛出的错误一律吞掉并记日志：保存档案是主任务，卡片刷新是附属动作。
   * 因为「桌面服务没连上」而让保存失败，用户会以为自己的课表丢了 ——
   * 而下一次卡片被系统唤醒时自然会读到新档案。
   */
  static async reloadAll(context: common.UIAbilityContext): Promise<FormWidgetReport> {
    const report: FormWidgetReport = new FormWidgetReport();
    try {
      const reloaded: number = await formProvider.reloadAllForms(context);
      report.reloaded = reloaded;
      report.count = reloaded;
    } catch (err) {
      const e = err as BusinessError;
      report.reason = '桌面服务暂时不可用，卡片会在下次被唤醒时更新';
      hilog.info(LOG_DOMAIN, LOG_TAG, 'reloadAllForms 失败 code=%{public}d', e.code);
    }
    return report;
  }

  /**
   * 桌面上有几张卡片。
   *
   * 给编辑页显示「已添加 N 张」用。查不到就返回 count = -1，界面据此不去显示
   * 具体数字 —— 拿 0 冒充「查到了，确实没有」会把「系统服务不可用」说成
   * 「用户没添加卡片」，后者引导他去做一件他已经做过的事。
   */
  static async publishedCount(): Promise<number> {
    try {
      // getPublishedFormInfos 从 API 20 起废弃，换成 getPublishedRunningFormInfos。
      const infos = await formProvider.getPublishedRunningFormInfos();
      return infos.length;
    } catch (err) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'getPublishedRunningFormInfos 失败');
      return -1;
    }
  }

  /**
   * 不关心结果的重建。给「主任务是保存档案」这种场景用。
   *
   * 单独一个方法而不是让调用方自己 `.then`：调用点是组合根里的回调，
   * 那里写一个空的 catch 会被当成漏写异常处理，而一个只能记日志的失败
   * 也没有值得让调用方分支的分支。
   */
  static reloadAllQuietly(context: common.UIAbilityContext): void {
    FormWidgetService.reloadAll(context).catch((err: BusinessError) => {
      // reloadAll 内部已兜住所有异常，走到这里说明连兜底逻辑本身出问题了。
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'reloadAll 的兜底也失败了 code=%{public}d', err.code);
    });
  }
}
