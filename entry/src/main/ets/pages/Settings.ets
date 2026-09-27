/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 设置页。
 *
 * 为什么把值镜像到 @Local 而不是直接在 build 里读 AppPreferences
 * ------------------------------------------------------------
 * AppPreferences 是「读盘」的，每次 getXxx 都是一次 readTextSync + JSON.parse。
 * 在 build 里直接读有两个问题：一是 build 会被重跑很多次（任何依赖变化都触发），
 * 一次重跑几十次读盘；二是写完之后没有可观测的变化通知 —— 改的是磁盘上的文件，
 * 那个对象本身没变，得靠额外机制才让控件刷新。
 *
 * 所以：aboutToAppear 读一次填进 @Local，改的时候同时写盘和改 @Local。
 * 这与 Index.ets 里 grid / banner 的做法一致。
 *
 * 为什么只用 ListItem 不用 ListItemGroup
 * -------------------------------------
 * ListItemGroup 的 header 只收 CustomBuilder，收不了字符串
 * （`{header: 'x'}` 编译不过），而为一屏标题给每个分组都写一个 @Builder 不划算。
 * 所以用一条浅底色的 ListItem 只放标题文字，没有交互。分组标题在这里唯一的作用
 * 是让人扫一眼定位，浅底色加粗已经做到了。
 *
 * 箭头用 '›' 字符而不是图片
 * ----------------------
 * 为一个箭头引入 png 不划算：它在深色主题下还要另备一张（图片不跟随文字颜色），
 * 而字符天然跟随 fontColor。
 *
 * 取值都是「点一下循环」而不是选择器
 * ------------------------------
 * 每一项的可选值都是已知的少量枚举，循环比弹选择器少一次界面往返，也不会让
 * 用户在一个临时列表里找「浅色」两个字。代价是看不到「全部有哪些值」，对这几项
 * 来说不构成问题。
 */

import { common } from '@kit.AbilityKit';
import {
  AppPreferences,
  DefaultPage,
  PrefKeys,
  ThemeMode
} from '../common/AppPreferences';
import { UiFeedback } from '../common/UiFeedback';

/** 字体缩放的档位。循环切换用，不给滑块 —— 见 cycleFontScale 的注释。 */
const FONT_SCALE_STEPS: number[] = [0.8, 0.9, 1.0, 1.1, 1.3, 1.6];

/** 提前量的档位（秒）。 */
const ADVANCE_STEPS: number[] = [0, 60, 300, 600];

/** 提醒提前量的合法范围。 */
const ADVANCE_MAX_SECONDS: number = 3600;

@Entry
@ComponentV2
struct SettingsPage {
  @Local ready: boolean = false;

  // 界面
  @Local theme: number = ThemeMode.System;
  @Local fontScale: number = 1.0;
  @Local defaultPage: number = DefaultPage.Schedule;

  // 课表
  @Local showWeekNum: boolean = true;
  @Local showFreeTime: boolean = true;
  @Local conflictDetection: boolean = true;
  @Local autoSelectCurrentWeek: boolean = true;

  // 课前提醒
  @Local reminderEnabled: boolean = true;
  @Local advanceIndoor: number = 60;
  @Local advanceOutdoor: number = 600;
  @Local reminderMode: number = -1;

  // 自动化
  @Local automationEnabled: boolean = true;
  @Local automationConfig: string = 'Default';

  // 诊断
  @Local debugLog: boolean = false;
  @Local performanceOverlay: boolean = false;

  /** 不加装饰器：持有它的字段不需要可观测，AppPreferences 本身是纯读写器。 */
  private prefs: AppPreferences | undefined = undefined;

  aboutToAppear(): void {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as
      common.UIAbilityContext;
    this.prefs = new AppPreferences(context);
    this.reload();
    this.ready = true;
  }

  /** 从盘上重读一遍，填满所有 @Local。 */
  private reload(): void {
    const prefs: AppPreferences | undefined = this.prefs;
    if (prefs === undefined) {
      return;
    }
    this.theme = prefs.theme();
    this.fontScale = prefs.fontScale();
    this.defaultPage = prefs.defaultPage();

    this.showWeekNum = prefs.getBoolean(PrefKeys.SHOW_WEEK_NUM, true);
    this.showFreeTime = prefs.getBoolean(PrefKeys.SHOW_FREE_TIME, true);
    this.conflictDetection = prefs.getBoolean(PrefKeys.CONFLICT_DETECTION, true);
    this.autoSelectCurrentWeek = prefs.getBoolean(PrefKeys.AUTO_SELECT_CURRENT_WEEK, true);

    this.reminderEnabled = prefs.getBoolean(PrefKeys.REMINDER_ENABLED, true);
    this.advanceIndoor = AppPreferences.clampInt(
      prefs.getNumber(PrefKeys.REMINDER_ADVANCE_INDOOR, 60), 0, ADVANCE_MAX_SECONDS);
    this.advanceOutdoor = AppPreferences.clampInt(
      prefs.getNumber(PrefKeys.REMINDER_ADVANCE_OUTDOOR, 600), 0, ADVANCE_MAX_SECONDS);
    this.reminderMode = prefs.getNumber(PrefKeys.REMINDER_MODE, -1);

    this.automationEnabled = prefs.getBoolean(PrefKeys.AUTOMATION_ENABLED, true);
    this.automationConfig = prefs.getString(PrefKeys.AUTOMATION_CONFIG, 'Default');

    this.debugLog = prefs.getBoolean(PrefKeys.DEBUG_LOG, false);
    this.performanceOverlay = prefs.getBoolean(PrefKeys.PERFORMANCE_OVERLAY, false);
  }

