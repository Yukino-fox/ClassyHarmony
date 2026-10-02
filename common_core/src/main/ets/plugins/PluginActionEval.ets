/*
 * 声明式动作的执行描述（给 AutomationExecutor 用）。
 *
 * 这一层只回答「这条动作要做成什么样」，不做
 * ------------------------------------------
 * 弹通知、退出应用、写设置都要碰 @kit.*，那是 entry 的事。这里产出的是一份
 * 「决定」，与 AutomationEngine 产出 AutomationRun 是同一个分工：判定层不碰系统
 * 能力，于是整个链路能进 Node 测试台测。
 *
 * 三种动作类别
 * -----------
 *   Notification   → 一条「发通知」的描述（标题正文原样，执行时再渲染模板）。
 *                    执行走 entry 已有的 NotificationService，与内置
 *                    showNotification 同一条路 —— 所以朗读也自动跟着走，
 *                    不需要声明式动作再单独接一次。
 *   ModifySetting  → 一条「改设置」的描述。值按文本存，实际类型由设置键决定
 *                    （开关认 on/off，数值键认数字），解释放在 entry。
 *   None           → 什么也不做。装上能看见，但跑了等于没跑。
 *
 * 关于改设置的白名单
 * ---------------
 * core 不复制一份「哪些键可以改」的名单（那会与 AppPreferences 的真源对不上，
 * 而对不上时的症状是「扩展改了个它不该改的设置」，极难排查）。清单校验时用调用方
 * 给的集合判断（见 PluginValidation.PluginSandbox），这里再判一次 ——
 * 校验是为了给作者回话，执行前这道是为了「即使校验被绕过也不越权」。
 */

import { t } from '../i18n/I18n';
import { JsonNode, JsonNumber, JsonObject, JsonString, JsonValue } from 'common_shared';
import { ActionExtension, PluginActionKind } from './PluginManifest';

/** 一条「发通知」的动作描述。 */
export class PluginNotificationPlan {
  /** 通知分类，取值与 NotificationCategory 同名。 */
  category: string = '';
  /** 标题模板（未渲染）。 */
  title: string = '';
  /** 正文模板（未渲染）。 */
  content: string = '';
}

/** 一条「改设置」的动作描述。 */
export class PluginSettingPlan {
  key: string = '';
  /** 值原文。由 entry 按设置键的类型解释。 */
  value: string = '';
}

/** 一个动作这一帧要做什么。 */
export class PluginActionPlan {
  kind: PluginActionKind = PluginActionKind.None;
  notification: PluginNotificationPlan = new PluginNotificationPlan();
  setting: PluginSettingPlan = new PluginSettingPlan();
  /** 执行不了时给自动化引擎的原因说明，空串表示能执行。 */
  reason: string = '';
}

/** 通知分类的取值。与 entry 的 NotificationCategory 逐字一致（那边是字符串枚举）。 */
export const PLUGIN_CATEGORY_AUTOMATION: string = 'automation';
export const PLUGIN_CATEGORY_CLASS_REMINDER: string = 'class_reminder';
export const PLUGIN_CATEGORY_WEATHER: string = 'weather';
export const PLUGIN_CATEGORY_SYSTEM: string = 'system';

/** 全部合法分类。用于清单校验与执行前的二次检查。 */
export const PLUGIN_CATEGORIES: string[] = [
  PLUGIN_CATEGORY_AUTOMATION,
  PLUGIN_CATEGORY_CLASS_REMINDER,
  PLUGIN_CATEGORY_WEATHER,
  PLUGIN_CATEGORY_SYSTEM
];

/**
 * 把动作配置节点解析成计划。
 *
 * category 陌生时归到 automation：声明式动作是「用户自己配的东西」，
 * 用 automation 通道（默认优先级、用户可静音）比归到 class_reminder
 * （响铃震动）安全 —— 归错方向的代价是不该响的东西响了。
 */
export function planPluginAction(settings: JsonNode | undefined,
  allowedSettingKeys: Set<string>): PluginActionPlan {
  const out: PluginActionPlan = new PluginActionPlan();
  const obj: JsonObject | undefined = JsonValue.asObject(settings);
  if (obj === undefined) {
    out.reason = t('plugin_action_settings_not_object');
    return out;
  }
  out.kind = parseActionKindText(JsonValue.asStringLoose(obj.tryGet('actionKind'), ''));
  out.notification.title = JsonValue.asStringLoose(obj.tryGet('title'), '');
  out.notification.content = JsonValue.asStringLoose(obj.tryGet('content'), '');
  out.notification.category = normalizeCategory(JsonValue.asStringLoose(obj.tryGet('category'), ''));
  out.setting.key = JsonValue.asStringLoose(obj.tryGet('settingKey'), '');
  out.setting.value = JsonValue.asStringLoose(obj.tryGet('settingValue'), '');
  if (out.kind === PluginActionKind.ModifySetting && !allowedSettingKeys.has(out.setting.key)) {
    // 校验阶段应该已经拦下；到这里说明有人绕过校验直接塞了配置。
    // 宁可什么也不做也不要越权改设置 —— 声明式扩展的整个安全模型就是「只能改
    // 明确开放的键」。
    out.kind = PluginActionKind.None;
    out.reason = `设置键「${out.setting.key}」不在允许改的名单里，行动已被跳过。`;
  }
  return out;
}

/** 类别文本 → 枚举。 */
export function parseActionKindText(text: string): PluginActionKind {
  if (text === PluginActionKind.Notification) {
    return PluginActionKind.Notification;
  }
  if (text === PluginActionKind.ModifySetting) {
    return PluginActionKind.ModifySetting;
  }
  return PluginActionKind.None;
}

/** 通知分类归一。陌生值落 automation。 */
export function normalizeCategory(text: string): string {
  const trimmed: string = text.trim();
  if (PLUGIN_CATEGORIES.indexOf(trimmed) >= 0) {
    return trimmed;
  }
  return PLUGIN_CATEGORY_AUTOMATION;
}

/**
 * 清单里的行动条目 → 动作配置节点。
 *
 * 装进 ActionItem.Settings 的就是这个节点。执行时 planPluginAction 读它，
 * 所以字段名与清单一致，不另发明一套。
 */
export function settingsOfActionExtension(entry: ActionExtension): JsonObject {
  const out: JsonObject = new JsonObject();
  out.set('actionKind', new JsonString(entry.actionKind));
  out.set('title', new JsonString(entry.title));
  out.set('content', new JsonString(entry.content));
  out.set('category', new JsonString(normalizeCategory(entry.category)));
  out.set('settingKey', new JsonString(entry.settingKey));
  out.set('settingValue', new JsonString(entry.settingValue));
  return out;
}
