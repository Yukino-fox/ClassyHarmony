/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 课前提醒的同步：把 core 编排出来的计划落到平台的周期提醒上。
 *
 * 这一层只做胶水：编排（该排什么、几点触发、额度不够怎么降级）在
 * common_core/reminder/ReminderPlan.ets 的纯函数里，差量比对也在那里。
 * 这里负责的只有四件平台相关的事：
 *   1. 读设置、读档案
 *   2. 把 core 的 item 翻译成平台的 ReminderRequestCalendar
 *   3. 把平台的 ReminderInfo 翻译成 core 的 ReminderSnapshot
 *   4. 按「先取消、再更新、最后新建」的顺序执行
 *
 * 为什么要差量而不是全量重发
 * ------------------------
 * 全量（cancelAllReminders + 全部 publish）有两处会坏：
 *   - 中间那一瞬间平台上一条提醒都没有。用户恰好在这时候开机，看到的是
 *     「今天没有课」而不是「课表还没同步」—— 一个无法自查的假状态。
 *   - 每次都重发一遍全部提醒，而额度是 30 条（API 9 起；API 26 才提到 64）。
 *     高频同步会天天撞 1700002。
 * 差量同步把「发布次数」压到「真正变化的条数」，两次同步之间通常一条都不用动。
 *
 * 为什么执行顺序是「取消 → 更新 → 新建」
 * ------------------------------------
 * 额度是全局共享的，只有取消能腾出位置。形态从精确切到折叠时，旧形态的十几条
 * 全在待取消列表里，而新形态要占同样多的位置 —— 先新建就必然撞 1700002，
 * 而且是「同步失败」这种界面上看不出原因的结果。
 *
 * 为什么不做「同步窗口内也绝不漏」
 * ----------------------------
 * 差量同步下取消与新建之间仍有极短的窗口。这里接受它：本应用是每天最多几十次
 * 的低频操作，而为了消除一个亚秒窗口去做「先排新的、确认成功再删旧的」会把
 * 额度需求翻倍（30 条额度上双倍等于直接撞墙），得不偿失。真要彻底解决就得靠
 * addExcludeDate 逐条排除，属另一件事。
 *
 * 写提醒时的字段取舍见 requestOf() 的注释。
 */

import { common } from '@kit.AbilityKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import notification from '@ohos.notification';
import { BusinessError } from '@kit.BasicServicesKit';
import { DateTimeValue, Profile } from 'common_shared';
import {
  ReminderDiff,
  ReminderMode,
  ReminderPlan,
  ReminderPlanItem,
  ReminderPlanner,
  ReminderSnapshot
} from 'common_core';
import { AppPreferences } from '../common/AppPreferences';
import { ProfileRepository } from '../data/ProfileRepository';
import { ensureNotificationEnabled, ensureReminderChannel } from './ReminderChannels';
import { ReminderSettings } from './ReminderSettings';

/** 同步结果状态。 */
export const SYNC_OK: string = 'ok';
/** 通知权限没开，提醒一条也发不出去。 */
export const SYNC_NOTIFICATIONS_OFF: string = 'notificationsOff';
/** 已经有一次同步在跑，本次请求被合并进去了。 */
export const SYNC_BUSY: string = 'busy';
/** 出错了。message 里带原因。 */
export const SYNC_FAILED: string = 'failed';

/** 平台错误码：通知未开启。 */
const ERR_NOTIFICATION_OFF: number = 1700001;
/** 平台错误码：提醒条数超限。 */
const ERR_TOO_MANY: number = 1700002;

/** 一次同步的对外结果。界面上照它如实显示，不自己另算一套。 */
export class ReminderSyncResult {
  status: string = SYNC_OK;
  message: string = '';
  /** 实际采用的形态。 */
  mode: ReminderMode = ReminderMode.Specific;
  /** 编排出的条数（已截断到额度）。 */
  plannedCount: number = 0;
  /** 因为额度被丢掉的条数。 */
  droppedCount: number = 0;
  /** 实际新建成功的条数。 */
  publishedCount: number = 0;
  /** 实际更新成功的条数。 */
  refreshedCount: number = 0;
  /** 实际取消成功的条数。 */
  cancelledCount: number = 0;
  /** 执行中失败的条数。失败不影响其它条。 */
  failedCount: number = 0;
  /** 档案里有单双周课表。平台表达不了隔周，界面上要如实告知偏差。 */
  hasRotation: boolean = false;
}

