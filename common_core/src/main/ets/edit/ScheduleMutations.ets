/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 档案改动：全部是「传入档案、就地改、不返回自己」的纯函数。
 *
 * 为什么不写在 entry 里
 * --------------------
 * 改档案要维护一批彼此相关的不变量（课程列表长度对齐时间表、引用重绑、
 * 下标回填、调课标记），是最容易出静默数据错误的地方。这类逻辑放进
 * 依赖 @kit.CoreFileKit 的 UI 层就永远只能靠手点验证。放到 core 后
 * 没有任何平台依赖，Node 测试台可以穷举各种改动的组合。
 *
 * 每组改动都以 settle() 收尾
 * ------------------------
 * 桌面版靠 PropertyChanged 事件链维持这些不变量，ArkTS 侧改成显式推导：
 * 漏调一次是静默错，订阅漏一个会崩，显式推导更容易发现。之所以不把这些
 * 收进模型方法，是因为「什么时候该重算」取决于这次改了什么，模型自己
 * 不知道 —— 统一在改动层末尾调一次，规则就只有一条。
 */

import {
  ClassInfo,
  ClassPlan,
  ClassPlanGroup,
  DateTimeValue,
  Guid,
  OrderedSchedule,
  Profile,
  Subject,
  TempClassPlanGroupType,
  TIME_TYPE_BREAK,
  TIME_TYPE_CLASS,
  TimeLayout,
  TimeLayoutItem,
  TimeSpanValue
} from 'common_shared';

export class ScheduleMutations {
  // ------------------------------------------------------------ 派生量

  /**
   * 收尾：重绑引用、对齐课程列表、重算调课标记。
   *
   * 调课标记只对叠加课表有意义 —— 没有 overlaySourceId 的课表全部置 false，
   * 与桌面版 RefreshIsChangedClass 的分支一致。桌面版另外还有「课表成为当前
   * 时重算」这一条，那是 LessonsService 的事，不属于档案改动。
   */
  static settle(profile: Profile): void {
    profile.refreshDerivedState();
    profile.classPlans.forEach((plan: ClassPlan) => {
      plan.refreshIsChangedClass(ScheduleMutations.overlaySourceOf(profile, plan));
    });
  }

  /** 叠加课表的来源课表；非叠加课表返回 undefined。 */
  static overlaySourceOf(profile: Profile, plan: ClassPlan): ClassPlan | undefined {
    const sourceId: Guid | undefined = plan.overlaySourceId;
    if (sourceId === undefined) {
      return undefined;
    }
    return profile.tryGetClassPlan(sourceId);
  }

  // ---------------------------------------------------------------- 科目

  /**
   * 新增科目，返回它的档案键。
   *
   * 档案的三个字典都是「GUID -> 模型」的表，而模型对象里并不存自己的 GUID
   * （Subject.Name 是显示名不是键），所以键只能在这里生成并返回。调用方要拿
   * 它做后续修改。
   */
  static addSubject(profile: Profile, name: string): Guid {
    const guid: Guid = Guid.newGuid();
    const subject: Subject = new Subject();
    subject.name = name;
    // IsActive 是「反序列化时判断要不要写回」的运行期标志，默认 false。
    // 桌面版新建对象时同样显式置上，留着 false 会让新科目在部分路径下
    // 被当成幽灵项跳过。
    subject.isActive = true;
    profile.subjects.set(guid.toString(), subject);
    return guid;
  }

  static removeSubject(profile: Profile, guid: Guid): boolean {
    if (!profile.subjects.delete(guid.toString())) {
      return false;
    }
    // 引用该科目的课表格清空。不能留一个指向已删科目的 Guid：渲染时
    // tryGetSubject 失败会显示成「（无）」，看着像没排课，实际是悬空引用。
    profile.classPlans.forEach((plan: ClassPlan) => {
      plan.classes.forEach((info: ClassInfo) => {
        if (info.subjectId.equals(guid)) {
          info.subjectId = Guid.empty();
        }
      });
    });
    return true;
  }

  static renameSubject(profile: Profile, guid: Guid, name: string): boolean {
    const subject: Subject | undefined = profile.tryGetSubject(guid);
    if (subject === undefined) {
      return false;
    }
    subject.name = name;
    return true;
  }

