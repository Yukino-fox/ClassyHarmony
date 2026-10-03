/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 档案编辑页的状态。
 *
 * 唯一的一份草稿
 * ------------
 * 编辑期间所有改动都落在内存里的草稿上，不碰磁盘。用户点「保存」才写盘。
 * 这不只是为了「取消」按钮能还原：写盘是原子替换（临时文件 + rename），
 * 每改一下就写一次的话，一次连续编辑要落盘几十次，而用户中途点「返回」
 * 就全没了。
 *
 * 草稿与基线的差就是「未保存的改动」
 * ----------------------------------
 * isDirty 直接拿 Profile.stringify(草稿) 和载入时的基线比，不设布尔标志。
 * 布尔标志的坑是「改了又改回原样」判不出来：用户把时间点从 08:00 拖到
 * 09:00 又拖回 08:00，标志还亮着，用户会以为有东西没保存而不敢退出。
 * 序列化比对没有这个状态 —— 字节一样就是不脏。
 *
 * 行的更新方式
 * ------------
 * 每次改动都整体重建全部行数组，而不是就地改某一行。理由有两个：
 *   1. 一次改动经常同时影响多处（改一节课的时间会改行标签、改摘要、改别的
 *      课表的引用数），逐处挑出来改必然漏一处，而漏掉的那处不报错，只是
 *      界面显示旧值。
 *   2. ArkUI V2 的依赖追踪靠 @Trace 上的引用变化触发，就地改字段不触发。
 * 代价是每次改动重算一遍，档案规模（几十行）下这点开销可以忽略。
 *
 * 改动层只在这里被调用
 * ------------------
 * 界面不直接碰 ScheduleMutations。所有改动都走本类的 public 方法，
 * 由本类负责 settle、重建行、刷新脏标记。这样漏调 settle 只可能发生在
 * 一个地方，而不是散落在几十个点击回调里。
 */

import { DateTimeValue, Guid, Profile, TempClassPlanGroupType } from 'common_shared';
import { t, tf } from 'common_core';
import {
  ClassPlanGroupRow,
  ClassPlanResolver,
  ClassPlanRow,
  EditorRows,
  EngineSettings,
  OrderedScheduleRow,
  ProfileRow,
  ScheduleMutations,
  SubjectRow,
  TimeLayoutRow
} from 'common_core';
import { AppClock } from '../common/AppClock';
import { defaultEngineSettings } from '../common/AppSettings';
import { ProfileRepository } from '../data/ProfileRepository';
import { ImportOutcome, ProfileTransfer, TransferOutcome } from '../data/ProfileTransfer';

/** 提示行显示多久（毫秒）。到点自动清空，避免旧提示一直挂着误导用户。 */
const STATUS_TTL_MS: number = 4000;

/**
 * 「这一项不改」的哨兵值。
 *
 * 界面上没法表达 undefined（文本框要么有内容要么空），而改动层用 undefined
 * 表示不改，两边必须有个翻译。选 -1 而不是 0：0 是合法时刻（午夜），
 * 拿它当哨兵的话用户就没法把时间点设到 00:00 了。
 */
const UNCHANGED: number = -1;

@ObservedV2
export class ScheduleEditorViewModel {
  // ------------------------------------------------------------ 视图数据

  /** 档案摘要。整体替换。 */
  @Trace profile: ProfileRow = new ProfileRow();

  /** 科目行。整体替换。 */
  @Trace subjects: SubjectRow[] = [];

  /** 时间表行。整体替换。 */
  @Trace timeLayouts: TimeLayoutRow[] = [];

  /** 课表行。整体替换。 */
  @Trace classPlans: ClassPlanRow[] = [];

  /** 课表群行。整体替换。 */
  @Trace groups: ClassPlanGroupRow[] = [];
  /** 预定课表行，按日期升序。见 EditorRows.orderedSchedules 的排序理由。 */
  @Trace orderedSchedules: OrderedScheduleRow[] = [];

  // -------------------------------------------------------------- 页面态

