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
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AppPreferences,
  DefaultPage,
  PrefKeys,
  ThemeMode
} from '../common/AppPreferences';
import { UiFeedback } from '../common/UiFeedback';
import { ThemeService } from '../common/ThemeService';
import { CONTENT_MAX_WIDTH } from '../components/ContentWidth';
import { EditorTextField } from '../components/EditorWidgets';
import { ExactTimeService, resolveExactTimeService } from '../time/ExactTimeService';

const DOMAIN: number = 0x0000;
const TAG: string = 'Settings';

/** 字体缩放的档位。循环切换用，不给滑块 —— 见 cycleFontScale 的注释。 */
const FONT_SCALE_STEPS: number[] = [0.8, 0.9, 1.0, 1.1, 1.3, 1.6];

/** 提前量的档位（秒）。 */
const ADVANCE_STEPS: number[] = [0, 60, 300, 600];

/** 提醒提前量的合法范围。 */
const ADVANCE_MAX_SECONDS: number = 3600;

/*
 * 手动偏移的档位（秒）。
 *
 * 负值排在正值前面且 0 在中间：偏移是「往哪边拨」的一个双向量，把 0 放在
 * 列表中间并让循环从它开始，点到 0 时不用先滚过所有负档。
 */
const OFFSET_STEPS: number[] = [-60, -30, -10, -5, -1, 0, 1, 5, 10, 30, 60];

/*
 * 每日补偿的档位（秒/天）。
 *
 * 不含负档：补偿的语义是「本机每天慢 X 秒，补回来」，负数在界面上读起来
 * 是「每天快 X 秒，要往回拨」—— 那不是用户会主动想要的事，需要的话用手动
 * 偏移即可。想要每天回拨的用户请把符号反着想。
 */