/** 正在同步中的标志。用模块级而不是实例字段：跨实例才是真的在跑。 */
let busy: boolean = false;
/**
 * 「跑的过程中又有人要同步」。
 *
 * 最典型的来源是用户连着保存两次课表：第一次同步读到的是第一次保存后的档案，
 * 第二次请求如果被直接丢掉，结果就是提醒与档案不一致，而且没有下一次同步来
 * 纠正它（同步的触发点是启动、保存、改设置，不是定时轮询）。
 * 所以这里不丢弃而是置标志，让正在跑的那一轮结束后再跑一轮。
 */
let pending: boolean = false;

/**
 * 同步课前提醒。
 *
 * @param context UIAbility 的 context。发布提醒需要 bundleName / abilityName，
 *        所以必须是 UIAbilityContext 而不是基类 Context。
 * @param repository 档案仓库。
 * @param now 基准时刻，由调用方给，便于测试台复现。
 */
export async function syncReminders(context: common.UIAbilityContext,
  repository: ProfileRepository, now: DateTimeValue): Promise<ReminderSyncResult> {
  if (busy) {
    pending = true;
    const out: ReminderSyncResult = new ReminderSyncResult();
    out.status = SYNC_BUSY;
    return out;
  }
  busy = true;
  try {
    // 上限 3 轮：每一轮都由「保存 / 改设置」这类真实用户操作触发，
    // 连续三轮还在被要求同步已经不是正常路径了。设上限是为了让这个循环
    // 在任何情况下都会结束 —— 它跑在 ability 的生命周期里，不结束就等于
    // 卡住界面。
    let result: ReminderSyncResult = new ReminderSyncResult();
    for (let round: number = 0; round < 3; round++) {
      pending = false;
      result = await runOnce(context, repository, now);
      if (!pending) {
        break;
      }
    }
    return result;
  } finally {
    busy = false;
  }
}

/**
 * 取消全部课前提醒。设置里关掉总开关时走这里。
 *
 * 与同步里的「按 key 逐条取消」不同：关掉总开关时我们不再知道该保留哪些，
 * 而 cancelAllReminders 只影响本应用的提醒（getValidReminders 的文档口径），
 * 不会碰到别的应用。
 */
export async function cancelAllReminders(): Promise<boolean> {
  try {
    await reminderAgentManager.cancelAllReminders();
    return true;
  } catch (err) {
    console.warn(`[ClassyHarmony] 取消全部提醒失败：${err}`);
    return false;
  }
}

// ------------------------------------------------------------------ 内部

/** 真正跑一轮同步。 */
async function runOnce(context: common.UIAbilityContext, repository: ProfileRepository,
  now: DateTimeValue): Promise<ReminderSyncResult> {
  const result: ReminderSyncResult = new ReminderSyncResult();
  const settings: ReminderSettings = ReminderSettings.load(new AppPreferences(context));

  if (!settings.enabled) {
    // 总开关关掉：取消全部，而不是「不再新增」。留着旧提醒等于用户关了之后
    // 还在响，而界面上显示着「已关闭」。
    const ok: boolean = await cancelAllReminders();
    result.status = ok ? SYNC_OK : SYNC_FAILED;
    result.message = ok ? '已关闭课前提醒' : '关闭失败，稍后重试';
    return result;
  }

  // 权限与渠道的顺序不能换：渠道必须在第一条提醒发布之前就位，否则那条
  // 提醒落进默认渠道，而之后的注册对它无效。
  if (!(await ensureNotificationEnabled(context))) {
    result.status = SYNC_NOTIFICATIONS_OFF;
    result.message = '通知权限未开启，请在系统设置里允许本应用发送通知';
    return result;
  }
  await ensureReminderChannel(context);

  let profile: Profile;
  try {
    profile = repository.load();
  } catch (err) {
    // 档案读不出来时**不动**平台上的提醒。取消掉所有提醒看起来更干净，
    // 但「档案临时读不出来」（比如刚同步下来还没落盘）与「档案真的空了」
    // 在这里分不出来，前者不该导致用户丢掉今天的提醒。
    result.status = SYNC_FAILED;
    result.message = '课表读不出来，本次未改动提醒';
    return result;
  }

  const existing: ReminderAgentSnapshot[] = await readSnapshots(result);

  const plan: ReminderPlan = planFor(profile, now, settings, result);

  if (plan.items.length === 0 && plan.droppedCount === 0 && existing.length === 0) {
    result.mode = plan.mode;
    result.plannedCount = 0;
    result.message = '没有需要提醒的课';
    return result;
  }

  const snapshots: ReminderSnapshot[] = [];
  for (const entry of existing) {
    snapshots.push(entry.snapshot);
  }
  const diff: ReminderDiff = ReminderPlanner.diff(plan, snapshots, now);
  result.mode = plan.mode;
  result.plannedCount = plan.items.length;
  result.droppedCount = plan.droppedCount;
  result.hasRotation = plan.hasRotation;

  await applyDiff(context, diff, existing, result);
  return result;
}