  /** 时间表页当前展开的那张表。空串表示没选。 */
  @Trace activeLayoutId: string = '';

  /** 排课页当前展开的那张表。空串表示没选。 */
  @Trace activePlanId: string = '';

  /** 是否有未保存的改动。 */
  @Trace isDirty: boolean = false;

  /** 底部提示行。空串表示不显示。 */
  @Trace statusText: string = '';

  /** 档案是否已成功载入。false 时界面显示载入中或错误。 */
  @Trace isReady: boolean = false;

  /** 载入失败的原因。空串表示没有错误。 */
  @Trace errorText: string = '';

  // ---------------------------------------------------------------- 内部

  private readonly clock: AppClock;
  private readonly repository: ProfileRepository;
  private draft: Profile = new Profile();
  /** 基线：上次载入或保存时的序列化结果。 */
  private baseline: string = '';
  private statusTimer: number = -1;
  /**
   * 档案写盘后的通知回调。
   *
   * 桌面卡片有自己的运行时，改了档案它不会自己知道。不通知的话用户回桌面看到的
   * 还是旧课表，而且旧数据带着「正在上课 语文」这种有时间感的文字，看起来完全可信 ——
   * 他不会怀疑卡片，只会以为刚才的保存没生效。
   *
   * 用注入而不是在这里直接调 widget 服务：ViewModel 不该知道桌面上有几张卡片，
   * 而要拿到 reloadAllForms 需要的 UIAbilityContext 也得从外面给。组合根
   * （AppServices）是唯一同时握有这两样的地方。
   */
  private profileSavedListener: (() => void) | undefined = undefined;

  constructor(clock: AppClock, repository: ProfileRepository) {
    this.clock = clock;
    this.repository = repository;
  }

  /** 注册「档案已写盘」回调。传 undefined 取消。 */
  onProfileSaved(listener: (() => void) | undefined): void {
    this.profileSavedListener = listener;
  }

  /**
   * 载入草稿。
   *
   * 载入后会先 settle 一次再取基线，所以打开编辑页不会立刻显示「未保存」。
   * settle 做的规范化（按预置科目补空格、归零散落的调课标记）留到首次保存
   * 时才写回磁盘 —— 与桌面版 RefreshClassesList 的时机一致。
   */
  load(): void {
    try {
      const loaded: Profile = this.repository.load();
      ScheduleMutations.settle(loaded);
      this.draft = loaded;
      this.baseline = Profile.stringify(loaded);
      this.errorText = '';
      this.isReady = true;
      this.activeLayoutId = this.firstLayoutId();
      this.activePlanId = this.firstPlanId();
      this.refreshDirty();
      this.rebuild();
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      this.errorText = tf('common_profile_load_failed', message);
      this.isReady = false;
    }
  }

  /** 丢弃改动，从磁盘重读。 */
  reload(): void {
    this.load();
    this.say(t('edit_discarded'));
  }

  /**
   * 写盘。
   *
   * @returns 是否写成功。失败时错误已写进 errorText。
   */
  save(): boolean {
    if (!this.isDirty) {
      this.say(t('edit_nothing_to_save'));
      return true;
    }
    try {
      this.repository.save(this.draft);
      this.baseline = Profile.stringify(this.draft);
      this.refreshDirty();
      this.say(t('edit_saved'));
      this.notifySaved();
      return true;
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      this.errorText = tf('common_save_failed', message);
      return false;
    }
  }

  /**
   * 通知外部「档案已落盘」。
   *
   * 通知本身失败绝不影响 save 的返回值：卡片晚几分钟更新只是「卡片旧了一点」，
   * 而让保存报失败会让用户以为自己的课表没存上，进而重复操作甚至放弃保存。
   */
  private notifySaved(): void {
    const listener: (() => void) | undefined = this.profileSavedListener;
    if (listener === undefined) {
      return;
    }
    try {
      listener();
    } catch (err) {
      // 同上：吞掉。调用方（AppServices）自己会记日志。
    }
  }

  // ------------------------------------------------------------ 档案级