  static setSubjectTeacher(profile: Profile, guid: Guid, teacherName: string): boolean {
    const subject: Subject | undefined = profile.tryGetSubject(guid);
    if (subject === undefined) {
      return false;
    }
    subject.teacherName = teacherName;
    return true;
  }

  static setSubjectInitial(profile: Profile, guid: Guid, initial: string): boolean {
    const subject: Subject | undefined = profile.tryGetSubject(guid);
    if (subject === undefined) {
      return false;
    }
    subject.initial = initial;
    return true;
  }

  static setSubjectOutDoor(profile: Profile, guid: Guid, isOutDoor: boolean): boolean {
    const subject: Subject | undefined = profile.tryGetSubject(guid);
    if (subject === undefined) {
      return false;
    }
    subject.isOutDoor = isOutDoor;
    return true;
  }

  /**
   * 上下移动一个科目，返回是否真的移动了。
   *
   * KeyedMap 底层是插入序的 Map，set 已存在的键会保留原位，所以要换序只能
   * 整个重建字典。科目数量以十计，重建成本可以忽略。
   */
  static moveSubject(profile: Profile, guid: Guid, delta: number): boolean {
    const keys: string[] = profile.subjects.keys();
    const from: number = keys.indexOf(guid.toString());
    if (from < 0) {
      return false;
    }
    const to: number = from + delta;
    if (to < 0 || to >= keys.length) {
      return false;
    }
    // values() 返回的是新数组，可以就地重排。
    // 键序与值序必须施加同一个置换：只重排值的话，键仍按原序，字典重建后
    // 键与值的对应就整体错位了（表现是每个 guid 都指向别人的科目）。
    const values: Subject[] = profile.subjects.values();
    const reorderedKeys: string[] = keys.slice(0, from)
      .concat(keys.slice(from + 1));
    const reorderedValues: Subject[] = values.slice(0, from)
      .concat(values.slice(from + 1));
    reorderedKeys.splice(to, 0, keys[from]);
    reorderedValues.splice(to, 0, values[from]);
    profile.subjects.clear();
    for (let i: number = 0; i < keys.length; i++) {
      profile.subjects.set(reorderedKeys[i], reorderedValues[i]);
    }
    return true;
  }

  // -------------------------------------------------------------- 时间表

  /**
   * 新增时间表，返回档案键。
   *
   * 预置一个课程时间点：空的时间表在界面上无法编辑（没有行可点），
   * 桌面版新建时间表时同样会加默认时间点。
   */
  static addTimeLayout(profile: Profile, name: string): Guid {
    const guid: Guid = Guid.newGuid();
    const layout: TimeLayout = new TimeLayout();
    layout.name = name.length > 0 ? name : '新时间表';
    layout.isActive = true;
    layout.layouts.push(ScheduleMutations.newPoint(TIME_TYPE_CLASS, 0, 45));
    profile.timeLayouts.set(guid.toString(), layout);
    return guid;
  }

  /**
   * 删除时间表。绑定在它上面的课表会被解绑。
   *
   * 解绑后那些课表不再参与选课（resolveTimeLayout 拿不到时间表），
   * 与桌面版一致。指向该时间表的叠加源也一并清掉：留着会得到一个
   * overlaySourceId 指向不存在对象的课表。
   */
  static removeTimeLayout(profile: Profile, guid: Guid): boolean {
    if (!profile.timeLayouts.delete(guid.toString())) {
      return false;
    }
    profile.classPlans.forEach((plan: ClassPlan) => {
      if (plan.timeLayoutId.equals(guid)) {
        plan.timeLayoutId = Guid.empty();
        plan.classes = [];
      }
    });
    profile.classPlans.forEach((plan: ClassPlan) => {
      const sourceId: Guid | undefined = plan.overlaySourceId;
      if (sourceId !== undefined && sourceId.equals(guid)) {
        plan.overlaySourceId = undefined;
      }
    });
    return true;
  }

  static renameTimeLayout(profile: Profile, guid: Guid, name: string): boolean {
    const layout: TimeLayout | undefined = profile.tryGetTimeLayout(guid);
    if (layout === undefined) {
      return false;
    }
    layout.name = name;
    return true;
  }

