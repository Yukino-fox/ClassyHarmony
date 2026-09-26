/*
 * 课程状态机。对应 LessonsService.ProcessLessons
 *
 * 一次 compute() 走完这几步，产出不可变的 LessonsSnapshot：
 *  1. LoadCurrentClassPlan：清过期临时层 / 临时群，按当前时间选出生效课表
 *  2. 重置各时间表与课表的「已激活」标记，再把生效的那两张点亮
 *  3. 在「有效时间点」里找当前时间点 -> 推出 state / currentSubject
 *  4. 找下一节课、下一节课间 -> 推出倒计时
 *  5. 都没有则 state = AfterSchool
 *
 * 几个必须照搬的细节：
 *
 * - 区间比较两端都是闭区间（StartTime <= now <= EndTime），且取第一个命中。
 *   相邻时间点在边界秒会同时满足，靠 FirstOrDefault 的先后顺序定胜负。
 * - 上课中只算「距课间」，非上课中只算「距下一节课」。另一个恒为 0，
 *   不是负数——桌面版用 AtLeastZero 兜的底，负数会被夹成 0。
 * - 没有时间点跨越零点：StartTime > EndTime 的时间段永远匹配不上。
 *   桌面版同样如此（比较的是当天 TimeOfDay），照搬。
 * - TimeState.PrepareOnClass（上课准备中）在本计算中永远不会出现，
 *   它由 P6 的提醒链路按 ClassPrepareNotifySeconds 自行判断。
 */

import {
  ClassPlan,
  DateTimeValue,
  Guid,
  OrderedSchedule,
  Profile,
  Subject,
  TimeLayout,
  TimeLayoutItem,
  TimeSpanValue,
  TimeState
} from 'common_shared';
import { ClassPlanResolver, ResolvedClassPlan } from './ClassPlanResolver';
import { EngineSettings } from './EngineSettings';
import { LessonsSnapshot } from './LessonsSnapshot';
import { TempPlanManager } from './TempPlanManager';

/** 内部辅助：选课结果。 */
class LoadedClassPlan {
  plan: ClassPlan | undefined = undefined;
  guid: Guid = Guid.empty();
}

export class LessonsEngine {
  /**
   * 计算 now 时刻的课表状态。纯函数：只读档案（临时清理会写），不持有状态。
   *
   * previous 传入上一份快照用于判定状态迁移；首次计算传 undefined。
   */
  static compute(profile: Profile, settings: EngineSettings, now: DateTimeValue,
    previous?: LessonsSnapshot, isClassPlanEnabled: boolean = true): LessonsSnapshot {
    const snapshot: LessonsSnapshot = new LessonsSnapshot();
    snapshot.isClassPlanEnabled = isClassPlanEnabled;

    const loaded: LoadedClassPlan = LessonsEngine.loadCurrentClassPlan(profile, settings, now,
      isClassPlanEnabled);
    snapshot.currentClassPlan = loaded.plan;
    snapshot.currentClassPlanGuid = loaded.guid;
    if (loaded.plan === undefined) {
      // 桌面版在此处 goto final：课表都没加载出来，所有派生量保持初始值。
      LessonsEngine.fillTransition(snapshot, previous);
      return snapshot;
    }
    const plan: ClassPlan = loaded.plan;

    LessonsEngine.activate(profile, plan);
    snapshot.isClassPlanLoaded = true;

    const layout: TimeLayout | undefined = plan.resolveTimeLayout();
    if (layout === undefined) {
      LessonsEngine.fillTransition(snapshot, previous);
      return snapshot;
    }

    const nowSeconds: number = now.timeOfDaySeconds();
    const validItems: TimeLayoutItem[] = plan.validTimeLayoutItems();

    // 当前时间点：上课或课间，且 StartTime <= now <= EndTime（两端闭）
    const currentItem: TimeLayoutItem | undefined = LessonsEngine.findContaining(validItems, nowSeconds);
    if (currentItem !== undefined) {
      snapshot.currentTimeLayoutItem = currentItem;
      snapshot.selectedIndex = layout.layouts.indexOf(currentItem);
      if (currentItem.isClass()) {
        snapshot.state = TimeState.OnClass;
        const subject: Subject | undefined = ClassPlanResolver.subjectAt(
          profile, plan, plan.getClassIndex(snapshot.selectedIndex));
        if (subject !== undefined) {
          snapshot.currentSubject = subject;
        }
      } else if (currentItem.isBreak()) {
        snapshot.state = TimeState.Breaking;
        snapshot.currentSubject = Subject.breaking(currentItem.breakNameText());
      }
      snapshot.isLessonConfirmed = true;
    }

    // 下一节课：第一个 TimeType==0 且 EndTime >= now
    const nextClass: TimeLayoutItem | undefined = LessonsEngine.findFirst(validItems, nowSeconds, true);
    if (nextClass !== undefined) {
      snapshot.nextClassTimeLayoutItem = nextClass;
      const subject: Subject | undefined = ClassPlanResolver.subjectAt(
        profile, plan, plan.getClassIndex(layout.layouts.indexOf(nextClass)));
      if (subject !== undefined) {
        snapshot.nextClassSubject = subject;
      }
    }

    // 下一节课间：第一个 TimeType==1 且 EndTime >= now
    const nextBreak: TimeLayoutItem | undefined =
      LessonsEngine.findFirst(validItems, nowSeconds, false);
    if (nextBreak !== undefined) {
      snapshot.nextBreakingTimeLayoutItem = nextBreak;
    }

    // 倒计时：上课中看课间，否则看下节课
    if (snapshot.state === TimeState.OnClass) {
      if (nextBreak !== undefined) {
        snapshot.onBreakingTimeLeftTime = atLeastZero(
          nextBreak.startTime.toSeconds() - nowSeconds);
      }
    } else if (nextClass !== undefined) {
      snapshot.onClassLeftTime = atLeastZero(nextClass.startTime.toSeconds() - nowSeconds);
    }

    // 上课与课间都没有 -> 已放学
    if (nextClass === undefined && nextBreak === undefined) {
      snapshot.state = TimeState.AfterSchool;
    }

    LessonsEngine.fillTransition(snapshot, previous);
    return snapshot;
  }

