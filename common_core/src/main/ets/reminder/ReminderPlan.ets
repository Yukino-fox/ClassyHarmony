/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 课前提醒的编排。纯函数，不碰任何平台 API。
 *
 * 这一层为什么值得单独存在
 * ------------------------
 * 平台侧的提醒 API（reminderAgentManager）只有真机能验，而「提醒该在什么时刻
 * 触发、覆盖哪几天、额度不够时怎么降级」这三点全是算术，算错了在真机上的表现是
 * 「上课前没响」——用户不会怀疑实现，只会怀疑应用，然后卸载。把算术抽到纯函数，
 * 就能在 Node 测试台上穷举：跨零点、跨周、额度边界、单双周、悬空指针。
 *
 * 三条设计取舍
 * ------------
 *
 * 1. 只排「常规课表」，不排临时课表 / 预定课表 / 叠加课表
 *    平台日历型提醒是**每周重复**的（daysOfWeek），而临时课表只管一两天、预定课表
 *    只管某一天。把「一两天的事」映射到「每周都响」上，绝大多数时候是错的；完全不响
 *    只在极少数日子错。拿稳定的那个当源。
 *
 * 2. 单双周课表照样排，但只在对应星期几响
 *    平台的 daysOfWeek 表达不了「隔周」。所以单双周课表会在**每一个**对应星期几
 *    都提醒，而不是隔一个周次。plan().hasRotation 供界面如实告知用户，不假装没有
 *    这个偏差。真正的修法是用 addExcludeDate 逐个排除，那是另一件事（见 P6 收尾）。
 *
 * 3. 星期几在档案与平台之间**不是同一套口径**
 *    档案侧 TimeRule.weekDay / DateTimeValue.dayOfWeek() 都是 .NET 口径
 *    0=周日 … 6=周六（桌面版 LessonsService 就是拿 WeekDay 和 (int)DayOfWeek 直接
 *    比的，档案 JSON 里的值也是这个口径，不能改）。平台侧
 *    ReminderRequestCalendar.daysOfWeek 是 1=周一 … 7=周日。
 *    两套口径只在 0 与 7 上不同，于是「周日」这一格差 7 天而不是 1 天，肉眼看
 *    提醒都在，只有周日那一条整体偏移 —— 静默错一周的提醒比没有提醒更糟。
 *    本文件内部一律用档案口径，只在 platformDaysOfWeek() 里转一次，
 *    那个函数有测试台覆盖。
 *
 * 4. 额度不够时整体降级，不做部分降级
 *    平台对普通应用的代理提醒有数量上限（API 9 起 30 条，API 26 提到 64 条）。
 *    超了 publishReminder 直接报 1700002，且是**整批失败**。所以宁可退回「按时间点
 *    折叠」这种内容不精确但覆盖完整的形态，也不要「精确内容只覆盖一半」——
 *    后者会让用户在某些天收不到提醒，而且完全不知道自己漏了。
 */

import {
  ClassInfo,
  ClassPlan,
  ClassPlanGroup,
  DateTimeValue,
  Guid,
  Profile,
  Subject,
  TimeLayout,
  TimeLayoutItem
} from 'common_shared';
import { t, tf } from '../i18n/I18n';
import { formatClock } from '../view/TextFormat';

/** 提醒形态。 */
export enum ReminderMode {
  /** 按（课表 × 时间点 × 星期几）逐条排，内容带科目名与老师。 */
  Specific = 0,
  /** 按（课表 × 时间点）折叠成一条，用 daysOfWeek 覆盖多个星期几，内容只带时刻。 */
  Collapsed = 1
}

/** 提醒的触发策略。室内外分开是照搬桌面版：操场上的课得早提醒。 */
export class ReminderAdvance {
  /** 室内课的提前量（秒）。 */
  indoorSeconds: number = 300;

  /** 室外课的提前量（秒）。 */
  outdoorSeconds: number = 600;
}

/**
 * 一条待发布的提醒。字段刻意与平台的 ReminderRequestCalendar 一一对应，
 * 这样 entry 侧不需要再做一次形状转换，也就不会有转换处的错位。
 */
export class ReminderPlanItem {
  /**
   * 稳定标识，最终写进 ReminderRequest.groupId。
   *
   * 组成刻意只含**不会随时间自己变**的部分：课表 guid、时间点下标、星期几集合、
   * 触发时刻。「下一次出现日期」不在里面 —— 那个每天都在变，放进去会导致每天
   * 全部重发一遍提醒。
   */
  key: string = '';

