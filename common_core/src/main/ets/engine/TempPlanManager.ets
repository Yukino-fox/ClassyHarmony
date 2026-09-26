/*
 * 临时课表与临时课表群的生命周期管理。
 * 对应 ProfileService 的 ClearTempClassPlan / CleanExpiredTempClassPlan /
 * ConvertToStdClassPlan / SetupTempClassPlanGroup / ClearTempClassPlanGroup /
 * ClearExpiredTempClassPlanGroup / CreateTempClassPlan
 *
 * 桌面版把这些挂在单例服务上，50ms 轮询每帧都调一遍清理。这里保持同样的
 * 调用频率与幂等性，但全部是「传入档案 + 传入当前时间」的静态方法，
 * 不持有任何状态——小组件 Extension 加载完即可调用，无需考虑残留。
 *
 * 桌面版内部用 IAppHost 静态取当前时间，可测性很差。这里把时间提升为参数，
 * 行为不变而可测。
 */

import {
  ClassPlan,
  DateTimeValue,
  Guid,
  JsonObject,
  ModelCloner,
  OrderedSchedule,
  Profile,
  TimeLayout
} from 'common_shared';
import { EngineSettings } from './EngineSettings';

/** 创建临时层时追加到课表 / 时间表名的后缀，转正时移除。 */
const TEMP_LAYOUT_SUFFIX: string = '（临时层）';

export class TempPlanManager {
  /**
   * 清理过期预定与无人引用的临时课表 / 临时时间表。
   * 对应 ProfileService.CleanExpiredTempClassPlan。
   *
   * 三步，顺序有依赖，不可调换：
   *  1. 删掉日期早于今天的预定
   *  2. 删掉 isOverlay 且不再被任何预定引用的课表
   *  3. 删掉 isOverlay 且不再被任何存活课表引用的时间表
   * 第 3 步的活跃引用集要靠第 2 步的结果才能算准。
   */
  static cleanExpired(profile: Profile, now: DateTimeValue): void {
    const today: number = now.dateOnly().epochDay();

    // 1. 过期预定
    const expiredKeys: string[] = [];
    profile.orderedSchedules.forEach((_schedule: OrderedSchedule, key: string) => {
      const day: number | undefined = TempPlanManager.dayOfKey(key);
      if (day !== undefined && day < today) {
        expiredKeys.push(key);
      }
    });
    for (const key of expiredKeys) {
      profile.orderedSchedules.delete(key);
    }

    // 2. 无人引用的临时课表
    const stillReferenced: Set<string> = new Set<string>();
    profile.orderedSchedules.forEach((schedule: OrderedSchedule) => {
      stillReferenced.add(schedule.classPlanId.toString());
    });
    const orphanPlanKeys: string[] = [];
    profile.classPlans.forEach((plan: ClassPlan, key: string) => {
      if (plan.isOverlay && !stillReferenced.has(key)) {
        orphanPlanKeys.push(key);
      }
    });
    for (const key of orphanPlanKeys) {
      profile.classPlans.delete(key);
    }

    // 3. 无人引用的临时时间表
    const activeLayoutIds: Set<string> = new Set<string>();
    profile.classPlans.forEach((plan: ClassPlan, key: string) => {
      if (!plan.isOverlay || stillReferenced.has(key)) {
        activeLayoutIds.add(plan.timeLayoutId.toString());
      }
    });
    const orphanLayoutKeys: string[] = [];
    profile.timeLayouts.forEach((layout: TimeLayout, key: string) => {
      if (layout.isOverlay && !activeLayoutIds.has(key)) {
        orphanLayoutKeys.push(key);
      }
    });
    for (const key of orphanLayoutKeys) {
      profile.timeLayouts.delete(key);
    }
  }

  /**
   * 临时课表已过期则解绑。
   * 对应 LoadCurrentClassPlan 中 `if (TempClassPlanSetupTime.Date < now.Date) TempClassPlanId = null;`
   *
   * 判据是严格早于今天，即「今天到期」的临时课表当天仍然生效。
   */
  static clearExpiredTempClassPlan(profile: Profile, now: DateTimeValue): boolean {
    if (TempPlanManager.dateBefore(profile.tempClassPlanSetupTime, now)) {
      profile.tempClassPlanId = undefined;
      return true;
    }
    return false;
  }

