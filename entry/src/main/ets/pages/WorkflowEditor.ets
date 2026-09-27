/**
 * 单个工作流的编辑页面：触发器列表、条件、行动列表。
 */
import { AutomationViewModel } from '../viewmodel/AutomationViewModel';
import { Workflow, TriggerSettings, ActionItem } from 'common_shared';
import { TriggerCatalog } from 'common_core';
import { ActionCatalog } from 'common_core';
import { ProfileRepository } from '../data/ProfileRepository';
import { CONTENT_MAX_WIDTH } from '../components/ContentWidth';

@Entry
@Component
export struct WorkflowEditor {
  @State vm: AutomationViewModel = new AutomationViewModel('', new ProfileRepository(''));
  @State showEditor: boolean = false;
  @State editingIndex: number = -1;
  @State loading: boolean = true;

  private get wf(): Workflow {
    return this.vm!.workflows[this.editingIndex];
  }

  aboutToAppear(): void {
    const filesDir = this.getUIContext().getHostContext()!.filesDir;
    this.vm = new AutomationViewModel(filesDir, new ProfileRepository(filesDir));
    this.loading = false;
  }

  build() {
    Column() {
      if (this.loading) {
        Text('加载中...')
          .fontSize(16)
          .margin({ top: 24 })
      } else if (this.editingIndex < 0 || this.editingIndex >= this.vm!.workflows.length) {
        Text('无效的工作流')
          .fontSize(18)
          .margin({ top: 24 })
      } else {
        // 顶部：工作流名 + 启用开关
        Row() {
          TextInput({ placeholder: '工作流名称', text: this.wf.actionSet.name ?? '' })
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .margin({ left: 16, top: 12, bottom: 12 })
            .onChange((v: string) => {
              this.wf.actionSet.name = v;
              this.vm!.saveWorkflows();
            })
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.wf.actionSet.isEnabled })
            .onChange((on: boolean) => {
              this.vm!.toggleWorkflowEnabled(this.editingIndex);
            })
            .margin({ right: 16 })
        }

        Divider()

        // 触发器区段
        Column() {
          Row() {
            Text('触发器')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
            Blank()
            if (this.wf.triggers.length < 5) {
              Button('+', { type: ButtonType.Circle })
                .width(32)
                .height(32)
                .margin({ right: 16 })
                .onClick(() => this.addTrigger())
            }
          }
          .margin({ left: 16, right: 16, bottom: 8 })

          ForEach(this.wf!.triggers, (trigger: TriggerSettings, idx: number) => {
            Row() {
              Text(this.getTriggerDisplayName(trigger.id))
                .fontSize(14)
                .margin({ left: 16, right: 12 })
                .layoutWeight(1)
                .onClick(() => this.showTriggerPicker(idx))

              Text(this.getTriggerSettingsSummary(trigger))
                .fontSize(13)
                .fontColor($r('app.color.ch_text_secondary'))
                .maxLines(1)
                .layoutWeight(1)

              Text('删除')
                .fontSize(14)
                .fontColor($r('app.color.ch_accent'))
                .margin({ right: 16 })
                .onClick(() => this.removeTrigger(idx))
            }
            .height(44)
            .backgroundColor($r('app.color.ch_surface'))
            .borderRadius(8)
            .margin({ left: 16, right: 16, top: 4, bottom: 4 })
          }, (item: TriggerSettings) => item.id)
        }
        .width('100%')

        Divider()

        // 条件区段
        Column() {
          Row() {
            Text('条件')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.wf!.isConditionEnabled })
              .onChange((on: boolean) => {
                this.wf!.isConditionEnabled = on;
                this.vm!.saveWorkflows();
              })
              .margin({ right: 16 })
          }
          .margin({ left: 16, right: 16, bottom: 8 })

