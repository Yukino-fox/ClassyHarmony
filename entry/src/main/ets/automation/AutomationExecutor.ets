/**
 * 自动化行动的执行器（entry 侧，有 UIAbilityContext，可调用 terminateSelf）。
 *
 * 已实现的 3 个行动：
 *  - classisland.action.sleep      → 等待指定秒数
 *  - classisland.settings          → 修改应用设置（写 settings.json）
 *  - classisland.app.quit          → 退出应用（调用 terminateSelf）
 *
 * 未实现的 4 个行动（占位，返回 false 供上层记录失败）：
 *  - classisland.showNotification  → 等 P9 通知系统
 *  - classisland.notification.weather → 等 P11 天气
 *  - classisland.os.run            → 鸿蒙无法拉起任意进程
 *  - classisland.app.restart       → 无对应物
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { JsonNode, JsonObject, JsonReader, JsonWriter } from 'common_shared';
import { ActionIds } from 'common_shared';
import {
  SleepActionSettings,
  ModifyAppSettingsActionSettings,
  ActionItem
} from 'common_shared';
import { AutomationSettings } from './AutomationSettings';
import { common } from '@kit.AbilityKit';

/** 执行结果：true=成功，false=失败 */
export type ExecResult = boolean;

/** 执行器需要的上下文 */
export interface ExecutorContext {
  context: common.UIAbilityContext;
  filesDir: string;
}

/** 原因文本载体 */
export class CauseText {
  value: string = '';
}

export class AutomationExecutor {
  private readonly ctx: ExecutorContext;
  private readonly settings: AutomationSettings;

  constructor(ctx: ExecutorContext) {
    this.ctx = ctx;
    this.settings = new AutomationSettings(ctx.filesDir);
  }

  /** 执行单个行动 */
  async execute(action: ActionItem, causeText: CauseText): Promise<ExecResult> {
    switch (action.id) {
      case ActionIds.SLEEP:
        return this.execSleep(action, causeText);
      case ActionIds.SETTINGS:
        return this.execModifySettings(action, causeText);
      case ActionIds.APP_QUIT:
        return this.execQuit(action, causeText);
      case ActionIds.SHOW_NOTIFICATION:
        causeText.value = '行动「显示通知」尚未实现（等待 P9 通知系统）';
        return false;
      case ActionIds.NOTIFICATION_WEATHER:
        causeText.value = '行动「天气通知」尚未实现（等待 P11 天气）';
        return false;
      case ActionIds.OS_RUN:
        causeText.value = '行动「运行程序」在鸿蒙上不可用';
        return false;
      case ActionIds.APP_RESTART:
        causeText.value = '行动「重启应用」无对应实现';
        return false;
      default:
        causeText.value = `未知行动 id：${action.id}`;
        return false;
    }
  }

  /** classisland.action.sleep：等待 Value 秒（支持小数） */
  private async execSleep(action: ActionItem, causeText: CauseText): Promise<ExecResult> {
    const s: SleepActionSettings | undefined = SleepActionSettings.parse(action.settings);
    if (s === undefined) {
      causeText.value = 'Sleep 设置解析失败';
      return false;
    }
    const seconds: number = s.value;
    if (seconds <= 0) {
      causeText.value = '睡眠时长必须 > 0';
      return false;
    }
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, Math.floor(seconds * 1000));
    });
    return true;
  }

  /** classisland.settings：修改应用设置（写 settings.json） */
  private async execModifySettings(action: ActionItem, causeText: CauseText): Promise<ExecResult> {
    const s: ModifyAppSettingsActionSettings | undefined = ModifyAppSettingsActionSettings.parse(action.settings);
    if (s === undefined) {
      causeText.value = 'ModifyAppSettings 设置解析失败';
      return false;
    }
    if (s.name === '' || s.name === undefined) {
      return true;
    }
    const path: string = `${this.ctx.filesDir}/settings.json`;
    let all: JsonObject = new JsonObject();
    try {
      const content: string = fs.readTextSync(path);
      const node: JsonNode = JsonReader.parse(content);
      if (node instanceof JsonObject) {
        all = node;
      }
    } catch {
      // 文件不存在或解析失败，按空对象处理
    }

    switch (s.mode) {
      case 0: // Replace
        if (s.value !== undefined) {
          all.set(s.name, s.value);
        } else {
          all.set(s.name, JsonNull.getInstance());
        }
        break;
      case 1: // Merge
        if (s.value instanceof JsonObject) {
          const existing: JsonNode | undefined = all.tryGet(s.name);
          if (existing !== undefined && existing instanceof JsonObject) {
            this.mergeObject(existing, s.value);
          } else {
            all.set(s.name, s.value);
          }
        }
        break;
      case 2: // Delete
        all = this.removeKey(all, s.name);
        break;
      default:
        causeText.value = `未知的设置修改模式：${s.mode}`;
        return false;
    }

    const tmp: string = `${path}.tmp.${Date.now()}`;
    const file: fs.File = fs.openSync(tmp, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JsonWriter.writeCompact(all), { encoding: 'utf-8' });
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(tmp, path);
    return true;
  }

  /** 深合并两个 JsonObject（src 覆盖 dst） */
  private mergeObject(dst: JsonObject, src: JsonObject): void {
    const members: readonly { name: string; value: JsonNode }[] = src.entries();
    for (let i = 0; i < members.length; i++) {
      const key: string = members[i].name;
      const val: JsonNode = members[i].value;
      const existing: JsonNode | undefined = dst.tryGet(key);
      if (existing !== undefined && existing instanceof JsonObject && val instanceof JsonObject) {
        this.mergeObject(existing, val);
      } else {
        dst.set(key, val);
      }
    }
  }

  /** 移除键（JsonObject 无 delete，重建） */
  private removeKey(obj: JsonObject, key: string): JsonObject {
    const out: JsonObject = new JsonObject();
    const members: readonly { name: string; value: JsonNode }[] = obj.entries();
    for (let i = 0; i < members.length; i++) {
      if (members[i].name !== key) {
        out.set(members[i].name, members[i].value);
      }
    }
    return out;
  }

  /** classisland.app.quit：退出应用 */
  private async execQuit(action: ActionItem, causeText: CauseText): Promise<ExecResult> {
    try {
      const ctx: common.UIAbilityContext = this.ctx.context;
      const terminateSelf = (ctx as unknown as { terminateSelf?: () => void }).terminateSelf;
      if (terminateSelf) {
        terminateSelf();
        return true;
      }
      causeText.value = '无法获取 terminateSelf 能力';
      return false;
    } catch {
      causeText.value = '退出应用失败';
      return false;
    }
  }
}

/** JsonNull 单例（用于表示 JSON null） */
class JsonNull extends JsonNode {
  private static instance: JsonNull = new JsonNull();
  private constructor() { super(); }
  static getInstance(): JsonNull { return JsonNull.instance; }
  toString(): string { return 'null'; }
}