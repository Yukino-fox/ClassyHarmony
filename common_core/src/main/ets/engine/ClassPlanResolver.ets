/*
 * 按日期挑出当前生效课表。对应 LessonsService.GetClassPlanByDate + CheckClassPlan
 *
 * 优先级从高到低，桌面版的判定顺序是：
 *  1. 预定临时课表：OrderedSchedules 里当天那条指向的课表
 *  2. 临时课表：TempClassPlanId 指向的、且尚未过期（建立时间 >= 目标日）
 *  3. 常规课表：按课表群匹配 + 单双周规则筛，取群优先级最高者
 *
 * 第 3 步里「群优先级」与「是否真的匹配今天」是两个独立维度：桌面版先按群
 * 优先级排序、再用 CheckClassPlan 过滤、最后取第一个。也就是说优先级高的
 * 课表即便今天不匹配，也只是被自己过滤掉，不会把位置让给低优先级的课表。
 * 这个顺序照搬——反过来会让高优先级群「空一天」，行为就变了。
 */

import {
  ClassPlan,
  ClassPlanGroup,
  DateTimeValue,
  Guid,
  OrderedSchedule,
  Profile,
  Subject,
  TempClassPlanGroupType
} from 'common_shared';
import { EngineSettings } from './EngineSettings';
import { WeekRotation } from './WeekRotation';

/** 生效课表的来源分支。仅用于诊断与测试断言，不影响选课结果。 */
export enum ResolvedSource {
  None = 0,
  /** 来自 OrderedSchedules 当天的预定。 */
  OrderedSchedule = 1,
  /** 来自 TempClassPlanId。 */
  TempClassPlan = 2,
  /** 来自常规课表的群匹配 + 单双周匹配。 */
  Regular = 3
}

/** 选中的课表及其来源 ID。 */
export class ResolvedClassPlan {
  plan: ClassPlan | undefined = undefined;

  /**
   * 命中的课表 ID；未命中时为 Guid.Empty。
   *
   * 桌面版签名是 `out Guid? guid`，第 3 步未命中时赋的是
   * `FirstOrDefault()` 的 default(KeyValuePair).Key —— 即 Guid.Empty 而非 null。
   * 判空请用 plan，不要指望 guid 为 undefined。
   */
  guid: Guid = Guid.empty();

  source: ResolvedSource = ResolvedSource.None;
}

export class ClassPlanResolver {
  /**
   * 取目标日期应生效的课表。
   * 对应 LessonsService.GetClassPlanByDate(date, out guid)。
   */
  static resolve(profile: Profile, date: DateTimeValue,
    settings: EngineSettings): ResolvedClassPlan {
    const out: ResolvedClassPlan = new ResolvedClassPlan();

    // 1. 预定临时课表
    const schedule: OrderedSchedule | undefined = profile.orderedScheduleFor(date);
    if (schedule !== undefined) {
      const ordered: ClassPlan | undefined = profile.tryGetClassPlan(schedule.classPlanId);
      // 叠加课表需开启叠加班表开关，否则视为没有预定。
      if (ordered !== undefined && (!ordered.isOverlay || profile.isOverlayClassPlanEnabled)) {
        out.plan = ordered;
        out.guid = schedule.classPlanId;
        out.source = ResolvedSource.OrderedSchedule;
        return out;
      }
    }

    // 2. 临时课表（建立日期 >= 目标日期才算有效，即尚未过期）
    const tempPlanId: Guid | undefined = profile.tempClassPlanId;
    if (tempPlanId !== undefined) {
      const tempPlan: ClassPlan | undefined = profile.tryGetClassPlan(tempPlanId);
      if (tempPlan !== undefined &&
        !ClassPlanResolver.dateBefore(profile.tempClassPlanSetupTime, date)) {
        out.plan = tempPlan;
        out.guid = tempPlanId;
        out.source = ResolvedSource.TempClassPlan;
        return out;
      }
    }

    // 3. 常规课表
    const hit: ResolvedHit = ClassPlanResolver.firstMatching(profile, date, settings);
    out.plan = hit.plan;
    out.guid = hit.guid;
    out.source = hit.plan === undefined ? ResolvedSource.None : ResolvedSource.Regular;
    return out;
  }

  /**
   * 群匹配的课表按优先级分桶，桶内保持档案内的原有顺序，取第一个匹配的。
   * 对应桌面版的 Where(群匹配).OrderByDescending(群优先级).Where(CheckClassPlan).FirstOrDefault()。
   */
  private static firstMatching(profile: Profile, date: DateTimeValue,
    settings: EngineSettings): ResolvedHit {
    // 优先级只有 0..3 四个取值，用桶排序而非比较排序：
    // 稳定序是硬要求（OrderByDescending 是稳定排序），桶排序由构造方式天然保证。
    const buckets: ClassPlanCandidate[][] = [[], [], [], []];
    profile.classPlans.forEach((plan: ClassPlan, key: string) => {
      if (!ClassPlanResolver.matchesGroup(profile, plan, date)) {
        return;
      }
      const candidate: ClassPlanCandidate = new ClassPlanCandidate();
      candidate.plan = plan;
      candidate.guid = Guid.fromCanonical(key);
      buckets[ClassPlanResolver.groupPriority(profile, plan)].push(candidate);
    });
    const hit: ResolvedHit = new ResolvedHit();
    for (let priority: number = 3; priority >= 0; priority--) {
      for (const candidate of buckets[priority]) {
        if (ClassPlanResolver.checkPlan(candidate.plan, date, profile, settings)) {
          hit.plan = candidate.plan;
          hit.guid = candidate.guid;
          return hit;
        }
      }
    }
    return hit;
  }

