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
import { ClassTableViewModel } from '../viewmodel/ClassTableViewModel';
import { AppClock, SystemClock } from './AppClock';
import { ProfileRepository } from '../data/ProfileRepository';
import { ServiceContainer, ServiceKeys } from './ServiceContainer';

let instance: ClassTableViewModel | undefined = undefined;

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
