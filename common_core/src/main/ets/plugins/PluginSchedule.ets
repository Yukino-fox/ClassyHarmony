/*
 * 声明式触发器的日程求值。
 *
 * 三种日程，三种口径
 * ------------------
 *   cron          复用内置 CronExpression 的六段式，与桌面版 TriggerSettings 的
 *                 cron 触发器完全同一套判据。匹配在 PluginTriggerEval 里做
 *                 （CronExpression.matches 收 DateTimeValue），本文件只判参数。
 *   dailyAt       当日第 atSeconds 秒命中。轮询每秒一次、比较的是整秒，所以它
 *                 只会命中一次，不会像「>= 时刻」那样连着命中。
 *   everyMinutes  当日秒数对 (everyMinutes × 60) 取模为 0 时命中，同样只命中一次。
 *
 * 为什么不留状态（与内置 cron 一样）
 * -------------------------------
 * 三种口径都是「问此刻符不符合」，所以不需要「上一帧」。代价与内置 cron 一样：
 * 轮询被冻结的那段时间（应用后台、系统限流）里跨过的命中点会漏掉。这与桌面版
 * sleeping 到点唤醒必到的差异，我们选择接受 —— 换来的是不需要一套自建调度器，
 * 也就没有「唤醒后补触发」那类边缘行为。
 *
 * cron 的匹配为什么不放在这里
 * --------------------------
 * `CronExpression.matches` 收的是 DateTimeValue（内部要读 second/minute/hour/
 * month/daysOfMonth/daysOfWeek 六个字段），没法只喂一个秒数。造一个假的时间对象
 * 去喂它更糟：凑出来的 month 与 daysOfMonth 一旦与真实时刻不符，cron 的结果就是
 * 错的（`0 0 1 * *` 会在任何一天都命中）。所以 cron 一律走 PluginTriggerEval。
 *
 * 判定原因与 AutomationReason 用同一批字面量
 * ---------------------------------------
 * 原因字符串会原样进界面与日志。这里不 import AutomationReason 是为了避开环
 * （AutomationEngine 要用本文件）。代价是「两边改了只有一个」不会编译报错 ——
 * 所以 Node 测试台里逐条比对这两个集合。
 */

import { JsonNode, JsonNumber, JsonObject, JsonString, JsonValue } from 'common_shared';
import { t, tf } from '../i18n/I18n';
import { PluginScheduleKind, TriggerExtension } from './PluginManifest';

/** 判定原因。与 AutomationEngine.AutomationReason 的字面量逐字一致。 */
export const PLUGIN_REASON_FIRED: string = 'fired';
export const PLUGIN_REASON_NOT_YET: string = 'notYet';
export const PLUGIN_REASON_BAD_SETTINGS: string = 'badSettings';

/** `everyMinutes` 的上限：一天的全部分钟。再大没有意义（等价于 1）。 */
export const MAX_EVERY_MINUTES: number = 1440;

/** 一天的秒数（不含）。 */
export const SECONDS_PER_DAY: number = 86400;

/** 一份日程。 */
export class PluginSchedule {
  kind: PluginScheduleKind = PluginScheduleKind.None;
  /** Cron 类别用的表达式原文。 */
  cronExpression: string = '';
  /** DailyAt 类别用的当日秒数。 */
  atSeconds: number = 0;
  /** EveryMinutes 类别用的分钟数。 */
  everyMinutes: number = 0;
}

/** 一个日程这一帧的判定。 */
export class PluginScheduleVerdict {
  /** 有没有命中。 */
  fired: boolean = false;
  /** 原因，取值见上面三个常量。 */
  reason: string = PLUGIN_REASON_NOT_YET;
  /** 附加说明（比如参数越界）。 */
  detail: string = '';
}

/** 参数不合法时的原因。合法返回空串。 */
export function scheduleSettingsProblem(schedule: PluginSchedule): string {
  if (schedule.kind === PluginScheduleKind.None) {
    return '';
  }
  if (schedule.kind === PluginScheduleKind.Cron) {
    return schedule.cronExpression.trim().length === 0 ? t('plugin_schedule_cron_missing') : '';
  }
  if (schedule.kind === PluginScheduleKind.DailyAt) {
    if (schedule.atSeconds < 0 || schedule.atSeconds >= SECONDS_PER_DAY) {
      return tf('plugin_dailyat_range', `${schedule.atSeconds}`, `${SECONDS_PER_DAY - 1}`);
    }
    return '';
  }
  if (schedule.everyMinutes < 1 || schedule.everyMinutes > MAX_EVERY_MINUTES) {
    return tf('plugin_every_range', `${schedule.everyMinutes}`, `${MAX_EVERY_MINUTES}`);
  }
  return '';
}

/**
 * 非 cron 日程这一帧命不命中。
 *
 * cron 类别在这里返回「请走带时间对象的入口」而不是猜一个结果 —— 调用方
 * （PluginTriggerEval）自己处理 cron，所以这条分支实际上只被直接测试时命中。
 */