  /** 课表 guid。排序与排查时用。 */
  planGuid: string = '';

  /** 课表名。提示语里的「来自新课表」。 */
  planName: string = '';

  /** 时间点下标（时间表 layouts 里的下标，不是课次下标）。 */
  timePointIndex: number = -1;

  /** 时间点在本课表课次里的下标。给界面用。 */
  classSlot: number = -1;

  /** 触发日期时间（已减去提前量）。年月日给平台用来定位首次触发。 */
  trigger: DateTimeValue = DateTimeValue.minValue();

  /**
   * 覆盖的星期几，**档案口径 0=周日 … 6=周六**。具体形态恒为单元素。
   *
   * 刻意不直接存平台口径：这样本层与档案、引擎、编辑页共用一套数，写错时
   * 越界检查（0..6）会当场抓住；而平台口径只在 platformDaysOfWeek() 里出现一次。
   */
  weekDays: number[] = [];

  /** 通知标题。 */
  title: string = '';

  /** 通知正文。 */
  content: string = '';

  /** 过期后（上课中）显示的正文。 */
  expiredContent: string = '';

  /** 稍后提醒的正文。 */
  snoozeContent: string = '';

  /** 科目名。折叠模式下为空串。 */
  subjectName: string = '';

  /** 老师名。 */
  teacherName: string = '';

  /** 上课时刻（秒，一天内）。折叠模式也带，便于文案。 */
  classStartSeconds: number = 0;

  /** 实际用的提前量（秒）。 */
  advanceSeconds: number = 0;
}

/** 一次编排的完整结果。 */
export class ReminderPlan {
  /** 本次采用的形态。 */
  mode: ReminderMode = ReminderMode.Specific;

  /** 要发布的提醒。顺序即发布优先级。 */
  items: ReminderPlanItem[] = [];

  /** 折叠前的条数，也就是「本该有多少条精确提醒」。 */
  specificCount: number = 0;

  /** 折叠后的条数，也就是「本该有多少条折叠提醒」。 */
  collapsedCount: number = 0;

  /** 因额度被丢弃的条数（折叠形态下指精确形态超出额度的部分）。 */
  droppedCount: number = 0;

  /** 档案里有没有单双周课表。界面上要如实告知偏差。 */
  hasRotation: boolean = false;

  /** 所有 key。给差异比对用。 */
  keys(): string[] {
    const out: string[] = [];
    for (const item of this.items) {
      out.push(item.key);
    }
    return out;
  }
}

/** 平台上已存在的一条提醒的快照。只有差异比对真正需要的字段。 */
export class ReminderSnapshot {
  /** 平台上的 reminderId。取消时要用。 */
  reminderId: number = -1;

  /** 平台上的 groupId，即我们写的 key。 */
  key: string = '';

  /** 平台记录的首次触发日期（年月日）。用于判断「起始日已经过去」。 */
  triggerYear: number = 0;

  triggerMonth: number = 0;

  triggerDay: number = 0;

  /** 平台记录的标题与正文。用于判断内容是否已经变过。 */
  title: string = '';

  content: string = '';
}

/** 差异结果。 */
export class ReminderDiff {
  /** 要新建。 */
  toAdd: ReminderPlanItem[] = [];

  /** 要更新（key 相同但内容或起始日变了）。 */
  toRefresh: ReminderPlanItem[] = [];

  /** 要取消的 reminderId。 */
  toCancel: number[] = [];
}

/** 编排入口。 */
export class ReminderPlanner {
  /**
   * 平台对普通应用的代理提醒数量上限。
   *
   * 取 30 而不是 API 26 的 64：30 是**所有**设备都够用的那个数，发布出去在老设备
   * 上不会撞 1700002。宁可少排几条也不要「在用户手机上突然全失效」。
   * 想榨干新设备的额度由 entry 侧探测：撞到 1700002 时它可以把实际可用条数记下来
   * 再重排（见 ReminderSyncService）。
   */
  static readonly QUOTA: number = 30;

