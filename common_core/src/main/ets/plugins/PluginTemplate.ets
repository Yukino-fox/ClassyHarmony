/*
 * 声明式动作的模板渲染。
 *
 * 为什么需要模板
 * --------------
 * 声明式动作最常见的一条是「发个通知说点什么」。如果 title / content 只能写死，
 * 那扩展作者唯一能做的差异化就是把时间/课表信息硬编进去 —— 而他写这份清单时
 * 并不知道用户哪天有课。所以给一组占位符，让文案里能引用当前状态。
 *
 * 占位符清单（大小写敏感，未知占位符原样保留）
 * ------------------------------------------
 *   {time}          HH:mm:ss
 *   {hour}          HH
 *   {minute}        mm
 *   {date}          yyyy-MM-dd
 *   {weekday}       星期一
 *   {state}         当前时间状态（上课中 / 课间休息 / 已放学 …）
 *   {profile}       当前档案名
 *   {subject}       当前科目
 *   {nextSubject}   下一科目
 *   {classPlan}     当前课表方案名
 *   {onClassLeft}   距下课还有多少（HH:mm:ss）
 *   {breakingLeft}  距上课还有多少（HH:mm:ss）
 *
 * 未知占位符原样保留而不是替换成空串
 * ------------------------------
 * 因为 `{tme}` 拼错时如果变成空串，通知里就少了一段字，作者会以为「这个占位符
 * 不支持」而去改文案，改成另一个也不支持，然后永远找不到真正的原因。
 * 保留原文能一眼看出「这个占位符没被替换」。
 *
 * 不做表达式求值
 * ------------
 * 只做字符串替换，不引入任何脚本能力。这是声明式扩展安全模型的一部分：
 * 扩展提供的是数据，而数据不该能变成逻辑。宁可少几个占位符，也不要开一个求值器。
 */

import { t } from '../i18n/I18n';
import { DateTimeValue, TimeState } from 'common_shared';
import { LessonsSnapshot } from '../engine/LessonsSnapshot';

/**
 * 五个时间状态的中文名，按枚举值排列。
 *
 * 放在 core 而不是各自写一份：模板的 {state}、规则编辑器的下拉、设置页的摘要
 * 都要说同一件事。三处各写一份的话，改了一处另外两处就开始说另一种话 ——
 * 而这类不一致只有用户截图反馈时才看得出来。
 */
export const TIME_STATE_LABELS: string[] = [
  t('time_state_none'), t('time_state_on_class'), t('time_state_prepare'),
  t('time_state_break'), t('time_state_after_school')
];

/** 时间状态的中文名。认不出来的值给「未知状态（n）」而不是空串。 */
export function timeStateLabel(state: number): string {
  if (state < 0 || state >= TIME_STATE_LABELS.length) {
    return t('time_state_unknown');
  }
  return TIME_STATE_LABELS[state];
}

/** 渲染时的取值。字段全为空串时占位符落空串。 */
export class PluginTemplateContext {
  now: DateTimeValue | undefined = undefined;
  snapshot: LessonsSnapshot | undefined = undefined;
  profileName: string = '';
  /** 时间状态的中文名。留空则按快照上的状态自动取（见 renderPluginTemplate）。 */
  stateText: string = '';
}

/**
 * 渲染一段模板。
 *
 * 逐字符扫描而不是 split/join：占位符里可能出现嵌套的 `{`（如 `{a{b}`），
 * 而 split 那一套在这种情况下会给出一堆碎片段，还得再拼回来。
 */
export function renderPluginTemplate(template: string, ctx: PluginTemplateContext): string {
  if (template.indexOf('{') < 0) {
    return template;
  }
  let out: string = '';
  let i: number = 0;
  while (i < template.length) {
    const ch: string = template.charAt(i);
    if (ch !== '{') {
      out += ch;
      i++;
      continue;
    }
    const end: number = template.indexOf('}', i);
    if (end < 0) {
      // 没有配对的 }：剩下整段原样输出（含那个孤零零的 {）。
      out += template.substring(i);
      break;
    }
    const name: string = template.substring(i + 1, end);
    const resolved: string | undefined = PluginTemplateResolver.lookup(name, ctx);
    if (resolved === undefined) {
      // 未知占位符：原样保留。
      out += template.substring(i, end + 1);
    } else {
      out += resolved;
    }
    i = end + 1;
  }
  return out;
}

