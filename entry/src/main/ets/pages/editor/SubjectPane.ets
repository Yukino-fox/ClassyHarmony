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
    this.expanded = this.vm.addSubject('新课程');
  }

  build() {
    NavDestination() {
      Column() {
        EditorHeader({ title: '科目', stack: this.stack })

        Scroll() {
          Column() {
            if (this.vm.subjects.length === 0) {
              EditorEmptyHint({ text: '还没有科目。先添加科目，再去课表里排课。' })
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

            EditorChip({ text: '添加科目', onTap: () => { this.add(); } })
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
        label: '名称',
        value: row.name,
        placeholder: '科目名',
        onCommit: (text: string) => { vm.renameSubject(row.guid, text); }
      })
      EditorTextField({
        label: '简称',
        value: row.initial,
        placeholder: '课表里显示的一两个字',
        onCommit: (text: string) => { vm.setSubjectInitial(row.guid, text); }
      })
      EditorTextField({
        label: '教师',
        value: row.teacherName,
        placeholder: '选填',
        onCommit: (text: string) => { vm.setSubjectTeacher(row.guid, text); }
      })
      EditorToggleRow({
        label: '室外课',
        hint: '在课表上会标出来',
        isOn: row.isOutDoor,
        onToggle: (isOn: boolean) => { vm.setSubjectOutDoor(row.guid, isOn); }
      })

      if (row.usedByClassesTotal > 0) {
        Text(`被 ${row.usedByPlans} 张课表、共 ${row.usedByClassesTotal} 节课引用。`)
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .width('100%')
          .margin({ top: 6 })
      } else {
        Text('还没有课次引用这个科目。')
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