const AUTO_ADJUST_STEPS: number[] = [0, 0.5, 1, 2, 5, 10, 30, 60];

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

  // 精确时间
  @Local exactTimeEnabled: boolean = true;
  @Local exactTimeServer: string = 'ntp.aliyun.com';
  @Local timeOffsetSeconds: number = 0;
  @Local timeAutoAdjustEnabled: boolean = false;
  @Local timeAutoAdjustSeconds: number = 0;
  /** NTP 服务器的编辑框是否展开。默认收起，保持设置列表行长一致。 */
  @Local editingServer: boolean = false;
  /** 同步状态文案。校时服务是异步的，这里存一份快照供界面显示。 */
  @Local syncStatus: string = '';
  /** 正在校时。用来把按钮置灰、避免连点发出多个查询。 */
  @Local syncing: boolean = false;

  // 诊断
  @Local debugLog: boolean = false;
  @Local performanceOverlay: boolean = false;

  /** 不加装饰器：持有它的字段不需要可观测，AppPreferences 本身是纯读写器。 */
  private prefs: AppPreferences | undefined = undefined;

  /**
   * 换配色要用 UIAbilityContext。
   *
   * 存下来而不是每次现取：getHostContext() 在 ArkUI 里是拿宿主 context，
   * 拿到的对象在整个 Ability 生命周期内是同一个，存下来省掉一处类型断言，
   * 也让「换配色」这个动作不必关心 context 从哪来。
   */
  private host: common.UIAbilityContext | undefined = undefined;

  aboutToAppear(): void {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as
      common.UIAbilityContext;
    this.host = context;
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

    // 校时的几项从服务读，不从 prefs 读。服务是它们的唯一持有者（偏移会被
    // 每日补偿就地改掉，服务器会被空串回落成默认值），直接读盘会拿到一个
    // 与「实际在用的」不一样的值 —— 界面上写着 A、跑起来是 B 这种最难查。
    const exact: ExactTimeService | undefined = this.exactService();
    if (exact !== undefined) {
      this.exactTimeEnabled = exact.isEnabled();
      this.exactTimeServer = exact.currentServer();
      this.timeOffsetSeconds = exact.currentOffsetSeconds();
      this.timeAutoAdjustEnabled = exact.isAutoAdjustEnabled();
      this.timeAutoAdjustSeconds = exact.currentAutoAdjustSeconds();
      this.syncStatus = exact.statusText();
    }

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

  /**
   * 切主题：写盘 + 立刻生效。
   *
   * 立刻生效而不是「下次启动生效」：配色是那种「不立刻看到就以为自己没改
   * 成功」的东西，而生效成本只是改一个窗口属性。
   *
   * 顺序是先落盘再切：万一 setColorMode 失败，盘上已经是新值，用户下次
   * 进来会看到生效；反过来先切后落盘，中间崩了就出现「屏幕上变了但重进
   * 又变回去」的更糟状态。
   */
  private cycleTheme(): void {
    this.theme = (this.theme + 1) % 3;
    this.writeNumber(PrefKeys.THEME, this.theme);
    if (this.host !== undefined) {
      ThemeService.apply(this.host, this.theme);
    }
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

  /**
   * 取校时服务。
   *
   * host 还没赋值时返回 undefined 而不是抛 —— aboutToAppear 里赋值顺序是
   * 先 host 后 reload，但 reload 也被 resetAll 调，而 resetAll 是用户点的，
   * 理论上不该有 undefined；返回 undefined 只是让「拿不到就跳过这一段」
   * 成为可能，而不是崩掉整个设置页。
   */
  private exactService(): ExactTimeService | undefined {
    if (this.host === undefined) {
      return undefined;
    }
    return resolveExactTimeService(this.host);
  }

  // ------------------------------------------------------------ 精确时间

  private toggleExactTime(on: boolean): void {
    this.exactTimeEnabled = on;
    const exact: ExactTimeService | undefined = this.exactService();
    if (exact !== undefined) {
      exact.setEnabled(on);
      this.syncStatus = exact.statusText();
    }
  }

  /**
   * 提交 NTP 服务器。
   *
   * 走服务而不是直接写盘：换服务器会立刻触发一次查询，用户按回车到看见
   * 结果之间的那 1~3 秒正是「这个改动有没有生效」的答案。
   */
  private commitServer(text: string): void {
    const exact: ExactTimeService | undefined = this.exactService();
    if (exact === undefined) {
      return;
    }
    exact.setServer(text);
    this.exactTimeServer = exact.currentServer();
    this.editingServer = false;
    this.syncing = true;
    this.refreshStatusSoon();
  }

  private cycleOffset(): void {
    const next: number = SettingsPage.nextStep(OFFSET_STEPS, this.timeOffsetSeconds);
    this.timeOffsetSeconds = next;
    this.exactService()?.setOffsetSeconds(next);
  }

  private toggleAutoAdjust(on: boolean): void {
    this.timeAutoAdjustEnabled = on;
    this.exactService()?.setAutoAdjustEnabled(on);
  }

  private cycleAutoAdjust(): void {
    const next: number = SettingsPage.nextStep(AUTO_ADJUST_STEPS, this.timeAutoAdjustSeconds);
    this.timeAutoAdjustSeconds = next;
    this.exactService()?.setAutoAdjustSeconds(next);
  }

  /** 立即校时。等结果再刷状态，不 await 到界面。 */
  private async syncNow(): Promise<void> {
    const exact: ExactTimeService | undefined = this.exactService();
    if (exact === undefined || this.syncing) {
      return;
    }
    this.syncing = true;
    try {
      await exact.syncNow();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'syncNow threw: %{public}s', `${err}`);
    }
    this.syncStatus = exact.statusText();
    this.syncing = false;
  }

  /**
   * 延迟一拍再读状态。
   *
   * setServer 里那次查询是 fire-and-forget 的（不 await），所以提交后立刻读
   * 拿到的必然是「正在同步时间……」。等它自己回来更简单，也避免为了等一个
   * 3 秒的查询把提交回调变成异步（那会让 TextInput 的 onBlur/onSubmit 语义
   * 变模糊）。200 毫秒够覆盖本地网络的往返，不够也不影响正确性 ——
   * 下一条状态本来就是用户自己再点一次「立即校时」看出来的。
   */
  private refreshStatusSoon(): void {
    setTimeout((): void => {
      this.syncStatus = this.exactService()?.statusText() ?? '';
      this.syncing = false;
    }, 200);
  }

  /** 在档位表里往后走一档，到顶后回到第一档。 */
  private static nextStep(steps: number[], current: number): number {
    for (let i: number = 0; i < steps.length; i++) {
      if (steps[i] > current + 1e-9) {
        return steps[i];
      }
    }
    return steps[0];
  }

  private offsetLabel(): string {
    const seconds: number = this.timeOffsetSeconds;
    if (seconds === 0) {
      return '不调整';
    }
    const sign: string = seconds > 0 ? '+' : '-';
    return `${sign}${Math.abs(seconds)} 秒`;
  }

  private autoAdjustLabel(): string {
    if (this.timeAutoAdjustSeconds === 0) {
      return '不补偿';
    }
    return `每天 +${this.timeAutoAdjustSeconds} 秒`;
  }

  private resetAll(): void {
    this.prefs?.resetToDefaults();

    // 校时要在 reload 之前 start：它不只是读 @Local，服务自己还持有一份
    // 启用状态、偏移与定时器。盘上重置了而服务还按旧值跑，就是「界面写着关、
    // 服务还在每 10 分钟发包」。start() 重读全部设置并重建定时器，之后
    // reload() 才能从服务读到已归零的值 —— 顺序反了就会读到旧值。
    //
    // 它顺带会跑一次每日补偿：刚重置时 LastTimeAdjustDateTime 已被置空，
    // 天数算出来是 0，不会多补。
    this.exactService()?.start();

    this.reload();
    this.editingServer = false;

    // 主题要重新落到窗口上：reload() 只改了 @Local，屏幕上还是重置前的配色。
    // 其他设置项没有这个问题 —— 它们在 build 里读 @Local，reload 完就重画了；
    // 配色是窗口级属性，不经过 build。
    if (this.host !== undefined) {
      ThemeService.apply(this.host, this.theme);
    }
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

  /**
   * 说明行：左标题、右侧可换行的长文本。用来放校时状态。
   *
   * 不用 valueRow：那个把值限成 maxLines(1)，而状态文案在「系统时间被修改」
   * 这种场景下会带上「上次同步：……」的前后缀，截断成一行就看不出发生了什么。
   */
  @Builder
  private noteRow(title: string, body: string) {
    ListItem() {
      Row() {
        Text(title)
          .fontSize(16)
          .fontColor($r('app.color.ch_text_primary'))
          .width(96)
        Text(body)
          .fontSize(13)
          .fontColor($r('app.color.ch_text_secondary'))
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    }
  }

  /** 纯文字的整行按钮。 */
  @Builder
  private actionRow(label: string, enabled: boolean, onTap: () => void) {
    ListItem() {
      Text(label)
        .fontSize(16)
        .fontColor(enabled ? $r('app.color.ch_accent') : $r('app.color.ch_text_hint'))
        .width('100%')
        .height(52)
        .padding({ left: 16, right: 16 })
        .textAlign(TextAlign.Start)
    }
    .onClick(() => {
      if (enabled) {
        onTap();
      }
    })
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

          // ---- 精确时间
          this.groupTitle('精确时间')
          this.toggleRow('启用精确时间', this.exactTimeEnabled, (on: boolean) => {
            this.toggleExactTime(on);
          })
          this.valueRow('NTP 服务器', this.exactTimeServer, () => {
            this.editingServer = !this.editingServer;
          })
          if (this.editingServer) {
            // 只在展开时挂载：EditorTextField 在 aboutToAppear 里把值拷进
            // draft，折叠再展开会重新挂载并重新拷贝，正好是想要的「重置编辑框」。
            ListItem() {
              Column() {
                EditorTextField({
                  label: '服务器',
                  value: this.exactTimeServer,
                  placeholder: 'ntp.aliyun.com',
                  onCommit: (text: string) => {
                    this.commitServer(text);
                  }
                })
                Text('回车或点别处生效。留空则回落到 ntp.aliyun.com。')
                  .fontSize(12)
                  .fontColor($r('app.color.ch_text_hint'))
                  .width('100%')
                  .padding({ top: 4 })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            }
          }
          this.valueRow('手动偏移', this.offsetLabel(), () => {
            this.cycleOffset();
          })
          this.toggleRow('每日自动补偿', this.timeAutoAdjustEnabled, (on: boolean) => {
            this.toggleAutoAdjust(on);
          })
          this.valueRow('每日补偿量', this.autoAdjustLabel(), () => {
            this.cycleAutoAdjust();
          })
          this.noteRow('同步状态', this.syncStatus.length === 0 ? '尚未开始' : this.syncStatus)
          this.actionRow(this.syncing ? '正在校时…' : '立即校时',
            this.exactTimeEnabled && !this.syncing, () => {
              this.syncNow();
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
    // 宽屏封顶居中，理由见 ContentWidth.ets 头注
    .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
    .alignSelf(ItemAlign.Center)
  }
}