  /** 改名档案。 */
  renameProfile(name: string): boolean {
    return this.run(t('edit_profile_renamed'), (): boolean => {
      return ScheduleMutations.renameProfile(this.draft, name);
    });
  }

  // -------------------------------------------------------------- 科目

  /** 新建科目。返回新科目的 guid，供界面展开到那一行。 */
  addSubject(name: string): string {
    let created: string = '';
    this.run(t('edit_subject_added'), (): boolean => {
      created = ScheduleMutations.addSubject(this.draft, name).toString();
      return true;
    });
    return created;
  }

  renameSubject(guid: string, name: string): boolean {
    return this.run(t('edit_subject_renamed'), (): boolean => {
      return ScheduleMutations.renameSubject(this.draft, Guid.fromCanonical(guid), name);
    });
  }

  setSubjectTeacher(guid: string, teacherName: string): boolean {
    return this.run(t('edit_teacher_updated'), (): boolean => {
      return ScheduleMutations.setSubjectTeacher(this.draft, Guid.fromCanonical(guid), teacherName);
    });
  }

  setSubjectInitial(guid: string, initial: string): boolean {
    return this.run(t('edit_shortname_updated'), (): boolean => {
      return ScheduleMutations.setSubjectInitial(this.draft, Guid.fromCanonical(guid), initial);
    });
  }

  setSubjectOutDoor(guid: string, isOutDoor: boolean): boolean {
    return this.run(t('edit_updated'), (): boolean => {
      return ScheduleMutations.setSubjectOutDoor(this.draft, Guid.fromCanonical(guid), isOutDoor);
    });
  }

  moveSubject(guid: string, delta: number): boolean {
    return this.run(t('edit_reordered'), (): boolean => {
      return ScheduleMutations.moveSubject(this.draft, Guid.fromCanonical(guid), delta);
    });
  }

  removeSubject(guid: string): boolean {
    return this.run(t('edit_subject_deleted'), (): boolean => {
      return ScheduleMutations.removeSubject(this.draft, Guid.fromCanonical(guid));
    });
  }

  // ------------------------------------------------------------ 时间表

  /** 新建时间表，返回其 guid。 */
  addTimeLayout(name: string): string {
    let created: string = '';
    this.run(t('edit_timelayout_added'), (): boolean => {
      created = ScheduleMutations.addTimeLayout(this.draft, name).toString();
      return true;
    });
    return created;
  }

  renameTimeLayout(guid: string, name: string): boolean {
    return this.run(t('edit_timelayout_renamed'), (): boolean => {
      return ScheduleMutations.renameTimeLayout(this.draft, Guid.fromCanonical(guid), name);
    });
  }

  removeTimeLayout(guid: string): boolean {
    return this.run(t('edit_timelayout_deleted'), (): boolean => {
      return ScheduleMutations.removeTimeLayout(this.draft, Guid.fromCanonical(guid));
    });
  }

  /** 展开一张时间表。传空串表示收起。 */
  openTimeLayout(guid: string): void {
    this.activeLayoutId = guid;
  }

  /**
   * 追加一个时间点。
   *
   * @param timeType 0 上课 / 1 课间 / 2 分割线 / 3 行动
   * @param startSeconds 开始时刻（秒）
   * @param minutes 时长（分钟）
   */
  addTimePoint(guid: string, timeType: number, startSeconds: number, minutes: number): boolean {
    return this.run(t('edit_period_added'), (): boolean => {
      return ScheduleMutations.addTimePoint(this.draft, Guid.fromCanonical(guid), timeType,
        startSeconds, minutes);
    });
  }

  removeTimePoint(guid: string, rowIndex: number): boolean {
    return this.run(t('edit_period_deleted'), (): boolean => {
      return ScheduleMutations.removeTimePoint(this.draft, Guid.fromCanonical(guid), rowIndex);
    });
  }

  moveTimePoint(guid: string, rowIndex: number, delta: number): boolean {
    return this.run(t('edit_reordered'), (): boolean => {
      return ScheduleMutations.moveTimePoint(this.draft, Guid.fromCanonical(guid), rowIndex, delta);
    });
  }

