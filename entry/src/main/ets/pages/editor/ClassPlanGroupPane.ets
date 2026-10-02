/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 课表群页。
 *
 * 默认群与全局群不可改、不可删
 * ------------------------
 * 按钮整个不出现，而不是出现一个点了没反应。它们的 guid 是常量，改不了
 * 「默认群」这个概念 —— 只能改「现在选中哪个群」。界面上把这两行画成可点
 * 的话，用户会以为「默认」只是一条记录，改了之后才发现整个档案里所有
 * associatedGroup 都指向它，改不动。
 *
 * 解散与删除的区别要在界面上讲清
 * --------------------------
 * 解散 = 群没了，群里的课表留着，落到默认群。删除 = 群和群里的课表一起没了。
 * 这两个词从字面上看不出来差别，而点错的后果差一个量级（一个丢一个群，
 * 一个丢一批课表）。所以两个按钮分开摆，不做成「删除 / 解散」的下拉。
 */

import { t } from 'common_core';
import { ClassPlanGroupRow } from 'common_core';
import { ScheduleEditorViewModel } from '../../viewmodel/ScheduleEditorViewModel';
import { UiFeedback } from '../../common/UiFeedback';
import {
  ClassPlanGroupRowView,
  EditorChip,
  EditorEmptyHint,
  EditorHeader,
  EditorTextField
} from '../../components/EditorWidgets';

@ComponentV2
export struct ClassPlanGroupPane {
  @Require @Param vm: ScheduleEditorViewModel;
  @Param stack: NavPathStack = new NavPathStack();

  @Local expanded: string = '';

  private newGroup(): void {
    this.expanded = this.vm.addClassPlanGroup('新课表群');
  }

  build() {
    NavDestination() {
      Column() {
        EditorHeader({ title: '课表群', stack: this.stack })

        Scroll() {
          Column() {
            Text(t('cgp_desc'))
              .fontSize(11)
              .fontColor($r('app.color.ch_text_hint'))
              .width('100%')
              .margin({ bottom: 8 })

            if (this.vm.groups.length === 0) {
              EditorEmptyHint({ text: t('cgp_no_groups') })
            }

            ForEach(this.vm.groups, (row: ClassPlanGroupRow) => {
              Column() {
                ClassPlanGroupRowView({
                  row: row,
                  onSelect: () => { this.vm.selectClassPlanGroup(row.guid); },
                  onDelete: () => { this.vm.deleteClassPlanGroup(row.guid); },
                  onDisband: () => {
                    UiFeedback.confirm(
                      this.getUIContext(),
                      '解散课表群',
                      `群会被删掉，里面 ${row.planCount} 张课表留着，落到默认群。` +
                        t('cgp_delete_hint'),
                      '解散',
                      () => { this.vm.disbandClassPlanGroup(row.guid); }
                    );
                  }
                })

                if (this.expanded === row.guid) {
                  EditorTextField({
                    label: '群名',
                    value: row.name,
                    placeholder: '群名',
                    onCommit: (text: string) => { this.vm.renameClassPlanGroup(row.guid, text); }
                  })
                } else {
                  Row() {
                    EditorChip({
                      text: '改名',
                      onTap: () => {
                        this.expanded = this.expanded === row.guid ? '' : row.guid;
                      }
                    })
                    Blank()
                  }
                  .width('100%')
                  .padding({ top: 4, bottom: 4 })
                }
              }
              .width('100%')
              .padding({ top: 6, bottom: 6 })

              Divider().color($r('app.color.ch_outline'))
            }, (row: ClassPlanGroupRow) => row.guid)

            EditorChip({ text: '新建课表群', onTap: () => { this.newGroup(); } })
              .margin({ top: 16 })
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 24 })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
  }
}