  /**
   * 追加一个时间点。
   *
   * @param startSeconds 当天 0 点起的秒偏移
   * @param minutes 时长
   */
  static addTimePoint(profile: Profile, guid: Guid, timeType: number,
    startSeconds: number, minutes: number): boolean {
    const layout: TimeLayout | undefined = profile.tryGetTimeLayout(guid);
    if (layout === undefined) {
      return false;
    }
    layout.layouts.push(ScheduleMutations.newPoint(timeType, startSeconds, minutes));
    return true;
  }

  /**
   * 删掉某个时间点。
   *
   * 参数是时间表内的行下标，不是课次下标：课间与分割线占位但不占课次，
   * 用户在界面上看到的「一行一格」正好对应行下标。
   *
   * 删课程时段时，绑定这张时间表的课表里对应那节课也会被删掉，而不是让
   * settle 去截断尾部。桌面版的 RefreshClassesList 只会在末尾截断
   * （Remove 分支与调用点都被注释掉了），从中间删一节课会静默丢掉最后一节
   * 的排课。这里有意不跟：从中间删掉第 2 节课，丢的应该是第 2 节课的内容，
   * 而用户在界面上删的也正是第 2 节课。落盘格式与桌面版一致，只是这个操作
   * 的结果不同。
   */
  static removeTimePoint(profile: Profile, guid: Guid, rowIndex: number): boolean {
    const layout: TimeLayout | undefined = profile.tryGetTimeLayout(guid);
    if (layout === undefined || rowIndex < 0 || rowIndex >= layout.layouts.length) {
      return false;
    }
    const slot: number = layout.classIndexOf(rowIndex);
    layout.layouts.splice(rowIndex, 1);
    if (slot >= 0) {
      ScheduleMutations.forEachPlanOnLayout(profile, guid, (plan: ClassPlan) => {
        if (slot < plan.classes.length) {
          plan.classes.splice(slot, 1);
        }
      });
    }
    return true;
  }

  /**
   * 上下移动一个时间点。
   *
   * 换完之后**不排序**。行序是用户自己排的，不是派生量：桌面版的
   * UpdateTimeLayout（升序重排）只挂在「按时段重排」按钮上，平时不动数组
   * 顺序，网格也按数组顺序渲染行。这里若顺手排一下序，用户刚拖上去的一行
   * 会被重排弹回原处，界面上看着就是「拖了没反应」。
   *
   * 课程时段跟着它的时间点走：把第 3 节课移到第 1 节课上面，第 3 节课排的
   * 科目就变成第 1 节，而不是留在原地变成第 2 节。
   */
  static moveTimePoint(profile: Profile, guid: Guid, rowIndex: number, delta: number): boolean {
    const layout: TimeLayout | undefined = profile.tryGetTimeLayout(guid);
    if (layout === undefined || rowIndex < 0 || rowIndex >= layout.layouts.length) {
      return false;
    }
    const to: number = rowIndex + delta;
    if (to < 0 || to >= layout.layouts.length) {
      return false;
    }
    const slot: number = layout.classIndexOf(rowIndex);
    const moved: TimeLayoutItem = layout.layouts[rowIndex];
    layout.layouts.splice(rowIndex, 1);
    layout.layouts.splice(to, 0, moved);
    if (slot < 0) {
      return true;
    }
    // 移到第几个课次上，课表里那节课也要挪到同一个位置
    const newSlot: number = layout.classIndexOf(to);
    ScheduleMutations.forEachPlanOnLayout(profile, guid, (plan: ClassPlan) => {
      if (slot < plan.classes.length && newSlot < plan.classes.length) {
        const carried: ClassInfo = plan.classes[slot];
        plan.classes[slot] = plan.classes[newSlot];
        plan.classes[newSlot] = carried;
      }
    });
    return true;
  }