export function evaluatePluginSchedule(schedule: PluginSchedule,
  nowSecondOfDay: number): PluginScheduleVerdict {
  const out: PluginScheduleVerdict = new PluginScheduleVerdict();
  if (schedule.kind === PluginScheduleKind.None) {
    out.detail = t('plugin_trigger_no_schedule_short');
    return out;
  }
  if (schedule.kind === PluginScheduleKind.Cron) {
    out.detail = t('plugin_cron_judge_elsewhere');
    return out;
  }
  const problem: string = scheduleSettingsProblem(schedule);
  if (problem.length > 0) {
    out.reason = PLUGIN_REASON_BAD_SETTINGS;
    out.detail = problem;
    return out;
  }
  if (schedule.kind === PluginScheduleKind.DailyAt) {
    return verdictOf(nowSecondOfDay === schedule.atSeconds);
  }
  return verdictOf(nowSecondOfDay % (schedule.everyMinutes * 60) === 0);
}

function verdictOf(fired: boolean): PluginScheduleVerdict {
  const out: PluginScheduleVerdict = new PluginScheduleVerdict();
  out.fired = fired;
  out.reason = fired ? PLUGIN_REASON_FIRED : PLUGIN_REASON_NOT_YET;
  return out;
}

/** 展开一段配置 JSON 成日程。字段名与清单里的 TriggerExtension 一致。 */
export function parsePluginSchedule(node: JsonNode | undefined): PluginSchedule {
  const out: PluginSchedule = new PluginSchedule();
  const obj: JsonObject | undefined = JsonValue.asObject(node);
  if (obj === undefined) {
    return out;
  }
  out.kind = parseScheduleKindText(JsonValue.asStringLoose(obj.tryGet('scheduleKind'), ''));
  out.cronExpression = JsonValue.asStringLoose(obj.tryGet('cronExpression'), '');
  out.atSeconds = JsonValue.asInt(obj.tryGet('atSeconds'), 0);
  out.everyMinutes = JsonValue.asInt(obj.tryGet('everyMinutes'), 0);
  return out;
}

/** 类别文本 → 枚举。陌生取值落 None（恒不触发），与 TriggerExtensionCodec 同一口径。 */
export function parseScheduleKindText(text: string): PluginScheduleKind {
  if (text === PluginScheduleKind.Cron) {
    return PluginScheduleKind.Cron;
  }
  if (text === PluginScheduleKind.DailyAt) {
    return PluginScheduleKind.DailyAt;
  }
  if (text === PluginScheduleKind.EveryMinutes) {
    return PluginScheduleKind.EveryMinutes;
  }
  return PluginScheduleKind.None;
}

/** 把清单里的触发器条目转成日程。 */
export function scheduleOfExtension(entry: TriggerExtension): PluginSchedule {
  const out: PluginSchedule = new PluginSchedule();
  out.kind = entry.scheduleKind;
  out.cronExpression = entry.cronExpression;
  out.atSeconds = entry.atSeconds;
  out.everyMinutes = entry.everyMinutes;
  return out;
}

/**
 * 日程说明（设置页显示用）。
 *
 * 说「每 5 分钟」而不是把 cron 表达式原文摆给用户看：CronExpression 的六段式是桌面版
 * 的表达习惯，鸿蒙用户没有这个背景。cron 那一类只能原样显示表达式 —— 翻译成中文
 * 要重写一套 cron 文法，而能读 cron 的用户看得懂原文。
 */
export function scheduleText(schedule: PluginSchedule): string {
  if (schedule.kind === PluginScheduleKind.Cron) {
    return schedule.cronExpression.trim().length === 0 ? t('plugin_cron_not_set') : schedule.cronExpression;
  }
  if (schedule.kind === PluginScheduleKind.DailyAt) {
    return tf('plugin_schedule_daily_at', formatSecondOfDay(schedule.atSeconds));
  }
  if (schedule.kind === PluginScheduleKind.EveryMinutes) {
    return tf('plugin_schedule_every_minutes', `${schedule.everyMinutes}`);
  }
  return t('plugin_never_fires');
}

/**
 * 清单里的触发器条目 → 触发器配置节点。
 *
 * 装进 TriggerSettings.settings 的就是它。字段名与清单一致，不另发明一套：
 * 这样一份清单被装上之后，用户在编辑器里看到的设置节点与作者写的一模一样。
 */
export function settingsOfTriggerExtension(entry: TriggerExtension): JsonObject {
  const out: JsonObject = new JsonObject();
  out.set('scheduleKind', new JsonString(entry.scheduleKind));
  out.set('cronExpression', new JsonString(entry.cronExpression));
  out.set('atSeconds', JsonNumber.ofInt(entry.atSeconds));
  out.set('everyMinutes', JsonNumber.ofInt(entry.everyMinutes));
  return out;
}

/** 当日秒数写成 HH:mm:ss。越界照写（错误信息里要用）。 */
export function formatSecondOfDay(second: number): string {
  const h: number = Math.floor(second / 3600);
  const m: number = Math.floor((second - h * 3600) / 60);
  const s: number = second - h * 3600 - m * 60;
  return `${pad2(h)}:${pad2(m)}:${pad2(s)}`;
}

function pad2(value: number): string {
  if (value < 10) {
    return `0${value}`;
  }
  return `${value}`;
}