  /** 按开始时刻重排整张时间表。 */
  sortTimeLayout(guid: string): boolean {
    return this.run(t('edit_reordered_by_period'), (): boolean => {
      return ScheduleMutations.sortTimeLayout(this.draft, Guid.fromCanonical(guid));
    });
  }

  /**
   * 改一个时间点。
   *
   * -1 表示「这一项不改」。这不是随便定的约定：改动的底层用 undefined 表示
   * 不改，界面上没法表达 undefined（文本框要么有内容要么空），所以在这里
   * 翻译一次。忘了翻译的话 -1 秒会被当成时刻写进去，时间点跑到前一天 23:59:59。
   *
   * @param timeType 时段类型 0 上课 / 1 课间 / 2 分割线 / 3 行动
   * @param startSeconds 新的开始时刻（秒）；传 -1 表示不改
   * @param minutes 新的时长（分钟）；传 -1 表示不改
   * @param breakName 新的课间名；传空串表示清空（清空是合法操作）
   */
  updateTimePoint(guid: string, rowIndex: number, timeType: number, startSeconds: number,
    minutes: number, breakName: string): boolean {
    return this.run(t('edit_period_updated'), (): boolean => {
      return ScheduleMutations.updateTimePoint(this.draft, Guid.fromCanonical(guid), rowIndex,
        timeType, startSeconds === UNCHANGED ? undefined : startSeconds,
        minutes === UNCHANGED ? undefined : minutes, breakName);
    });
  }

  /**
   * 设 / 清某个时间点的预置科目。
   *
   * @param subjectId 科目 guid；传空串表示清除预置
   * @param isHideDefault 是否隐藏预置的显示
   */
  setDefaultClass(guid: string, rowIndex: number, subjectId: string,
    isHideDefault: boolean): boolean {
    return this.run(t('edit_preset_subjects_updated'), (): boolean => {
      return ScheduleMutations.setDefaultClass(this.draft, Guid.fromCanonical(guid), rowIndex,
        Guid.fromCanonical(subjectId), isHideDefault);
    });
  }

  // -------------------------------------------------------------- 课表

  /** 新建课表，返回其 guid。 */
  addClassPlan(timeLayoutId: string, name: string): string {
    let created: string = '';
    this.run(t('edit_schedule_added'), (): boolean => {
      created = ScheduleMutations.addClassPlan(this.draft, Guid.fromCanonical(timeLayoutId),
        name).toString();
      return true;
    });
    return created;
  }

  /** 展开一张课表。传空串表示收起。 */
  openClassPlan(guid: string): void {
    this.activePlanId = guid;
  }

  renameClassPlan(guid: string, name: string): boolean {
    return this.run(t('edit_schedule_renamed'), (): boolean => {
      return ScheduleMutations.renameClassPlan(this.draft, Guid.fromCanonical(guid), name);
    });
  }

  removeClassPlan(guid: string): boolean {
    return this.run(t('edit_schedule_deleted'), (): boolean => {
      return ScheduleMutations.removeClassPlan(this.draft, Guid.fromCanonical(guid));
    });
  }

  setClassPlanEnabled(guid: string, isEnabled: boolean): boolean {
    return this.run(t('edit_updated'), (): boolean => {
      return ScheduleMutations.setClassPlanEnabled(this.draft, Guid.fromCanonical(guid), isEnabled);
    });
  }

  setClassPlanTimeLayout(guid: string, timeLayoutId: string): boolean {
    return this.run(t('edit_timelayout_bound'), (): boolean => {
      return ScheduleMutations.setClassPlanTimeLayout(this.draft, Guid.fromCanonical(guid),
        Guid.fromCanonical(timeLayoutId));
    });
  }

  setClassPlanGroup(guid: string, groupId: string): boolean {
    return this.run(t('edit_group_moved'), (): boolean => {
      return ScheduleMutations.setClassPlanGroup(this.draft, Guid.fromCanonical(guid),
        Guid.fromCanonical(groupId));
    });
  }

