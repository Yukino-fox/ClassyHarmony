/*
 * 编辑页的视图数据。
 *
 * 放在 core 而不是 entry：这些行是「编辑界面该显示什么」的推导结果，
 * 和 P3 的课表网格同性质。放 core 才能在 Node 测试台里断言
 * 「新建一张课表后，编辑页列出的是几行几格」「删了科目后引用数归零」，
 * 而不必靠手点。
 *
 * 全部是标量字段，没有对象引用
 * --------------------------------
 * 组件入参传 @ObservedV2 对象时 V2 会保留引用，一个字段变了可能牵动整棵
 * 子树；传标量则只有用到该标量的格子会重绘。编辑页一次要渲染几十行，
 * 这个差别在低端机上是能感知的。
 *
 * 键从 KeyedMap 遍历时取，不问模型对象
 * ------------------------------------
 * 档案里三个字典的键都是 guid，模型对象自己并不存。Subject.name 是显示名，
 * 不是键。所以每一行的 guid 都来自遍历回调的 key 参数，不来自对象字段。
 */

import { t, tf } from '../i18n/I18n';
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
  TimeLayout,
  TimeLayoutItem
} from 'common_shared';
import { ClassPlanResolver, ResolvedClassPlan, ResolvedSource } from '../engine/ClassPlanResolver';
import { EngineSettings } from '../engine/EngineSettings';
import { EMPTY_SUBJECT_TEXT } from '../view/ScheduleGrid';
import {
  formatClock,
  formatDuration,
  timeTypeName,
  weekDayName,
  weekRotationText
} from '../view/TextFormat';

// ------------------------------------------------------------------ 科目

export class SubjectRow {
  guid: string = '';
  name: string = '';
  initial: string = '';
  teacherName: string = '';
  isOutDoor: boolean = false;
  /** 被几节课引用。删科目前要让用户看见这个数，否则是盲删。 */
  usedByClasses: number = 0;
  /** 总引用次数（含同一张表里多节课用同一科目）。 */
  usedByClassesTotal: number = 0;
  /** 被几张课表用到。 */
  usedByPlans: number = 0;
}

// -------------------------------------------------------------- 时间点

export class TimePointRow {
  /** 时间表内的行下标。传回改动层用。 */
  rowIndex: number = 0;
  timeType: number = 0;
  timeTypeText: string = '';
  startText: string = '';
  endText: string = '';
  durationMinutes: number = 0;
  durationText: string = '';
  breakName: string = '';
  isClass: boolean = false;
  /** 课次下标；非课程行是 -1。 */
  classSlot: number = -1;
  classSlotText: string = '';
  /** 预置科目。空串表示没设。 */
  defaultSubjectId: string = '';
  defaultSubjectName: string = '';
  isHideDefault: boolean = false;
  /** 这一格在已绑定课表里被实际排成该科目的次数。 */
  defaultAppliedCount: number = 0;
}

// -------------------------------------------------------------- 时间表

export class TimeLayoutRow {
  guid: string = '';
  name: string = '';
  rows: TimePointRow[] = [];
  classCount: number = 0;
  rowCount: number = 0;
  /** 摘要，取前几项；作息表可能有十几行，全列出来在列表页会挤成一片。 */
  summary: string = '';
  usedByPlans: number = 0;
  /** 绑在这张时间表上的课表名，顿号分隔。删之前要让用户看见会波及谁。 */
  boundPlanNames: string = '';
}

// ---------------------------------------------------------- 课表（排课）

export class ClassSlotRow {
  /** 课次下标。传回改动层用。 */
  slot: number = 0;
  slotText: string = '';
  subjectId: string = '';
  subjectName: string = '';
  initial: string = '';
  teacherName: string = '';
  isEmpty: boolean = true;
  isEnabled: boolean = true;
  isChangedClass: boolean = false;
  /** 该课次对应时间点上的预置科目，用于界面上提示「可用默认」。 */
  defaultSubjectId: string = '';
  defaultSubjectName: string = '';
  hasDefault: boolean = false;
}

/**
 * 排课页的一行。
 *
 * 刻意不用「行标签数组 + 课次数组」两条平行数据：界面上要把这两者按下标配对
 * （取 slots[classSlot] 排课、同时显示那一行的时段），平行数组只要有一个
 * 多了一项或少了一项，配对就从这里整体错位，而且不报任何错。合成一行之后
 * 配对关系是数据结构自带的。
 */