  // ------------------------------------------------------------ 写

  private writeBool(key: string, value: boolean): void {
    this.prefs?.put(key, value);
  }

  private writeNumber(key: string, value: number): void {
    this.prefs?.put(key, value);
  }

  // ------------------------------------------------------------ 取值展示

  private themeLabel(): string {
    if (this.theme === ThemeMode.Light) {
      return '浅色';
    }
    if (this.theme === ThemeMode.Dark) {
      return '深色';
    }
    return '跟随系统';
  }

  private defaultPageLabel(): string {
    if (this.defaultPage === DefaultPage.Editor) {
      return '编辑页';
    }
    if (this.defaultPage === DefaultPage.Panel) {
      return '信息面板';
    }
    if (this.defaultPage === DefaultPage.Automation) {
      return '自动化';
    }
    return '课表页';
  }

  private fontScaleLabel(): string {
    return `${Math.round(this.fontScale * 100)}%`;
  }

  private advanceLabel(seconds: number): string {
    if (seconds <= 0) {
      return '上课那一刻';
    }
    if (seconds < 60) {
      return `${seconds} 秒`;
    }
    return `${Math.round(seconds / 60)} 分钟`;
  }

  private reminderModeLabel(): string {
    if (this.reminderMode === 0) {
      return '精确到每节课';
    }
    if (this.reminderMode === 1) {
      return '折叠成一条';
    }
    return '自动';
  }

  // ------------------------------------------------------------ 交互

  private cycleTheme(): void {
    this.theme = (this.theme + 1) % 3;
    this.writeNumber(PrefKeys.THEME, this.theme);
  }

  private cycleDefaultPage(): void {
    this.defaultPage = (this.defaultPage + 1) % 4;
    this.writeNumber(PrefKeys.DEFAULT_PAGE, this.defaultPage);
  }

  /**
   * 字体缩放按档位循环，不给滑块。
   *
   * 连续滑块每帧都要写盘，而帧间隔短到能让 rename 连续做十几次；档位循环只在
   * 点一下时写一次。代价是调不到 1.25 这种中间值 —— 对正文字号来说六个档位已经
   * 够用，真要连续值可以放到设置页之外的独立入口。
   */
  private cycleFontScale(): void {
    let next: number = FONT_SCALE_STEPS[FONT_SCALE_STEPS.length - 1];
    for (let i: number = 0; i < FONT_SCALE_STEPS.length; i++) {
      if (FONT_SCALE_STEPS[i] > this.fontScale) {
        next = FONT_SCALE_STEPS[i];
        break;
      }
    }
    this.fontScale = next;
    this.writeNumber(PrefKeys.FONT_SCALE, next);
    UiFeedback.toast(this.getUIContext(), `字体缩放 ${Math.round(next * 100)}%`);
  }

  private cycleAdvanceIndoor(): void {
    this.advanceIndoor = this.nextAdvance(this.advanceIndoor);
    this.writeNumber(PrefKeys.REMINDER_ADVANCE_INDOOR, this.advanceIndoor);
  }

  private cycleAdvanceOutdoor(): void {
    this.advanceOutdoor = this.nextAdvance(this.advanceOutdoor);
    this.writeNumber(PrefKeys.REMINDER_ADVANCE_OUTDOOR, this.advanceOutdoor);
  }

  /** 在四档之间往后走一档，到顶后回到第一档。 */
  private nextAdvance(current: number): number {
    for (let i: number = 0; i < ADVANCE_STEPS.length; i++) {
      if (ADVANCE_STEPS[i] > current) {
        return ADVANCE_STEPS[i];
      }
    }
    return ADVANCE_STEPS[0];
  }

  private cycleReminderMode(): void {
    // -1（自动）→ 0（精确）→ 1（折叠）→ -1
    if (this.reminderMode === -1) {
      this.reminderMode = 0;
    } else if (this.reminderMode === 0) {
      this.reminderMode = 1;
    } else {
      this.reminderMode = -1;
    }
    this.writeNumber(PrefKeys.REMINDER_MODE, this.reminderMode);
  }

  private resetAll(): void {
    this.prefs?.resetToDefaults();
    this.reload();
    UiFeedback.toast(this.getUIContext(), '已恢复默认设置');
  }

  private goAutomation(): void {
    const uiContext: UIContext = this.getUIContext();
    uiContext.getRouter().pushUrl({ url: 'pages/Automation' }).catch(() => {
      UiFeedback.toast(uiContext, '进不去自动化页');
    });
  }

  // ------------------------------------------------------------ 渲染片段

