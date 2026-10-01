/**
 * 自动化每秒 tick 调度器（entry 侧，启动/停止随应用生命周期）。
 *
 * 职责：
 *  1. 每秒触发一次（setInterval）
 *  2. 读总开关 IsAutomationEnabled，关则不执行
 *  3. 读 CurrentAutomationConfig，加载对应方案的 Workflow[]
 *  4. 构造 AutomationTick（含 LessonsSnapshot、RuleContext）
 *  5. 调用 AutomationEngine.tick()
 *  6. 对每个 AutomationRun：执行行动组
 *  7. 持久化 Workflow 状态变更
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { JsonNode, JsonObject, JsonReader, JsonWriter, JsonArray } from 'common_shared';
import { Profile } from 'common_shared';
import { EngineSettings } from 'common_core';
import { LessonsEngine } from 'common_core';
import { LessonsSnapshot } from 'common_core';
import { DateTimeValue } from 'common_shared';
import { Workflow } from 'common_shared';
import { ActionSet, ActionSetStatus } from 'common_shared';
import { ActionIds } from 'common_shared';
import { AutomationEngine, AutomationTick, AutomationTickResult, AutomationRun } from 'common_core';
import { AutomationSettings } from './AutomationSettings';
import { AutomationExecutor, ExecutorContext, CauseText } from './AutomationExecutor';
import { WorkflowMutations } from 'common_core';
import { ProfileRepository } from '../data/ProfileRepository';
import { RuleContext } from 'common_core';
import { currentWeatherSnapshot } from '../weather/WeatherService';
import {
  DistributedStateService,
  resolveDistributedStateService
} from '../ipc/DistributedStateService';

const AUTOMATION_DIR: string = 'Automations';

export class AutomationTickScheduler {
  private readonly filesDir: string;
  private readonly executorCtx: ExecutorContext;
  private readonly profileRepo: ProfileRepository;
  private readonly automationSettings: AutomationSettings;
  private readonly executor: AutomationExecutor;
  private readonly engine: AutomationEngine;
  private intervalId: number | undefined;
  private running: boolean = false;
  private lastSnapshot: LessonsSnapshot | undefined;

  constructor(
    filesDir: string,
    executorCtx: ExecutorContext,
    profileRepo: ProfileRepository
  ) {
    this.filesDir = filesDir;
    this.executorCtx = executorCtx;
    this.profileRepo = profileRepo;
    this.automationSettings = new AutomationSettings(filesDir);
    this.executor = new AutomationExecutor(executorCtx);
    this.engine = new AutomationEngine();
  }

  /** 启动调度器（幂等） */
  start(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.tickOnce();
    this.intervalId = setInterval(() => this.tickOnce(), 1000) as number;
  }

  /** 停止调度器（幂等） */
  stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    if (this.intervalId !== undefined) {
      clearInterval(this.intervalId);
      this.intervalId = undefined;
    }
  }

  /** 单次 tick */
  private async tickOnce(): Promise<void> {
    const automationOn: boolean = this.automationSettings.getIsAutomationEnabled();
    // 跨设备发布与自动化共用同一次快照计算：两者都要「当前课表快照」，
    // 各算一次会读两遍档案、还可能跨过秒边界拿到两个不同的 now。
    const distributed: DistributedStateService =
      resolveDistributedStateService(this.executorCtx.context);
    const distributedOn: boolean = distributed.isEnabled();
    if (!automationOn && !distributedOn) {
      return;
    }

    const profile: Profile = this.profileRepo.load();
    const layouts = profile.timeLayouts;
    const plans = profile.classPlans;
    if (layouts === undefined || plans === undefined || layouts.size === 0 || plans.size === 0) {
      return;
    }

    const now: DateTimeValue = DateTimeValue.now();
    const previous: LessonsSnapshot | undefined = this.lastSnapshot;
    const engineSettings: EngineSettings = new EngineSettings(DateTimeValue.fromLocalMillis(0));
    const snapshot: LessonsSnapshot = LessonsEngine.compute(profile, engineSettings, now, previous);
    this.lastSnapshot = snapshot;

    if (distributedOn) {
      distributed.publish(snapshot, profile);
    }

    if (!automationOn) {
      return;
    }

    const scheme: string = this.automationSettings.getCurrentAutomationConfig();
    if (!AutomationSettings.isValidSchemeName(scheme)) {
      return;
    }

    const workflows: Workflow[] = this.loadWorkflows(scheme);
    if (workflows.length === 0) {
      return;
    }

    const ruleContext: RuleContext = new RuleContext();
    ruleContext.now = now;
    ruleContext.profile = profile;
    ruleContext.snapshot = snapshot;
    // 天气快照注入。拿不到（天气服务没起来）就是 undefined，五条天气规则全判
    // false —— 与「本轮还没刷新成功」同结果。
    ruleContext.weather = currentWeatherSnapshot();

    const tick: AutomationTick = new AutomationTick(now);
    tick.hasTrustedProfile = true;
    tick.isAutomationEnabled = true;
    tick.snapshot = snapshot;
    tick.ruleContext = ruleContext;

    const result: AutomationTickResult = this.engine.tick(workflows, tick);
    if (result.runs.length === 0) {
      return;
    }

    for (let i = 0; i < result.runs.length; i++) {
      const run: AutomationRun = result.runs[i];
      const wf: Workflow = workflows[run.workflowIndex];
      await this.executeRun(wf, run);
    }

    this.saveWorkflows(scheme, workflows);
  }

  private loadWorkflows(scheme: string): Workflow[] {
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
        return out;
      }
    } catch {
      // 文件不存在或解析失败
    }
    return [];
  }

  private saveWorkflows(scheme: string, workflows: Workflow[]): void {
    const dir: string = `${this.filesDir}/${AUTOMATION_DIR}`;
    try {
      fs.accessSync(dir);
    } catch {
      fs.mkdirSync(dir);
    }
    const path: string = `${dir}/${scheme}.json`;
    const tmp: string = `${path}.tmp.${Date.now()}`;
    const arr: JsonArray = new JsonArray();
    for (let i = 0; i < workflows.length; i++) {
      arr.push(workflows[i].toJson());
    }
    const file: fs.File = fs.openSync(tmp, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JsonWriter.writeCompact(arr), { encoding: 'utf-8' });
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(tmp, path);
  }

  private async executeRun(wf: Workflow, run: AutomationRun): Promise<void> {
    const actionSet: ActionSet = wf.actionSet;
    const causeText: CauseText = new CauseText();

    if (run.isRevert) {
      actionSet.status = ActionSetStatus.Reverting;
      for (let i = 0; i < actionSet.actions.length; i++) {
        const action = actionSet.actions[i];
        if (action.id === ActionIds.SETTINGS) {
          await this.executor.execute(action, causeText);
        }
      }
      actionSet.status = actionSet.isRevertEnabled ? ActionSetStatus.IsOn : ActionSetStatus.Normal;
    } else {
      actionSet.status = ActionSetStatus.Invoking;
      for (let i = 0; i < actionSet.actions.length; i++) {
        const action = actionSet.actions[i];
        await this.executor.execute(action, causeText);
      }
      actionSet.status = WorkflowMutations.statusAfterRun(wf, false, false);
    }
  }
}