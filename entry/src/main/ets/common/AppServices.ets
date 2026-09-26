/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 组合根：把服务装起来，并保证整个进程只有一个 ViewModel。
 *
 * 生命周期
 * --------
 * ViewModel 持有轮询定时器，必须与页面同生共死。ArkUI 的 struct 每次进入页面
 * 都会重新构造，所以实例挂在这里的模块级变量上而不是页面里 —— 页面被销毁
 * 重建时定时器不会被重复启动，旋转屏幕 / 折叠展开也不会泄漏。
 *
 * 小组件那边不共用这个容器：FormExtensionAbility 是独立运行时，自己装配自己
 * 那一份。引擎没有跨实例可变状态，所以这样切是安全的。
 */

import { common } from '@kit.AbilityKit';
import { DateTimeValue } from 'common_shared';
import { ClassTableViewModel } from '../viewmodel/ClassTableViewModel';
import { ScheduleEditorViewModel } from '../viewmodel/ScheduleEditorViewModel';
import { AppClock, SystemClock } from './AppClock';
import { ProfileRepository } from '../data/ProfileRepository';
import { FormWidgetService } from '../widget/FormWidgetService';
import { ReminderSyncResult, syncReminders } from '../reminder/ReminderSyncService';
import { ServiceContainer, ServiceKeys } from './ServiceContainer';

let instance: ClassTableViewModel | undefined = undefined;
let editorInstance: ScheduleEditorViewModel | undefined = undefined;

/**
 * 取进程内唯一的课表页 ViewModel，首次调用时装配。
 *
 * @param context UIAbility 的 context，提供应用沙箱内可写的 filesDir。
 *        档案落在 filesDir 下，随应用卸载一并清除。
 */
export function resolveClassTableViewModel(context: common.UIAbilityContext): ClassTableViewModel {
  if (instance !== undefined) {
    return instance;
  }
  const container: ServiceContainer = new ServiceContainer();
  container.registerValue<AppClock>(ServiceKeys.CLOCK, new SystemClock());
  container.register<ProfileRepository>(ServiceKeys.PROFILE_REPO, () => {
    return new ProfileRepository(context.filesDir);
  });

  instance = new ClassTableViewModel(
    container.require<AppClock>(ServiceKeys.CLOCK),
    container.require<ProfileRepository>(ServiceKeys.PROFILE_REPO)
  );
  return instance;
}

/** 只为测试与「重置」用：丢掉当前实例，下次 resolve 会重新装配。 */
export function resetClassTableViewModel(): void {
  if (instance !== undefined) {
    instance.stop();
  }
  instance = undefined;
}

/**
 * 取进程内唯一的编辑页 ViewModel，首次调用时装配。
 *
 * 与课表页的 ViewModel 分开持有：编辑页持有草稿（一份完整的 Profile），
 * 课表页持有轮询定时器。放同一个实例里的话，进编辑页会把课表页的定时器
 * 一起牵住，退出编辑页又要判断「用户到底有没有改动」来决定要不要刷盘 ——
 * 两个生命周期不同的事耦在一起，最后谁也说不清。
 *
 * @param context UIAbility 的 context
 */
export function resolveScheduleEditorViewModel(
  context: common.UIAbilityContext): ScheduleEditorViewModel {
  if (editorInstance !== undefined) {
    return editorInstance;
  }
  const container: ServiceContainer = new ServiceContainer();
  container.registerValue<AppClock>(ServiceKeys.CLOCK, new SystemClock());
  container.register<ProfileRepository>(ServiceKeys.PROFILE_REPO, () => {
    return new ProfileRepository(context.filesDir);
  });

  editorInstance = new ScheduleEditorViewModel(
    container.require<AppClock>(ServiceKeys.CLOCK),
    container.require<ProfileRepository>(ServiceKeys.PROFILE_REPO)
  );
  // 桌面卡片有自己的运行时，档案改了它不会自己知道。这里是全应用唯一同时
  // 握有「档案已落盘」和「UIAbilityContext」的地方，通知由它发出。
  editorInstance.onProfileSaved((): void => {
    FormWidgetService.reloadAllQuietly(context);
    // 课前提醒同样有自己的运行时（平台侧的周期提醒），改了课表不知道。
    // 提前触发不 await：保存这件事不该因为提醒同步慢而被拖住，
    // 而同步失败也不该让「保存」看起来失败。
    void syncClassReminders(context);
  });
  return editorInstance;
}

/**
 * 同步课前提醒。
 *
 * 触发点有三个：进入前台、保存课表、改提醒设置。前两个不够 ——
 * 只靠「进入前台」的话，用户改了课表却一直没切前台过（平板上很常见），
 * 提醒就还停在旧课表上；而只靠「保存课表」的话，设备关机一整周之后
 * 平台上首次触发日已经落在过去，而课表可能是被别的设备同步进来的、
 * 本机从没打开过。
 *
 * 不做定时轮询：平台的周期重复挂在 daysOfWeek 上，不依赖应用运行，
 * 「一整周没开应用」期间提醒照常响。轮询只会耗电，且没有新信息可同步 ——
 * 编排是纯函数，同一份档案同一份设置，同一天算出来的结果完全一样。
 */
export async function syncClassReminders(
  context: common.UIAbilityContext): Promise<ReminderSyncResult> {
  return syncReminders(context, new ProfileRepository(context.filesDir), DateTimeValue.now());
}

/** 丢掉编辑页 ViewModel，下次 resolve 重新装配（草稿随之丢弃）。 */
export function resetScheduleEditorViewModel(): void {
  editorInstance = undefined;
}
