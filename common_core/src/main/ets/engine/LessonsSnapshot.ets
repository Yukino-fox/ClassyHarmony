/*
 * 一次课表计算的结果快照。对应 LessonsService 那一堆 PropertyChanged 属性。
 *
 * 刻意做成不可变的值对象而非「服务上的可变属性」：
 * 桌面版每个属性各自 setProperty，靠 PropertyChanged 事件通知 UI；
 * 这里一次算完整份快照，由调用方比对前后两份得出差异。
 * 好处是 50ms 轮询里不会出现「界面读到一半新一半旧」的中间态，
 * 小组件 Extension 也能一次性算完直接取用。
 */

import { ClassPlan, Guid, Subject, TimeLayoutItem, TimeSpanValue, TimeState } from 'common_shared';

export class LessonsSnapshot {
  /** 时刻状态。 */
  state: TimeState = TimeState.None;

  /** 生效课表；未命中任何课表时为 undefined。 */
  currentClassPlan: ClassPlan | undefined = undefined;

  /** 生效课表 ID；未命中时为 Guid.Empty。 */
  currentClassPlanGuid: Guid = Guid.empty();

  /**
   * 当前时间点在时间表 layouts 全列表中的下标，无则 -1。
   * 注意不是「第几节课」——要换算成课程序号需再过一次 getClassIndex。
   */
  selectedIndex: number = -1;

  /** 当前时间点；无则 TimeLayoutItem.empty()。 */
  currentTimeLayoutItem: TimeLayoutItem = TimeLayoutItem.empty();

  /** 当前科目；无课或课间时为 Subject.fallback() / Subject.breaking()。 */
  currentSubject: Subject = Subject.fallback();

  /** 下一节课的科目；无则 Subject.fallback()。 */
  nextClassSubject: Subject = Subject.fallback();

  /**
   * 上一节课的科目；无则 Subject.fallback()。
   *
   * 桌面版没有这个属性：PreviousSubjectHandler 每次被问起就现查一遍
   * `layout.Layouts.Reverse().FirstOrDefault(i => i.TimeType == 0 && i.EndTime < now)`。
   * 这里提前算好，是因为规则求值每帧都可能问，而反向扫描是 O(n)；
   * 顺带也让小组件与面板不必各自再写一遍。
   *
   * 口径与桌面版的处理器一致：取**最后一个** EndTime < now 的上课时间点
   * （严格小于，不含边界 —— 正在上的那节不算「上一节」）。
   */
  previousSubject: Subject = Subject.fallback();

  /** 下一个上课时间点；无则 TimeLayoutItem.empty()。 */
  nextClassTimeLayoutItem: TimeLayoutItem = TimeLayoutItem.empty();

  /** 下一个课间时间点；无则 TimeLayoutItem.empty()。 */
  nextBreakingTimeLayoutItem: TimeLayoutItem = TimeLayoutItem.empty();

  /**
   * 距下一节课开始还有多久。
   * 只有 state == OnClass 时有意义，其余情况恒为 0（不是负数）。
   */
  onClassLeftTime: TimeSpanValue = TimeSpanValue.zero();

  /**
   * 距下一节课间开始还有多久。
   * 只有 state != OnClass 时有意义，其余情况恒为 0。
   */
  onBreakingTimeLeftTime: TimeSpanValue = TimeSpanValue.zero();

  /** 是否已定位到当前时间点（进入上课或课间）。 */
  isLessonConfirmed: boolean = false;

  /** 是否已加载到课表。为 false 时其余字段均处于初始值。 */
  isClassPlanLoaded: boolean = false;

  /** 是否已确认课表加载开关打开。调用方可据此决定要不要展示课表。 */
  isClassPlanEnabled: boolean = true;

  /**
   * 本次计算相对上一份快照发生的状态迁移，无变化则为 undefined。
   * 对应桌面版 CurrentOverlayEventStatus 那一段的去抖逻辑。
   */
  transitionTo: TimeState | undefined = undefined;

  /** 本次计算是否被判定为「课表内容/时间已经变化到需要刷新」。 */
  isSameClassPlanAs(previous: LessonsSnapshot): boolean {
    return this.currentClassPlanGuid.toString() === previous.currentClassPlanGuid.toString() &&
      this.state === previous.state &&
      this.selectedIndex === previous.selectedIndex;
  }
}

/** 状态迁移的语义标签。用于日志与测试断言，不参与计算。 */
export class StateEvent {
  static readonly None: string = 'None';
  static readonly OnClass: string = 'OnClass';
  static readonly Breaking: string = 'Breaking';
  static readonly AfterSchool: string = 'AfterSchool';
}
