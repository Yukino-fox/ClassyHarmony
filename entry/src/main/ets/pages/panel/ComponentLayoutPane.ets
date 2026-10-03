/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 信息面板布局编辑页。
 *
 * 手机上不提供这个入口
 * --------------------
 * 面板是「桌面替代信息面板」：它的价值在于屏幕常驻、能一眼扫到。手机上有小组件
 * （今日课程表）和临上课提醒，屏幕上常驻的那部分已经被占掉了，硬塞一个需要手动
 * 打开才能看的面板只是多一个入口。所以在 Index 那边的入口按布局形态显示，
 * 只有平板与 2in1 能进来。
 *
 * 设置面板是内联展开的，不是推一个子页
 * ----------------------------------
 * 组件的位置是「哪一行 + 逐层下标」，推路由就得把它塞进路由参数里再取回来。
 * 取回来的那个下标可能已经因为别的改动而失效（用户改完设置、返回时如果有人动过
 * 布局，写回就落到了别的组件上）。内联展开期间这个对象一直握着最新下标。
 *
 * 方案切换不用弹窗
 * --------------
 * 方案是「用哪一份布局」，切方案会丢未保存的改动，属于要问一句的操作；方案数量
 * 也就几个到几十个，列出来比让人在弹窗里猜要省事。所以内联展开一个列表，选之前
 * 先问。
 */

import { t, tf } from 'common_core';
import { ComponentLocation } from 'common_core';
import { UiFeedback } from '../../common/UiFeedback';
import { EditorCard, EditorChip, EditorEmptyHint } from '../../components/EditorWidgets';
import {
  ComponentLayoutViewModel,
  PanelComponentRow,
  PanelLineRow
} from '../../viewmodel/ComponentLayoutViewModel';
import { ComponentSettingsPane } from './ComponentSettingsPane';
import { ComponentLineView } from './ComponentTreeView';
import { PanelPreview } from '../../panel/PanelPreview';

/** 复制方案时推荐的名字。 */
const COPY_SUFFIX: string = t('cl_copy_suffix');

@ComponentV2
export struct ComponentLayoutPane {
  @Require @Param vm: ComponentLayoutViewModel;
  @Event onExit: () => void = () => {};

  /** 正在改设置的组件。空串表示没在改。 */
  @Local editing: PanelComponentRow | undefined = undefined;
  /** 方案列表是否展开。 */
  @Local switching: boolean = false;
  /**
   * 预览是否展开。
   *
   * 默认开着：排面板是看着效果调的过程，看不见效果就只能靠背组件的尺寸。多一屏
   * 内容，编辑区本身是 Scroll，少了顶部几行而已。
   */
  @Local showPreview: boolean = true;

  // ------------------------------------------------------------ 方案切换

  private askSwitch(name: string): void {
    this.switching = false;
    if (name === this.vm.schemeName) {
      return;
    }
    if (this.vm.isDirty) {
      // 切方案要丢改动。先说清楚丢的是什么，再问要不要存 —— 直接切走的话，
      // 用户回到这一页会发现刚排的面板没了，而且没有任何提示。
      UiFeedback.confirmDiscardOrSave(
        this.getUIContext(),
        t('cl_switch_scheme'),
        tf('cl_switch_warn', name),
        t('cl_switch_confirm'),
        () => { this.doSwitch(name); },
        () => {
          if (this.vm.save()) {
            this.doSwitch(name);
          }
        }
      );
      return;
    }
    this.doSwitch(name);
  }

  private doSwitch(name: string): void {
    if (this.vm.switchScheme(name)) {
      this.editing = undefined;
    }
  }

  private askDuplicate(): void {
    UiFeedback.confirm(
      this.getUIContext(),
      t('cl_duplicate_title'),
      t('cl_duplicate_hint'),
      t('cl_duplicate'),
      () => {
        this.vm.duplicateScheme(`${this.vm.schemeName}${COPY_SUFFIX}`);
      }
    );
  }

  private askRemove(name: string): void {
    UiFeedback.confirm(
      this.getUIContext(),
      tf('cl_delete_scheme', name),
      t('cl_delete_scheme_warn'),
      t('common_delete'),
      () => {
        this.vm.removeScheme(name);
      }
    );
  }

  // ---------------------------------------------------------------- 渲染