  /**
   * 临时课表群过期则清除。对应 ProfileService.ClearExpiredTempClassPlanGroup。
   *
   * 这里的过期判据同样是严格早于今天。注意它与 ClassPlanResolver.matchesGroup
   * 中「临时群是否生效」的判据不同：后者额外要求「未过期」用的是
   * `!(到期日 < 目标日)`，两者对「今天到期」给出的结论相反——
   * 清理会保留它，但选课当它不存在。这是桌面版原样，已逐字核实，照搬。
   */
  static clearExpiredTempGroup(profile: Profile, now: DateTimeValue): boolean {
    if (TempPlanManager.dateBefore(profile.tempClassPlanGroupExpireTime, now)) {
      TempPlanManager.clearTempGroup(profile);
      return true;
    }
    return false;
  }

  /** 清除临时课表群。对应 ProfileService.ClearTempClassPlanGroup。 */
  static clearTempGroup(profile: Profile): void {
    profile.tempClassPlanGroupId = undefined;
    profile.isTempClassPlanGroupEnabled = false;
  }

  /**
   * 把临时层课表转为普通课表。对应 ProfileService.ConvertToStdClassPlan(id)。
   * 课表不存在时返回 false 且不做任何改动。
   */
  static convertToStdClassPlan(profile: Profile, id: Guid): boolean {
    const plan: ClassPlan | undefined = profile.tryGetClassPlan(id);
    if (plan === undefined) {
      return false;
    }
    plan.isOverlay = false;
    const layout: TimeLayout | undefined = profile.tryGetTimeLayout(plan.timeLayoutId);
    if (layout !== undefined && layout.isOverlay) {
      layout.isOverlay = false;
      layout.name = layout.name.replace(TEMP_LAYOUT_SUFFIX, '');
    }
    return true;
  }

  /**
   * 启用临时课表群并算出到期时间。对应 ProfileService.SetupTempClassPlanGroup。
   *
   * 到期时间 = 今天 + 群内所有课表生效日偏移的最大值，即等最后一门课跑完。
   * 群内没有可用课表时偏移为 0，群在今天结束时过期。
   *
   * expireTime 非空时直接采用，覆盖计算结果——与桌面版的 `expireTime ??=` 一致。
   */
  static setupTempGroup(profile: Profile, key: Guid, settings: EngineSettings,
    now: DateTimeValue, expireTime?: DateTimeValue): DateTimeValue {
    const resolved: DateTimeValue = expireTime === undefined
      ? now.dateOnly().addDays(TempPlanManager.groupDayOffset(profile, key, settings, now))
      : expireTime;
    profile.tempClassPlanGroupExpireTime = resolved;
    profile.tempClassPlanGroupId = key;
    profile.isTempClassPlanGroupEnabled = true;
    return resolved;
  }

  /**
   * 群内所有课表生效日相对今天的最大天数偏移。
   * 对应 SetupTempClassPlanGroup 里的那个循环。
   *
   * 单门课表的生效日由两件事叠加决定：
   *  - baseOffset：WeekDay 与今天星期几之差（跨一周则 +7）
   *  - divOffset：单双周轮转里还要等几个「轮次周」（模 WeekCountDivTotal）
   * 次序是「先等轮转周数，再等星期几」，故按 baseOffset + divOffset * 7 合成。
   */
  private static groupDayOffset(profile: Profile, key: Guid, settings: EngineSettings,
    now: DateTimeValue): number {
    const keyText: string = key.toString();
    const todayDow: number = now.dayOfWeek();
    // 桌面版是 floor(天数差 / 7) + 1，注意那个 +1。
    const elapsedWeeks: number = Math.floor(
      (now.dateOnly().epochDay() - settings.singleWeekStartTime.dateOnly().epochDay()) / 7) + 1;
    let maxOffset: number = 0;
    profile.classPlans.forEach((plan: ClassPlan) => {
      if (plan.associatedGroup.toString() !== keyText) {
        return;
      }
      const total: number = plan.timeRule.weekCountDivTotal;
      // 桌面版在此处做 % total，total <= 0 会抛 DivideByZeroException。
      // 档案里出现这种脏数据时让该课表不参与偏移计算，群里其余课表照常生效。
      if (total <= 0) {
        return;
      }
      const w: number = elapsedWeeks % total;
      const baseOffset: number = plan.timeRule.weekDay - todayDow;
      const divOffset: number = (plan.timeRule.weekCountDiv + total - w) % total;
      let finalOffset: number = baseOffset + divOffset * 7;
      if (finalOffset < 0) {
        finalOffset += 7;
      }
      if (finalOffset > maxOffset) {
        maxOffset = finalOffset;
      }
    });
    return maxOffset;
  }

