/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 布局里一行的可视化与操作。
 *
 * 展平渲染而不是递归渲染
 * ----------------------
 * ViewModel 把「行 → 容器 → 子容器」展平成一个 PanelComponentRow 数组，深度
 * 记在每一行上。这里只跑一层 ForEach，按 depth 缩进。
 *
 * 递归不是不行，是不值得：容器深度由数据决定，用 @Builder 递归调用渲染就得让
 * @Builder 间接一层，而它返回 void、不能挂修饰符，交互回调只能从外面闭包
 * 捕获 —— 每多一层递归捕获链就长一截。展平之后 ForEach 的 key 用「行 + 完整
 * 下标路径」，增删移换之后 key 天然变，ArkUI 会重建而不是复用错位。
 *
 * 位置而不是引用
 * -------------
 * 组件在容器里没有身份，只有一个下标。所以每一行渲染时只带一个
 * ComponentLocation，所有操作都把它交回 ViewModel —— 界面不持有组件引用，
 * 也就不会出现「拿着一个已经被移走的引用去改设置」。
 *
 * 展开式操作面板
 * --------------
 * 选中一个组件后在它下面内联展开操作，而不是弹窗或长按菜单。理由与编辑页
 * 那些分页一致：API 26 上 ActionSheetOptions 只剩 title/subtitle/message/
 * confirm/cancel，做不了多行选项列表；弹窗还会遮住用户正在看的那个组件。
 */

import { ComponentLocation } from 'common_core';
import { EditorChip, EditorEmptyHint } from '../../components/EditorWidgets';
import {
  AddableComponent,
  ComponentLayoutViewModel,
  PanelComponentRow,
  PanelLineRow,
  addableComponents
} from '../../viewmodel/ComponentLayoutViewModel';

/** 每层缩进多少 vp。 */
const INDENT_VP: number = 16;

/**
 * 一排可选的组件类型。
 *
 * 用 Flex + Wrap 而不是手算下标拼两列：数量会随插件增长，手算的分组逻辑
 * 每次加组件都要跟着改一遍，而 Wrap 自己会折行。
 */
@ComponentV2
struct ComponentPicker {
  @Param title: string = '';
  @Event onPick: (guid: string) => void = (guid: string) => {};

  build() {
    Column() {
      if (this.title.length > 0) {
        Text(this.title)
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .width('100%')
          .margin({ bottom: 6 })
      }
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(addableComponents(), (item: AddableComponent) => {
          Text(item.name)
            .fontSize(12)
            .fontColor($r('app.color.ch_accent'))
            .backgroundColor($r('app.color.ch_accent_soft'))
            .borderRadius(10)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .margin({ right: 6, bottom: 6 })
            .onClick(() => {
              this.onPick(item.guid);
            })
        }, (item: AddableComponent) => item.guid)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 8, bottom: 4 })
  }
}

/** 一个组件。选中后在下方展开操作。 */
@ComponentV2
struct ComponentRowView {
  @Require @Param vm: ComponentLayoutViewModel;
  @Require @Param row: PanelComponentRow;
  @Param isSelected: boolean = false;
  @Event onSelect: (row: PanelComponentRow) => void = (row: PanelComponentRow) => {};
  @Event onOpenSettings: (row: PanelComponentRow) => void = (row: PanelComponentRow) => {};

  /** 正在给这个容器挑要加的组件。 */
  @Local picking: boolean = false;
  /** 正在挑「换成哪种组件」。 */
  @Local replacing: boolean = false;

  private add(guid: string): void {
    this.vm.addComponent(this.row.location, guid);
    this.picking = false;
  }

  private replace(guid: string): void {
    this.vm.replaceComponentAt(this.row.location, guid);
    this.replacing = false;
  }