/** 占位符解析。集中在一处，render 只管扫描。 */
class PluginTemplateResolver {
  /** 认得的占位符取值；返回 undefined 表示「不认识，原样保留」。 */
  static lookup(name: string, ctx: PluginTemplateContext): string | undefined {
    const now: DateTimeValue | undefined = ctx.now;
    const snapshot: LessonsSnapshot | undefined = ctx.snapshot;
    if (name === 'time') {
      return now === undefined ? '' : PluginTemplateResolver.timeText(now);
    }
    if (name === 'hour') {
      return now === undefined ? '' : pad2(now.hour);
    }
    if (name === 'minute') {
      return now === undefined ? '' : pad2(now.minute);
    }
    if (name === 'date') {
      return now === undefined ? '' : now.toDateString();
    }
    if (name === 'weekday') {
      if (now === undefined) {
        return '';
      }
      return PluginTemplateResolver.weekdayText(now.dayOfWeek());
    }
    if (name === 'state') {
      // stateText 是给「想换个说法」的调用方留的出口；没给就从快照上取。
      // 不做这个回落的话，{state} 恒为空串 —— 而调用方十有八九不会去设置它，
      // 症状是「模板里 {state} 什么都没替换出来」，而清单作者什么也改不了。
      if (ctx.stateText.length > 0) {
        return ctx.stateText;
      }
      return snapshot === undefined ? '' : timeStateLabel(snapshot.state);
    }
    if (name === 'profile') {
      return ctx.profileName;
    }
    if (name === 'subject') {
      const subject = snapshot === undefined ? undefined : snapshot.currentSubject;
      return subject === undefined ? '' : subject.name;
    }
    if (name === 'nextSubject') {
      const next = snapshot === undefined ? undefined : snapshot.nextClassSubject;
      return next === undefined ? '' : next.name;
    }
    if (name === 'classPlan') {
      const plan = snapshot === undefined ? undefined : snapshot.currentClassPlan;
      return plan === undefined ? '' : plan.name;
    }
    if (name === 'onClassLeft') {
      const left = snapshot === undefined ? undefined : snapshot.onClassLeftTime;
      return left === undefined ? '' : left.toString();
    }
    if (name === 'breakingLeft') {
      const left = snapshot === undefined ? undefined : snapshot.onBreakingTimeLeftTime;
      return left === undefined ? '' : left.toString();
    }
    return undefined;
  }

  private static timeText(now: DateTimeValue): string {
    return `${pad2(now.hour)}:${pad2(now.minute)}:${pad2(now.second)}`;
  }

  /** 星期几。dayOfWeek 是 .NET 口径（周日 = 0）。 */
  private static weekdayText(dayOfWeek: number): string {
    switch (dayOfWeek) {
      case 0:
        return t('time_weekday_sunday');
      case 1:
        return t('time_weekday_monday');
      case 2:
        return t('time_weekday_tuesday');
      case 3:
        return t('time_weekday_wednesday');
      case 4:
        return t('time_weekday_thursday');
      case 5:
        return t('time_weekday_friday');
      case 6:
        return t('time_weekday_saturday');
      default:
        return '';
    }
  }
}

function pad2(value: number): string {
  if (value < 10) {
    return `0${value}`;
  }
  return `${value}`;
}

/** 供设置页预览用：把模板里出现的占位符列出来（去重、保序）。 */
export function pluginTemplatePlaceholders(template: string): string[] {
  const out: string[] = [];
  const seen: Set<string> = new Set<string>();
  let i: number = 0;
  while (i < template.length) {
    if (template.charAt(i) !== '{') {
      i++;
      continue;
    }
    const end: number = template.indexOf('}', i);
    if (end < 0) {
      break;
    }
    const name: string = template.substring(i + 1, end);
    if (!seen.has(name)) {
      seen.add(name);
      out.push(name);
    }
    i = end + 1;
  }
  return out;
}

/** 全部受支持的占位符（设置页的说明文案）。 */
export const PLUGIN_TEMPLATE_PLACEHOLDERS: string[] = [
  '{time}', '{hour}', '{minute}', '{date}', '{weekday}', '{state}',
  '{profile}', '{subject}', '{nextSubject}', '{classPlan}',
  '{onClassLeft}', '{breakingLeft}'
];

/**
 * 未被替换的占位符（模板写错了）。设置页在预览时用它标红。
 *
 * 与 renderPluginTemplate 的保留策略配套：既然渲染时原样保留，就得有个办法
 * 把它们找出来告诉作者。
 */
export function unresolvedPlaceholders(template: string,
  ctx: PluginTemplateContext): string[] {
  const out: string[] = [];
  for (const name of pluginTemplatePlaceholders(template)) {
    if (PluginTemplateResolver.lookup(name, ctx) === undefined) {
      out.push(name);
    }
  }
  return out;
}