  /** 分组标题：一条只放文字的浅底 ListItem，没有交互。 */
  @Builder
  private groupTitle(text: string) {
    ListItem() {
      Text(text)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ch_text_secondary'))
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 6 })
        .backgroundColor($r('app.color.ch_surface_alt'))
    }
  }

  /** 可点击的行：左标题、右当前值、末尾箭头。 */
  @Builder
  private valueRow(title: string, value: string, onTap: () => void) {
    ListItem() {
      Row() {
        Text(title)
          .fontSize(16)
          .fontColor($r('app.color.ch_text_primary'))
        Blank()
        Text(value)
          .fontSize(15)
          .fontColor($r('app.color.ch_text_secondary'))
          .maxLines(1)
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.ch_text_hint'))
          .margin({ left: 6 })
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })
    }
    .onClick(() => {
      onTap();
    })
  }

  /** 开关行：左标题、右侧开关。 */
  @Builder
  private toggleRow(title: string, isOn: boolean, onChange: (on: boolean) => void) {
    ListItem() {
      Row() {
        Text(title)
          .fontSize(16)
          .fontColor($r('app.color.ch_text_primary'))
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: isOn })
          .selectedColor($r('app.color.ch_accent'))
          .onChange((on: boolean) => {
            onChange(on);
          })
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })
    }
  }

  build() {
    Column() {
      if (!this.ready) {
        Text('正在准备设置…')
          .fontSize(14)
          .fontColor($r('app.color.ch_text_secondary'))
          .width('100%')
          .height('100%')
          .textAlign(TextAlign.Center)
      } else {
        List() {
          // ---- 界面
          this.groupTitle('界面')
          this.valueRow('主题', this.themeLabel(), () => {
            this.cycleTheme();
          })
          this.valueRow('字体缩放', this.fontScaleLabel(), () => {
            this.cycleFontScale();
          })
          this.valueRow('首页默认页', this.defaultPageLabel(), () => {
            this.cycleDefaultPage();
          })

          // ---- 课表
          this.groupTitle('课表')
          this.toggleRow('显示周数', this.showWeekNum, (on: boolean) => {
            this.showWeekNum = on;
            this.writeBool(PrefKeys.SHOW_WEEK_NUM, on);
          })
          this.toggleRow('显示课间空档', this.showFreeTime, (on: boolean) => {
            this.showFreeTime = on;
            this.writeBool(PrefKeys.SHOW_FREE_TIME, on);
          })
          this.toggleRow('检测时间冲突', this.conflictDetection, (on: boolean) => {
            this.conflictDetection = on;
            this.writeBool(PrefKeys.CONFLICT_DETECTION, on);
          })
          this.toggleRow('自动定位到当前周', this.autoSelectCurrentWeek, (on: boolean) => {
            this.autoSelectCurrentWeek = on;
            this.writeBool(PrefKeys.AUTO_SELECT_CURRENT_WEEK, on);
          })

          // ---- 课前提醒
          this.groupTitle('课前提醒')
          this.toggleRow('启用课前提醒', this.reminderEnabled, (on: boolean) => {
            this.reminderEnabled = on;
            this.writeBool(PrefKeys.REMINDER_ENABLED, on);
          })
          this.valueRow('室内课提前', this.advanceLabel(this.advanceIndoor), () => {
            this.cycleAdvanceIndoor();
          })
          this.valueRow('室外课提前', this.advanceLabel(this.advanceOutdoor), () => {
            this.cycleAdvanceOutdoor();
          })
          this.valueRow('提醒形态', this.reminderModeLabel(), () => {
            this.cycleReminderMode();
          })

          // ---- 自动化
          this.groupTitle('自动化')
          this.toggleRow('启用自动化', this.automationEnabled, (on: boolean) => {
            this.automationEnabled = on;
            this.writeBool(PrefKeys.AUTOMATION_ENABLED, on);
          })
          this.valueRow('自动化方案', this.automationConfig, () => {
            this.goAutomation();
          })

          // ---- 诊断
          this.groupTitle('诊断')
          this.toggleRow('调试日志', this.debugLog, (on: boolean) => {
            this.debugLog = on;
            this.writeBool(PrefKeys.DEBUG_LOG, on);
          })
          this.toggleRow('性能叠加层', this.performanceOverlay, (on: boolean) => {
            this.performanceOverlay = on;
            this.writeBool(PrefKeys.PERFORMANCE_OVERLAY, on);
          })

          // ---- 重置
          this.groupTitle('重置')
          ListItem() {
            Text('恢复全部默认设置')
              .fontSize(16)
              .fontColor($r('app.color.ch_accent'))
              .width('100%')
              .height(52)
              .padding({ left: 16, right: 16 })
              .textAlign(TextAlign.Start)
          }
          .onClick(() => {
            UiFeedback.confirm(this.getUIContext(), '恢复默认设置',
              '所有设置项都会回到初始值，包括提醒提前量与自动化方案。', '恢复', () => {
                this.resetAll();
              });
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.ch_surface_weak'))
        .divider({
          strokeWidth: 1,
          color: $r('app.color.ch_outline'),
          startMargin: 16,
          endMargin: 16
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.ch_surface_weak'))
  }
}