  /**
   * 编排。
   *
   * @param profile 档案。调用前应当已经 refreshDerivedState。
   * @param now 编排基准时刻。决定每条提醒的「首次触发」落在哪一天。
   * @param advance 提前量策略。
   * @param mode 形态。
   * @param budget 条数上限。超出部分按 items 顺序从尾部丢弃。
   */
  static plan(profile: Profile, now: DateTimeValue, advance: ReminderAdvance,
    mode: ReminderMode, budget: number): ReminderPlan {
    const out: ReminderPlan = new ReminderPlan();
    out.mode = mode;

    const sources: ReminderSource[] = ReminderPlanner.collectSources(profile, out);
    // 两个计数都算，因为界面上要同时说清「本该有多少条精确提醒」和「实际排了多少条」：
    // 只报一个数字的话，用户看到 12 条而实际有 60 个时段，无从判断是课表就这么少
    // 还是被额度砍掉了。
    out.specificCount = ReminderPlanner.countSpecific(sources, profile);
    out.collapsedCount = ReminderPlanner.countCollapsed(sources, profile);

    const all: ReminderPlanItem[] = mode === ReminderMode.Specific
      ? ReminderPlanner.buildSpecific(sources, profile, now, advance)
      : ReminderPlanner.buildCollapsed(sources, profile, now, advance);

    // 截断：保留前 budget 条，丢弃其余。items 已按「时间点下标优先、星期几次之」
    // 排序，所以截断丢的是**后面几节课**而不是某几天 —— 用户看到的是「一天里较早
    // 的课有提醒、较晚的没有」，而不是「周一三五没有」，后者完全无法自查。
    const limit: number = budget < 0 ? all.length : budget;
    if (all.length <= limit) {
      out.items = all;
    } else {
      out.items = all.slice(0, limit);
      out.droppedCount = all.length - limit;
    }
    return out;
  }

  /**
   * 档案口径（0=周日 … 6=周六）转平台口径（1=周一 … 7=周日），去重后升序。
   *
   * 整个工程只有这一处做这次转换，所以它有测试台断言守着：
   *   0 -> 7（周日）
   *   1..6 -> 1..6（周一..周六）
   * 两套口径的其余六个值恰好相同，于是漏掉周日不会让周一到周五的任何一条提醒
   * 出问题 —— 症状是「周日那条提醒在别的日子响」，极难从使用现场联想到口径。
   *
   * 升序而不保序：平台只关心集合，而升序让同一条提醒在多次同步之间不会因为
   * 插入顺序变化而触发一次「内容变了」的重复发布。
   */
  static platformDaysOfWeek(weekDays: number[]): number[] {
    const seen: Set<number> = new Set<number>();
    for (const day of weekDays) {
      if (day < 0 || day > 6) {
        continue;
      }
      seen.add(day === 0 ? 7 : day);
    }
    const out: number[] = [];
    seen.forEach((day: number) => {
      out.push(day);
    });
    out.sort(ReminderPlanner.compareNumbers);
    return out;
  }

  /**
   * 比对平台现状与编排结果，算出要增删改什么。
   *
   * 刻意不在这里做「全部推倒重来」：重来的代价是额度在同步瞬间被占满，而
   * cancelAllReminders 之后到 publishReminder 之间有个窗口，窗口里用户上课了
   * 就没人提醒。差量同步让每一轮都不出现这个窗口。
   *
   * @param plan 编排结果。
   * @param existing 平台现状。
   * @param today 判定「起始日是否已过去」的基准日。
   */
  static diff(plan: ReminderPlan, existing: ReminderSnapshot[], today: DateTimeValue): ReminderDiff {
    const out: ReminderDiff = new ReminderDiff();
    const byKey: Map<string, ReminderSnapshot> = new Map<string, ReminderSnapshot>();
    for (const snapshot of existing) {
      // 只认我们自己排的。groupId 为空的可能是别处（历史版本）留下的，
      // 认了会让差异比对把它算进「保留」，而实际上没人会去更新它。
      if (snapshot.key.length > 0) {
        byKey.set(snapshot.key, snapshot);
      }
    }

    const kept: Set<string> = new Set<string>();
    for (const item of plan.items) {
      const found: ReminderSnapshot | undefined = byKey.get(item.key);
      if (found === undefined) {
        out.toAdd.push(item);
        continue;
      }
      kept.add(item.key);
      if (ReminderPlanner.needsRefresh(item, found, today)) {
        out.toRefresh.push(item);
      }
    }

    // 「不在 kept 里就取消」，而不是「key 非空且不在 kept 里才取消」。
    // groupId 为空的是旧版本排下的残留（getValidReminders 只返回本应用的），
    // 没人会去更新它，而它照占额度 —— 让额度被自己留下的垃圾吃光是很难查的问题。
    for (const snapshot of existing) {
      if (!kept.has(snapshot.key)) {
        out.toCancel.push(snapshot.reminderId);
      }
    }
    return out;
  }

