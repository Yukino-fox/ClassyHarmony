/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 课表页的状态。
 *
 * 这个类是页面与引擎之间唯一的桥。引擎是纯函数（「档案 + 时刻 -> 网格」），
 * 所以状态管理这一侧只做三件事：定时取时刻、调引擎、把结果换成新对象塞进 @Trace。
 *
 * 换新对象而不是就地改，是为了让 ArkUI V2 的依赖追踪生效：@Trace 打在 grid 上，
 * 整体替换引用即触发重绘，就地改字段则不会。
 *
 * 轮询的粒度
 * ----------
 * 15 秒一次。课表高亮只会在跨过时间点边界时变化，15 秒足够及时（最短的时间点
 * 也有几十秒），又不会让设备整天醒着。
 *
 * 每次轮询都重算整个网格看起来浪费，但重算本身很轻（7 次选课 + 几十个格子的
 * 字符串拼接），真正贵的是把新对象交给状态管理引发重绘。所以重算后先用
 * ScheduleGrid.displaySignature() 比一次，相同就不动 grid —— 绝大多数 tick
 * 什么都不会发生。
 */

import { ClassPlan, DateTimeValue, Profile, Subject, TimeLayout, TimeLayoutItem, TimeSpanValue, TimeState } from 'common_shared';
import { t } from 'common_core';
import { EngineSettings, LessonsEngine, LessonsSnapshot, ScheduleGrid, ScheduleGridBuilder } from 'common_core';
import { AppClock } from '../common/AppClock';
import { ProfileRepository } from '../data/ProfileRepository';
import { defaultEngineSettings } from '../common/AppSettings';

/** 轮询间隔（毫秒）。 */
const TICK_MS: number = 15000;

/** 顶部横幅的文案与配色依据，由快照归约出来，界面不直接读引擎快照。 */
export class LessonBanner {
  /** 主标题：课程名 / 「课间」/「已放学」等。 */
  title: string = '';

  /** 副标题：下一节课、倒计时、或空。 */
  subtitle: string = '';

  /** 强调色用途标记，界面据此取色。 */
  tone: number = BannerTone.Idle;
}

export class BannerTone {
  /** 无课时（放学 / 还没到校）。 */
  static readonly Idle: number = 0;
  /** 正在上课。 */
  static readonly OnClass: number = 1;
  /** 课间。 */
  static readonly Breaking: number = 2;
}

@ObservedV2
export class ClassTableViewModel {
  /** 当前展示的网格。整体替换，界面靠这个引用变化重绘。 */
  @Trace grid: ScheduleGrid = new ScheduleGrid();

  /** 顶部横幅。 */
  @Trace banner: LessonBanner = new LessonBanner();

  /** 手机单列形态下选中的那一天（行下标）。-1 表示跟随今天。 */
  @Trace selectedRowIndex: number = -1;

  /** 档案是否已成功载入。false 时界面显示载入中或错误。 */
  @Trace isReady: boolean = false;

  /** 载入失败的原因；为空表示没有错误。 */
  @Trace errorText: string = '';

  private readonly clock: AppClock;
  private readonly repository: ProfileRepository;
  private settings: EngineSettings;
  private profile: Profile = new Profile();
  private timer: number = -1;
  private lastSignature: string = '';
  private widgetJumpConsumed: boolean = false;

  constructor(clock: AppClock, repository: ProfileRepository) {
    this.clock = clock;
    this.repository = repository;
    this.settings = defaultEngineSettings(clock.now());
  }

  /** 载入档案并开始轮询。重复调用只会重读一次档案，不会叠加定时器。 */
  start(): void {
    this.reloadProfile();
    if (this.timer < 0) {
      this.timer = setInterval(() => {
        this.tick();
      }, TICK_MS);
    }
    this.tick();
  }