  /**
   * 预览。
   *
   * 模型由 vm 每次改动后重排，界面只画 vm.panelModel。预览的「实时时钟」开关
   * 交给 vm.setLiveClock，因为它要在 ViewModel 里起/清定时器 —— 放在视图里起
   * 定时器的话，aboutToDisappear 忘了清就会在页面销毁后继续每秒钟重建一次面板。
   */
  @Builder
  private previewCard() {
    EditorCard({
      title: t('cl_preview'),
      hint: t('cl_preview_hint')
    })
    Row() {
      EditorChip({
        text: this.showPreview ? t('cl_collapse_preview') : t('cl_expand_preview'),
        tone: 1,
        onTap: () => { this.showPreview = !this.showPreview; }
      })
      if (this.showPreview) {
        EditorChip({
          text: this.vm.liveClock ? t('cl_clock_running') : t('cl_clock_paused'),
          onTap: () => { this.vm.setLiveClock(!this.vm.liveClock); }
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)

    if (this.showPreview) {
      Stack({ alignContent: Alignment.Start }) {
        PanelPreview({ model: this.vm.panelModel, inEditMode: true })
      }
      .width('100%')
      .backgroundColor($r('app.color.ch_surface'))
      .borderRadius(10)
      .border({ width: 1, color: $r('app.color.ch_outline') })
      .margin({ top: 6 })
    }
  }

  @Builder
  private schemeCard() {
    EditorCard({
      title: t('cl_scheme'),
      hint: t('cl_scheme_hint')
    })
    Row() {
      Text(this.vm.schemeName)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      EditorChip({
        text: this.switching ? t('cl_collapse') : t('cl_switch'),
        tone: 1,
        onTap: () => { this.switching = !this.switching; }
      })
      EditorChip({
        text: t('cl_duplicate'),
        onTap: () => { this.askDuplicate(); }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)

    if (this.switching) {
      Column() {
        if (this.vm.schemeNames.length === 0) {
          EditorEmptyHint({ text: t('cl_no_other_schemes') })
        }
        ForEach(this.vm.schemeNames, (name: string) => {
          Row() {
            Text(name)
              .fontSize(13)
              .fontColor(name === this.vm.schemeName
                ? $r('app.color.ch_text_hint')
                : $r('app.color.ch_text_primary'))
              .layoutWeight(1)
            if (name === this.vm.schemeName) {
              Text(t('cl_current'))
                .fontSize(11)
                .fontColor($r('app.color.ch_text_hint'))
                .margin({ right: 8 })
            } else {
              Text(t('common_delete'))
                .fontSize(12)
                .fontColor($r('app.color.ch_accent'))
                .margin({ right: 8 })
                .onClick(() => { this.askRemove(name); })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: 7, bottom: 7 })
          .onClick(() => { this.askSwitch(name); })
        }, (name: string) => name)
      }
      .width('100%')
      .backgroundColor($r('app.color.ch_surface_weak'))
      .borderRadius(8)
      .padding({ left: 10, right: 10, top: 2, bottom: 2 })
      .margin({ top: 6 })
    }
  }

  @Builder
  private topBar() {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor($r('app.color.ch_text_primary'))
        .width(32)
        .onClick(() => { this.onExit(); })
      Text(t('cl_info_panel'))
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

  @Builder
  private statusBar() {
    if (this.vm.statusText.length > 0) {
      Text(this.vm.statusText)
        .fontSize(12)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 4, bottom: 4 })
    }
  }

  @Builder
  private saveBar() {
    Column() {
      Row() {
        Text(t('cl_unsaved_changes'))
          .fontSize(12)
          .fontColor($r('app.color.ch_accent'))
          .layoutWeight(1)
        Text(t('cl_reload'))
          .fontSize(13)
          .fontColor($r('app.color.ch_text_secondary'))
          .margin({ right: 16 })
          .onClick(() => {
            UiFeedback.confirm(
              this.getUIContext(),
              t('cl_reload_title'),
              t('cl_reload_confirm'),
              t('cl_reload'),
              () => {
                this.editing = undefined;
                this.vm.reload();
              }
            );
          })
        Text(t('cl_save'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ch_accent'))
          .onClick(() => {
            if (this.vm.save()) {
              this.editing = undefined;
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    }
    .width('100%')
    .backgroundColor($r('app.color.ch_surface'))
  }

  build() {
    if (this.editing !== undefined) {
      ComponentSettingsPane({
        vm: this.vm,
        location: this.editing.location,
        displayName: this.editing.displayName,
        componentGuid: this.editing.componentGuid,
        onClose: () => { this.editing = undefined; }
      })
    } else {
      Column() {
        this.topBar()

        Scroll() {
          Column() {
            if (this.vm.loadErrorText.length > 0) {
              Text(this.vm.loadErrorText)
                .fontSize(12)
                .fontColor($r('app.color.ch_accent'))
                .width('100%')
                .padding({ top: 4, bottom: 8 })
            }

            this.schemeCard()

            this.previewCard()

            if (this.vm.lines.length === 0) {
              EditorEmptyHint({ text: t('cl_no_rows') })
            } else {
              ForEach(this.vm.lines, (lineRow: PanelLineRow) => {
                ComponentLineView({
                  vm: this.vm,
                  lineRow: lineRow,
                  rows: this.vm.rowsInLine(lineRow.lineIndex),
                  onOpenSettings: (row: PanelComponentRow) => { this.editing = row; }
                })
                Divider()
                  .color($r('app.color.ch_surface_weak'))
              }, (lineRow: PanelLineRow) => lineRow.lineIndex.toString())
            }

            Row() {
              EditorChip({
                text: t('cl_add_row'),
                tone: 1,
                onTap: () => { this.vm.addLine(this.vm.lines.length - 1); }
              })
              EditorChip({
                text: t('cl_add_row_top'),
                onTap: () => { this.vm.addLine(-1); }
              })
            }
            .width('100%')
            .padding({ top: 8, bottom: 24 })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)

        this.statusBar()
        if (this.vm.isDirty) {
          this.saveBar()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.start_window_background'))
    }
  }
}
