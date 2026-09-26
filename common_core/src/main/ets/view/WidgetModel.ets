/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 今日课程表小组件的视图数据。
 *
 * 为什么放在 common_core
 * --------------------
 * FormExtensionAbility 在 10 秒不活动之后就被系统回收，下次拉起是全新进程。
 * 于是小组件这条路上唯一能测的部分，就是「给定档案和时刻，算出该显示什么」，
 * 而它必须落在能跑 Node 测试台的模块里 —— 否则每次改一行显示逻辑都要装机。
 * 所以这里只有纯函数 WidgetBuilder.build，卡片 UI 那侧只负责把结果画出来。
 *
 * 显示「接下来」而不是「今天全部」
 * -------------------------------
 * 桌面上把整天的课都摊开是因为屏幕够大；小组件只有 2x4 / 4x4 两档，
 * 摊开一整天等于把最重要的两行埋在中间。所以这里从「此刻仍在进行或还没开始」
 * 的第一节开始往后排。用户的实际问题是「我下一节上什么」，不是「我上周三上什么」。
 *
 * 今天上完之后显示下一个有课的日子
 * ------------------------------
 * 放学后卡片就空着的话，它在桌面上一整天都是无用装饰。所以往后找 7 天，
 * 找到第一个有课的那天就显示它，并把日期标签换成「明天」「周一」之类。
 * 副作用正好是想要的：周末打开看到的是下周一，而不是一个空的周六。
 *
 * 不显示倒计时
 * ------------
 * 卡片的下一次系统级刷新最快只能约到 5 分钟（setFormNextRefreshTime 的下限）。
 * 在 5 分钟粒度下显示「距上课还有 3 分 12 秒」就是显示一个必然在错的东西。
 * 所以这里只显示固定的起止时刻和「正在上」这种不会过期的标记 —— 这两样在
 * 5 分钟粒度下永远是对的。nextRefreshMinutes 的作用是在真正会变的那一刻叫醒卡片，
 * 而不是让卡片自己数秒。
 *
 * nextRefreshMinutes 的自校正
 * --------------------------
 * 每次构建都按「当前这份显示内容下一次会变是多久」去申请下一次刷新，于是刷新时点
 * 天然跟着课表走，不需要额外的定时器或后台任务。夹在 [5, 720] 是因为平台下限 5 分钟；
 * 上限取 12 小时是因为一张课表不可能连续 12 小时没有任何时刻点变化。
 */

import {
  ClassPlan,
  DateTimeValue,
  JsonArray,
  JsonBoolean,
  JsonNode,
  JsonNumber,
  JsonObject,
  JsonReader,
  JsonString,
  JsonValue,
  JsonWriter,
  Profile,
  Subject,
  TimeLayout,
  TimeLayoutItem
} from 'common_shared';
import { ClassPlanResolver, ResolvedClassPlan, ResolvedSource } from '../engine/ClassPlanResolver';
import { EngineSettings } from '../engine/EngineSettings';
import { formatClock, weekDayName } from './TextFormat';

/** 卡片规格字符串。平台 form_config.json 里写的就是带星号的这种形式。 */
export class WidgetDimension {
  static readonly COMPACT: string = '2*4';
  static readonly ROOMY: string = '4*4';
  static readonly SMALL: string = '2*2';
  static readonly TINY: string = '1*1';
}

/**
 * 平台 setFormNextRefreshTime 的下限（分钟）。
 *
 * 写死在这里而不是让调用方处理：它是平台的事实，core 不该假装不知道，
 * 顺便让 nextRefreshMinutes 的返回值本身就可以直接传给平台。
 */
export const WIDGET_REFRESH_MIN_MINUTES: number = 5;

/** 申请刷新的上限（分钟）。12 小时足够覆盖任何作息。 */
export const WIDGET_REFRESH_MAX_MINUTES: number = 720;

/** 往后找有课日子的天数。一周足够覆盖所有作息，再多只是白跑。 */
const LOOKAHEAD_DAYS: number = 7;

/** 空课表时显示的占位文案，与课表网格一致。 */
const EMPTY_SUBJECT_TEXT: string = '（无）';

/** 小组件里的一节课。 */
export class WidgetLesson {
  /** 课次下标（0 起），也就是「第 N 节」的 N-1。 */
  classSlot: number = -1;

  /** 「第 1 节」。 */
  slotText: string = '';

  /** 「08:00」。 */
  startText: string = '';

  /** 「08:45」。 */
  endText: string = '';