  @Builder
  private actions() {
    Row() {
      if (this.row.isKnown) {
        EditorChip({
          text: '设置',
          tone: 1,
          onTap: () => { this.onOpenSettings(this.row); }
        })
      } else {
        // 未注册的组件没有设置面板可进。给它一个说明而不是一个点不动的按钮。
        Text('未识别组件，无法设置')
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .margin({ right: 8, top: 4, bottom: 4 })
      }

      EditorChip({
        text: '前移',
        disabled: this.row.siblingIndex === 0,
        onTap: () => { this.vm.shiftSibling(this.row.location, -1); }
      })
      EditorChip({
        text: '后移',
        disabled: this.row.siblingIndex >= this.row.siblingCount - 1,
        onTap: () => { this.vm.shiftSibling(this.row.location, 1); }
      })
      if (this.row.location.path.length > 1) {
        EditorChip({
          text: '移出容器',
          onTap: () => { this.vm.moveOutToLine(this.row.location); }
        })
      }
      if (this.row.isContainer) {
        EditorChip({
          text: '添加子组件',
          onTap: () => { this.picking = !this.picking; }
        })
      }
      // 替换只在用户主动要它时把选择器展开：它会把这个位置上的组件连同设置一起
      // 换掉，属于不可逆的那一类，不该和「前移后移」摆在同一排里当日常操作。
      EditorChip({
        text: '替换',
        onTap: () => { this.replacing = !this.replacing; }
      })
      EditorChip({
        text: '删除',
        tone: 1,
        onTap: () => { this.vm.removeComponent(this.row.location); }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ top: 6 })
  }

  build() {
    Column() {
      Row() {
        Text(this.row.displayName)
          .fontSize(14)
          .fontColor(this.row.isKnown
            ? $r('app.color.ch_text_primary')
            : $r('app.color.ch_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: this.row.depth * INDENT_VP })
          .layoutWeight(1)

        if (this.row.isContainer) {
          this.tag('容器')
        }
        if (this.row.hideOnRule) {
          // 规则判定在 P8。这里只透出「开了这个开关」这件事，不假装它在生效。
          this.tag('规则待支持')
        }

        Text(this.isSelected ? '收起' : '操作')
          .fontSize(12)
          .fontColor($r('app.color.ch_accent'))
          .padding({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 8, bottom: 4 })
      .onClick(() => {
        this.onSelect(this.row);
      })

      if (this.row.isTruncated) {
        Text('嵌套太深，子组件没有展开')
          .fontSize(11)
          .fontColor($r('app.color.ch_accent'))
          .width('100%')
          .padding({ bottom: 4 })
      }

      if (this.isSelected) {
        this.actions()
        if (this.row.isContainer && this.picking) {
          ComponentPicker({
            title: `往「${this.row.displayName}」里添加`,
            onPick: (guid: string) => { this.add(guid); }
          })
        }
        if (this.replacing) {
          ComponentPicker({
            title: `把「${this.row.displayName}」换成`,
            onPick: (guid: string) => { this.replace(guid); }
          })
        }
      }
    }
    .width('100%')
  }

  @Builder
  private tag(text: string) {
    Text(text)
      .fontSize(10)
      .fontColor($r('app.color.ch_text_hint'))
      .backgroundColor($r('app.color.ch_surface_alt'))
      .borderRadius(8)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .margin({ right: 6 })
  }
}

/** 一行：标题、显示开关、行的前后移动，以及这一行里的全部组件。 */
@ComponentV2
export struct ComponentLineView {
  @Require @Param vm: ComponentLayoutViewModel;
  @Require @Param lineRow: PanelLineRow;
  @Event onOpenSettings: (row: PanelComponentRow) => void = (row: PanelComponentRow) => {};

  /** 这一行的组件（已展平）。由父组件按行切好传进来。 */
  @Param rows: PanelComponentRow[] = [];
  @Local selectedKey: string = '';
  @Local picking: boolean = false;

  private keyOf(row: PanelComponentRow): string {
    return `${row.location.lineIndex}/${row.location.path.join('/')}`;
  }

  private toggle(row: PanelComponentRow): void {
    const key: string = this.keyOf(row);
    this.selectedKey = this.selectedKey === key ? '' : key;
  }

  private summaryText(): string {
    if (this.lineRow.childCount === 0) {
      return '空行';
    }
    const unknown: number = this.lineRow.childCount - this.lineRow.knownCount;
    if (unknown > 0) {
      return `${this.lineRow.childCount} 个组件，其中 ${unknown} 个未识别`;
    }
    return `${this.lineRow.childCount} 个组件`;
  }

  @Builder
  private header() {
    Row() {
      Text(`第 ${this.lineRow.lineIndex + 1} 行`)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
      Text(this.summaryText())
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .margin({ left: 8 })
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private lineToolbar() {
    Row() {
      Toggle({ type: ToggleType.Switch, isOn: this.lineRow.isVisible })
        .selectedColor($r('app.color.ch_accent'))
        .width(40)
        .margin({ right: 8 })
        .onChange(() => {
          this.vm.toggleLineVisible(this.lineRow.lineIndex);
        })
      Text('显示')
        .fontSize(12)
        .fontColor($r('app.color.ch_text_secondary'))
        .margin({ right: 14 })
        .onClick(() => {
          this.vm.toggleLineVisible(this.lineRow.lineIndex);
        })

      EditorChip({
        text: '前移',
        disabled: this.lineRow.lineIndex === 0,
        onTap: () => {
          this.vm.moveLine(this.lineRow.lineIndex, this.lineRow.lineIndex - 1);
        }
      })
      EditorChip({
        text: '后移',
        disabled: this.lineRow.lineIndex >= this.vm.lines.length - 1,
        onTap: () => {
          this.vm.moveLine(this.lineRow.lineIndex, this.lineRow.lineIndex + 1);
        }
      })
      EditorChip({
        text: '添加组件',
        tone: 1,
        onTap: () => { this.picking = !this.picking; }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ top: 4, bottom: 4 })
  }

  build() {
    Column() {
      this.header()
      this.lineToolbar()

      if (this.picking) {
        ComponentPicker({
          title: `往第 ${this.lineRow.lineIndex + 1} 行里添加`,
          onPick: (guid: string) => {
            this.vm.addComponent(ComponentLocation.of(this.lineRow.lineIndex, []), guid);
            this.picking = false;
          }
        })
      }

      if (this.rows.length === 0) {
        EditorEmptyHint({ text: '这一行还没有组件' })
      } else {
        ForEach(this.rows, (row: PanelComponentRow) => {
          ComponentRowView({
            vm: this.vm,
            row: row,
            isSelected: this.selectedKey === this.keyOf(row),
            onSelect: (target: PanelComponentRow) => { this.toggle(target); },
            onOpenSettings: (target: PanelComponentRow) => { this.onOpenSettings(target); }
          })
        }, (row: PanelComponentRow) => this.keyOf(row))
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }
}
