/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 编辑页共用的小控件。
 *
 * 为什么文本框不直接双向绑到 ViewModel
 * ----------------------------------
 * 直接 onChange -> ViewModel 的话，每敲一个键都要重建全部行数组并重算一次
 * 脏检查（整份档案序列化）。档案大一点这就是每键几毫秒，输入会发涩，而且
 * 每敲一键都让几十行重绘。
 *
 * 所以这里让文本框自己持有一份草稿，只在「提交」（回车 / 失焦）时通知外面。
 * 外面改了值但当前没在编辑时才同步回来 —— 用户正在输入时把他敲的半截字
 * 冲掉是这类输入框最招人烦的毛病。
 *
 * 破坏性操作一律走二次确认
 * ----------------------
 * 删科目会让所有引用它的课次变成空位，删时间表会让绑定的课表解绑，删课表群
 * 会连带删掉群内所有课表。这些都不是「点错了退回来」能解决的（已经写进草稿，
 * 退回来要点放弃）。所以统一用带确认的按钮，措辞里必须写清会波及什么 ——
 * 只写「确定删除吗」的话用户点完之后才发现课没了。
 */

import { ClassPlanGroupRow, ClassSlotRow, SubjectRow, TimeLayoutRow, TimePointRow } from 'common_core';
import { UiFeedback } from '../common/UiFeedback';

/**
 * 分页标题条。
 *
 * 放在共享控件里而不是每个分页各写一份：返回按钮的行为、字号、点击热区
 * 一旦有分页漏了复制，用户就会在某页上发现返回失灵，而这类不一致极难定位。
 */
@ComponentV2
export struct EditorHeader {
  @Param title: string = '';
  @Param stack: NavPathStack = new NavPathStack();

  build() {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor($r('app.color.ch_text_primary'))
        .width(32)
        .onClick(() => {
          this.stack.pop();
        })
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .alignItems(VerticalAlign.Center)
    .padding({ left: 8, right: 12 })
  }
}

/** 卡片式容器。编辑页的每个分块都用它，好让留白与分隔统一。 */
@ComponentV2
export struct EditorCard {
  @Param title: string = '';
  @Param hint: string = '';
  @Param trailing: string = '';