  /** 「08:00-08:45」。 */
  rangeText: string = '';

  subjectName: string = '';
  teacherName: string = '';

  /** 这节课没有排科目。 */
  isEmpty: boolean = false;

  /** 调课 / 换课。 */
  isChangedClass: boolean = false;

  /** 就是此刻正在上的那节课。 */
  isCurrent: boolean = false;

  /** 接下来第一节。正在上的那节课不算「下一节」——它已经是「现在」了。 */
  isNext: boolean = false;
}

/**
 * 今日课程表小组件的全部显示内容。
 *
 * 所有字段都是标量或 WidgetLesson 数组：卡片 UI 不再做推导。
 * 推导留在 WidgetBuilder 里，纯函数、可单测、不会在卡片上冒出只在某机型复现的 bug。
 */
export class WidgetModel {
  /** 卡片规格，如 '2*4'。 */
  dimension: string = WidgetDimension.COMPACT;

  /** 没有任何可显示的内容。 */
  isEmpty: boolean = false;

  /** isEmpty 时给用户看的话，写清是「没有课表」还是「这周没课」。 */
  emptyHint: string = '';

  /** 「今天」/「明天」/「周一」。 */
  dayLabel: string = '';

  /** 「9月26日 周六」。 */
  dateText: string = '';

  /** 展示的那天距今天几天。0 = 今天。 */
  dayOffset: number = 0;

  /** 展示的那天用的是哪张课表。 */
  planName: string = '';

  /** 「临时」/「预定」/空。用了临时课表或预定课表时标出来，否则用户查不出课表为什么变了。 */
  planTag: string = '';

  /** 大字：正在上的科目，或接下来第一节的科目。 */
  headline: string = '';

  /** headline 下面那行小字：「正在上课」「08:00 上课」。 */
  headlineHint: string = '';

  /** 列表。 */
  lessons: WidgetLesson[] = [];

  /** lessons 里 isCurrent 的下标；没有则 -1。 */
  currentIndex: number = -1;

  /** lessons 里 isNext 的下标；没有则 -1。 */
  nextIndex: number = -1;

  /** 距下一次显示内容变化还有多少分钟，已夹到平台允许的区间。 */
  nextRefreshMinutes: number = WIDGET_REFRESH_MIN_MINUTES;

  /**
   * 展示指纹。用来判断「重新构建之后内容真的变了吗」。
   *
   * 组件每次 onUpdateForm 都会被拉起，拉起本身有成本（读文件 + 选课）。
   * 指纹相同就说明没什么可改的，此时可以省掉一次 updateForm 往返 ——
   * 那次往返会触发卡片重绘，而重绘是用户看得见的闪烁。
   */
  displaySignature(): string {
    const parts: string[] = [
      this.dimension, `${this.isEmpty}`, this.emptyHint, this.dayLabel,
      this.dateText, `${this.dayOffset}`, this.planName, this.planTag,
      this.headline, this.headlineHint, `${this.currentIndex}`, `${this.nextIndex}`
    ];
    for (const lesson of this.lessons) {
      parts.push(`${lesson.classSlot},${lesson.slotText},${lesson.startText},${lesson.endText},` +
        `${lesson.rangeText},${lesson.subjectName},${lesson.teacherName},${lesson.isEmpty},` +
        `${lesson.isChangedClass},${lesson.isCurrent},${lesson.isNext}`);
    }
    return parts.join('|');
  }
}

export class WidgetBuilder {
  /**
   * 算出小组件要显示什么。
   *
   * @param profile 已载入并 refreshDerivedState 的档案
   * @param settings 引擎参数（单周起始日等）
   * @param now 当前时刻
   * @param dimension 卡片规格，决定排几节
   */
  static build(profile: Profile, settings: EngineSettings, now: DateTimeValue,
    dimension: string = WidgetDimension.COMPACT): WidgetModel {
    const model: WidgetModel = new WidgetModel();
    model.dimension = dimension;

    const today: DateTimeValue = now.dateOnly();
    const todayLessons: DayLessons = WidgetBuilder.lessonsOf(profile, settings, today, now, true);

    if (todayLessons.lessons.length > 0) {
      // 此刻还在上的课 end > now，所以它必然在 remaining 里 ——
      // 「正在上的那节」永远出现在列表第一条，不存在它被筛掉的分支。
      WidgetBuilder.fill(model, today, 0, todayLessons, dimension);
      return model;
    }

    // 今天没有「此刻起还有的」课了。往后找一个有课的日子，让卡片继续有用。
    for (let offset: number = 1; offset <= LOOKAHEAD_DAYS; offset++) {
      const date: DateTimeValue = today.addDays(offset);
      const upcoming: DayLessons = WidgetBuilder.lessonsOf(profile, settings, date, now, false);
      if (upcoming.lessons.length === 0) {
        continue;
      }
      WidgetBuilder.fill(model, date, offset, upcoming, dimension);
      return model;
    }

    WidgetBuilder.fillEmpty(model, profile, settings, today);
    return model;
  }

