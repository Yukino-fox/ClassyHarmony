/*
 * 展示用文本格式化。
 *
 * 单独成文件而不是各写各的：同一份时间表既在课表网格里显示，也在时间表编辑页
 * 显示，两边算出来的「08:00」要是差一分钟，用户会以为是数据坏了。这里集中一处，
 * 以后要改格式（比如加秒）只改一处。
 */

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
    return `${minutes} 分钟`;
  }
  const hours: number = Math.floor(minutes / 60);
  const rest: number = minutes % 60;
  return rest === 0 ? `${hours} 小时` : `${hours} 小时 ${rest} 分`;
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
    return '每周';
  }
  const total: number = weekCountDivTotal > 0 ? weekCountDivTotal : 2;
  if (total === 2) {
    return weekCountDiv === 1 ? '单周' : '双周';
  }
  return `第 ${weekCountDiv}/${total} 周`;
}

/** 时间点类型的可读名。 */
export function timeTypeName(timeType: number): string {
  if (timeType === 0) {
    return '上课';
  }
  if (timeType === 1) {
    return '课间';
  }
  if (timeType === 2) {
    return '分割线';
  }
  if (timeType === 3) {
    return '行动';
  }
  return '未知';
}

const WEEK_DAY_NAMES: string[] =
  ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

const WEEK_DAY_SHORT_NAMES: string[] = ['日', '一', '二', '三', '四', '五', '六'];

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}