export class PlanEditRow {
  /** 时间表内的行下标。传回改动层用。 */
  rowIndex: number = 0;
  /** 「第 1 节」或课间名 / 分割线名。 */
  label: string = '';
  timeRange: string = '';
  isClass: boolean = false;
  /** 是 ClassSlotRow 在 slots 里的下标；非课程行是 -1。 */
  classSlot: number = -1;
  /** 这一行是分隔线，不占课次也不显示时段。 */
  isSeparator: boolean = false;
}

export class ClassPlanRow {
  guid: string = '';
  name: string = '';
  timeLayoutId: string = '';
  timeLayoutName: string = '';
  /** 时间表被删掉后这里是 false，界面据此提示「未绑定时间表」。 */
  hasTimeLayout: boolean = true;
  isEnabled: boolean = true;
  isOverlay: boolean = false;
  overlaySourceId: string = '';
  overlaySourceName: string = '';
  groupId: string = '';
  groupName: string = '';
  weekDay: number = 0;
  weekDayText: string = '';
  weekCountDiv: number = 0;
  weekCountDivTotal: number = 2;
  weekRotationText: string = '';
  slots: ClassSlotRow[] = [];
  /** 排课页要渲染的行：课程行与课间 / 分割线行都在。 */
  editRows: PlanEditRow[] = [];
  /** 「语文、数学、英语」，空课次不占位。 */
  filledText: string = '';
  filledCount: number = 0;
  classCount: number = 0;
  /** 基准日（通常今天）实际生效的是这张课表。判定由引擎给出。 */
  isActiveOnBaseDate: boolean = false;
}

// -------------------------------------------------------------- 课表群

export class ClassPlanGroupRow {
  guid: string = '';
  name: string = '';
  isGlobal: boolean = false;
  isSelected: boolean = false;
  isDefault: boolean = false;
  planCount: number = 0;
  /** 不可删除也不可解散（默认群、全局群）。界面据此隐藏按钮。 */
  canDisband: boolean = true;
  canDelete: boolean = true;
}

// ---------------------------------------------------------- 预定课表

export class OrderedScheduleRow {
  /**
   * 档案里的键，也就是日期本身（`2026-09-26T00:00:00`）。
   *
   * 界面拿它当 ForEach 的 key，同时它就是「取消这条预定」要传给
   * setOrderedSchedule 的日期 —— 键与日期是同一个东西，不另存一份日期字段，
   * 免得两边漂移（改了一份没改另一份，行还在但取消不掉）。
   */
  dateKey: string = '';
  /** `2026-09-26` */
  dateText: string = '';
  /** `周六`，用档案口径（0=周日）。 */
  weekDayText: string = '';
  /** 距今天多少天。负数表示已经过去。 */
  dayOffset: number = 0;
  planId: string = '';
  planName: string = '';
  /** 指向的课表被删掉了。界面据此显示「已失效」而不是当成没设。 */
  planExists: boolean = true;
  /**
   * 这条预定当天真的生效。
   *
   * 交给 ClassPlanResolver 判，不自己判：预定可能被更靠前的规则盖掉
   * （这张表是叠加班表而叠加班表开关关着），自己判就会把「没生效」标成
   * 「生效中」，用户以为安排好了其实没有。
   */
  isActive: boolean = false;
  /**
   * 这条预定是死条目。
   *
   * 过去的日期，或指向已删的课表。它照样留在档案里（桌面版也留着，不擅自
   * 清理用户数据），但界面上要标出来 —— 否则用户翻出一堆去年的预定，
   * 以为程序出了 bug。
   */
  isStale: boolean = false;
}

// ------------------------------------------------------------ 档案摘要

export class ProfileRow {
  name: string = '';
  subjectCount: number = 0;
  timeLayoutCount: number = 0;
  classPlanCount: number = 0;
  groupCount: number = 0;
  isOverlayEnabled: boolean = false;
  tempPlanId: string = '';
  tempPlanName: string = '';
  tempPlanExists: boolean = false;
  tempPlanFromText: string = '';
  tempGroupId: string = '';
  tempGroupName: string = '';
  tempGroupExists: boolean = false;
  tempGroupExpireText: string = '';
  tempGroupTypeText: string = '';
  isTempGroupEnabled: boolean = false;
  orderedScheduleCount: number = 0;
  selectedGroupId: string = '';
  selectedGroupName: string = '';
}

// ---------------------------------------------------------------- 构造