  /**
   * 以某张课表为源创建临时层课表。
   * 对应 ProfileService.CreateTempClassPlan(id, timeLayoutId, enableDateTime, createTempTimeLayout)。
   *
   * 当天已存在指向 isOverlay 课表的预定时返回 undefined（桌面版返回 null），
   * 语义是「今天已经改过了，不要覆盖」。
   *
   * 复制走 JSON 往返（见 ModelCloner）而非逐字段克隆：临时层要带上源课表的
   * 全部字段，包括插件写进 AttachedObjects 的任意 JSON。
   */
  static createTempClassPlan(profile: Profile, sourceId: Guid, enableDate: DateTimeValue,
    createTempTimeLayout: boolean, timeLayoutId?: Guid): Guid | undefined {
    const existingKey: string = enableDate.dateOnly().toString();
    const existingSchedule: OrderedSchedule | undefined = profile.orderedSchedules.tryGet(existingKey);
    if (existingSchedule !== undefined) {
      const current: ClassPlan | undefined =
        profile.tryGetClassPlan(existingSchedule.classPlanId);
      if (current !== undefined && current.isOverlay) {
        return undefined;
      }
    }

    const sourcePlan: ClassPlan | undefined = profile.tryGetClassPlan(sourceId);
    if (sourcePlan === undefined) {
      return undefined;
    }
    const baseLayoutId: Guid = timeLayoutId === undefined ? sourcePlan.timeLayoutId : timeLayoutId;

    let effectiveLayoutId: Guid = baseLayoutId;
    if (createTempTimeLayout) {
      const sourceLayout: TimeLayout | undefined = profile.tryGetTimeLayout(baseLayoutId);
      if (sourceLayout !== undefined) {
        const newLayout: TimeLayout = ModelCloner.duplicate(
          sourceLayout,
          (value: TimeLayout): JsonObject => value.toJson(),
          (node: JsonObject): TimeLayout => TimeLayout.fromJson(node));
        newLayout.isOverlay = true;
        newLayout.overlaySourceId = baseLayoutId;
        newLayout.name += TEMP_LAYOUT_SUFFIX;
        const newLayoutId: Guid = Guid.newGuid();
        profile.timeLayouts.set(newLayoutId.toString(), newLayout);
        effectiveLayoutId = newLayoutId;
      }
    }

    const newPlan: ClassPlan = ModelCloner.duplicate(
      sourcePlan,
      (value: ClassPlan): JsonObject => value.toJson(),
      (node: JsonObject): ClassPlan => ClassPlan.fromJson(node));
    newPlan.isOverlay = true;
    newPlan.timeLayoutId = effectiveLayoutId;
    newPlan.overlaySourceId = sourceId;
    newPlan.name += TEMP_LAYOUT_SUFFIX;
    newPlan.overlaySetupTime = enableDate;
    profile.isOverlayClassPlanEnabled = true;
    const newId: Guid = Guid.newGuid();
    profile.classPlans.set(newId.toString(), newPlan);
    profile.overlayClassPlanId = newId;
    TempPlanManager.setOrdered(profile, existingKey, newId);
    return newId;
  }

  /**
   * 取消今天的临时层。对应 ProfileService.ClearTempClassPlan。
   * 删掉今天的预定、解绑 OverlayClassPlanId，然后照常执行过期清理。
   */
  static clearTempClassPlan(profile: Profile, now: DateTimeValue): boolean {
    const overlayId: Guid | undefined = profile.overlayClassPlanId;
    if (overlayId === undefined || !profile.classPlans.has(overlayId.toString())) {
      return false;
    }
    const key: string = now.dateOnly().toString();
    if (profile.orderedSchedules.has(key)) {
      profile.orderedSchedules.delete(key);
    }
    profile.overlayClassPlanId = undefined;
    TempPlanManager.cleanExpired(profile, now);
    return true;
  }

  /** 写入某日预定。已有则改 ClassPlanId（保持字典键序，避免落盘重排）。 */
  private static setOrdered(profile: Profile, key: string, classPlanId: Guid): void {
    const existing: OrderedSchedule | undefined = profile.orderedSchedules.tryGet(key);
    if (existing !== undefined) {
      existing.classPlanId = classPlanId;
      return;
    }
    const created: OrderedSchedule = new OrderedSchedule();
    created.classPlanId = classPlanId;
    profile.orderedSchedules.set(key, created);
  }

  /** 预定键 -> 历日。键非法时返回 undefined（该预定不参与过期清理）。 */
  private static dayOfKey(key: string): number | undefined {
    const parsed: DateTimeValue | undefined = DateTimeValue.tryParse(key);
    return parsed === undefined ? undefined : parsed.dateOnly().epochDay();
  }

  private static dateBefore(left: DateTimeValue, right: DateTimeValue): boolean {
    return left.dateOnly().epochDay() < right.dateOnly().epochDay();
  }
}