  /**
   * 按开始时刻重排时间点。
   *
   * 对应桌面版的「按时段重排」按钮（ProfileSettingsWindow.UpdateTimeLayout：
   * 降序 CompareTo 排完再 Reverse，净效果是升序）。因为降序比较器容易被
   * 读反，这里直接按升序写，测试里断言具体行序。
   *
   * 重排会改变课程时段的下标，所以必须连带把课表里的课跟着挪。
   */
  static sortTimeLayout(profile: Profile, guid: Guid): boolean {
    const layout: TimeLayout | undefined = profile.tryGetTimeLayout(guid);
    if (layout === undefined) {
      return false;
    }
    // 记住每个时间点原本是第几个课次
    const before: number[] = layout.classSlotIndexes();
    const beforeSlot: Map<TimeLayoutItem, number> = new Map<TimeLayoutItem, number>();
    for (let i: number = 0; i < layout.layouts.length; i++) {
      if (before[i] >= 0) {
        beforeSlot.set(layout.layouts[i], before[i]);
      }
    }
    layout.layouts.sort((a: TimeLayoutItem, b: TimeLayoutItem) => {
      const byStart: number = a.startTime.toSeconds() - b.startTime.toSeconds();
      return byStart !== 0 ? byStart : a.endTime.toSeconds() - b.endTime.toSeconds();
    });
    // 算出「原课次 -> 新课次」的映射
    const after: number[] = layout.classSlotIndexes();
    const newSlotOfOld: number[] = new Array<number>(before.length).fill(-1);
    for (let i: number = 0; i < layout.layouts.length; i++) {
      const old: number | undefined = beforeSlot.get(layout.layouts[i]);
      if (old !== undefined) {
        newSlotOfOld[old] = after[i];
      }
    }
    ScheduleMutations.forEachPlanOnLayout(profile, guid, (plan: ClassPlan) => {
      // 一次搬完，不能逐对换：置换是环（0->2, 1->0, 2->1）时，
      // 连续 swap 会被后面的那一次撤销掉前面那一次
      const snapshot: ClassInfo[] = plan.classes.slice(0);
      for (let slot: number = 0; slot < snapshot.length; slot++) {
        const target: number = newSlotOfOld[slot];
        if (target >= 0 && target < snapshot.length) {
          plan.classes[target] = snapshot[slot];
        }
      }
    });
    return true;
  }

  /**
   * 改一个时间点。传 undefined 的项保持原值。
   *
   * 改成课程类型时清掉课间名：课间名只对非课程点有意义，留着会让用户
   * 在「课间」和「课程」之间来回切时看到上一个课间的名字挂在课程上。
   */
  static updateTimePoint(profile: Profile, guid: Guid, rowIndex: number,
    timeType: number | undefined, startSeconds: number | undefined,
    durationMinutes: number | undefined, breakName: string | undefined): boolean {
    const layout: TimeLayout | undefined = profile.tryGetTimeLayout(guid);
    if (layout === undefined || rowIndex < 0 || rowIndex >= layout.layouts.length) {
      return false;
    }
    const point: TimeLayoutItem = layout.layouts[rowIndex];
    if (timeType !== undefined) {
      point.timeType = timeType;
      if (timeType === TIME_TYPE_CLASS) {
        point.breakName = '';
      }
    }
    if (startSeconds !== undefined) {
      point.startTime = TimeSpanValue.fromSeconds(startSeconds);
    }
    if (durationMinutes !== undefined && durationMinutes > 0) {
      point.endTime = TimeSpanValue.fromSeconds(point.startTime.toSeconds() + durationMinutes * 60);
    }
    if (breakName !== undefined) {
      point.breakName = breakName;
    }
    return true;
  }

  /**
   * 设置某时间点的预置科目，并刷到所有绑定这张时间表的课表上。
   *
   * 对应桌面版「IsHideDefault + DefaultClassId」：用户在时间表上设一次
   * 「这几节默认是语文」，所有用这张时间表的课表都跟着变。只改时间表
   * 而不刷课表，界面上会显示改了但课表里没变。
   */
  static setDefaultClass(profile: Profile, guid: Guid, rowIndex: number,
    subjectId: Guid, hideDefault: boolean): boolean {
    const layout: TimeLayout | undefined = profile.tryGetTimeLayout(guid);
    if (layout === undefined || rowIndex < 0 || rowIndex >= layout.layouts.length) {
      return false;
    }
    const point: TimeLayoutItem = layout.layouts[rowIndex];
    point.defaultClassId = subjectId;
    point.isHideDefault = hideDefault;
    profile.overwriteAllClassPlanSubject(guid, point, subjectId);
    return true;
  }

  // ------------------------------------------------------------ 课表（排课）