  /** 改课表的单双周规则。 */
  setClassPlanRule(guid: string, weekDay: number, weekCountDiv: number,
    weekCountDivTotal: number): boolean {
    return this.run(t('edit_rotation_updated'), (): boolean => {
      return ScheduleMutations.setClassPlanRule(this.draft, Guid.fromCanonical(guid), weekDay,
        weekCountDiv, weekCountDivTotal);
    });
  }

  /**
   * 排课 / 清空某一节课。
   *
   * @param slot 课次下标
   * @param subjectId 科目 guid；传空串表示清空这节课
   */
  setClassSubject(guid: string, slot: number, subjectId: string): boolean {
    return this.run(t('edit_class_filled'), (): boolean => {
      return ScheduleMutations.setClassSubject(this.draft, Guid.fromCanonical(guid), slot,
        Guid.fromCanonical(subjectId));
    });
  }

  setClassEnabled(guid: string, slot: number, isEnabled: boolean): boolean {
    return this.run(t('edit_updated'), (): boolean => {
      return ScheduleMutations.setClassEnabled(this.draft, Guid.fromCanonical(guid), slot, isEnabled);
    });
  }

  setClassChanged(guid: string, slot: number, isChanged: boolean): boolean {
    return this.run(t('edit_updated'), (): boolean => {
      return ScheduleMutations.setClassChanged(this.draft, Guid.fromCanonical(guid), slot, isChanged);
    });
  }

  // ------------------------------------------------------------ 叠加课表

  /** 以某张课表为源建一张叠加课表。 */
  createOverlay(sourceGuid: string, name: string): boolean {
    return this.run(t('edit_overlay_created'), (): boolean => {
      return ScheduleMutations.createOverlayClassPlan(this.draft, Guid.fromCanonical(sourceGuid),
        name) !== undefined;
    });
  }

  setClassPlanOverlayEnabled(isEnabled: boolean): boolean {
    return this.run(t('edit_overlay_toggled'), (): boolean => {
      return ScheduleMutations.setClassPlanOverlayEnabled(this.draft, isEnabled);
    });
  }

  // -------------------------------------------------------------- 课表群

  /** 新建课表群，返回其 guid。 */
  addClassPlanGroup(name: string): string {
    let created: string = '';
    this.run(t('edit_group_added'), (): boolean => {
      created = ScheduleMutations.addClassPlanGroup(this.draft, name).toString();
      return true;
    });
    return created;
  }

  renameClassPlanGroup(guid: string, name: string): boolean {
    return this.run(t('edit_group_renamed'), (): boolean => {
      return ScheduleMutations.renameClassPlanGroup(this.draft, Guid.fromCanonical(guid), name);
    });
  }

  /** 删除课表群，群内课表一并删除。 */
  deleteClassPlanGroup(guid: string): boolean {
    return this.run(t('edit_group_deleted'), (): boolean => {
      return ScheduleMutations.deleteClassPlanGroup(this.draft, Guid.fromCanonical(guid));
    });
  }

  /** 解散课表群，群内课表移到默认群。 */
  disbandClassPlanGroup(guid: string): boolean {
    return this.run(t('edit_group_dissolved'), (): boolean => {
      return ScheduleMutations.disbandClassPlanGroup(this.draft, Guid.fromCanonical(guid));
    });
  }

  selectClassPlanGroup(guid: string): boolean {
    return this.run(t('edit_group_switched'), (): boolean => {
      return ScheduleMutations.selectClassPlanGroup(this.draft, Guid.fromCanonical(guid));
    });
  }

  // -------------------------------------------------------- 临时 / 预定

  /**
   * 启用临时课表：按临时群选中的课表，在指定日期之前一直生效。
   *
   * @param planId 要临时启用的课表 guid
   * @param from 生效起点
   */
  applyTempClassPlan(planId: string, from: DateTimeValue): boolean {
    return this.run(t('edit_temp_enabled'), (): boolean => {
      return ScheduleMutations.applyTempClassPlan(this.draft, Guid.fromCanonical(planId), from);
    });
  }