/**
 * 选形态。
 *
 * 「自动」时先按精确编排，编排完才知道要不要截断 —— 排之前无法预知条数，
 * 只能先排一次看看。这不是浪费：排结果是纯函数，算完不用就丢。
 * 截断了就再试折叠形态，取丢得更少的那个；一样少就留在精确形态
 * （内容更具体，没有理由选信息更少的那个）。
 */
function planFor(profile: Profile, now: DateTimeValue, settings: ReminderSettings,
  result: ReminderSyncResult): ReminderPlan {
  const requested: ReminderMode | undefined = settings.requestedMode();
  if (requested !== undefined) {
    return ReminderPlanner.plan(profile, now, settings.advance(), requested,
      ReminderPlanner.QUOTA);
  }
  const specific: ReminderPlan = ReminderPlanner.plan(profile, now, settings.advance(),
    ReminderMode.Specific, ReminderPlanner.QUOTA);
  if (specific.droppedCount === 0) {
    return specific;
  }
  const collapsed: ReminderPlan = ReminderPlanner.plan(profile, now, settings.advance(),
    ReminderMode.Collapsed, ReminderPlanner.QUOTA);
  return collapsed.droppedCount < specific.droppedCount ? collapsed : specific;
}

/** 平台上的现状：id + core 认的快照。 */
class ReminderAgentSnapshot {
  reminderId: number = 0;
  snapshot: ReminderSnapshot = new ReminderSnapshot();
}

async function readSnapshots(result: ReminderSyncResult): Promise<ReminderAgentSnapshot[]> {
  const out: ReminderAgentSnapshot[] = [];
  try {
    // 用 getAllValidReminders 而不是 getValidReminders：后者返回 ReminderRequest，
    // 不带 reminderId，而取消与更新都必须有 id。
    const infos: reminderAgentManager.ReminderInfo[] =
      await reminderAgentManager.getAllValidReminders();
    for (const info of infos) {
      const entry: ReminderAgentSnapshot = new ReminderAgentSnapshot();
      entry.reminderId = info.reminderId;
      entry.snapshot = snapshotOfRequest(info.reminderReq);
      out.push(entry);
    }
  } catch (err) {
    // 读不到现状就**不动**。按「平台上一条都没有」去同步会重新发布全部提醒，
    // 而旧的还在，于是条数翻倍 —— 下一次同步就会撞额度。
    console.warn(`[ClassyHarmony] 读取现有提醒失败：${err}`);
    result.status = SYNC_FAILED;
    result.message = '读不到现有提醒，本次未改动';
  }
  return out;
}

