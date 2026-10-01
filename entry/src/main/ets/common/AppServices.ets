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
 *
 * 唯一的例外是时钟：容器里注册的不是 SystemClock 而是 resolveExactTimeService
 * 的结果（它实现 AppClock）。校时服务有跨调用状态 —— 10 分钟定时器、已同步
 * 偏差、冻结标记 —— 做成两份的话两边会各自发查询、各自算偏差，课表页和编辑页
 * 上显示的时间就对不上了。小组件那侧仍是 SystemClock，原因见该文件注释。
 */

import { common } from '@kit.AbilityKit';
import { DateTimeValue } from 'common_shared';
import { ClassTableViewModel } from '../viewmodel/ClassTableViewModel';
import { ScheduleEditorViewModel } from '../viewmodel/ScheduleEditorViewModel';
import { AppClock } from './AppClock';
import { ProfileRepository } from '../data/ProfileRepository';
import { ComponentLayoutRepository } from '../data/ComponentLayoutRepository';
import { ComponentLayoutViewModel } from '../viewmodel/ComponentLayoutViewModel';
import { AppPreferences, PrefKeys } from './AppPreferences';
import { FormWidgetService } from '../widget/FormWidgetService';
import { ReminderSyncResult, syncReminders } from '../reminder/ReminderSyncService';
import { resolveExactTimeService } from '../time/ExactTimeService';
import { ServiceContainer, ServiceKeys } from './ServiceContainer';
import { AutomationTickScheduler } from '../automation/AutomationTickScheduler';

let instance: ClassTableViewModel | undefined = undefined;
let editorInstance: ScheduleEditorViewModel | undefined = undefined;
let panelInstance: ComponentLayoutViewModel | undefined = undefined;
let automationScheduler: AutomationTickScheduler | undefined = undefined;

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
  // 校时服务实现 AppClock。进程内单例（见 resolveExactTimeService 的说明），
  // 所以两处 resolve 拿到的是同一个时钟，课表页与编辑页显示的时间不会差。
  container.registerValue<AppClock>(ServiceKeys.CLOCK, resolveExactTimeService(context));
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
  container.registerValue<AppClock>(ServiceKeys.CLOCK, resolveExactTimeService(context));
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

/**
 * 取进程内唯一的信息面板 ViewModel，首次调用时装配。
 *
 * 方案名从 preferences 读（对应桌面版 settings.json 的 CurrentComponentConfig）。
 * 不从 profile.json 读：那份要与桌面版字节级往返，塞一个桌面版不认识的字段进去
 * 就等于给双向同步埋一颗雷（见 AppPreferences 的头注）。
 *
 * @param context UIAbility 的 context，提供 filesDir 与 preferences 的落点。
 */
export function resolveComponentLayoutViewModel(
  context: common.UIAbilityContext): ComponentLayoutViewModel {
  if (panelInstance !== undefined) {
    return panelInstance;
  }
  const container: ServiceContainer = new ServiceContainer();
  container.register<ComponentLayoutRepository>(ServiceKeys.PANEL_REPO, () => {
    return new ComponentLayoutRepository(context.filesDir);
  });

  panelInstance = new ComponentLayoutViewModel(
    container.require<ComponentLayoutRepository>(ServiceKeys.PANEL_REPO),
    new ProfileRepository(context.filesDir)
  );
  // 方案名走 preferences，与 ReminderSettings 一样直接 new：preferences 按名字
  // 返回进程内同一份实例，不需要容器来保证唯一性。
  // load() 内部会 rebuild() → refreshPreview()，所以这里出来就有预览模型，
  // 不用等用户第一次改动。
  panelInstance.load(new AppPreferences(context).getString(PrefKeys.PANEL_SCHEME, ''));
  return panelInstance;
}

/** 丢掉信息面板 ViewModel，下次 resolve 重新装配。 */
export function resetComponentLayoutViewModel(): void {
  if (panelInstance !== undefined) {
    panelInstance.dispose();
  }
  panelInstance = undefined;
}

/**
 * 取进程内唯一的自动化 tick 调度器，首次调用时装配。
 *
 * 调度器只在这一处装配：它每秒读档案、算快照、跑规则，多一份实例就会
 * 把同一条自动化的行动执行两遍（弹两条通知、念两遍语音）。
 *
 * 生命周期跟着 Ability 走：前台 start、后台按「保活是否生效」决定停不停
 * （见 EntryAbility.onBackground）。与 ViewModel 分开持有 —— ViewModel 是
 * 「页面要显示什么」，调度器是「该不该弹通知」，后者在页面不可见时仍有意义。
 */
export function resolveAutomationScheduler(
  context: common.UIAbilityContext): AutomationTickScheduler {
  if (automationScheduler !== undefined) {
    return automationScheduler;
  }
  automationScheduler = new AutomationTickScheduler(
    context.filesDir,
    { context: context, filesDir: context.filesDir },
    new ProfileRepository(context.filesDir)
  );
  return automationScheduler;
}

/** 丢掉自动化调度器；调用方负责先 stop（onDestroy 与 onBackground 各自会停）。 */
export function resetAutomationScheduler(): void {
  automationScheduler?.stop();
  automationScheduler = undefined;
}