  cancelTempClassPlan(): void {
    this.run(t('edit_temp_canceled'), (): boolean => {
      ScheduleMutations.cancelTempClassPlan(this.draft);
      return true;
    });
  }

  /** 启用临时课表群。 */
  applyTempClassPlanGroup(groupId: string, expire: DateTimeValue, type: number): boolean {
    return this.run(t('edit_temp_group_enabled'), (): boolean => {
      const kind: TempClassPlanGroupType = type === 1
        ? TempClassPlanGroupType.Override : TempClassPlanGroupType.Inherit;
      return ScheduleMutations.applyTempClassPlanGroup(this.draft, Guid.fromCanonical(groupId),
        expire, kind);
    });
  }

  cancelTempClassPlanGroup(): void {
    this.run(t('edit_temp_group_canceled'), (): boolean => {
      ScheduleMutations.cancelTempClassPlanGroup(this.draft);
      return true;
    });
  }

  /** 给某一天预定一张课表。 */
  setOrderedSchedule(date: DateTimeValue, planId: string | undefined): boolean {
    return this.run(t('edit_booking_set'), (): boolean => {
      const id: Guid | undefined = planId === undefined || planId.length === 0
        ? undefined : Guid.fromCanonical(planId);
      return ScheduleMutations.setOrderedSchedule(this.draft, date, id);
    });
  }

  // ---------------------------------------------------------- 导入导出

  /**
   * 导出当前草稿。
   *
   * @param context UIAbility 的 context，给文件选择器用
   * @returns 是否导出成功（用户取消也算「没出错」，返回 true）
   */
  async exportTo(context: Object): Promise<boolean> {
    try {
      const outcome: TransferOutcome =
        await ProfileTransfer.exportProfile(this.asContext(context), this.draft);
      if (outcome.canceled) {
        this.say(t('edit_export_canceled'));
        return true;
      }
      this.say(t('edit_exported'));
      return true;
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      this.errorText = tf('common_export_failed', message);
      return false;
    }
  }

  /**
   * 导入档案，替换整份草稿。
   *
   * 解析失败时抛上来的错原样显示在 errorText 里，草稿保持原样不动。
   * 「保持原样」不等于「静默」—— 一定会报出来，用户不会误以为导入成功。
   *
   * @param context UIAbility 的 context，给文件选择器用
   * @returns 是否导入成功
   */
  async importFrom(context: Object): Promise<boolean> {
    try {
      const outcome: ImportOutcome = await ProfileTransfer.importProfile(this.asContext(context));
      if (outcome.canceled) {
        this.say(t('edit_import_canceled'));
        return true;
      }
      this.adopt(outcome.profile);
      this.say(t('edit_imported_save'));
      return true;
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      this.errorText = tf('common_import_failed', message);
      return false;
    }
  }

  // -------------------------------------------------------------- 取行

  /** 展开中的时间表行；没展开返回 undefined。 */
  activeTimeLayout(): TimeLayoutRow | undefined {
    for (const row of this.timeLayouts) {
      if (row.guid === this.activeLayoutId) {
        return row;
      }
    }
    return undefined;
  }

  /** 展开中的课表行；没展开返回 undefined。 */
  activeClassPlan(): ClassPlanRow | undefined {
    for (const row of this.classPlans) {
      if (row.guid === this.activePlanId) {
        return row;
      }
    }
    return undefined;
  }

  // -------------------------------------------------------------- 内部

  /**
   * 所有改动的唯一入口。
   *
   * 三件事一件不漏：跑动作、settle、重建行 + 刷新脏标记。
   * 顺序也不能改：settle 必须在动作之后（它要看到动作的结果），
   * 重建必须在 settle 之后（行是从 settle 后的档案推出来的）。
   *
   * @param message 成功时的提示文案
   * @param action 改动动作，返回 false 表示没改成（界面提示会换成失败文案）
   */
  private run(message: string, action: () => boolean): boolean {
    if (!this.isReady) {
      return false;
    }
    const changed: boolean = action();
    // settle 无条件跑：即使动作返回 false 也要跑，因为上一个动作可能留下了
    // 派生量没刷新的状态（比如刚删了时间表，绑定它的课表还没解绑派生量）
    ScheduleMutations.settle(this.draft);
    this.repairSelection();
    this.refreshDirty();
    this.rebuild();
    this.say(changed ? message : t('edit_nothing_to_change'));
    return changed;
  }