  /**
   * 新增一张课表，返回档案键。
   *
   * 绑一张课表必须有 weekday 与单双周规则才有意义，所以新表直接分到「未排课」
   * 状态（weekCountDiv=0 表示每周都匹配，见 TimeRule.matches）。默认绑
   * defaultGroupGuid，与桌面版 ClassPlan 的默认值一致。
   *
   * 返回前就重算一次派生量，让这张表立刻能排课。不这么做的话 classes 还是
   * 空数组，接下来的 setClassSubject 会因下标越界静默失败 —— 用户新建一张
   * 课表，什么都排不进去，且没有任何报错。
   */
  static addClassPlan(profile: Profile, timeLayoutId: Guid, name: string): Guid {
    const guid: Guid = Guid.newGuid();
    const plan: ClassPlan = new ClassPlan();
    plan.name = name.length > 0 ? name : '新课表';
    plan.timeLayoutId = timeLayoutId;
    plan.isActive = true;
    profile.classPlans.set(guid.toString(), plan);
    profile.refreshDerivedState();
    return guid;
  }

  /**
   * 删除课表，并把指向它的临时引用清干净。
   *
   * tempClassPlanId / overlayClassPlanId / orderedSchedules 三处都可能还指着它。
   * 留着不会崩（resolve 时 tryGet 拿不到就往下走），但界面上会出现
   * 「临时课表已启用」而课表列表里找不到它，点进去是空的。
   */
  static removeClassPlan(profile: Profile, guid: Guid): boolean {
    if (!profile.classPlans.delete(guid.toString())) {
      return false;
    }
    if (profile.tempClassPlanId !== undefined && profile.tempClassPlanId.equals(guid)) {
      profile.tempClassPlanId = undefined;
    }
    if (profile.overlayClassPlanId !== undefined && profile.overlayClassPlanId.equals(guid)) {
      profile.overlayClassPlanId = undefined;
    }
    const stale: string[] = [];
    profile.orderedSchedules.forEach((item: OrderedSchedule, key: string) => {
      if (item.classPlanId.equals(guid)) {
        stale.push(key);
      }
    });
    for (const key of stale) {
      profile.orderedSchedules.delete(key);
    }
    profile.classPlans.forEach((plan: ClassPlan) => {
      const sourceId: Guid | undefined = plan.overlaySourceId;
      if (sourceId !== undefined && sourceId.equals(guid)) {
        plan.overlaySourceId = undefined;
      }
    });
    return true;
  }

  static renameClassPlan(profile: Profile, guid: Guid, name: string): boolean {
    const plan: ClassPlan | undefined = profile.tryGetClassPlan(guid);
    if (plan === undefined) {
      return false;
    }
    plan.name = name;
    return true;
  }

  static setClassPlanEnabled(profile: Profile, guid: Guid, isEnabled: boolean): boolean {
    const plan: ClassPlan | undefined = profile.tryGetClassPlan(guid);
    if (plan === undefined) {
      return false;
    }
    plan.isEnabled = isEnabled;
    return true;
  }

  static setClassPlanTimeLayout(profile: Profile, guid: Guid, timeLayoutId: Guid): boolean {
    const plan: ClassPlan | undefined = profile.tryGetClassPlan(guid);
    if (plan === undefined) {
      return false;
    }
    plan.timeLayoutId = timeLayoutId;
    // 换时间表意味着换了课程数与行数。classes 先清空，让 refreshDerivedState
    // 按新时间表重建：沿用旧课表内容只会在课次数不同的两张表之间错位。
    plan.classes = [];
    profile.refreshDerivedState();
    return true;
  }

  static setClassPlanGroup(profile: Profile, guid: Guid, groupId: Guid): boolean {
    const plan: ClassPlan | undefined = profile.tryGetClassPlan(guid);
    if (plan === undefined) {
      return false;
    }
    plan.associatedGroup = groupId;
    return true;
  }

  /**
   * 设课表规则。
   *
   * @param weekDay 0=周日 .. 6=周六（.NET 口径，不要用 ArkUI 的 1=周一）
   * @param weekCountDiv 0=每周都匹配；否则是单双周位置，取值 1..weekCountDivTotal
   */
  static setClassPlanRule(profile: Profile, guid: Guid, weekDay: number,
    weekCountDiv: number, weekCountDivTotal: number): boolean {
    const plan: ClassPlan | undefined = profile.tryGetClassPlan(guid);
    if (plan === undefined) {
      return false;
    }
    plan.timeRule.weekDay = weekDay;
    // 越界的轮转位置会让规则永远不匹配，界面上却看不出哪里不对，
    // 表现成「这张课表永远不生效」。夹到合法区间。
    if (weekCountDivTotal < 1) {
      plan.timeRule.weekCountDivTotal = 1;
    } else {
      plan.timeRule.weekCountDivTotal = weekCountDivTotal;
    }
    if (weekCountDiv <= 0) {
      plan.timeRule.weekCountDiv = 0;
    } else {
      plan.timeRule.weekCountDiv = Math.min(weekCountDiv, plan.timeRule.weekCountDivTotal);
    }
    return true;
  }

