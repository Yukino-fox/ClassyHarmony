/**
 * 自动化主页面：工作流列表 + 编辑器入口。
 */
import { AutomationViewModel } from '../viewmodel/AutomationViewModel';
import { AutomationSettings } from '../automation/AutomationSettings';
import { ProfileRepository } from '../data/ProfileRepository';
import { Workflow } from 'common_shared';
import { CONTENT_MAX_WIDTH } from '../components/ContentWidth';

@Entry
@Component
export struct Automation {
  @State vm: AutomationViewModel = new AutomationViewModel('', new ProfileRepository(''));
  @State showEditor: boolean = false;
  @State editingIndex: number = -1;
  @State loading: boolean = true;

  aboutToAppear(): void {
    const filesDir = this.getUIContext().getHostContext()!.filesDir;
    this.vm = new AutomationViewModel(filesDir, new ProfileRepository(filesDir));
    AutomationViewModel.createDefaultScheme(filesDir);
    this.loading = false;
  }

  build() {
    Column() {
      if (this.loading) {
        Text('加载中...')
          .fontSize(16)
          .margin({ top: 24 })
      } else {
        Navigation() {
          Column() {
            // 顶部：总开关
            Row() {
              Text('自动化')
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .margin({ left: 16, top: 12, bottom: 12 })
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.vm!.isEnabled })
                .onChange((on: boolean) => this.vm!.setEnabled(on))
                .margin({ right: 16 })
            }
            .height(56)
            .backgroundColor($r('app.color.ch_surface'))

            Divider()

            // 方案显示
            Row() {
              Text('方案：')
                .fontSize(16)
                .margin({ left: 16 })
              Text(this.vm!.currentScheme)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .margin({ left: 8 })
              Blank()
            }
            .height(48)
            .backgroundColor($r('app.color.ch_surface'))

            Divider()

            // 工作流列表
            List() {
              ForEach(this.vm!.workflows, (wf: Workflow, index: number) => {
                ListItem() {
                  Row() {
                    Toggle({ type: ToggleType.Switch, isOn: wf.actionSet.isEnabled })
                      .onChange((on: boolean) => {
                        this.vm!.toggleWorkflowEnabled(index);
                      })
                      .margin({ left: 16 })

                    Column() {
                      Text(this.vm!.getWorkflowDisplayName(index))
                        .fontSize(16)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Row() {
                        Text(`${wf.triggers.length} 个触发器`)
                          .fontSize(12)
                          .fontColor($r('app.color.ch_text_hint'))
                        Text(' · ')
                          .fontSize(12)
                          .fontColor($r('app.color.ch_text_hint'))
                        Text(`${wf.actionSet.actions.length} 个行动`)
                          .fontSize(12)
                          .fontColor($r('app.color.ch_text_hint'))
                      }
                    }
                    .margin({ left: 12, top: 8, bottom: 8 })

                    Blank()

                    Text('编辑')
                      .fontSize(14)
                      .fontColor($r('app.color.ch_accent'))
                      .margin({ right: 16 })
                      .onClick(() => {
                        this.editingIndex = index;
                        this.showEditor = true;
                      })
                  }
                  .height(72)
                }

              }, (item: Workflow) => item.actionSet.guid.toString())
            }
            .divider({ strokeWidth: 1, color: $r('app.color.ch_outline'), startMargin: 16, endMargin: 16 })
            .layoutWeight(1)

            // 底部新建按钮
            Button('新建工作流', { type: ButtonType.Capsule })
              .width('90%')
              .height(44)
              .margin({ bottom: 24 })
              .onClick(() => {
                this.editingIndex = this.vm!.addWorkflow();
                this.showEditor = true;
              })
          }
          .backgroundColor($r('app.color.ch_surface_weak'))
        }
        .title('自动化')
        .hideTitleBar(false)
        .mode(NavigationMode.Stack)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.ch_surface_weak'))
    // 宽屏封顶居中，理由见 ContentWidth.ets 头注
    .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
    .alignSelf(ItemAlign.Center)
  }
}