export class EditorRows {
  /**
   * 档案摘要。
   *
   * @param profile 档案
   * @param activeGroupId 当前课表群 guid；传空串时回落到档案里记的那个
   */
  static profile(profile: Profile): ProfileRow {
    const out: ProfileRow = new ProfileRow();
    out.name = profile.name.length > 0 ? profile.name : '（未命名档案）';
    out.subjectCount = profile.subjects.size;
    out.timeLayoutCount = profile.timeLayouts.size;
    out.classPlanCount = profile.classPlans.size;
    out.groupCount = profile.classPlanGroups.size;
    out.isOverlayEnabled = profile.isOverlayClassPlanEnabled;
    out.orderedScheduleCount = profile.orderedSchedules.size;
    out.selectedGroupId = profile.selectedClassPlanGroupId.toString();

    // 指针可能指向已被删掉的对象。用户文件里残留悬空指针是常态（桌面版
    // 删课表时也可能留下），所以显示「已失效」而不是当成没设。
    const tempId: Guid | undefined = profile.tempClassPlanId;
    if (tempId !== undefined) {
      const plan: ClassPlan | undefined = profile.tryGetClassPlan(tempId);
      out.tempPlanId = tempId.toString();
      out.tempPlanExists = plan !== undefined;
      out.tempPlanName = plan === undefined ? t('editor_stale') : plan.name;
    }
    out.tempPlanFromText = profile.tempClassPlanSetupTime.toDateString();

    const tempGroupId: Guid | undefined = profile.tempClassPlanGroupId;
    if (tempGroupId !== undefined) {
      const group: ClassPlanGroup | undefined =
        profile.classPlanGroups.tryGet(tempGroupId.toString());
      out.tempGroupId = tempGroupId.toString();
      out.tempGroupExists = group !== undefined;
      out.tempGroupName = group === undefined ? t('editor_stale') : group.name;
    }
    out.isTempGroupEnabled = profile.isTempClassPlanGroupEnabled;
    out.tempGroupExpireText = profile.tempClassPlanGroupExpireTime.toDateString();
    out.tempGroupTypeText = profile.tempClassPlanGroupType === TempClassPlanGroupType.Override
      ? t('editor_type_override') : t('editor_type_inherit');

    const selected: ClassPlanGroup | undefined =
      profile.classPlanGroups.tryGet(out.selectedGroupId);
    if (selected !== undefined) {
      out.selectedGroupName = selected.name;
    } else {
      out.selectedGroupName = t('editor_stale');
    }
    return out;
  }

  /**
   * 预定课表行。
   *
   * 按日期升序排，不按档案里的插入序：预定是个「到日子之前会看几眼」的列表，
   * 最近的排在最前才用得上。档案是 `KeyedMap`，插入序取决于用户历来的操作
   * 顺序，跟「什么时候要生效」毫无关系。
   *
   * 排不动的（键不是合法日期）不丢，挂在末尾按原样列出。用户文件里出现这种
   * 键只可能是被外部改过；直接不显示等于让它凭空消失，用户连「它还在档案里」
   * 都无从知道。
   *
   * @param profile 档案
   * @param settings 引擎参数，判「当天是否生效」要用
   * @param today 今天（只取日期部分）
   */
  static orderedSchedules(profile: Profile, settings: EngineSettings,
    today: DateTimeValue): OrderedScheduleRow[] {
    const rows: OrderedScheduleRow[] = [];
    const unparsable: OrderedScheduleRow[] = [];
    profile.orderedSchedules.forEach((schedule: OrderedSchedule, key: string) => {
      const row: OrderedScheduleRow = new OrderedScheduleRow();
      row.dateKey = key;
      const date: DateTimeValue | undefined = DateTimeValue.tryParse(key);
      if (date === undefined) {
        row.dateText = key;
        row.weekDayText = '';
        row.dayOffset = 0;
        row.isStale = true;
      } else {
        const day: DateTimeValue = date.dateOnly();
        row.dateText = day.toDateString();
        row.weekDayText = weekDayName(day.dayOfWeek());
        row.dayOffset = day.epochDay() - today.dateOnly().epochDay();
        row.isStale = row.dayOffset < 0;
      }
      const plan: ClassPlan | undefined = profile.tryGetClassPlan(schedule.classPlanId);
      row.planId = schedule.classPlanId.toString();
      row.planExists = plan !== undefined;
      row.planName = plan === undefined ? t('editor_stale') : plan.name;
      if (date !== undefined && plan !== undefined) {
        const resolved: ResolvedClassPlan = ClassPlanResolver.resolve(profile, date, settings);
        row.isActive = resolved.source === ResolvedSource.OrderedSchedule &&
          resolved.guid.toString() === row.planId;
      }
      if (date === undefined) {
        unparsable.push(row);
      } else {
        rows.push(row);
      }
    });
    rows.sort((a: OrderedScheduleRow, b: OrderedScheduleRow): number => a.dayOffset - b.dayOffset);
    for (const row of unparsable) {
      rows.push(row);
    }
    return rows;
  }