  /**
   * 课表所属群是否在「今天应参与选课」的群集合内。
   * 对应 GetClassPlanByDate 里那段 Where 的群匹配部分。
   */
  private static matchesGroup(profile: Profile, plan: ClassPlan, date: DateTimeValue): boolean {
    const group: Guid = plan.associatedGroup;
    const matchGlobal: boolean = group.equals(ClassPlanGroup.globalGroupGuid());
    const matchDefault: boolean = group.equals(profile.selectedClassPlanGroupId);
    // 临时群未启用、或已过期，则只认默认群与全局群。
    if (!ClassPlanResolver.tempGroupActive(profile, date)) {
      return matchDefault || matchGlobal;
    }
    const matchTemp: boolean = ClassPlanResolver.groupEqualsTemp(profile, group);
    if (profile.tempClassPlanGroupType === TempClassPlanGroupType.Inherit) {
      return matchDefault || matchTemp || matchGlobal;
    }
    if (profile.tempClassPlanGroupType === TempClassPlanGroupType.Override) {
      return matchTemp || matchGlobal;
    }
    return matchDefault || matchGlobal;
  }

  /**
   * 群优先级：临时群 3 > 所选群 2 > 全局群 1 > 其他 0。
   * 对应桌面版 OrderByDescending 的键。
   */
  private static groupPriority(profile: Profile, plan: ClassPlan): number {
    const group: Guid = plan.associatedGroup;
    if (ClassPlanResolver.groupEqualsTemp(profile, group)) {
      return 3;
    }
    if (group.equals(profile.selectedClassPlanGroupId)) {
      return 2;
    }
    if (group.equals(ClassPlanGroup.globalGroupGuid())) {
      return 1;
    }
    return 0;
  }

  private static groupEqualsTemp(profile: Profile, group: Guid): boolean {
    const tempGroupId: Guid | undefined = profile.tempClassPlanGroupId;
    return tempGroupId !== undefined && group.equals(tempGroupId);
  }

  /** 临时课表群是否生效：已启用、已设置 ID、且未过期。 */
  private static tempGroupActive(profile: Profile, date: DateTimeValue): boolean {
    return profile.isTempClassPlanGroupEnabled &&
      profile.tempClassPlanGroupId !== undefined &&
      !ClassPlanResolver.dateBefore(profile.tempClassPlanGroupExpireTime, date);
  }

  /** 两个时间按「日期部分」比较，左边是否早于右边。 */
  private static dateBefore(left: DateTimeValue, right: DateTimeValue): boolean {
    return left.dateOnly().epochDay() < right.dateOnly().epochDay();
  }

  /**
   * 课表是否在目标日期生效。对应 LessonsService.CheckClassPlan。
   */
  static checkPlan(plan: ClassPlan, date: DateTimeValue, profile: Profile,
    settings: EngineSettings): boolean {
    // 叠加课表不参与常规选课——它只能被 OrderedSchedules / TempClassPlanId 显式拉起。
    if (plan.isOverlay || !plan.isEnabled) {
      return false;
    }
    if (plan.timeRule.weekDay !== date.dayOfWeek()) {
      return false;
    }
    if (!plan.associatedGroup.equals(ClassPlanGroup.globalGroupGuid()) &&
      !plan.associatedGroup.equals(profile.selectedClassPlanGroupId) &&
      !ClassPlanResolver.groupEqualsTemp(profile, plan.associatedGroup)) {
      return false;
    }
    // 轮转周期比设置上限还长 -> 超出可表达范围，不参与匹配
    if (plan.timeRule.weekCountDivTotal > settings.multiWeekRotationMaxCycle) {
      return false;
    }
    if (plan.timeRule.weekCountDiv === 0) {
      return true;
    }
    return plan.timeRule.weekCountDiv ===
      WeekRotation.positionOf(date, settings, plan.timeRule.weekCountDivTotal);
  }

  /** 课表内第 index 节课对应的科目；越界或科目未定义时返回 undefined。 */
  static subjectAt(profile: Profile, plan: ClassPlan | undefined,
    index: number): Subject | undefined {
    if (plan === undefined) {
      return undefined;
    }
    if (index < 0 || index >= plan.classes.length) {
      return undefined;
    }
    return profile.tryGetSubject(plan.classes[index].subjectId);
  }
}

/** 内部辅助：常规选课命中结果。 */
class ResolvedHit {
  plan: ClassPlan | undefined = undefined;
  guid: Guid = Guid.empty();
}

/** 内部辅助：分桶时的候选项，携带课表及其档案键。 */
class ClassPlanCandidate {
  plan: ClassPlan = new ClassPlan();
  guid: Guid = Guid.empty();
}