/** 平台的请求转成 core 的快照。 */
function snapshotOfRequest(req: reminderAgentManager.ReminderRequest): ReminderSnapshot {
  const out: ReminderSnapshot = new ReminderSnapshot();
  out.key = req.groupId === undefined ? '' : req.groupId;
  out.title = req.title === undefined ? '' : req.title;
  out.content = req.content === undefined ? '' : req.content;

  if (req.reminderType !== reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR) {
    // 不是日历型（未来的实况窗倒计时可能是别的类型）就没有首次触发日。
    // key 留空，差异比对应会把它当成「不保留」而取消掉 —— 那些提醒由各自的
    // 通道管理，不该被课表同步顺手删掉又删不干净。
    out.key = '';
    return out;
  }
  // 往子类型收窄：ReminderRequestCalendar extends ReminderRequest，是合法的
  // 向下转型。上面那一步判过 reminderType，所以 dateTime 一定在。
  const calendar: reminderAgentManager.ReminderRequestCalendar =
    req as reminderAgentManager.ReminderRequestCalendar;
  out.triggerYear = calendar.dateTime.year;
  out.triggerMonth = calendar.dateTime.month;
  out.triggerDay = calendar.dateTime.day;
  return out;
}

/** core 的 item 翻译成平台的请求。 */
function requestOf(context: common.UIAbilityContext, item: ReminderPlanItem):
  reminderAgentManager.ReminderRequestCalendar {
  const trigger: DateTimeValue = item.trigger;
  const request: reminderAgentManager.ReminderRequestCalendar = {
    reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
    dateTime: {
      year: trigger.year,
      month: trigger.month,
      day: trigger.day,
      hour: trigger.hour,
      minute: trigger.minute,
      // 不给秒：我们的触发时刻本来就没有秒，平台按 0 处理。
      second: 0
    },
    // 口径转换在这里。档案是 0=周日…6=周六，平台是 1=周一…7=周日。
    daysOfWeek: ReminderPlanner.platformDaysOfWeek(item.weekDays),
    title: item.title,
    content: item.content,
    expiredContent: item.expiredContent,
    // 每条一个 key，于是通知不折叠，「不再提醒」也只影响它自己。
    // 若图省事全用同一个 groupId，用户点一次「不再提醒」会把全部提醒清掉。
    groupId: item.key,
    // notificationId 必须逐条不同：同 id 的提醒「后者覆盖前者」，
    // 而默认值是 0 —— 全部用默认值的话，只有最后一条能活下来。
    notificationId: notificationIdOf(item.key),
    slotType: SLOT_TYPE,
    wantAgent: {
      pkgName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name
    },
    // 用户点过就清掉，不留一堆「已处理」的提醒在通知中心。
    tapDismissed: true
  };
  return request;
}

/**
 * 提醒渠道类型。与 ReminderChannels 注册的那个一致。
 *
 * 这里用 @ohos.notification 的旧枚举，构建日志里那三条 deprecated 警告是预期的：
 * ReminderRequest.slotType 与 snoozeSlotType 这两个字段的类型就声明成已废弃的
 * notification.SlotType（since 9 废弃、建议改用 notificationManager.SlotType），
 * 而 ReminderRequest 上**没有**提供 notificationManager 版的替代字段 ——
 * 是 SDK 自己没跟上的。不设 slotType 的话提醒会落进应用默认渠道，我们注册的
 * 专用渠道形同虚设，所以宁可留这三条警告。
 *
 * 也不写裸数字 2：那样确实不警告，但 SDK 哪天改了枚举表就再也不会有编译错误
 * 提醒我们，而症状是「提醒莫名跑到别的渠道」，极难联想到这一行。
 */
const SLOT_TYPE: notification.SlotType = notification.SlotType.SERVICE_INFORMATION;

/**
 * 由 key 推出一个稳定的正整数当 notificationId。
 *
 * 稳定是必须的：不稳定的话同一条提醒每次重发都会换 id，旧的不会被覆盖，
 * 而通知中心里会堆出好几条一模一样的。
 *
 * FNV-1a 32 位，再掩掉符号位。碰撞的概率在 30 条量级上低到可以忽略，
 * 真撞了的后果也只是两条提醒共用一个通知号（显示时互相顶掉），不会丢提醒 ——
 * 而这正是 notificationId 的全部作用。
 */
function notificationIdOf(key: string): number {
  let hash: number = 0x811c9dc5;
  for (let i: number = 0; i < key.length; i++) {
    hash ^= key.charCodeAt(i);
    // 乘 16777619，用移位加法代替乘法避免溢出成浮点。
    hash = (hash + ((hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24))) >>> 0;
  }
  return hash & 0x3fffffff;
}