  build() {
    Column() {
      if (this.title.length > 0) {
        Row() {
          Text(this.title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ch_text_primary'))
            .layoutWeight(1)
          if (this.trailing.length > 0) {
            Text(this.trailing)
              .fontSize(12)
              .fontColor($r('app.color.ch_text_hint'))
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(12)
          .fontColor($r('app.color.ch_text_hint'))
          .margin({ top: 4, bottom: 8 })
      }
    }
    .width('100%')
  }
}

/** 一行「标签 + 值」的只读展示。 */
@ComponentV2
export struct EditorValueRow {
  @Param label: string = '';
  @Param value: string = '';
  @Param isWarning: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize(13)
        .fontColor($r('app.color.ch_text_secondary'))
        .width(76)
      Text(this.value)
        .fontSize(13)
        .fontColor(this.isWarning ? $r('app.color.ch_accent') : $r('app.color.ch_text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 3, bottom: 3 })
  }
}

/**
 * 标签 + 单行输入。
 *
 * 值由外面给，本控件只在提交（回车 / 失焦）时通知外面改。
 *
 * 为什么不在每次外部值变化时同步回来
 * ------------------------------
 * 直接把 TextInput 的 text 绑到外部值上、onChange 就改档案的话，每敲一键都要
 * 重建全部行数组并重算一次脏检查（整份档案序列化），档案大一点就是每键几
 * 毫秒，输入会发涩。
 *
 * 代价是外部改了值这里不会跟着变。这个代价在本工程可以接受，因为外部能在
 * 控件存活期间改同一个字段的路径不存在：导入是整份替换草稿，而导入入口在
 * 编辑主页，各分页是在那之后才被 push 进来的，一律全新挂载。将来若加出「在
 * 另一个地方改名、这边实时跟着变」的需求，这里要补一个显式的 syncToken 参数
 * 并在 build 里比对 —— 但那时候也得先想清楚不能让正在输入的那一格被冲掉。
 */
@ComponentV2
export struct EditorTextField {
  @Param label: string = '';
  @Param value: string = '';
  @Param placeholder: string = '';
  /** 0 普通文本，1 数字。 */
  @Param type: number = 0;
  @Event onCommit: (text: string) => void = (text: string) => {};

  @Local draft: string = '';

  aboutToAppear(): void {
    this.draft = this.value;
  }

  private commit(): void {
    if (this.draft !== this.value) {
      this.onCommit(this.draft);
    }
  }

  build() {
    Row() {
      Text(this.label)
        .fontSize(13)
        .fontColor($r('app.color.ch_text_secondary'))
        .width(76)
      TextInput({ text: this.draft, placeholder: this.placeholder })
        .type(this.type === 1 ? InputType.Number : InputType.Normal)
        .fontSize(13)
        .backgroundColor($r('app.color.ch_surface_alt'))
        .borderRadius(6)
        .layoutWeight(1)
        .onChange((next: string) => {
          this.draft = next;
        })
        .onBlur(() => {
          this.commit();
        })
        .onSubmit(() => {
          this.commit();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 4, bottom: 4 })
  }
}

/** 一行开关。 */
@ComponentV2
export struct EditorToggleRow {
  @Param label: string = '';
  @Param hint: string = '';
  @Param isOn: boolean = false;
  @Event onToggle: (isOn: boolean) => void = (isOn: boolean) => {};

  build() {
    Row() {
      Column() {
        Text(this.label)
          .fontSize(13)
          .fontColor($r('app.color.ch_text_primary'))
        if (this.hint.length > 0) {
          Text(this.hint)
            .fontSize(11)
            .fontColor($r('app.color.ch_text_hint'))
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor($r('app.color.ch_accent'))
        .onChange((next: boolean) => {
          this.onToggle(next);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 4, bottom: 4 })
  }
}

/** 一个小按钮。用它而不是 Button：Button 默认的胶囊造型在这个列表里太重。 */
@ComponentV2
export struct EditorChip {
  @Param text: string = '';
  @Param tone: number = 0;
  @Event onTap: () => void = () => {};

  build() {
    Text(this.text)
      .fontSize(12)
      .fontColor(this.tone === 1 ? $r('app.color.ch_accent') : $r('app.color.ch_text_secondary'))
      .backgroundColor(this.tone === 1 ? $r('app.color.ch_accent_soft') : $r('app.color.ch_surface_alt'))
      .borderRadius(10)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .onClick(() => {
        this.onTap();
      })
  }
}

/** 空态提示。列表为空时给出下一步该做什么，而不是留一片空白。 */
@ComponentV2
export struct EditorEmptyHint {
  @Param text: string = '';

  build() {
    Text(this.text)
      .fontSize(12)
      .fontColor($r('app.color.ch_text_hint'))
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ top: 16, bottom: 16 })
  }
}

/**
 * 破坏性按钮，自带二次确认。
 *
 * @param message 确认文案。必须写清会波及什么，不要只写「确定删除吗」。
 */
@ComponentV2
export struct EditorDeleteButton {
  @Param text: string = '删除';
  @Param message: string = '';
  @Event onConfirm: () => void = () => {};

  build() {
    Text(this.text)
      .fontSize(12)
      .fontColor($r('app.color.ch_accent'))
      .backgroundColor($r('app.color.ch_accent_soft'))
      .borderRadius(10)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .onClick(() => {
        UiFeedback.confirm(this.getUIContext(), this.text, this.message, this.text,
          () => { this.onConfirm(); });
      })
  }
}

/** 科目行的展开态按钮组。 */
@ComponentV2
export struct SubjectRowHeader {
  @Param row: SubjectRow = new SubjectRow();
  @Param isExpanded: boolean = false;
  @Event onToggle: () => void = () => {};
  @Event onMoveUp: () => void = () => {};
  @Event onMoveDown: () => void = () => {};
  @Event onDelete: () => void = () => {};

  build() {
    Column() {
      Row() {
        Text(this.row.name.length > 0 ? this.row.name : '（未命名科目）')
          .fontSize(14)
          .fontColor($r('app.color.ch_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.row.isOutDoor) {
          Text('室外')
            .fontSize(11)
            .fontColor($r('app.color.ch_next'))
            .margin({ right: 8 })
        }
        if (this.row.usedByClassesTotal > 0) {
          Text(`${this.row.usedByClassesTotal} 处`)
            .fontSize(11)
            .fontColor($r('app.color.ch_text_hint'))
            .margin({ right: 8 })
        }
        Text(this.isExpanded ? '收起' : '展开')
          .fontSize(12)
          .fontColor($r('app.color.ch_accent'))
          .onClick(() => {
            this.onToggle();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.isExpanded) {
        Row() {
          EditorChip({ text: '上移', onTap: () => { this.onMoveUp(); } })
          Blank()
          EditorChip({ text: '下移', onTap: () => { this.onMoveDown(); } })
          Blank()
          EditorDeleteButton({
            text: '删除',
            message: this.row.usedByClassesTotal > 0
              ? `「${this.row.name}」正被 ${this.row.usedByClassesTotal} 节课引用。` +
                '删除后这些课次会变成空白，其余不受影响。'
              : `「${this.row.name}」没有被任何课次引用。`,
            onConfirm: () => { this.onDelete(); }
          })
        }
        .width('100%')
        .margin({ top: 8 })
      }
    }
    .width('100%')
  }
}

/** 时间点行的只读摘要（列表里那一行）。 */
@ComponentV2
export struct TimePointRowSummary {
  @Param row: TimePointRow = new TimePointRow();

  build() {
    Row() {
      Text(this.row.classSlotText.length > 0 ? this.row.classSlotText : this.row.timeTypeText)
        .fontSize(12)
        .fontColor($r('app.color.ch_text_secondary'))
        .width(64)
        .maxLines(1)
      Text(`${this.row.startText}-${this.row.endText}`)
        .fontSize(12)
        .fontColor($r('app.color.ch_text_primary'))
        .width(104)
      if (this.row.breakName.length > 0) {
        Text(this.row.breakName)
          .fontSize(12)
          .fontColor($r('app.color.ch_text_hint'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      } else if (this.row.defaultSubjectName.length > 0) {
        Text(`默认 ${this.row.defaultSubjectName}`)
          .fontSize(12)
          .fontColor($r('app.color.ch_text_hint'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      } else {
        Blank()
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}

/** 课次（排课格子）的一行。 */
@ComponentV2
export struct ClassSlotRowView {
  @Param row: ClassSlotRow = new ClassSlotRow();
  @Event onPick: () => void = () => {};
  @Event onToggleEnabled: () => void = () => {};

  build() {
    Row() {
      Text(this.row.slotText)
        .fontSize(12)
        .fontColor($r('app.color.ch_text_secondary'))
        .width(64)

      Text(this.row.isEmpty ? '（空）' : this.row.subjectName)
        .fontSize(14)
        .fontColor(this.row.isEmpty ? $r('app.color.ch_text_hint') : $r('app.color.ch_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .onClick(() => {
          this.onPick();
        })

      if (this.row.hasDefault) {
        Text('有默认')
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .margin({ right: 8 })
      }

      Toggle({ type: ToggleType.Switch, isOn: this.row.isEnabled })
        .width(40)
        .height(20)
        .selectedColor($r('app.color.ch_accent'))
        .onChange(() => {
          this.onToggleEnabled();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 6, bottom: 6 })
  }
}

/** 课表群一行。 */
@ComponentV2
export struct ClassPlanGroupRowView {
  @Param row: ClassPlanGroupRow = new ClassPlanGroupRow();
  @Event onSelect: () => void = () => {};
  @Event onDelete: () => void = () => {};
  @Event onDisband: () => void = () => {};

  build() {
    Row() {
      Column() {
        Row() {
          Text(this.row.name)
            .fontSize(14)
            .fontColor($r('app.color.ch_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.row.isDefault) {
            Text('默认')
              .fontSize(11)
              .fontColor($r('app.color.ch_text_hint'))
              .margin({ left: 6 })
          }
          if (this.row.isGlobal) {
            Text('全局')
              .fontSize(11)
              .fontColor($r('app.color.ch_text_hint'))
              .margin({ left: 6 })
          }
        }
        .width('100%')

        Text(`${this.row.planCount} 张课表`)
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.row.isSelected) {
        Text('当前')
          .fontSize(11)
          .fontColor($r('app.color.ch_accent'))
          .margin({ right: 8 })
      } else {
        Text('设为当前')
          .fontSize(12)
          .fontColor($r('app.color.ch_accent'))
          .margin({ right: 8 })
          .onClick(() => {
            this.onSelect();
          })
      }

      // 默认群与全局群不可解散也不可删除：删掉它们改的是选课结果而不只是
      // 少一个列表项，所以按钮整个不出现，而不是出现了一个点了没反应
      if (this.row.canDisband) {
        EditorChip({ text: '解散', onTap: () => { this.onDisband(); } })
          .margin({ right: 6 })
      }
      if (this.row.canDelete) {
        EditorDeleteButton({
          text: '删除',
          message: this.row.planCount > 0
            ? `「${this.row.name}」里有 ${this.row.planCount} 张课表，删除课表群会一并删除它们。`
            : `「${this.row.name}」是空的。`,
          onConfirm: () => { this.onDelete(); }
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 6, bottom: 6 })
  }
}

/** 时间表一行（列表里的折叠项）。 */
@ComponentV2
export struct TimeLayoutRowHeader {
  @Param row: TimeLayoutRow = new TimeLayoutRow();
  @Param isExpanded: boolean = false;
  @Event onToggle: () => void = () => {};

  build() {
    Row() {
      Text(this.row.name)
        .fontSize(14)
        .fontColor($r('app.color.ch_text_primary'))
        .maxLines(1)
        .layoutWeight(1)
      Text(`${this.row.classCount} 节 · ${this.row.rowCount} 行`)
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .margin({ right: 8 })
      Text(this.isExpanded ? '收起' : '展开')
        .fontSize(12)
        .fontColor($r('app.color.ch_accent'))
        .onClick(() => {
          this.onToggle();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 8, bottom: 4 })
  }
}
