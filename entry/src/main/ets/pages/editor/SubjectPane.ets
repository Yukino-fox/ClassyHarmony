/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 科目页。
 *
 * 展开态才显示编辑项
 * ----------------
 * 科目几十个，每行都摆满输入框的话页面就没法看了。而且改哪一个是明确的
 * 用户行为，展开就是「我现在要改这个」。收起态只留名字、室外标记、被引用
 * 次数 —— 引用次数必须留在收起态，因为它是判断「删掉会不会出事」的唯一依据。
 *
 * 新建完自动展开新行
 * ------------------
 * 新建一个科目之后，用户下一步一定是改它的名字。如果新建完还收着，用户会
 * 以为没建成功（看不到新名字），或者手动去找哪一行是新的。
 */

import { t, tf } from 'common_core';
import { SubjectRow } from 'common_core';
import { ScheduleEditorViewModel } from '../../viewmodel/ScheduleEditorViewModel';
import {
  EditorChip,
  EditorEmptyHint,
  EditorHeader,
  EditorTextField,
  EditorToggleRow,
  SubjectRowHeader
} from '../../components/EditorWidgets';

/** 收纳态只记 guid，展开态记 guid -> 处于展开。 */
@ComponentV2
export struct SubjectPane {
  @Require @Param vm: ScheduleEditorViewModel;
  @Param stack: NavPathStack = new NavPathStack();

  @Local expanded: string = '';

  private isExpanded(guid: string): boolean {
    return this.expanded === guid;
  }

  private toggle(guid: string): void {
    this.expanded = this.isExpanded(guid) ? '' : guid;
  }

  private add(): void {
    this.expanded = this.vm.addSubject(t('sub_default_name'));
  }

  build() {
    NavDestination() {
      Column() {
        EditorHeader({ title: t('sub_title'), stack: this.stack })

        Scroll() {
          Column() {
            if (this.vm.subjects.length === 0) {
              EditorEmptyHint({ text: t('sub_no_subjects') })
            }
            ForEach(this.vm.subjects, (row: SubjectRow) => {
              Column() {
                SubjectRowHeader({
                  row: row,
                  isExpanded: this.isExpanded(row.guid),
                  onToggle: () => { this.toggle(row.guid); },
                  onMoveUp: () => { this.vm.moveSubject(row.guid, -1); },
                  onMoveDown: () => { this.vm.moveSubject(row.guid, 1); },
                  onDelete: () => { this.vm.removeSubject(row.guid); }
                })

                if (this.isExpanded(row.guid)) {
                  this.detail(this.vm, row)
                }
              }
              .width('100%')
              .padding({ top: 4, bottom: 8 })

              Divider().color($r('app.color.ch_outline'))
            }, (row: SubjectRow) => row.guid)

            EditorChip({ text: t('sub_add'), onTap: () => { this.add(); } })
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

  @Builder
  private detail(vm: ScheduleEditorViewModel, row: SubjectRow) {
    Column() {
      EditorTextField({
        label: t('sub_name'),
        value: row.name,
        placeholder: t('sub_name_hint'),
        onCommit: (text: string) => { vm.renameSubject(row.guid, text); }
      })
      EditorTextField({
        label: t('sub_initial'),
        value: row.initial,
        placeholder: t('sub_name_placeholder'),
        onCommit: (text: string) => { vm.setSubjectInitial(row.guid, text); }
      })
      EditorTextField({
        label: t('sub_teacher'),
        value: row.teacherName,
        placeholder: t('sub_optional'),
        onCommit: (text: string) => { vm.setSubjectTeacher(row.guid, text); }
      })
      EditorToggleRow({
        label: t('sub_outdoor'),
        hint: t('sub_outdoor_hint'),
        isOn: row.isOutDoor,
        onToggle: (isOn: boolean) => { vm.setSubjectOutDoor(row.guid, isOn); }
      })

      if (row.usedByClassesTotal > 0) {
        Text(tf('sub_used_by', `${row.usedByPlans}`, `${row.usedByClassesTotal}`))
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .width('100%')
          .margin({ top: 6 })
      } else {
        Text(t('sub_no_classes_use'))
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .width('100%')
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .padding({ left: 8, top: 6 })
  }
}