  /** 给某节课排科目。slotIndex 是课次下标（不含课间与分割线）。 */
  static setClassSubject(profile: Profile, guid: Guid, slotIndex: number, subjectId: Guid): boolean {
    const plan: ClassPlan | undefined = profile.tryGetClassPlan(guid);
    if (plan === undefined || slotIndex < 0 || slotIndex >= plan.classes.length) {
      return false;
    }
    plan.classes[slotIndex].subjectId = subjectId;
    return true;
  }

  /** 停用 / 启用某节课（停用的课在网格里删除线显示，且不参与选课）。 */
  static setClassEnabled(profile: Profile, guid: Guid, slotIndex: number, isEnabled: boolean): boolean {
    const plan: ClassPlan | undefined = profile.tryGetClassPlan(guid);
    if (plan === undefined || slotIndex < 0 || slotIndex >= plan.classes.length) {
      return false;
    }
    plan.classes[slotIndex].isEnabled = isEnabled;
    return true;
  }

  /** 手动标记 / 取消「调课」。叠加课表的标记由 settle 自动算。 */
  static setClassChanged(profile: Profile, guid: Guid, slotIndex: number, isChanged: boolean): boolean {
    const plan: ClassPlan | undefined = profile.tryGetClassPlan(guid);
    if (plan === undefined || slotIndex < 0 || slotIndex >= plan.classes.length) {
      return false;
    }
    plan.classes[slotIndex].isChangedClass = isChanged;
    return true;
  }

  // -------------------------------------------------------------- 叠加课表

  /**
   * 把一张课表复制成叠加课表。
   *
   * 深拷贝走 JSON 往返而不是逐字段复制：ClassPlan 的字段有十几项且以后还会加，
   * 手写拷贝迟早漏字段，而漏掉的字段不会报错，只会让叠加课表少一个设置。
   */
  static createOverlayClassPlan(profile: Profile, sourceGuid: Guid, name: string): Guid | undefined {
    const source: ClassPlan | undefined = profile.tryGetClassPlan(sourceGuid);
    if (source === undefined) {
      return undefined;
    }
    const guid: Guid = Guid.newGuid();
    const copy: ClassPlan = ClassPlan.fromJson(source.toJson());
    copy.name = name.length > 0 ? name : `${source.name} 副本`;
    copy.isOverlay = true;
    copy.overlaySourceId = sourceGuid;
    copy.overlaySetupTime = DateTimeValue.now();
    copy.isActive = true;
    // 复制过来的 classes 是「相对源课表的改动」，标记应当清空重新算，
    // 否则源课表改一次，叠加课表上会留着一批已经不成立的调课标记。
    for (const info of copy.classes) {
      info.isChangedClass = false;
    }
    profile.classPlans.set(guid.toString(), copy);
    return guid;
  }

  static setClassPlanOverlayEnabled(profile: Profile, isEnabled: boolean): boolean {
    profile.isOverlayClassPlanEnabled = isEnabled;
    return true;
  }

  // -------------------------------------------------------------- 课表群

  static addClassPlanGroup(profile: Profile, name: string): Guid {
    const guid: Guid = Guid.newGuid();
    const group: ClassPlanGroup = new ClassPlanGroup();
    group.name = name.length > 0 ? name : '新课表群';
    group.isActive = true;
    profile.classPlanGroups.set(guid.toString(), group);
    return guid;
  }

  /** 解散课表群：群还在，群里没搬走的课表移到默认群。 */
  static disbandClassPlanGroup(profile: Profile, guid: Guid): boolean {
    return profile.disbandClassPlanGroup(guid);
  }

  /** 删除课表群：群内课表一并删除。 */
  static deleteClassPlanGroup(profile: Profile, guid: Guid): boolean {
    const tempGroupId: Guid | undefined = profile.tempClassPlanGroupId;
    if (tempGroupId !== undefined && tempGroupId.equals(guid)) {
      profile.tempClassPlanGroupId = undefined;
    }
    return profile.deleteClassPlanGroup(guid);
  }