  private static fillEmpty(model: WidgetModel, profile: Profile, settings: EngineSettings,
    today: DateTimeValue): void {
    model.isEmpty = true;
    model.dayLabel = '今天';
    model.dateText = dateTextOf(today);
    // 区分两种「空」：一张课表都没有，是「还没配」；课表有但一周内没有一节课
    // 可上，是「放假了」。两者的下一步动作完全不同，提示不能混。
    model.emptyHint = WidgetBuilder.hasAnyPlan(profile, settings, today) ? '这一周没有课' : '还没有课表';
    model.nextRefreshMinutes = WIDGET_REFRESH_MAX_MINUTES;
  }

  /** 未来 7 天里是否存在任何生效的课表。用于区分「没配」与「放假」。 */
  private static hasAnyPlan(profile: Profile, settings: EngineSettings, today: DateTimeValue): boolean {
    for (let offset: number = 0; offset <= LOOKAHEAD_DAYS; offset++) {
      const resolved: ResolvedClassPlan =
        ClassPlanResolver.resolve(profile, today.addDays(offset), settings);
      if (resolved.plan !== undefined) {
        return true;
      }
    }
    return false;
  }

  /** 把某一天的课装进模型。fromNow 为 undefined 表示那天不是今天，不做「正在上」判定。 */
  private static fill(model: WidgetModel, date: DateTimeValue, offset: number, day: DayLessons,
    dimension: string): void {
    const capacity: number = capacityOf(dimension);
    model.lessons = day.lessons.slice(0, capacity);
    model.dateText = dateTextOf(date);
    model.dayOffset = offset;
    model.planName = day.planName;
    model.planTag = tagOf(day.source);
    model.dayLabel = dayLabelFor(offset, date);

    if (model.lessons.length === 0) {
      // 理论上到不了这里（调用方已过滤空列表），但空数组进 UI 会渲染成一片
      // 没有任何解释的空白，比显示一句「没有课」更难排查。
      model.isEmpty = true;
      model.emptyHint = '没有课';
      return;
    }

    for (let i: number = 0; i < model.lessons.length; i++) {
      if (model.lessons[i].isCurrent) {
        model.currentIndex = i;
      }
      if (model.lessons[i].isNext) {
        model.nextIndex = i;
      }
    }

    if (model.currentIndex >= 0) {
      model.headline = model.lessons[model.currentIndex].subjectName;
      model.headlineHint = '正在上课';
    } else {
      const first: WidgetLesson = model.lessons[0];
      model.headline = first.subjectName;
      model.headlineHint = offset === 0 ? `${first.startText} 上课` : first.startText;
    }

    model.nextRefreshMinutes = WidgetBuilder.refreshMinutes(offset, model, day.nowSeconds);
  }

  /**
   * 下一次该叫醒卡片的时刻。
   *
   * 今天：正在上的课结束、下一节课开始，两者取先到者。
   * 未来某天：日期标签（今天 -> 明天）和第一节课开始都会改内容，取先到者。
   *
   * 未来那天用 `offset * 86400` 换算而不是逐日累加真实经过的秒数：夏令时切换那天
   * 相邻两个本地午夜相差 23 或 25 小时，两种算法会差 1 小时。这里要的是
   * 「大概什么时候该再看一眼」，而平台下界本来就是 5 分钟，差 1 小时不影响正确性
   * ——真正决定显示内容的第一节课开始时刻，那一项是精确的。
   *
   * 夹到 720 分钟的上限会在「离下一次变化很久」时多唤醒几次（醒来发现没变化，
   * 再睡 12 小时）。一天最多多两三次，且每次都只重算一次选课，不值得为省它
   * 把上限压到 1 小时 —— 那会让设备整天醒着，而 1 小时的收益只是少几次唤醒。
   */
  private static refreshMinutes(offset: number, model: WidgetModel, nowSeconds: number): number {
    let soonest: number = WIDGET_REFRESH_MAX_MINUTES;

    if (offset === 0) {
      if (model.currentIndex >= 0) {
        soonest = minutesBetween(nowSeconds, secondsOf(model.lessons[model.currentIndex].endText));
      } else if (model.nextIndex >= 0) {
        soonest = minutesBetween(nowSeconds, secondsOf(model.lessons[model.nextIndex].startText));
      }
    } else {
      // 到那天零点的秒数：日期标签会从「明天」变成「第 N 天后」。
      const toMidnight: number = offset * 86400 - nowSeconds;
      soonest = minutesBetween(nowSeconds, nowSeconds + toMidnight);
      if (model.lessons.length > 0) {
        const firstStart: number = secondsOf(model.lessons[0].startText) + offset * 86400;
        soonest = Math.min(soonest, minutesBetween(nowSeconds, firstStart));
      }
    }

    return clampRefresh(soonest);
  }