  /**
   * key 对上了，但内容变了、或者平台记的首次触发日已经落到今天之前，才需要更新。
   *
   * 判据是「**平台记的日期**是否早于今天」，不是「平台记的日期是否等于我们要的
   * 日期」。后者看着更严，实际会天天重发：平台的 daysOfWeek 重复并不依赖 dateTime
   * 往后续，dateTime 只是起点与时刻来源 —— 我们要的首次触发日每天都在往前挪，
   * 而平台上记的还是当初那一天，两者永远不等，于是每次同步都把十几条提醒全更新
   * 一遍，额度就这么白耗掉了。真正需要处理的只有「起点已经过去」这一个状态。
   *
   * 只比日期不比时刻：平台可能把秒归零、或按本地时区重算，逐字段比对同样会永远
   * 判定「不一样」。按日期比，一天最多触发一次，而且那一次几乎总是必要的。
   */
  private static needsRefresh(item: ReminderPlanItem, found: ReminderSnapshot,
    today: DateTimeValue): boolean {
    if (found.title !== item.title || found.content !== item.content) {
      return true;
    }
    if (found.triggerYear < today.year) {
      return true;
    }
    if (found.triggerYear === today.year && found.triggerMonth < today.month) {
      return true;
    }
    return found.triggerYear === today.year && found.triggerMonth === today.month &&
      found.triggerDay < today.day;
  }

  // ------------------------------------------------------------ 内部

  /** 挑出参与编排的课表，并记下档案里有没有单双周。 */
  private static collectSources(profile: Profile, out: ReminderPlan): ReminderSource[] {
    const sources: ReminderSource[] = [];
    const selectedGroup: Guid = profile.selectedClassPlanGroupId;
    const globalGroup: Guid = ClassPlanGroup.globalGroupGuid();
    profile.classPlans.forEach((plan: ClassPlan, key: string) => {
      if (plan.isOverlay || !plan.isEnabled) {
        return;
      }
      if (!plan.associatedGroup.equals(selectedGroup) && !plan.associatedGroup.equals(globalGroup)) {
        return;
      }
      // TimeRule.weekDay 是 .NET 口径 0=周日 … 6=周六。越界的档案（手改 JSON 才会
      // 出现）在这里被丢掉而不是排成一条永远不触发的提醒。
      const weekDay: number = plan.timeRule.weekDay;
      if (weekDay < 0 || weekDay > 6) {
        return;
      }
      const layout: TimeLayout | undefined = plan.resolveTimeLayout();
      if (layout === undefined || layout.layouts.length === 0) {
        return;
      }
      if (plan.timeRule.weekCountDiv !== 0) {
        out.hasRotation = true;
      }
      const source: ReminderSource = new ReminderSource();
      source.planGuid = key;
      source.planName = plan.name;
      source.weekDay = weekDay;
      source.plan = plan;
      source.layout = layout;
      sources.push(source);
    });
    // 课表按星期几、课表 guid 排序：同一节课在不同档案载入顺序下位置一致，
    // 差异比对才不会因为「顺序变了」而反复重发。
    sources.sort(ReminderPlanner.compareSources);
    return sources;
  }

  private static compareSources(left: ReminderSource, right: ReminderSource): number {
    if (left.weekDay !== right.weekDay) {
      return left.weekDay - right.weekDay;
    }
    return left.planGuid < right.planGuid ? -1 : (left.planGuid > right.planGuid ? 1 : 0);
  }

  /** 精确形态的条数：每张课表每个排了课的时间点算一条。 */
  private static countSpecific(sources: ReminderSource[], profile: Profile): number {
    let total: number = 0;
    for (const source of sources) {
      total += ReminderPlanner.classSlotsOf(source, profile).length;
    }
    return total;
  }

