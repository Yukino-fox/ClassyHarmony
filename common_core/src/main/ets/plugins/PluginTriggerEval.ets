/*
 * 声明式触发器的判定入口（给 AutomationEngine 与设置页用）。
 *
 * 与 PluginSchedule 的分工
 * ----------------------
 * PluginSchedule 回答「这一刻符不符合日程」，但刻意不认识 DateTimeValue —— 它收的是
 * 「当日第几秒」。这样 Node 测试台能穷举秒数，不用构造时间对象。本文件是那层薄壳：
 * 把 DateTimeValue 拆成年内秒数、把 cron 解析结果缓存起来，然后调上面那个。
 *
 * 参数先查后算
 * ------------
 * 先 `scheduleSettingsProblem`：带着越界的秒数去取模不会崩，但会静默给出一个看似
 * 正常的「永不命中」，用户查不出原因。所以不合规立刻返回并带上那句话。
 *
 * 缓存的粒度
 * ---------
 * 由调用方持有（AutomationEngine 的 TriggerSlot，按「工作流下标 + 触发器下标」
 * 定位）。这里只在「没有缓存」或「表达式文本真的变了」时重解，让内置 cron 与
 * 声明式 cron 共用同一套缓存判据，不散成两处。
 */

import { DateTimeValue, JsonNode } from 'common_shared';
import { CronExpression } from '../automation/CronExpression';
import {
  PLUGIN_REASON_BAD_SETTINGS,
  PLUGIN_REASON_FIRED,
  PLUGIN_REASON_NOT_YET,
  PluginSchedule,
  PluginScheduleVerdict,
  evaluatePluginSchedule,
  parsePluginSchedule,
  scheduleSettingsProblem
} from './PluginSchedule';
import { PluginScheduleKind } from './PluginManifest';

/** 一个声明式触发器这一帧的判定。 */
export class PluginTriggerVerdict {
  /** 日程有没有命中。 */
  fired: boolean = false;
  /** 原因，取值与 AutomationReason 同名常量逐字一致。 */
  reason: string = PLUGIN_REASON_NOT_YET;
  /** 附加说明（cron 解不出来 / 参数越界之类）。 */
  detail: string = '';
  /** 本次判定用到的 cron 表达式（可能刚解出来），供调用方缓存。 */
  cron: CronExpression | undefined = undefined;
  /** 本次判定对应的 cron 表达式原文，供调用方判断缓存是否过期。 */
  cronText: string = '';
}

/**
 * 判定一个声明式触发器这一帧。
 *
 * settings 是触发器配置节点（TriggerSettings.settings，或清单条目本身）。
 * cachedCron / cachedCronText 由调用方持有。
 */
export function judgePluginTrigger(settings: JsonNode | undefined, now: DateTimeValue,
  cachedCron: CronExpression | undefined, cachedCronText: string): PluginTriggerVerdict {
  const out: PluginTriggerVerdict = new PluginTriggerVerdict();
  const schedule: PluginSchedule = parsePluginSchedule(settings);
  out.cronText = schedule.cronExpression;

  if (schedule.kind === PluginScheduleKind.None) {
    const verdict: PluginScheduleVerdict = evaluatePluginSchedule(schedule, now.timeOfDaySeconds());
    out.fired = verdict.fired;
    out.reason = verdict.reason;
    out.detail = verdict.detail;
    return out;
  }

  const problem: string = scheduleSettingsProblem(schedule);
  if (problem.length > 0) {
    out.reason = PLUGIN_REASON_BAD_SETTINGS;
    out.detail = problem;
    return out;
  }

  if (schedule.kind === PluginScheduleKind.Cron) {
    let cron: CronExpression | undefined = cachedCron;
    if (cron === undefined || cachedCronText !== schedule.cronExpression) {
      cron = CronExpression.parse(schedule.cronExpression);
    }
    out.cron = cron;
    out.cronText = schedule.cronExpression;
    if (!cron.valid) {
      out.reason = PLUGIN_REASON_BAD_SETTINGS;
      out.detail = `cron 表达式解不出来：${cron.reason}`;
      return out;
    }
    out.fired = cron.matches(now);
    out.reason = out.fired ? PLUGIN_REASON_FIRED : PLUGIN_REASON_NOT_YET;
    return out;
  }

  const verdict: PluginScheduleVerdict = evaluatePluginSchedule(schedule, now.timeOfDaySeconds());
  out.fired = verdict.fired;
  out.reason = verdict.reason;
  out.detail = verdict.detail;
  return out;
}