  stop(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  /** 从磁盘重读档案。编辑动作（P4）与小组件通知触发的刷新都走这里。 */
  reloadProfile(): void {
    try {
      const loaded: Profile = this.repository.load();
      // 桌面版每帧都刷派生量（RefreshTimeLayouts），这里改为载入后显式刷一次。
      loaded.refreshDerivedState();
      this.profile = loaded;
      this.errorText = '';
      this.isReady = true;
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      this.errorText = `档案读取失败：${message}`;
      this.isReady = false;
    }
  }

  /** 重新取时刻、重算网格。定时器与手动刷新都走这里。 */
  tick(): void {
    if (!this.isReady) {
      return;
    }
    const now: DateTimeValue = this.clock.now();
    // 单周起始日依赖「今天」，跨过零点时需要跟着重算，否则轮转会停在昨天。
    this.settings = defaultEngineSettings(now);

    const snapshot: LessonsSnapshot = LessonsEngine.compute(this.profile, this.settings, now);
    const next: ScheduleGrid = ScheduleGridBuilder.build(this.profile, this.settings, now, snapshot);

    const signature: string = next.displaySignature();
    if (signature !== this.lastSignature) {
      this.lastSignature = signature;
      this.grid = next;
      this.realignSelection(next);
    }
    this.banner = buildBanner(snapshot);
  }

  /** 选中的那一天。-1（跟随今天）解析成今天那行；跨零点后自动落到新的今天。 */
  effectiveRowIndex(): number {
    if (this.selectedRowIndex >= 0 && this.selectedRowIndex < this.grid.rows.length) {
      return this.selectedRowIndex;
    }
    return this.grid.todayRowIndex >= 0 ? this.grid.todayRowIndex : 0;
  }

  selectRow(index: number): void {
    if (index === this.effectiveRowIndex()) {
      // 再点一次已选中的那天，回到「跟随今天」。
      this.selectedRowIndex = this.grid.todayRowIndex;
      return;
    }
    this.selectedRowIndex = index;
  }

  /**
   * 定位到今天往后第 offset 天。桌面卡片跳进来时调。
   *
   * 走独立方法而不是复用 selectRow：selectRow 带「再点一次取消选择」的语义，
   * 而卡片跳转要求的是「明确落到那一天」，两者恰好相反 —— 复用会在 offset 为 0 时
   * 把选择清掉，表现为点卡片进应用后停在今天而不是今天那行的高亮态。
   *
   * 同一进程内只生效一次。router.getParams() 拿到的是本页生命周期内的常量，
   * 不做一次性消费的话，用户从编辑页返回时 onPageShow 又会跳一次，
   * 表现为「我看一眼编辑页，日期自己跳到明天了」。
   */
  focusDayFromWidget(offset: number): void {
    if (this.widgetJumpConsumed) {
      return;
    }
    this.widgetJumpConsumed = true;
    if (offset <= 0) {
      return;
    }
    const today: number = this.grid.todayRowIndex;
    const target: number = today + offset;
    if (today < 0 || target >= this.grid.rows.length) {
      return;
    }
    this.selectedRowIndex = target;
  }

  /** 网格换新之后修正选中行，避免行数变化时选中下标越界。 */
  private realignSelection(next: ScheduleGrid): void {
    if (this.selectedRowIndex < next.rows.length) {
      return;
    }
    this.selectedRowIndex = next.todayRowIndex;
  }
}

/**
 * 由引擎快照归约出顶部横幅。
 *
 * 倒计时口径照搬桌面版：上课中看「距课间」，不在上课则看「距下一节课」，
 * 另一个恒为 0。引擎已经算好这两个值，这里只负责挑一个并写成人话。
 */
function buildBanner(snapshot: LessonsSnapshot): LessonBanner {
  const banner: LessonBanner = new LessonBanner();
  if (!snapshot.isClassPlanLoaded) {
    banner.title = t('ctv_no_schedule');
    banner.subtitle = '添加课表后这里会显示今天的课程';
    return banner;
  }

  if (snapshot.state === TimeState.OnClass) {
    banner.tone = BannerTone.OnClass;
    banner.title = subjectName(snapshot.currentSubject);
    banner.subtitle = isRealTimePoint(snapshot, snapshot.nextBreakingTimeLayoutItem)
      ? countdown('距下课', snapshot.onBreakingTimeLeftTime)
      : t('ctv_no_break_after');
    return banner;
  }

  if (snapshot.state === TimeState.Breaking) {
    banner.tone = BannerTone.Breaking;
    banner.title = '课间';
    banner.subtitle = isRealTimePoint(snapshot, snapshot.nextClassTimeLayoutItem)
      ? countdown(t('ctv_until_next_class'), snapshot.onClassLeftTime)
      : t('ctv_no_more_class');
    return banner;
  }

  banner.tone = BannerTone.Idle;
  if (isRealTimePoint(snapshot, snapshot.nextClassTimeLayoutItem)) {
    banner.title = '还没开始上课';
    banner.subtitle = countdown(t('ctv_until_next_class'), snapshot.onClassLeftTime);
  } else {
    banner.title = t('ctv_after_school');
    banner.subtitle = '';
  }
  return banner;
}

/**
 * 判断快照里的时间点是真时间点还是「没有」哨兵。
 *
 * 必须用身份判定，不能看字段：TimeLayoutItem.empty() 就是 new TimeLayoutItem()，
 * 字段全是默认值，isClass() 还会因为 timeType 的默认是 0（上课）而返回 true。
 * 唯一可靠的区分是「它是否真的在那张时间表里」—— 引擎的 selectedIndex 用的
 * 也是这个办法。
 */
function isRealTimePoint(snapshot: LessonsSnapshot, item: TimeLayoutItem): boolean {
  const plan: ClassPlan | undefined = snapshot.currentClassPlan;
  if (plan === undefined) {
    return false;
  }
  const layout: TimeLayout | undefined = plan.resolveTimeLayout();
  if (layout === undefined) {
    return false;
  }
  return layout.layouts.indexOf(item) >= 0;
}

function countdown(prefix: string, left: TimeSpanValue): string {
  const minutes: number = Math.floor(left.toSeconds() / 60);
  const seconds: number = left.toSeconds() % 60;
  return `${prefix} ${minutes} 分 ${pad2(seconds)} 秒`;
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

function subjectName(subject: Subject): string {
  return subject.name.length === 0 ? '（无）' : subject.name;
}