  /**
   * 折叠形态的条数：同一个**上课时刻**不论来自几张课表、覆盖几个星期几都只算一条。
   *
   * 分组键是上课时刻而不是「课表 × 时间点」，因为本工程模型里**每个星期几各有一张
   * 课表**（TimeRule.weekDay 是课表级属性）。按课表分组等于一条都没折起来：
   * 12 节课 × 5 天仍是 60 条，额度一点没省，降级就白做了。
   *
   * 这也是差别所在：60 条精确提醒折成 12 条。
   */
  private static countCollapsed(sources: ReminderSource[], profile: Profile): number {
    const groups: Set<number> = new Set<number>();
    for (const source of sources) {
      for (const slot of ReminderPlanner.classSlotsOf(source, profile)) {
        groups.add(slot.startSeconds);
      }
    }
    return groups.size;
  }

  /**
   * 列出该课表里「真的排了课」的时间点。
   *
   * 判据三条同时成立：时间点是课程类型、课次启用、课次有科目。悬空指针
   * （subjectId 指向已删除的科目）在 resolveSubject 里被吃掉，会落到「不排」。
   */
  private static classSlotsOf(source: ReminderSource, profile: Profile): ReminderSlot[] {
    const out: ReminderSlot[] = [];
    const plan: ClassPlan = source.plan;
    const layout: TimeLayout = source.layout;
    const slotIndexes: number[] = layout.classSlotIndexes();
    for (let layoutIndex: number = 0; layoutIndex < slotIndexes.length; layoutIndex++) {
      const classIndex: number = slotIndexes[layoutIndex];
      if (classIndex < 0) {
        continue;
      }
      if (classIndex >= plan.classes.length) {
        continue;
      }
      const info: ClassInfo = plan.classes[classIndex];
      if (!info.isEnabled || info.isEmpty()) {
        continue;
      }
      if (classIndex >= layout.classTimePoints().length) {
        continue;
      }
      const item: TimeLayoutItem = layout.layouts[layoutIndex];
      // 悬空指针（subjectId 指向已删除的科目）在这里就判掉：查不到科目就不排提醒，
      // 排了等于告诉用户一节他不存在的课。存在 slot 上而不是等到建 item 时再查，
      // 是为了让「哪些时段不排」这个判据只写一次。
      const subject: Subject | undefined = profile.tryGetSubject(info.subjectId);
      if (subject === undefined) {
        continue;
      }
      const slot: ReminderSlot = new ReminderSlot();
      slot.timePointIndex = layoutIndex;
      slot.classSlot = classIndex;
      slot.startSeconds = item.startTime.toSeconds();
      slot.subject = subject;
      out.push(slot);
    }
    return out;
  }

  private static buildSpecific(sources: ReminderSource[], profile: Profile, now: DateTimeValue,
    advance: ReminderAdvance): ReminderPlanItem[] {
    const collected: ReminderPlanItem[] = [];
    for (const source of sources) {
      for (const slot of ReminderPlanner.classSlotsOf(source, profile)) {
        const subject: Subject = slot.subject;
        const advanceSeconds: number = ReminderPlanner.advanceOf(advance, subject);
        const item: ReminderPlanItem = new ReminderPlanItem();
        item.planGuid = source.planGuid;
        item.planName = source.planName;
        item.timePointIndex = slot.timePointIndex;
        item.classSlot = slot.classSlot;
        item.classStartSeconds = slot.startSeconds;
        item.advanceSeconds = advanceSeconds;
        item.weekDays = [source.weekDay];
        item.trigger = ReminderPlanner.firstTrigger(now, source.weekDay,
          slot.startSeconds - advanceSeconds);
        item.subjectName = subject.name;
        item.teacherName = subject.teacherName;
        item.key = ReminderPlanner.makeKey(item);
        ReminderPlanner.fillText(item);
        collected.push(item);
      }
    }
    return ReminderPlanner.sortForBudget(collected);
  }