  static subjects(profile: Profile): SubjectRow[] {
    const out: SubjectRow[] = [];
    profile.subjects.forEach((subject: Subject, key: string) => {
      const row: SubjectRow = new SubjectRow();
      row.guid = key;
      row.name = subject.name;
      row.initial = subject.initial;
      row.teacherName = subject.teacherName;
      row.isOutDoor = subject.isOutDoor;
      profile.classPlans.forEach((plan: ClassPlan) => {
        let hit: number = 0;
        for (const info of plan.classes) {
          if (info.subjectId.toString() === key) {
            hit++;
          }
        }
        if (hit > 0) {
          row.usedByPlans++;
          row.usedByClassesTotal += hit;
        }
      });
      out.push(row);
    });
    return out;
  }

  static timeLayouts(profile: Profile): TimeLayoutRow[] {
    const out: TimeLayoutRow[] = [];
    profile.timeLayouts.forEach((layout: TimeLayout, key: string) => {
      out.push(EditorRows.timeLayout(profile, layout, key));
    });
    return out;
  }

  static timeLayout(profile: Profile, layout: TimeLayout, key: string): TimeLayoutRow {
    const row: TimeLayoutRow = new TimeLayoutRow();
    row.guid = key;
    row.name = layout.name;
    row.rowCount = layout.layouts.length;
    const slots: number[] = layout.classSlotIndexes();
    for (let i: number = 0; i < layout.layouts.length; i++) {
      row.rows.push(EditorRows.timePoint(profile, layout, key, layout.layouts[i], i, slots[i]));
    }
    row.classCount = layout.classTimePoints().length;

    const parts: string[] = [];
    for (const item of row.rows) {
      parts.push(item.isClass ? item.startText : item.breakName);
    }
    row.summary = parts.slice(0, 3).join(' / ') + (parts.length > 3 ? ' / …' : '');

    profile.classPlans.forEach((plan: ClassPlan) => {
      if (plan.timeLayoutId.toString() === key) {
        row.usedByPlans++;
        row.boundPlanNames = row.boundPlanNames.length > 0
          ? `${row.boundPlanNames}、${plan.name}` : plan.name;
      }
    });
    return row;
  }

  static timePoint(profile: Profile, layout: TimeLayout, layoutKey: string,
    item: TimeLayoutItem, rowIndex: number, slot: number): TimePointRow {
    const row: TimePointRow = new TimePointRow();
    row.rowIndex = rowIndex;
    row.timeType = item.timeType;
    row.timeTypeText = timeTypeName(item.timeType);
    row.startText = formatClock(item.startTime.toSeconds());
    row.endText = formatClock(item.endTime.toSeconds());
    const start: number = Math.max(0, item.startTime.toSeconds());
    const end: number = Math.max(0, item.endTime.toSeconds());
    row.durationMinutes = Math.max(0, Math.round((end - start) / 60));
    row.durationText = formatDuration(row.durationMinutes);
    row.breakName = item.breakName;
    row.isClass = item.timeType === 0;
    row.classSlot = slot;
    row.classSlotText = slot >= 0 ? tf('wg_slot_n', `${slot + 1}`) : '';
    row.isHideDefault = item.isHideDefault;
    if (!item.defaultClassId.isEmpty()) {
      const subject: Subject | undefined = profile.tryGetSubject(item.defaultClassId);
      row.defaultSubjectId = item.defaultClassId.toString();
      // 指向的科目已被删除时显示占位符而不是空串，空串会被界面当成「没设」
      row.defaultSubjectName = subject === undefined ? EMPTY_SUBJECT_TEXT : subject.name;
      row.defaultAppliedCount = EditorRows.countApplied(profile, layoutKey, slot, row.defaultSubjectId);
    }
    return row;
  }

