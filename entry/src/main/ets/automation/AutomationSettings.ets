/**
 * 自动化全局设置的持久化（读写 settings.json 中的两个字段）。
 *
 * - IsAutomationEnabled: boolean（默认 true）
 * - CurrentAutomationConfig: string（默认 'Default'，方案名合法性由 isValidSchemeName 校验）
 *
 * 放在 entry 侧因为需要 UIAbilityContext.filesDir。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { JsonNode, JsonObject, JsonReader, JsonWriter, JsonBoolean, JsonString } from 'common_shared';

const SETTINGS_FILE_NAME: string = 'settings.json';
const AUTOMATION_ENABLED_KEY: string = 'IsAutomationEnabled';
const CURRENT_AUTOMATION_CONFIG_KEY: string = 'CurrentAutomationConfig';
const DEFAULT_AUTOMATION_CONFIG: string = 'Default';

export class AutomationSettings {
  private readonly filesDir: string;

  constructor(filesDir: string) {
    this.filesDir = filesDir;
  }

  /** 读取完整 settings.json（不存在返回空对象） */
  private readAll(): JsonObject {
    const path: string = `${this.filesDir}/${SETTINGS_FILE_NAME}`;
    try {
      const content: string = fs.readTextSync(path);
      const node: JsonNode = JsonReader.parse(content);
      return node instanceof JsonObject ? node : new JsonObject();
    } catch (e) {
      return new JsonObject();
    }
  }

  /** 原子写 settings.json（临时文件 + rename） */
  private writeAll(obj: JsonObject): void {
    const path: string = `${this.filesDir}/${SETTINGS_FILE_NAME}`;
    const tmp: string = `${path}.tmp.${Date.now()}`;
    const text: string = JsonWriter.writeCompact(obj);
    const file: fs.File = fs.openSync(tmp, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text, { encoding: 'utf-8' });
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(tmp, path);
  }

  /** 读总开关（默认 true） */
  getIsAutomationEnabled(): boolean {
    const all: JsonObject = this.readAll();
    const val: JsonNode | undefined = all.tryGet(AUTOMATION_ENABLED_KEY);
    if (val === undefined || !(val instanceof JsonBoolean)) {
      return true;
    }
    return val.value;
  }

  /** 写总开关 */
  setIsAutomationEnabled(enabled: boolean): void {
    const all: JsonObject = this.readAll();
    all.set(AUTOMATION_ENABLED_KEY, new JsonBoolean(enabled));
    this.writeAll(all);
  }

  /** 读当前自动化方案名（默认 'Default'） */
  getCurrentAutomationConfig(): string {
    const all: JsonObject = this.readAll();
    const val: JsonNode | undefined = all.tryGet(CURRENT_AUTOMATION_CONFIG_KEY);
    if (val === undefined || !(val instanceof JsonString)) {
      return DEFAULT_AUTOMATION_CONFIG;
    }
    return val.value;
  }

  /** 写当前自动化方案名（会做合法性校验，非法则忽略） */
  setCurrentAutomationConfig(name: string): void {
    if (!AutomationSettings.isValidSchemeName(name)) {
      return;
    }
    const all: JsonObject = this.readAll();
    all.set(CURRENT_AUTOMATION_CONFIG_KEY, new JsonString(name));
    this.writeAll(all);
  }

  /** 方案名合法性：字母/数字/下划线/中划线/空格，1..64 字符（与面板方案同规则） */
  static isValidSchemeName(name: string): boolean {
    if (name.length === 0 || name.length > 64) {
      return false;
    }
    return /^[A-Za-z0-9_\- ]+$/.test(name);
  }
}