  /**
   * 换一份草稿。
   *
   * 基线重设成新草稿自己，所以导入后 isDirty 为 false —— 这不对吗？对：
   * 导入是一次性的整体替换，导入进来的内容就是用户要的基线，之后再改才会脏。
   */
  private adopt(profile: Profile): void {
    ScheduleMutations.settle(profile);
    this.draft = profile;
    this.baseline = Profile.stringify(profile);
    this.errorText = '';
    this.isReady = true;
    this.activeLayoutId = this.firstLayoutId();
    this.activePlanId = this.firstPlanId();
    this.refreshDirty();
    this.rebuild();
  }

  /** 删掉当前展开的对象后，展开项会指向已不存在的东西，把选择修回第一个。 */
  private repairSelection(): void {
    if (this.activeLayoutId.length > 0 && !this.hasLayout(this.activeLayoutId)) {
      this.activeLayoutId = this.firstLayoutId();
    }
    if (this.activePlanId.length > 0 && !this.hasPlan(this.activePlanId)) {
      this.activePlanId = this.firstPlanId();
    }
  }

  private hasLayout(guid: string): boolean {
    for (const row of this.timeLayouts) {
      if (row.guid === guid) {
        return true;
      }
    }
    return false;
  }

  private hasPlan(guid: string): boolean {
    for (const row of this.classPlans) {
      if (row.guid === guid) {
        return true;
      }
    }
    return false;
  }

  private firstLayoutId(): string {
    for (const row of this.timeLayouts) {
      return row.guid;
    }
    return '';
  }

  private firstPlanId(): string {
    for (const row of this.classPlans) {
      return row.guid;
    }
    return '';
  }

  private refreshDirty(): void {
    this.isDirty = Profile.stringify(this.draft) !== this.baseline;
  }

  /**
   * 重建全部行数组。
   *
   * 「今天生效」交给 ClassPlanResolver 判定，这里只负责把结果传下去。
   * 自己重写一遍判据的话，两处判据迟早会漂，而漂了之后界面会标着 A 说今天上 B，
   * 这种不一致只有细看才发现。
   */
  private rebuild(): void {
    const settings: EngineSettings = defaultEngineSettings(this.clock.now());
    const resolved = ClassPlanResolver.resolve(this.draft, this.clock.now(), settings);
    const activeId: string = resolved.plan === undefined ? '' : resolved.guid.toString();

    this.profile = EditorRows.profile(this.draft);
    this.subjects = EditorRows.subjects(this.draft);
    this.timeLayouts = EditorRows.timeLayouts(this.draft);
    this.classPlans = EditorRows.classPlans(this.draft, activeId);
    this.groups = EditorRows.classPlanGroups(this.draft);
    this.orderedSchedules =
      EditorRows.orderedSchedules(this.draft, settings, this.clock.now());
  }

  /**
   * 底部提示。带自动消失。
   *
   * 不自动消失的话，上一条「已保存」会一直挂着，用户接着做别的操作后
   * 看到它会以为刚才那次改动又成功了。
   */
  private say(text: string): void {
    this.statusText = text;
    if (this.statusTimer >= 0) {
      clearTimeout(this.statusTimer);
    }
    this.statusTimer = setTimeout(() => {
      this.statusText = '';
      this.statusTimer = -1;
    }, STATUS_TTL_MS);
  }

  /** 把调用方给的 context 收窄成 UIAbilityContext。 */
  private asContext(context: Object): import('@kit.AbilityKit').common.UIAbilityContext {
    return context as import('@kit.AbilityKit').common.UIAbilityContext;
  }
}