          if (this.wf!.isConditionEnabled) {
            Text('条件编辑器：复用 RulesetEditorView（待接入）')
              .fontSize(14)
              .fontColor($r('app.color.ch_text_hint'))
              .margin({ left: 16, right: 16, top: 8, bottom: 8 })
          } else {
            Text('条件已关闭，工作流将无条件触发')
              .fontSize(14)
              .fontColor($r('app.color.ch_text_hint'))
              .margin({ left: 16, right: 16, top: 8, bottom: 8 })
          }
        }
        .width('100%')

        Divider()

        // 行动区段
        Column() {
          Row() {
            Text('行动')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
            Blank()
            if (this.wf!.actionSet.actions.length < 10) {
              Button('+', { type: ButtonType.Circle })
                .width(32)
                .height(32)
                .margin({ right: 16 })
                .onClick(() => this.addAction())
            }
          }
          .margin({ left: 16, right: 16, bottom: 8 })

          ForEach(this.wf!.actionSet.actions, (action: ActionItem, idx: number) => {
            Row() {
              Text(this.getActionDisplayName(action.id))
                .fontSize(14)
                .margin({ left: 16, right: 12 })
                .layoutWeight(1)
                .onClick(() => this.showActionPicker(idx))

              Text(this.getActionSettingsSummary(action))
                .fontSize(13)
                .fontColor($r('app.color.ch_text_secondary'))
                .maxLines(1)
                .layoutWeight(1)

              Text('删除')
                .fontSize(14)
                .fontColor($r('app.color.ch_accent'))
                .margin({ right: 16 })
                .onClick(() => this.removeAction(idx))
            }
            .height(44)
            .backgroundColor($r('app.color.ch_surface'))
            .borderRadius(8)
            .margin({ left: 16, right: 16, top: 4, bottom: 4 })
          }, (item: ActionItem) => item.id)

          // 恢复开关
          Row() {
            Text('可恢复')
              .fontSize(14)
            Toggle({ type: ToggleType.Switch, isOn: this.wf!.actionSet.isRevertEnabled })
              .onChange((on: boolean) => {
                this.wf!.actionSet.isRevertEnabled = on;
                this.vm!.saveWorkflows();
              })
              .margin({ left: 16 })
          }
          .margin({ left: 16, right: 16, top: 8 })
        }
        .width('100%')
      }
    }
    .padding({ bottom: 24 })
    .backgroundColor($r('app.color.ch_surface_weak'))
    .width('100%')
    // 宽屏封顶居中，理由见 ContentWidth.ets 头注
    .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
    .alignSelf(ItemAlign.Center)
  }

  // --- 触发器相关 ---

  private getTriggerDisplayName(id: string): string {
    return TriggerCatalog.displayNameOf(id) + ` (${id})`;
  }

  private getTriggerSettingsSummary(trigger: TriggerSettings): string {
    if (!trigger.settings) return '无设置';
    const str = JSON.stringify(trigger.settings);
    return str.length > 30 ? str.substring(0, 30) + '…' : str;
  }

  private addTrigger(): void {
    const trigger: TriggerSettings = new TriggerSettings();
    trigger.id = '';
    this.wf!.triggers.push(trigger);
    this.vm!.saveWorkflows();
  }

  private removeTrigger(idx: number): void {
    this.wf!.triggers.splice(idx, 1);
    this.vm!.saveWorkflows();
  }

  private showTriggerPicker(idx: number): void {
    // TODO: 实现触发器选择器
  }

  // --- 行动相关 ---

  private getActionDisplayName(id: string): string {
    return ActionCatalog.displayNameOf(id) + ` (${id})`;
  }

  private getActionSettingsSummary(action: ActionItem): string {
    if (!action.settings) return '无设置';
    const str = JSON.stringify(action.settings);
    return str.length > 30 ? str.substring(0, 30) + '…' : str;
  }

  private addAction(): void {
    const action: ActionItem = new ActionItem();
    action.id = '';
    this.wf!.actionSet.actions.push(action);
    this.vm!.saveWorkflows();
  }

  private removeAction(idx: number): void {
    this.wf!.actionSet.actions.splice(idx, 1);
    this.vm!.saveWorkflows();
  }

  private showActionPicker(idx: number): void {
    // TODO: 实现行动选择器
  }
}