  /**
   * 取某天的课。
   *
   * `now` 始终是真实当前时刻，与 `date` 是不是今天无关：算「下一次该什么时候
   * 刷新」时需要的是「离现在多久」，而未来那几天的基准时刻是那天的零点，
   * 拿它当现在会把「还有 9 小时」算成「还有 23.5 小时」，卡片于是睡过头。
   *
   * isToday 为 true 时只返回「end >= now 时刻」的那些。比较用结束时刻而不是
   * 开始时刻：正在上的课开始时刻已经过去了，用开始时刻比较会把它筛掉，
   * 首位就变成了下一节课，「正在上 N」这个最有用的信息就没了。
   */
  private static lessonsOf(profile: Profile, settings: EngineSettings, date: DateTimeValue,
    now: DateTimeValue, isToday: boolean): DayLessons {
    const day: DayLessons = new DayLessons();
    day.isToday = isToday;
    day.nowSeconds = now.timeOfDaySeconds();

    const resolved: ResolvedClassPlan = ClassPlanResolver.resolve(profile, date, settings);
    const plan: ClassPlan | undefined = resolved.plan;
    if (plan === undefined) {
      return day;
    }
    day.planName = plan.name;
    day.source = resolved.source;

    const layout: TimeLayout | undefined = plan.resolveTimeLayout();
    if (layout === undefined) {
      return day;
    }

    const items: TimeLayoutItem[] = plan.validTimeLayoutItems();
    for (let i: number = 0; i < items.length; i++) {
      const item: TimeLayoutItem = items[i];
      if (!item.isClass()) {
        continue;
      }
      const layoutIndex: number = layout.layouts.indexOf(item);
      const slot: number = plan.getClassIndex(layoutIndex);
      if (slot < 0 || slot >= plan.classes.length) {
        continue;
      }
      const info = plan.classes[slot];
      if (!info.isEnabled) {
        // 停用 = 这节课不上。摆在列表里等于骗用户。
        continue;
      }

      const endSeconds: number = item.endTime.toSeconds();
      if (day.isToday && endSeconds < day.nowSeconds) {
        continue;
      }

      const lesson: WidgetLesson = new WidgetLesson();
      lesson.classSlot = slot;
      lesson.slotText = `第 ${slot + 1} 节`;
      lesson.startText = formatClock(item.startTime.toSeconds());
      lesson.endText = formatClock(endSeconds);
      lesson.rangeText = `${lesson.startText}-${lesson.endText}`;
      lesson.isChangedClass = info.isChangedClass;

      const subject: Subject | undefined = ClassPlanResolver.subjectAt(profile, plan, slot);
      if (subject === undefined) {
        lesson.isEmpty = true;
        lesson.subjectName = EMPTY_SUBJECT_TEXT;
      } else {
        lesson.subjectName = subject.name.length > 0 ? subject.name : EMPTY_SUBJECT_TEXT;
        lesson.teacherName = subject.teacherName;
      }

      const startSeconds: number = item.startTime.toSeconds();
      lesson.isCurrent = day.isToday && startSeconds <= day.nowSeconds && day.nowSeconds <= endSeconds;
      day.lessons.push(lesson);
    }

    // 列表里第一节还没到的，就是「下一节」。正在上的那节不算「下一节」——
    // 它已经是「现在」了，再标一个「下一节」等于把两件事说成两节不同的课。
    for (let i: number = 0; i < day.lessons.length; i++) {
      if (!day.lessons[i].isCurrent) {
        day.lessons[i].isNext = true;
        break;
      }
    }
    return day;
  }
}