  private static buildCollapsed(sources: ReminderSource[], profile: Profile, now: DateTimeValue,
    advance: ReminderAdvance): ReminderPlanItem[] {
    // 分组键是上课时刻（见 countCollapsed 的注释）。同一时刻在不同星期几、
    // 不同课表上可能是不同科目，折叠后内容只能退化到「时刻 + 上课」——
    // 这是降级的定义，不是实现取巧。
    const groups: Map<number, ReminderPlanItem> = new Map<number, ReminderPlanItem>();
    for (const source of sources) {
      for (const slot of ReminderPlanner.classSlotsOf(source, profile)) {
        const advanceSeconds: number = ReminderPlanner.advanceOf(advance, slot.subject);
        let item: ReminderPlanItem | undefined = groups.get(slot.startSeconds);
        if (item === undefined) {
          item = new ReminderPlanItem();
          // 折叠后一条提醒可能来自若干张课表，planGuid / planName 没有单一答案。
          // 留空而不是取第一张：界面上「来自 X 课表」这句话在跨天折叠时本身就是
          // 误导 —— 用户看到的提醒覆盖周一到周五，说它来自周一的课表是假的。
          item.planGuid = '';
          item.planName = '';
          item.timePointIndex = -1;
          item.classSlot = -1;
          item.classStartSeconds = slot.startSeconds;
          item.advanceSeconds = advanceSeconds;
          item.trigger = ReminderPlanner.firstTrigger(now, source.weekDay,
            slot.startSeconds - advanceSeconds);
          groups.set(slot.startSeconds, item);
        }
        if (item.weekDays.indexOf(source.weekDay) < 0) {
          item.weekDays.push(source.weekDay);
        }
      }
    }
    const out2: ReminderPlanItem[] = [];
    for (const item of groups.values()) {
      // 室外课会先建组，触发时刻按室外提前量算的；组里若混进室内课，时刻就固定在
      // 第一个建组的那个口径上。不重算：让「这一格统一按第一个口径」比「按组内多数
      // 口径」更容易向用户解释。
      item.weekDays.sort(ReminderPlanner.compareNumbers);
      item.key = ReminderPlanner.makeKey(item);
      ReminderPlanner.fillText(item);
      out2.push(item);
    }
    return ReminderPlanner.sortForBudget(out2);
  }

  private static advanceOf(advance: ReminderAdvance, subject: Subject | undefined): number {
    if (subject === undefined) {
      return advance.indoorSeconds;
    }
    return subject.isOutDoor ? advance.outdoorSeconds : advance.indoorSeconds;
  }

  /**
   * 算出这条提醒的**首次**触发时刻。
   *
   * 平台的日历型提醒把 dateTime 当作「从这天开始，按 daysOfWeek 重复」，所以
   * dateTime 既是时刻来源也是起点。起点必须落在将来：若按星期几算出来的候选时刻
   * 已经过去（今天这节课的提醒时间点过了），就顺延一周。
   *
   * 跨零点：提前量可能把 00:05 的课拉到前一天 23:55。用秒为单位的整日偏移处理，
   * 不用「减 10 分钟」再补日期 —— 后者在减法跨日时会漏掉日期回退。
   */
  private static firstTrigger(now: DateTimeValue, weekDay: number, startSeconds: number):
    DateTimeValue {
    // 两侧都是 .NET 口径（0=周日 … 6=周六），所以取模不用做偏移。
    const todayDow: number = now.dayOfWeek();
    const daysAhead: number = (weekDay - todayDow + 7) % 7;
    const day: DateTimeValue = now.dateOnly().addDays(daysAhead);
    // 一天 86400 秒。startSeconds 可能为负（跨零点）或超过 86400（脏数据）。
    const dayDelta: number = Math.floor(startSeconds / 86400);
    const withinDay: number = startSeconds - dayDelta * 86400;
    // 顺序要紧：addDays 内部走 dateOnly()，也就是无条件把时刻清零，所以
    // 「先加秒数再加 0 天」会把 07:55 抹成 00:00。先挪整日、再补当日秒数。
    let trigger: DateTimeValue = day.addDays(dayDelta).addSeconds(withinDay);
    // 与 now 精确比较（含秒）：等于 now 也算过去，平台不接受此刻触发。
    if (trigger.epochDay() * 86400 + trigger.timeOfDaySeconds() <=
      now.epochDay() * 86400 + now.timeOfDaySeconds()) {
      trigger = trigger.addDays(7);
    }
    return trigger;
  }

  private static makeKey(item: ReminderPlanItem): string {
    const days: string[] = [];
    for (const day of item.weekDays) {
      days.push(`${day}`);
    }
    // 前缀标明形态：形态切换时 key 必然全变，差异比对于是「全取消 + 全新建」，
    // 而不是把两种形态的条目错配成同一批（课表 guid 与「-」不可能撞上，但把这件事
    // 交给不变量而不是祈祷更省事）。
    //
    // 分隔符用 -：guid 里本来就是 -，混用同一种分隔符可读性更好，且 - 避开了竖线
    // 在某些 shell / 日志系统里的转义麻烦。
    const prefix: string = item.planGuid.length === 0 ? 'c' : 's';
    return `${prefix}-${item.planGuid}-${item.timePointIndex}-${days.join('')}-${formatClock(
      item.trigger.timeOfDaySeconds()).replace(':', '')}`;
  }