  /**
   * 选课 + 过期清理。对应 LessonsService.LoadCurrentClassPlan。
   *
   * 前半段的清理会改写档案（解绑过期临时课表 / 群），因此 compute 并非
   * 严格只读——但它不持有任何状态，重复调用幂等。
   */
  private static loadCurrentClassPlan(profile: Profile, settings: EngineSettings,
    now: DateTimeValue, isClassPlanEnabled: boolean): LoadedClassPlan {
    // 桌面版每帧都调 RefreshTimeLayouts()，靠它维持 Classes 与课程时段数对齐。
    profile.refreshDerivedState();
    TempPlanManager.clearExpiredTempClassPlan(profile, now);
    TempPlanManager.cleanExpired(profile, now);
    TempPlanManager.clearExpiredTempGroup(profile, now);

    const out: LoadedClassPlan = new LoadedClassPlan();
    if (!isClassPlanEnabled) {
      return out;
    }
    const resolved: ResolvedClassPlan = ClassPlanResolver.resolve(profile, now, settings);
    out.plan = resolved.plan;
    out.guid = resolved.guid;

    // 同步 OverlayClassPlanId：当天的预定指向叠加课表时把它记在档案上，
    // 供「是否处于叠加班表模式」判断使用。桌面版在 LoadCurrentClassPlan 末尾做。
    profile.overlayClassPlanId = LessonsEngine.currentOverlayId(profile, now);
    return out;
  }

  /**
   * 当天预定指向的是叠加课表则记下其 ID，否则清空。
   * 对应 LoadCurrentClassPlan 末尾那个 if/else。
   */
  private static currentOverlayId(profile: Profile, now: DateTimeValue): Guid | undefined {
    const schedule: OrderedSchedule | undefined = profile.orderedScheduleFor(now);
    if (schedule === undefined) {
      return undefined;
    }
    const plan: ClassPlan | undefined = profile.tryGetClassPlan(schedule.classPlanId);
    if (plan === undefined || !plan.isOverlay) {
      return undefined;
    }
    return schedule.classPlanId;
  }

  /**
   * 点亮生效课表与其时间表，其余全部熄灭。
   * 对应 ProcessLessons 开头的 Deactivate 段与随后的 Activate 段。
   *
   * isActivatedManually 为真的时间表不参与熄灭——那是用户在编辑器里
   * 手动点亮的时间表，与运行期选课无关。
   */
  private static activate(profile: Profile, plan: ClassPlan): void {
    profile.timeLayouts.forEach((layout: TimeLayout) => {
      if (!layout.isActivatedManually) {
        layout.isActivated = false;
      }
    });
    profile.classPlans.forEach((each: ClassPlan) => {
      each.isActivated = false;
    });
    plan.isActivated = true;
    const layout: TimeLayout | undefined = plan.resolveTimeLayout();
    if (layout !== undefined) {
      layout.isActivated = true;
    }
    plan.refreshIsChangedClass(plan.overlaySourceId === undefined
      ? undefined
      : profile.tryGetClassPlan(plan.overlaySourceId));
  }

  /** 第一个 TimeType==0|1 且 StartTime <= now <= EndTime 的时间点。 */
  private static findContaining(items: TimeLayoutItem[], nowSeconds: number): TimeLayoutItem | undefined {
    for (const item of items) {
      if (!item.isClass() && !item.isBreak()) {
        continue;
      }
      if (item.startTime.toSeconds() <= nowSeconds && nowSeconds <= item.endTime.toSeconds()) {
        return item;
      }
    }
    return undefined;
  }

  /**
   * 第一个上课 / 课间时间点，且 EndTime >= now。
   * 对应 `validTimeLayoutItems.FirstOrDefault(i => i.TimeType == 0 && i.EndTime >= now)`。
   */
  private static findFirst(items: TimeLayoutItem[], nowSeconds: number,
    wantClass: boolean): TimeLayoutItem | undefined {
    for (const item of items) {
      const matched: boolean = wantClass ? item.isClass() : item.isBreak();
      if (matched && item.endTime.toSeconds() >= nowSeconds) {
        return item;
      }
    }
    return undefined;
  }

  /**
   * 填状态迁移字段。对应桌面版的
   * `if (CurrentState != CurrentOverlayEventStatus) { ...; CurrentOverlayEventStatus = CurrentState; }`
   *
   * 只在 state 变化时给出 transitionTo；首次计算（previous 为 undefined）不算变化。
   */
  private static fillTransition(snapshot: LessonsSnapshot, previous: LessonsSnapshot | undefined): void {
    if (previous === undefined) {
      snapshot.transitionTo = undefined;
      return;
    }
    snapshot.transitionTo = previous.state === snapshot.state ? undefined : snapshot.state;
  }
}

/** 负值夹到 0。对应 LessonsService.AtLeastZero。 */
function atLeastZero(seconds: number): TimeSpanValue {
  return TimeSpanValue.fromSeconds(seconds < 0 ? 0 : seconds);
}
