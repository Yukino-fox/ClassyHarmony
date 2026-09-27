/**
 * 自动化工作流列表的 ViewModel。
 *
 * 职责：
 *  1. 管理 workflows 列表（增删改、启停、排序）
 *  2. 读写 CurrentAutomationConfig / IsAutomationEnabled
 *  3. 暴露给 UI：workflows、当前方案名、总开关
 *  4. 所有改动落盘到 `${filesDir}/Automations/{CurrentAutomationConfig}.json`
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { JsonNode, JsonObject, JsonReader, JsonWriter, JsonArray } from 'common_shared';
import { Profile } from 'common_shared';
import { Workflow } from 'common_shared';
import { ActionSet, ActionSetStatus } from 'common_shared';
import { AutomationDefaults } from 'common_core';
import { WorkflowMutations } from 'common_core';
import { AutomationSettings } from '../automation/AutomationSettings';
import { ProfileRepository } from '../data/ProfileRepository';

const AUTOMATION_DIR: string = 'Automations';

export class AutomationViewModel {
  private readonly filesDir: string;
  private readonly profileRepo: ProfileRepository;
  private readonly settings: AutomationSettings;

  /** 当前加载的 workflows（直接绑定 UI） */
  workflows: Workflow[] = [];

  /** 当前方案名（UI 可修改） */
  currentScheme: string = 'Default';

  /** 总开关（UI 可修改） */
  isEnabled: boolean = true;

  constructor(filesDir: string, profileRepo: ProfileRepository) {
    this.filesDir = filesDir;
    this.profileRepo = profileRepo;
    this.settings = new AutomationSettings(filesDir);
    this.loadFromSettings();
  }

  /** 从 settings.json 读取总开关与当前方案名，再加载对应 workflows */
  loadFromSettings(): void {
    this.isEnabled = this.settings.getIsAutomationEnabled();
    this.currentScheme = this.settings.getCurrentAutomationConfig();
    this.loadWorkflows(this.currentScheme);
  }

  /** 设置总开关 */
  setEnabled(enabled: boolean): void {
    this.isEnabled = enabled;
    this.settings.setIsAutomationEnabled(enabled);
  }

  /** 设置当前方案名（会切换加载对应的 workflows） */
  setCurrentScheme(name: string): void {
    if (!AutomationSettings.isValidSchemeName(name)) {
      return;
    }
    this.currentScheme = name;
    this.settings.setCurrentAutomationConfig(name);
    this.loadWorkflows(name);
  }

  /** 重载当前方案的 workflows */
  private loadWorkflows(scheme: string): void {
    const path: string = `${this.filesDir}/${AUTOMATION_DIR}/${scheme}.json`;
    try {
      const content: string = fs.readTextSync(path);
      const node: JsonNode = JsonReader.parse(content);
      if (node instanceof JsonArray) {
        const out: Workflow[] = [];
        const values: readonly JsonNode[] = node.values();
        for (let i = 0; i < values.length; i++) {
          const item: JsonNode = values[i];
          if (item instanceof JsonObject) {
            out.push(Workflow.fromJson(item));
          }
        }
        this.workflows = out;
        return;
      }
    } catch {
      // 文件不存在或解析失败
    }
    this.workflows = [];
  }

  /** 保存当前方案的 workflows 到磁盘（原子写） */
  saveWorkflows(): void {
    const dir: string = `${this.filesDir}/${AUTOMATION_DIR}`;
    try {
      fs.accessSync(dir);
    } catch {
      fs.mkdirSync(dir);
    }
    const path: string = `${dir}/${this.currentScheme}.json`;
    const tmp: string = `${path}.tmp.${Date.now()}`;
    const arr: JsonArray = new JsonArray();
    for (let i = 0; i < this.workflows.length; i++) {
      arr.push(this.workflows[i].toJson());
    }
    const file: fs.File = fs.openSync(tmp, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JsonWriter.writeCompact(arr), { encoding: 'utf-8' });
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(tmp, path);
  }

  /** 新建一个空工作流并加到列表末尾 */
  addWorkflow(): number {
    const wf: Workflow = WorkflowMutations.newWorkflow();
    this.workflows.push(wf);
    this.saveWorkflows();
    return this.workflows.length - 1;
  }

  /** 删除指定下标的工作流 */
  removeWorkflow(index: number): boolean {
    if (index < 0 || index >= this.workflows.length) {
      return false;
    }
    this.workflows.splice(index, 1);
    this.saveWorkflows();
    return true;
  }

  /** 交换两个工作流的位置（用于拖拽排序） */
  moveWorkflow(from: number, to: number): boolean {
    if (from < 0 || from >= this.workflows.length || to < 0 || to >= this.workflows.length) {
      return false;
    }
    const moved = this.workflows.splice(from, 1)[0];
    this.workflows.splice(to, 0, moved);
    this.saveWorkflows();
    return true;
  }

  /** 切换工作流的启用状态 */
  toggleWorkflowEnabled(index: number): boolean {
    if (index < 0 || index >= this.workflows.length) {
      return false;
    }
    const wf: Workflow = this.workflows[index];
    wf.actionSet.isEnabled = !wf.actionSet.isEnabled;
    this.saveWorkflows();
    return true;
  }

  /** 获取工作流的显示名（优先 actionSet.name，其次 triggers 里第一个触发器的显示名） */
  getWorkflowDisplayName(index: number): string {
    if (index < 0 || index >= this.workflows.length) {
      return '';
    }
    const wf: Workflow = this.workflows[index];
    if (wf.actionSet.name && wf.actionSet.name.length > 0) {
      return wf.actionSet.name;
    }
    if (wf.triggers.length > 0) {
      return wf.triggers[0].id;
    }
    return `工作流 ${index + 1}`;
  }

  /** 创建默认方案（首次使用时调用） */
  static createDefaultScheme(filesDir: string): void {
    const dir: string = `${filesDir}/${AUTOMATION_DIR}`;
    try {
      fs.accessSync(dir);
    } catch {
      fs.mkdirSync(dir);
    }
    const path: string = `${dir}/Default.json`;
    try {
      fs.accessSync(path);
      return; // 已存在
    } catch {
      // 不存在，写入空数组
      const tmp: string = `${path}.tmp.${Date.now()}`;
      const file: fs.File = fs.openSync(tmp, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, '[]', { encoding: 'utf-8' });
      } finally {
        fs.closeSync(file);
      }
      fs.renameSync(tmp, path);
    }
  }
}