  /**
   * 通知文案。
   *
   * 与桌面版的差别写在标题里：桌面版是实时定时器，能说「距上课还剩 3 分 20 秒」；
   * 静态提醒只能说「3 分钟后」。所以措辞改成不含相对计时的样子，而不是把同一个
   * 模板套上去假装还剩多少 —— 用户照着「3 分钟后」等，等到 0 还没上课会以为应用坏了。
   */
  private static fillText(item: ReminderPlanItem): void {
    const subjectPart: string = item.subjectName.length > 0 ? item.subjectName : t('rp_class');
    if (item.subjectName.length === 0) {
      item.title = t('rp_title_time_up');
      item.content = tf('rp_content_check_schedule', formatClock(item.classStartSeconds));
    } else if (item.advanceSeconds <= 0) {
      item.title = tf('rp_title_subject_starts', subjectPart);
      item.content = ReminderPlanner.withTeacher(subjectPart, item.teacherName,
        t('rp_now_starts'));
    } else {
      const minutes: number = Math.round(item.advanceSeconds / 60);
      item.title = tf('rp_title_in_minutes', `${minutes}`, subjectPart);
      item.content = ReminderPlanner.withTeacher(subjectPart, item.teacherName,
        tf('rp_content_starts_at', formatClock(item.classStartSeconds)));
    }
    item.expiredContent = item.subjectName.length > 0 ? tf('rp_expired_in_class', subjectPart) : t('rp_in_class');
    item.snoozeContent = t('rp_snoozed');
  }

  private static withTeacher(subject: string, teacher: string, tail: string): string {
    const teacherText: string = teacher.trim();
    if (teacherText.length === 0) {
      return tf('rp_line_no_teacher', tail, subject);
    }
    return tf('rp_line_teacher', tail, subject, teacherText);
  }

  /**
   * 排序即发布优先级：先按上课时刻，再按星期几，最后按课表 guid 兜底。
   *
   * 两种形态统一按上课时刻排，不按时间点下标：折叠形态跨课表，时间点下标没有
   * 共同含义（已置 -1）。上课时刻在两种形态下都是同一个语义量，且是截断该保留
   * 哪部分时唯一说得清的口径。
   *
   * 于是额度不够被截断时丢的是「一天里靠后的课」，而不是「某些天」——
   * 后者的症状是「周一三五有提醒、周二四没有」，用户完全无法自查。
   */
  private static sortForBudget(items: ReminderPlanItem[]): ReminderPlanItem[] {
    items.sort((left: ReminderPlanItem, right: ReminderPlanItem): number => {
      if (left.classStartSeconds !== right.classStartSeconds) {
        return left.classStartSeconds - right.classStartSeconds;
      }
      const leftDay: number = left.weekDays.length > 0 ? left.weekDays[0] : 0;
      const rightDay: number = right.weekDays.length > 0 ? right.weekDays[0] : 0;
      if (leftDay !== rightDay) {
        return leftDay - rightDay;
      }
      if (left.timePointIndex !== right.timePointIndex) {
        return left.timePointIndex - right.timePointIndex;
      }
      if (left.planGuid !== right.planGuid) {
        return left.planGuid < right.planGuid ? -1 : 1;
      }
      return 0;
    });
    return items;
  }

  private static compareNumbers(left: number, right: number): number {
    return left - right;
  }
}

/** 编排的中间产物：一张课表 + 一个星期几。 */
class ReminderSource {
  plan: ClassPlan = new ClassPlan();
  planGuid: string = '';
  planName: string = '';
  /** TimeRule.weekDay，.NET 口径 0=周日 … 6=周六。 */
  weekDay: number = 0;
  layout: TimeLayout = new TimeLayout();
}

/** 课表里一个「真的排了课」的时间点。 */
class ReminderSlot {
  timePointIndex: number = -1;
  classSlot: number = -1;
  startSeconds: number = 0;
  /** 已经查好的科目。classSlotsOf 保证非空。 */
  subject: Subject = new Subject();
}