  static renameClassPlanGroup(profile: Profile, guid: Guid, name: string): boolean {
    const group: ClassPlanGroup | undefined = profile.classPlanGroups.tryGet(guid.toString());
    if (group === undefined) {
      return false;
    }
    group.name = name;
    return true;
  }

  static selectClassPlanGroup(profile: Profile, guid: Guid): boolean {
    profile.selectedClassPlanGroupId = guid;
    return true;
  }

  // ------------------------------------------------- 临时课表 / 临时课表群

  /**
   * 启用临时课表。
   *
   * @param expireDate 临时课表失效日（含当天）。桌面版用 SetupTime.Date >= date
   *        判有效，所以这里存「建立时间」而不是「过期时间」，两者等价。
   */
  static applyTempClassPlan(profile: Profile, planId: Guid, from: DateTimeValue): boolean {
    if (profile.tryGetClassPlan(planId) === undefined) {
      return false;
    }
    profile.tempClassPlanId = planId;
    profile.tempClassPlanSetupTime = from;
    profile.overlayClassPlanId = planId;
    return true;
  }

  static cancelTempClassPlan(profile: Profile): void {
    const planId: Guid | undefined = profile.tempClassPlanId;
    profile.tempClassPlanId = undefined;
    // OverlayClassPlanId 是「当前叠加生效的是哪张表」的旁路记录。它与临时
    // 课表指向同一张时一并清掉；指向别处（用户单独设过）就别动。
    const overlayId: Guid | undefined = profile.overlayClassPlanId;
    if (planId !== undefined && overlayId !== undefined && overlayId.equals(planId)) {
      profile.overlayClassPlanId = undefined;
    }
  }

  static applyTempClassPlanGroup(profile: Profile, groupId: Guid, expire: DateTimeValue,
    type: TempClassPlanGroupType): boolean {
    if (groupId.equals(ClassPlanGroup.globalGroupGuid()) ||
      groupId.equals(ClassPlanGroup.defaultGroupGuid())) {
      return false;
    }
    if (profile.classPlanGroups.tryGet(groupId.toString()) === undefined) {
      return false;
    }
    profile.tempClassPlanGroupId = groupId;
    profile.tempClassPlanGroupExpireTime = expire;
    profile.tempClassPlanGroupType = type;
    profile.isTempClassPlanGroupEnabled = true;
    return true;
  }

  static cancelTempClassPlanGroup(profile: Profile): void {
    profile.isTempClassPlanGroupEnabled = false;
    profile.tempClassPlanGroupId = undefined;
  }

  // ------------------------------------------------------------ 预定课表

  /** 给某天指定课表。传 undefined 表示取消这天的预定。 */
  static setOrderedSchedule(profile: Profile, date: DateTimeValue,
    planId: Guid | undefined): boolean {
    const key: string = date.dateOnly().toString();
    if (planId === undefined) {
      profile.orderedSchedules.delete(key);
      return true;
    }
    if (profile.tryGetClassPlan(planId) === undefined) {
      return false;
    }
    const schedule: OrderedSchedule = new OrderedSchedule();
    schedule.classPlanId = planId;
    schedule.isActive = true;
    profile.orderedSchedules.set(key, schedule);
    return true;
  }

  // -------------------------------------------------------------- 档案级

  static renameProfile(profile: Profile, name: string): boolean {
    profile.name = name;
    return true;
  }

  // ------------------------------------------------------------ 工具函数

  static newPoint(timeType: number, startSeconds: number, minutes: number): TimeLayoutItem {
    const point: TimeLayoutItem = new TimeLayoutItem();
    point.timeType = timeType;
    point.startTime = TimeSpanValue.fromSeconds(startSeconds);
    point.endTime = TimeSpanValue.fromSeconds(startSeconds + minutes * 60);
    if (timeType === TIME_TYPE_BREAK) {
      point.breakName = '课间';
    }
    return point;
  }

  /** 对所有绑定指定时间表的课表做一次操作。 */
  private static forEachPlanOnLayout(profile: Profile, layoutId: Guid,
    action: (plan: ClassPlan) => void): void {
    const key: string = layoutId.toString();
    profile.classPlans.forEach((plan: ClassPlan) => {
      if (plan.timeLayoutId.toString() === key) {
        action(plan);
      }
    });
  }
}