  /**
   * 课表列表。
   *
   * @param activeId 基准日实际生效的课表 guid，空串表示没有。判据交给
   *   ClassPlanResolver，这里不再重写一遍——重写就会出现「课表页说今天上
   *   A，编辑页标 B」这种只有细看才发现的不一致。
   */
  static classPlans(profile: Profile, activeId: string): ClassPlanRow[] {
    const out: ClassPlanRow[] = [];
    profile.classPlans.forEach((plan: ClassPlan, key: string) => {
      out.push(EditorRows.classPlan(profile, plan, key, activeId));
    });
    return out;
  }

  static classPlan(profile: Profile, plan: ClassPlan, key: string, activeId: string): ClassPlanRow {
    const row: ClassPlanRow = new ClassPlanRow();
    row.guid = key;
    row.name = plan.name;
    row.isEnabled = plan.isEnabled;
    row.isOverlay = plan.isOverlay;
    row.weekDay = plan.timeRule.weekDay;
    row.weekDayText = weekDayName(plan.timeRule.weekDay);
    row.weekCountDiv = plan.timeRule.weekCountDiv;
    row.weekCountDivTotal = plan.timeRule.weekCountDivTotal;
    row.weekRotationText = weekRotationText(plan.timeRule.weekCountDiv, plan.timeRule.weekCountDivTotal);

    row.timeLayoutId = plan.timeLayoutId.toString();
    const layout: TimeLayout | undefined = profile.tryGetTimeLayout(plan.timeLayoutId);
    if (layout === undefined) {
      row.hasTimeLayout = false;
      row.timeLayoutName = t('editor_stale');
    } else {
      row.timeLayoutName = layout.name;
      const points: TimeLayoutItem[] = layout.classTimePoints();
      row.classCount = points.length;
      for (let slot: number = 0; slot < plan.classes.length; slot++) {
        row.slots.push(EditorRows.classSlot(profile, points, plan.classes[slot], slot));
      }
      // 排课页的行：全部可显示时间点，课间与分割线也占行。
      // 注意这里用的是 isDisplayable()（原始行序），而课表网格用的是
      // validTimeLayoutItems()（按停用过滤）。两者行集不同是有意的：网格要
      // 呈现「今天看得到什么」，编辑页要呈现「这张时间表有哪些行」，停用的一行
      // 在编辑页恰恰不该消失，否则用户没法把它改回来。
      const slots: number[] = layout.classSlotIndexes();
      for (let i: number = 0; i < layout.layouts.length; i++) {
        const item: TimeLayoutItem = layout.layouts[i];
        if (!item.isDisplayable()) {
          continue;
        }
        const edit: PlanEditRow = new PlanEditRow();
        edit.rowIndex = i;
        edit.classSlot = slots[i];
        edit.isClass = slots[i] >= 0;
        edit.isSeparator = item.timeType === 2;
        edit.label = slots[i] >= 0 ? tf('wg_slot_n', `${slots[i] + 1}`) : item.breakNameText();
        // 分割线不占时段，显示成一段空白会让界面多出一条看不懂的栏
        edit.timeRange = edit.isSeparator ? ''
          : `${formatClock(item.startTime.toSeconds())}-${formatClock(item.endTime.toSeconds())}`;
        row.editRows.push(edit);
      }
    }

    const sourceId: Guid | undefined = plan.overlaySourceId;
    if (sourceId !== undefined) {
      const source: ClassPlan | undefined = profile.tryGetClassPlan(sourceId);
      row.overlaySourceId = sourceId.toString();
      row.overlaySourceName = source === undefined ? t('editor_stale') : source.name;
    }

    row.groupId = plan.associatedGroup.toString();
    const group: ClassPlanGroup | undefined = profile.classPlanGroups.tryGet(row.groupId);
    if (group !== undefined) {
      row.groupName = group.name;
    } else if (plan.associatedGroup.equals(ClassPlanGroup.defaultGroupGuid())) {
      row.groupName = t('editor_default_group');
    } else if (plan.associatedGroup.equals(ClassPlanGroup.globalGroupGuid())) {
      row.groupName = t('editor_global_group');
    } else {
      row.groupName = t('editor_stale');
    }

    const names: string[] = [];
    for (const slot of row.slots) {
      if (!slot.isEmpty) {
        names.push(slot.subjectName);
      }
    }
    row.filledCount = names.length;
    row.filledText = names.join('、');
    row.isActiveOnBaseDate = key === activeId;
    return row;
  }