/** 执行差异。 */
async function applyDiff(context: common.UIAbilityContext, diff: ReminderDiff,
  existing: ReminderAgentSnapshot[], result: ReminderSyncResult): Promise<void> {
  // 1) 取消。先腾额度。
  for (const id of diff.toCancel) {
    if (await cancelOne(id)) {
      result.cancelledCount++;
    } else {
      result.failedCount++;
    }
  }

  // 2) 更新。id 从快照里按 key 找。
  const idByKey: Map<string, number> = new Map<string, number>();
  for (const entry of existing) {
    if (entry.snapshot.key.length > 0) {
      idByKey.set(entry.snapshot.key, entry.reminderId);
    }
  }
  for (const item of diff.toRefresh) {
    const id: number | undefined = idByKey.get(item.key);
    if (id === undefined) {
      // key 对上却在快照里找不到 id：说明快照是半份（读取失败那一条）。
      // 当成新建处理，好过当成更新去调一个不存在的 id 报 1700003。
      if (await publishOne(context, item, result)) {
        result.publishedCount++;
      }
      continue;
    }
    if (await updateOne(id, context, item, result)) {
      result.refreshedCount++;
    } else {
      result.failedCount++;
    }
  }

  // 3) 新建。
  for (const item of diff.toAdd) {
    if (await publishOne(context, item, result)) {
      result.publishedCount++;
    }
  }
}

async function cancelOne(id: number): Promise<boolean> {
  try {
    await reminderAgentManager.cancelReminder(id);
    return true;
  } catch (err) {
    // 1700003 = 这条提醒已经不在了。它「已经是目标状态」，算成功。
    if (codeOf(err) === ERR_REMINDER_MISSING) {
      return true;
    }
    console.warn(`[ClassyHarmony] 取消提醒 ${id} 失败：${err}`);
    return false;
  }
}

async function updateOne(id: number, context: common.UIAbilityContext,
  item: ReminderPlanItem, result: ReminderSyncResult): Promise<boolean> {
  try {
    await reminderAgentManager.updateReminder(id, requestOf(context, item));
    return true;
  } catch (err) {
    const code: number = codeOf(err);
    if (code === ERR_REMINDER_MISSING) {
      // 平台那条已经没了（被用户在系统设置里删了、或被「不再提醒」清掉）。
      // 重新建一条，目标是「这条提醒存在」，不是「这条 id 存在」。
      return await publishOne(context, item, result);
    }
    console.warn(`[ClassyHarmony] 更新提醒 ${id} 失败（${code}）：${err}`);
    return false;
  }
}

async function publishOne(context: common.UIAbilityContext, item: ReminderPlanItem,
  result: ReminderSyncResult): Promise<boolean> {
  try {
    await reminderAgentManager.publishReminder(requestOf(context, item));
    return true;
  } catch (err) {
    const code: number = codeOf(err);
    if (code === ERR_NOTIFICATION_OFF) {
      result.status = SYNC_NOTIFICATIONS_OFF;
      result.message = '通知权限在同步过程中被关闭';
    } else if (code === ERR_TOO_MANY) {
      // 走到这里说明真实额度比 QUOTA 小（有可能系统里有本应用之外的提醒，
      // 或者设备给了更小的额度）。如实报出来，让界面上出现「额度不够」这句
      // 人话，而不是一句「同步失败」。
      result.message = '系统给的提醒条数不够，本应用最多排 30 条';
    }
    console.warn(`[ClassyHarmony] 发布提醒 ${item.key} 失败（${code}）：${err}`);
    return false;
  }
}

/** 平台错误码：这条提醒已经不存在。 */
const ERR_REMINDER_MISSING: number = 1700003;

function codeOf(err: Object | undefined): number {
  if (err === undefined || err === null) {
    return 0;
  }
  // ArkTS 的 catch 变量是 any，转成 BusinessError 才能取 code。
  const business: BusinessError = err as BusinessError;
  return business.code === undefined ? 0 : business.code;
}