/** 某一天的课在构建过程中的中间产物。 */
class DayLessons {
  lessons: WidgetLesson[] = [];
  planName: string = '';
  source: ResolvedSource = ResolvedSource.None;
  /** 构建的基准是否就是「今天」。 */
  isToday: boolean = false;
  /** 真实当前时刻的当日秒数。与展示的那天无关。 */
  nowSeconds: number = 0;
}

function tagOf(source: ResolvedSource): string {
  if (source === ResolvedSource.TempClassPlan) {
    return '临时';
  }
  if (source === ResolvedSource.OrderedSchedule) {
    return '预定';
  }
  return '';
}

/** 规格 -> 能排几节课。 */
function capacityOf(dimension: string): number {
  if (dimension === WidgetDimension.TINY) {
    return 1;
  }
  if (dimension === WidgetDimension.SMALL) {
    return 2;
  }
  if (dimension === WidgetDimension.ROOMY) {
    return 6;
  }
  return 3;
}

function dayLabelFor(offset: number, date: DateTimeValue): string {
  if (offset === 0) {
    return '今天';
  }
  if (offset === 1) {
    return '明天';
  }
  const weekDay: string = weekDayName(date.dayOfWeek());
  if (offset <= 6) {
    return weekDay.length > 0 ? weekDay : `${offset} 天后`;
  }
  return `${offset} 天后`;
}

function clampRefresh(minutes: number): number {
  if (isNaN(minutes) || minutes < WIDGET_REFRESH_MIN_MINUTES) {
    return WIDGET_REFRESH_MIN_MINUTES;
  }
  if (minutes > WIDGET_REFRESH_MAX_MINUTES) {
    return WIDGET_REFRESH_MAX_MINUTES;
  }
  return Math.ceil(minutes);
}

function minutesBetween(nowSeconds: number, targetSeconds: number): number {
  const delta: number = targetSeconds - nowSeconds;
  if (delta <= 0) {
    return WIDGET_REFRESH_MIN_MINUTES;
  }
  return Math.floor(delta / 60);
}

function dateTextOf(date: DateTimeValue): string {
  const weekDay: string = weekDayName(date.dayOfWeek());
  return `${date.month}月${date.day}日 ${weekDay}`.trim();
}

/** 'HH:mm' 折回秒。仅用于刚由 formatClock 生成的文本。 */
function secondsOf(clockText: string): number {
  const parts: string[] = clockText.split(':');
  if (parts.length < 2) {
    return 0;
  }
  const hours: number = parseInt(parts[0], 10);
  const minutes: number = parseInt(parts[1], 10);
  if (isNaN(hours) || isNaN(minutes)) {
    return 0;
  }
  return hours * 3600 + minutes * 60;
}

/**
 * 小组件数据的编解码。
 *
 * 卡片与 FormExtensionAbility 是两次独立执行，中间只隔一个 FormBindingData。
 * 那一层只能过 JSON，所以这里显式编码成字符串，而不是依赖框架对自定义类实例的
 * 序列化行为 —— 那个行为没有文档保证，跨版本一旦变了就是卡片一片空白，
 * 而且在装机之前完全测不出来。
 *
 * 用自研 JSON 内核而不是手拼字符串：转义规则（尤其是非 ASCII 一律 \uXXXX）
 * 已经在字节级往返测试里锁死，手拼等于重新发明一遍转义表。
 */
