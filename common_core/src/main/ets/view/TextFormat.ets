/*
 * 展示用文本格式化。
 *
 * 单独成文件而不是各写各的：同一份时间表既在课表网格里显示，也在时间表编辑页
 * 显示，两边算出来的「08:00」要是差一分钟，用户会以为是数据坏了。这里集中一处，
 * 以后要改格式（比如加秒）只改一处。
 */

import { t, tf } from '../i18n/I18n';

/** TimeSpanValue 折算成「HH:mm」。跨零点（负值）显示为 00:00。 */
export function formatClock(seconds: number): string {
  let value: number = seconds;
  if (value < 0) {
    value = 0;
  }
  const hours: number = Math.floor(value / 3600) % 24;
  const minutes: number = Math.floor(value / 60) % 60;
  return `${pad2(hours)}:${pad2(minutes)}`;
}

/** 时长折算成「45 分钟」「1 小时 5 分」。用于时间点编辑页。 */
export function formatDuration(minutes: number): string {
  if (minutes < 60) {
    return tf('fmt_minutes', `${minutes}`);
  }
  const hours: number = Math.floor(minutes / 60);
  const rest: number = minutes % 60;
  return rest === 0 ? tf('fmt_hours', `${hours}`) : tf('fmt_hours_min', `${hours}`, `${rest}`);
}

/**
 * 星期名。dayOfWeek 是 .NET 口径：0=周日 … 6=周六。
 *
 * 不要换成 ArkUI 的 1=周一 —— TimeRule.WeekDay 与 dayOfWeek() 都是 .NET 口径，
 * 混用会让所有单双周课表错位一天，而界面上看不出任何异常。
 */
export function weekDayName(weekDay: number): string {
  if (weekDay < 0 || weekDay > 6) {
    return '';
  }
  return WEEK_DAY_NAMES[weekDay];
}

/** weekDay -> 短名，编辑页的紧凑选择器用。 */
export function weekDayShortName(weekDay: number): string {
  if (weekDay < 0 || weekDay > 6) {
    return '';
  }
  return WEEK_DAY_SHORT_NAMES[weekDay];
}

/**
 * 单双周规则的可读描述。
 *
 * weekCountDiv === 0 表示每周都匹配（见 TimeRule.matches），不是「第 0 周」。
 * weekCountDivTotal 默认是 2，用户没动过就不要显示成「双周」——
 * 默认档案里的新课表应当读起来就是「每周」。
 */
export function weekRotationText(weekCountDiv: number, weekCountDivTotal: number): string {
  if (weekCountDiv <= 0) {
    return t('fmt_rot_weekly');
  }
  const total: number = weekCountDivTotal > 0 ? weekCountDivTotal : 2;
  if (total === 2) {
    return weekCountDiv === 1 ? t('fmt_rot_odd') : t('fmt_rot_even');
  }
  return tf('fmt_rot_week_n', `${weekCountDiv}`, `${total}`);
}

/** 时间点类型的可读名。 */
export function timeTypeName(timeType: number): string {
  if (timeType === 0) {
    return t('fmt_type_class');
  }
  if (timeType === 1) {
    return t('fmt_type_break');
  }
  if (timeType === 2) {
    return t('fmt_type_separator');
  }
  if (timeType === 3) {
    return t('fmt_type_action');
  }
  return t('fmt_type_unknown');
}

const WEEK_DAY_NAMES: string[] =
  [t('fmt_wd_0'), t('fmt_wd_1'), t('fmt_wd_2'), t('fmt_wd_3'), t('fmt_wd_4'), t('fmt_wd_5'), t('fmt_wd_6')];

const WEEK_DAY_SHORT_NAMES: string[] =
  [t('fmt_wd_short_0'), t('fmt_wd_short_1'), t('fmt_wd_short_2'), t('fmt_wd_short_3'), t('fmt_wd_short_4'), t('fmt_wd_short_5'), t('fmt_wd_short_6')];

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}