  static classSlot(profile: Profile, points: TimeLayoutItem[], info: ClassInfo,
    slot: number): ClassSlotRow {
    const row: ClassSlotRow = new ClassSlotRow();
    row.slot = slot;
    row.slotText = tf('wg_slot_n', `${slot + 1}`);
    row.isEnabled = info.isEnabled;
    row.isChangedClass = info.isChangedClass;
    if (!info.subjectId.isEmpty()) {
      // 键就是 ClassInfo 里存的那串 guid，问 tryGetSubject 拿不回键也用不着
      const subjectKey: string = info.subjectId.toString();
      const subject: Subject | undefined = profile.tryGetSubject(info.subjectId);
      if (subject !== undefined) {
        row.subjectId = subjectKey;
        row.subjectName = subject.name;
        row.initial = subject.initial;
        row.teacherName = subject.teacherName;
        row.isEmpty = false;
      }
    }
    if (slot < points.length) {
      const point: TimeLayoutItem = points[slot];
      if (!point.defaultClassId.isEmpty()) {
        row.hasDefault = true;
        row.defaultSubjectId = point.defaultClassId.toString();
        const subject: Subject | undefined = profile.tryGetSubject(point.defaultClassId);
        row.defaultSubjectName = subject === undefined ? EMPTY_SUBJECT_TEXT : subject.name;
      }
    }
    return row;
  }

  static classPlanGroups(profile: Profile): ClassPlanGroupRow[] {
    const out: ClassPlanGroupRow[] = [];
    profile.classPlanGroups.forEach((group: ClassPlanGroup, key: string) => {
      const row: ClassPlanGroupRow = new ClassPlanGroupRow();
      row.guid = key;
      row.name = group.name;
      row.isGlobal = group.isGlobal;
      row.isDefault = ClassPlanGroup.defaultGroupGuid().toString() === key;
      row.isSelected = profile.selectedClassPlanGroupId.toString() === key;
      row.planCount = EditorRows.countPlansInGroup(profile, key);
      // 默认群与全局群由引擎特判：删掉它们改的是选课结果，不只是少一个列表项
      row.canDisband = !row.isDefault && !group.isGlobal;
      row.canDelete = row.canDisband;
      out.push(row);
    });
    return out;
  }

  private static countPlansInGroup(profile: Profile, groupId: string): number {
    let count: number = 0;
    profile.classPlans.forEach((plan: ClassPlan) => {
      if (plan.associatedGroup.toString() === groupId) {
        count++;
      }
    });
    return count;
  }

  /** 某个课次在已绑定课表里被实际排成该预置科目的次数。 */
  private static countApplied(profile: Profile, layoutKey: string, slot: number,
    subjectId: string): number {
    if (slot < 0) {
      return 0;
    }
    let count: number = 0;
    profile.classPlans.forEach((plan: ClassPlan) => {
      if (plan.timeLayoutId.toString() !== layoutKey) {
        return;
      }
      if (slot < plan.classes.length && plan.classes[slot].subjectId.toString() === subjectId) {
        count++;
      }
    });
    return count;
  }
}

/**
 * 界面把「HH:mm」文本解析回秒。
 *
 * 格式不对时返回 undefined 而不是 0：返回 0 的话，一处拼错的输入会把时间点
 * 挪到 00:00，界面上看着像「凌晨第一节课」，用户很难发现是自己输错了。
 */
export function parseClockText(text: string): number | undefined {
  const trimmed: string = text.trim();
  const parts: string[] = trimmed.split(':');
  if (parts.length < 2 || parts.length > 3) {
    return undefined;
  }
  const hours: number = Number(parts[0]);
  const minutes: number = Number(parts[1]);
  if (!Number.isInteger(hours) || !Number.isInteger(minutes)) {
    return undefined;
  }
  if (hours < 0 || hours > 24 || minutes < 0 || minutes > 59) {
    return undefined;
  }
  return hours * 3600 + minutes * 60;
}

/** 时长文本（「45 分钟」「1 小时」）-> 分钟数。不合法时返回 undefined。 */
export function parseDurationText(text: string): number | undefined {
  const digits: string = text.replace(/[^\d]/g, '');
  if (digits.length === 0) {
    return undefined;
  }
  const value: number = Number(digits);
  if (!Number.isInteger(value) || value <= 0 || value > 24 * 60) {
    return undefined;
  }
  return value;
}