export class WidgetCodec {
  /** 编码成可以塞进 FormBindingData 的单行字符串。 */
  static encode(model: WidgetModel): string {
    const root: JsonObject = new JsonObject();
    root.set('dimension', new JsonString(model.dimension));
    root.set('isEmpty', new JsonBoolean(model.isEmpty));
    root.set('emptyHint', new JsonString(model.emptyHint));
    root.set('dayLabel', new JsonString(model.dayLabel));
    root.set('dateText', new JsonString(model.dateText));
    root.set('dayOffset', JsonNumber.ofInt(model.dayOffset));
    root.set('planName', new JsonString(model.planName));
    root.set('planTag', new JsonString(model.planTag));
    root.set('headline', new JsonString(model.headline));
    root.set('headlineHint', new JsonString(model.headlineHint));
    root.set('currentIndex', JsonNumber.ofInt(model.currentIndex));
    root.set('nextIndex', JsonNumber.ofInt(model.nextIndex));
    root.set('nextRefreshMinutes', JsonNumber.ofInt(model.nextRefreshMinutes));

    const lessons: JsonArray = new JsonArray();
    for (const lesson of model.lessons) {
      const item: JsonObject = new JsonObject();
      item.set('classSlot', JsonNumber.ofInt(lesson.classSlot));
      item.set('slotText', new JsonString(lesson.slotText));
      item.set('startText', new JsonString(lesson.startText));
      item.set('endText', new JsonString(lesson.endText));
      item.set('rangeText', new JsonString(lesson.rangeText));
      item.set('subjectName', new JsonString(lesson.subjectName));
      item.set('teacherName', new JsonString(lesson.teacherName));
      item.set('isEmpty', new JsonBoolean(lesson.isEmpty));
      item.set('isChangedClass', new JsonBoolean(lesson.isChangedClass));
      item.set('isCurrent', new JsonBoolean(lesson.isCurrent));
      item.set('isNext', new JsonBoolean(lesson.isNext));
      lessons.push(item);
    }
    root.set('lessons', lessons);
    return JsonWriter.writeCompact(root);
  }

  /**
   * 解码。
   *
   * 解析失败不抛异常，返回一份「正在载入」的模型：卡片组件渲染时不能因为数据
   * 读不出来就白屏，用户看到的应该是一句「载入中」，而异常只进日志。
   */
  static decode(text: string): WidgetModel {
    const loading: WidgetModel = new WidgetModel();
    loading.isEmpty = true;
    loading.emptyHint = '正在载入…';
    if (text.length === 0) {
      return loading;
    }

    let root: JsonObject | undefined;
    try {
      root = JsonValue.asObject(JsonReader.parse(text));
    } catch (err) {
      return loading;
    }
    if (root === undefined) {
      return loading;
    }

    const model: WidgetModel = new WidgetModel();
    model.dimension = str(root, 'dimension', model.dimension);
    model.isEmpty = bool(root, 'isEmpty', model.isEmpty);
    model.emptyHint = str(root, 'emptyHint', model.emptyHint);
    model.dayLabel = str(root, 'dayLabel', model.dayLabel);
    model.dateText = str(root, 'dateText', model.dateText);
    model.dayOffset = num(root, 'dayOffset', model.dayOffset);
    model.planName = str(root, 'planName', model.planName);
    model.planTag = str(root, 'planTag', model.planTag);
    model.headline = str(root, 'headline', model.headline);
    model.headlineHint = str(root, 'headlineHint', model.headlineHint);
    model.currentIndex = num(root, 'currentIndex', model.currentIndex);
    model.nextIndex = num(root, 'nextIndex', model.nextIndex);
    model.nextRefreshMinutes = num(root, 'nextRefreshMinutes', model.nextRefreshMinutes);

    const lessons: JsonArray | undefined = JsonValue.asArray(root.tryGet('lessons'));
    if (lessons !== undefined) {
      const items: JsonNode[] = lessons.values();
      for (const node of items) {
        const item: JsonObject | undefined = JsonValue.asObject(node);
        if (item === undefined) {
          continue;
        }
        const lesson: WidgetLesson = new WidgetLesson();
        lesson.classSlot = num(item, 'classSlot', lesson.classSlot);
        lesson.slotText = str(item, 'slotText', lesson.slotText);
        lesson.startText = str(item, 'startText', lesson.startText);
        lesson.endText = str(item, 'endText', lesson.endText);
        lesson.rangeText = str(item, 'rangeText', lesson.rangeText);
        lesson.subjectName = str(item, 'subjectName', lesson.subjectName);
        lesson.teacherName = str(item, 'teacherName', lesson.teacherName);
        lesson.isEmpty = bool(item, 'isEmpty', lesson.isEmpty);
        lesson.isChangedClass = bool(item, 'isChangedClass', lesson.isChangedClass);
        lesson.isCurrent = bool(item, 'isCurrent', lesson.isCurrent);
        lesson.isNext = bool(item, 'isNext', lesson.isNext);
        model.lessons.push(lesson);
      }
    }
    return model;
  }
}

function str(source: JsonObject, name: string, fallback: string): string {
  return JsonValue.asString(source.tryGet(name), fallback);
}

function bool(source: JsonObject, name: string, fallback: boolean): boolean {
  return JsonValue.asBoolean(source.tryGet(name), fallback);
}

function num(source: JsonObject, name: string, fallback: number): number {
  return JsonValue.asInt(source.tryGet(name), fallback);
}
