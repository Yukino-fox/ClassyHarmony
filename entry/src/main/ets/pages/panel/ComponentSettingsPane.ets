/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 单个组件的设置表单。
 *
 * 按组件类型分支，不做成一张通用表单
 * -------------------------------
 * 11 个组件的设置字段没有交集（时钟只有三个开关，课程表有十六个）。硬凑成
 * 「字段名 + 控件类型」的通用表看着省事，实际是每个字段都要写一个特例分支，
 * 而且新增字段时编译器不报错 —— 漏了就是那个开关在界面上不存在。所以这里
 * 一个组件类型一个子 struct，各自只认识自己的字段。
 *
 * 子 struct 改的是父组件手里那个对象的字段
 * --------------------------------------
 * payload 不是 @ObservedV2，就地改字段不触发重绘；父组件在写回之后重新读一遍
 * 拿到新对象再整体替换 @Local，重绘就来了。这条链路依赖 V2 的 @Param 按引用
 * 传递（子组件改的就是父组件那个对象），所以子 struct 里绝不能 new 一个新的
 * 出来塞回去 —— 那样父组件手里的对象没被改到，写回的是旧值。
 *
 * 颜色给预设 + 十六进制输入，不给取色器
 * ----------------------------------
 * 面板上的颜色来自桌面版，值是 #RRGGBBAA（透明度在末尾）。桌面版用的是完整
 * 颜色对话框，鸿蒙侧没有对等控件，退到「常用色一排 + 手输十六进制」：
 * 面板上真正用得上的就是白/黑/红/蓝/灰这几种，预设能覆盖绝大多数，而这一个
 * 输入框能覆盖剩下的全部 —— 包括桌面版同步过来的任意值。取色器只能覆盖
 * 前者。
 *
 * 缺字段不补
 * --------
 * 只编辑已建模的字段。没建模的（倒计时的周期设置等）原样留在文件里，往返一次
 * 它们还在。界面上不列出来是为了不给「能改所有设置」的错觉。隐藏规则集是个
 * 例外：它不在这份表单里，而是就地展开 RulesetEditorView。
 */

import { ColorValue, ComponentSettings, DateTimeValue } from 'common_shared';
import { t } from 'common_core';
import {
  ClockPayload,
  COMPONENT_CLOCK,
  COMPONENT_COUNTDOWN,
  COMPONENT_GROUP,
  COMPONENT_ROLLING,
  COMPONENT_SCHEDULE,
  COMPONENT_SEPARATOR,
  COMPONENT_SLIDE,
  COMPONENT_STACK,
  COMPONENT_TEXT,
  COMPONENT_WEATHER,
  ComponentLocation,
  ComponentPayload,
  CountDownPayload,
  RollingPayload,
  SchedulePayload,
  SlidePayload,
  TextPayload,
  WeatherPayload
} from 'common_core';
import {
  EditorCard,
  EditorEmptyHint,
  EditorTextField,
  EditorToggleRow
} from '../../components/EditorWidgets';
import { RulesetEditorView } from '../../panel/RulesetEditorView';
import { ComponentLayoutViewModel } from '../../viewmodel/ComponentLayoutViewModel';

/**
 * DateTimeValue 转 JS Date。
 *
 * 不用 `new Date(y, m - 1, d)`：那个构造器把 0..99 的年份当成 1900+y，于是
 * 档案里一个 0099 年的日期会让选择器打开在 1999 年。先给个非 0..99 的年份
 * 占位再 setFullYear 改正。
 */
function toJsDate(value: DateTimeValue): Date {
  const date: Date = new Date(2000, value.month - 1, value.day,
    value.hour, value.minute, value.second);
  date.setFullYear(value.year);
  return date;
}

/**
 * 常用色。
 *
 * 只有四个不是巧合：面板底色与前景色在深浅两种主题下要么是白要么是黑，强调色
 * 一个、警示色一个，多出来的自定义由下面的十六进制输入框兜住。
 */
const COLOR_PRESETS: ColorValue[] = [
  ColorValue.white(),
  ColorValue.black(),
  ColorValue.dodgerBlue(),
  ColorValue.red()
];

/** 一行「标签 + 取色」：色块 + 十六进制输入 + 常用色。 */
@ComponentV2
struct ColorField {
  @Param label: string = '';
  @Param value: ColorValue = ColorValue.white();
  @Event onChange: (value: ColorValue) => void = (value: ColorValue) => {};

  private presetAt(index: number): ColorValue {
    if (index < 0 || index >= COLOR_PRESETS.length) {
      return ColorValue.white();
    }
    return COLOR_PRESETS[index];
  }

  /** 输入的十六进制解析不出来时保留原值，不把颜色改成透明的。 */
  private commitText(text: string): void {
    const parsed: ColorValue | undefined = ColorValue.tryParse(text.trim());
    if (parsed !== undefined) {
      this.onChange(parsed);
    }
  }

  build() {
    Column() {
      EditorTextField({
        label: this.label,
        value: this.value.toString(),
        placeholder: '#RRGGBBAA',
        onCommit: (text: string) => { this.commitText(text); }
      })
      Row() {
        Text('色块')
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .width(34)
        Row()
          .width(28)
          .height(18)
          .backgroundColor(this.value.toArkUi())
          .borderRadius(4)
          .border({ width: 1, color: $r('app.color.ch_outline') })
          .margin({ right: 12 })
        ForEach([0, 1, 2, 3], (index: number) => {
          Row()
            .width(22)
            .height(22)
            .borderRadius(11)
            .backgroundColor(this.presetAt(index).toArkUi())
            .border({ width: 1, color: $r('app.color.ch_outline') })
            .margin({ right: 8 })
            .onClick(() => {
              this.onChange(this.presetAt(index));
            })
        }, (index: number) => index.toString())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 2, bottom: 4 })
    }
    .width('100%')
  }
}

/** 一行日期：显示 ISO 日期，点一下开选择器。 */
@ComponentV2
struct DateField {
  @Param label: string = '';
  @Param value: DateTimeValue = DateTimeValue.now();
  @Event onChange: (value: DateTimeValue) => void = (value: DateTimeValue) => {};

  private pick(): void {
    this.getUIContext().showDatePickerDialog({
      selected: toJsDate(this.value),
      lunar: false,
      onAccept: (result: DatePickerResult) => {
        if (result.year === undefined || result.month === undefined ||
          result.day === undefined) {
          // 回调给了不完整的日期：保留原值。默默落到今天的话，用户会以为自己
          // 选的就是今天。
          return;
        }
        this.onChange(new DateTimeValue(result.year, result.month, result.day, 0, 0, 0));
      }
    });
  }

  build() {
    Row() {
      Text(this.label)
        .fontSize(13)
        .fontColor($r('app.color.ch_text_secondary'))
        .width(76)
      Text(this.value.toDateString())
        .fontSize(13)
        .fontColor($r('app.color.ch_accent'))
        .layoutWeight(1)
      Text('选择')
        .fontSize(12)
        .fontColor($r('app.color.ch_text_hint'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 4, bottom: 4 })
    .onClick(() => {
      this.pick();
    })
  }
}

// ---------------------------------------------------------------- 各类设置
//
// 每个子 struct 一个 @Param value（父组件那个对象）+ 一个 onChanged 事件。
// 改完就调 onChanged，父组件负责写回并整体替换 @Local 以触发重绘。

@ComponentV2
struct ClockSettings {
  @Param value: ClockPayload = new ClockPayload();
  @Event onChanged: () => void = () => {};

  build() {
    Column() {
      EditorToggleRow({
        label: '显示秒',
        isOn: this.value.showSeconds,
        onToggle: (next: boolean) => {
          this.value.showSeconds = next;
          this.onChanged();
        }
      })
      EditorToggleRow({
        label: '用精确时间服务校时',
        hint: '关掉则直接用本机时间',
        isOn: this.value.showRealTime,
        onToggle: (next: boolean) => {
          this.value.showRealTime = next;
          this.onChanged();
        }
      })
      EditorToggleRow({
        label: '冒号闪烁',
        hint: '秒数不显示时才有效果',
        isOn: this.value.flashTimeSeparator,
        onToggle: (next: boolean) => {
          this.value.flashTimeSeparator = next;
          this.onChanged();
        }
      })
    }
    .width('100%')
  }
}

@ComponentV2
struct TextSettings {
  @Param value: TextPayload = new TextPayload();
  @Event onChanged: () => void = () => {};

  build() {
    Column() {
      EditorTextField({
        label: '文字',
        value: this.value.textContent,
        placeholder: '显示在这一行的文字',
        onCommit: (text: string) => {
          this.value.textContent = text;
          this.onChanged();
        }
      })
      EditorTextField({
        label: '字号',
        value: String(this.value.fontSize),
        type: 1,
        onCommit: (text: string) => {
          const size: number = Number.parseInt(text, 10);
          if (!Number.isNaN(size)) {
            this.value.fontSize = size;
            this.onChanged();
          }
        }
      })
      EditorToggleRow({
        label: '用自定义颜色',
        hint: '关掉则跟随面板前景色',
        isOn: this.value.useCustomFontColor,
        onToggle: (next: boolean) => {
          this.value.useCustomFontColor = next;
          this.onChanged();
        }
      })
      if (this.value.useCustomFontColor) {
        ColorField({
          label: '颜色',
          value: this.value.fontColor,
          onChange: (next: ColorValue) => {
            this.value.fontColor = next;
            this.onChanged();
          }
        })
      }
    }
    .width('100%')
  }
}

@ComponentV2
struct CountDownSettings {
  @Param value: CountDownPayload = new CountDownPayload();
  @Event onChanged: () => void = () => {};

  build() {
    Column() {
      EditorTextField({
        label: '名称',
        value: this.value.countDownName,
        onCommit: (text: string) => {
          this.value.countDownName = text;
          this.onChanged();
        }
      })
      DateField({
        label: '目标日期',
        value: this.value.overTime,
        onChange: (next: DateTimeValue) => {
          this.value.overTime = next.dateOnly();
          this.onChanged();
        }
      })
      DateField({
        label: '起始日期',
        value: this.value.startTime,
        onChange: (next: DateTimeValue) => {
          this.value.startTime = next.dateOnly();
          this.onChanged();
        }
      })
      EditorTextField({
        label: '连接词',
        value: this.value.countDownConnector,
        placeholder: '还有',
        onCommit: (text: string) => {
          this.value.countDownConnector = text;
          this.onChanged();
        }
      })
      EditorToggleRow({
        label: '连接词用强调色',
        isOn: this.value.isConnectorColorEmphasized,
        onToggle: (next: boolean) => {
          this.value.isConnectorColorEmphasized = next;
          this.onChanged();
        }
      })
      EditorToggleRow({
        label: '紧凑模式',
        isOn: this.value.isCompactModeEnabled,
        onToggle: (next: boolean) => {
          this.value.isCompactModeEnabled = next;
          this.onChanged();
        }
      })
      EditorToggleRow({
        label: '显示进度条',
        isOn: this.value.showProgress,
        onToggle: (next: boolean) => {
          this.value.showProgress = next;
          this.onChanged();
        }
      })
      if (this.value.showProgress) {
        EditorToggleRow({
          label: '进度条反向',
          hint: '改成显示已经过去的时间',
          isOn: this.value.isProgressInverted,
          onToggle: (next: boolean) => {
            this.value.isProgressInverted = next;
            this.onChanged();
          }
        })
      }
      EditorTextField({
        label: '格式',
        value: this.value.customStringFormat,
        placeholder: '%D天',
        onCommit: (text: string) => {
          this.value.customStringFormat = text;
          this.onChanged();
        }
      })
      EditorTextField({
        label: '字号',
        value: String(this.value.fontSize),
        type: 1,
        onCommit: (text: string) => {
          const size: number = Number.parseInt(text, 10);
          if (!Number.isNaN(size)) {
            this.value.fontSize = size;
            this.onChanged();
          }
        }
      })
      ColorField({
        label: '颜色',
        value: this.value.fontColor,
        onChange: (next: ColorValue) => {
          this.value.fontColor = next;
          this.onChanged();
        }
      })
      Text(`天数为 ${this.value.daysLeft}（由起止日期算出，不用手填）`)
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .padding({ top: 4, bottom: 4 })
    }
    .width('100%')
  }
}

@ComponentV2
struct WeatherSettings {
  @Param value: WeatherPayload = new WeatherPayload();
  @Event onChanged: () => void = () => {};

  build() {
    Column() {
      EditorToggleRow({
        label: '显示天气预警',
        isOn: this.value.showAlerts,
        onToggle: (next: boolean) => {
          this.value.showAlerts = next;
          this.onChanged();
        }
      })
      EditorToggleRow({
        label: '显示降雨时间',
        isOn: this.value.showRainTime,
        onToggle: (next: boolean) => {
          this.value.showRainTime = next;
          this.onChanged();
        }
      })
      EditorToggleRow({
        label: '模糊长时间降雨倒计时',
        hint: '长时间降雨时不显示具体剩余分钟',
        isOn: this.value.isFuzzyLongRainCountdownEnabled,
        onToggle: (next: boolean) => {
          this.value.isFuzzyLongRainCountdownEnabled = next;
          this.onChanged();
        }
      })
      EditorToggleRow({
        label: '显示主要天气信息',
        isOn: this.value.showMainWeatherInfo,
        onToggle: (next: boolean) => {
          this.value.showMainWeatherInfo = next;
          this.onChanged();
        }
      })
      Text('预警标题的显示方式、天气数据来源目前沿用桌面版的默认值，鸿蒙侧暂不可改。')
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .padding({ top: 4, bottom: 4 })
    }
    .width('100%')
  }
}

@ComponentV2
struct ScheduleSettings {
  @Param value: SchedulePayload = new SchedulePayload();
  @Event onChanged: () => void = () => {};

  build() {
    Column() {
      EditorToggleRow({
        label: '时刻显示额外信息',
        hint: '在每个时刻旁边补一行说明',
        isOn: this.value.showExtraInfoOnTimePoint,
        onToggle: (next: boolean) => {
          this.value.showExtraInfoOnTimePoint = next;
          this.onChanged();
        }
      })
      if (this.value.showExtraInfoOnTimePoint) {
        EditorTextField({
          label: '倒计时秒数',
          value: String(this.value.countdownSeconds),
          type: 1,
          onCommit: (text: string) => {
            const seconds: number = Number.parseInt(text, 10);
            if (!Number.isNaN(seconds)) {
              this.value.countdownSeconds = seconds;
              this.onChanged();
            }
          }
        })
      }
      EditorToggleRow({
        label: '只显示当前这节课',
        isOn: this.value.showCurrentLessonOnlyOnClass,
        onToggle: (next: boolean) => {
          this.value.showCurrentLessonOnlyOnClass = next;
          this.onChanged();
        }
      })
      EditorToggleRow({
        label: '隐藏已经上完的课',
        isOn: this.value.hideFinishedClass,
        onToggle: (next: boolean) => {
          this.value.hideFinishedClass = next;
          this.onChanged();
        }
      })
      EditorToggleRow({
        label: '淡化已上完的课',
        hint: '与「隐藏」不同，它只是变淡',
        isOn: this.value.fadeCompletedClasses,
        onToggle: (next: boolean) => {
          this.value.fadeCompletedClasses = next;
          this.onChanged();
        }
      })
      EditorToggleRow({
        label: '空课表时显示占位文字',
        isOn: this.value.showPlaceholderOnEmptyClassPlan,
        onToggle: (next: boolean) => {
          this.value.showPlaceholderOnEmptyClassPlan = next;
          this.onChanged();
        }
      })
      if (this.value.showPlaceholderOnEmptyClassPlan) {
        EditorTextField({
          label: '没有课的文案',
          value: this.value.placeholderTextNoClass,
          onCommit: (text: string) => {
            this.value.placeholderTextNoClass = text;
            this.onChanged();
          }
        })
        EditorTextField({
          label: '上完的文案',
          value: this.value.placeholderTextAllClassEnded,
          onCommit: (text: string) => {
            this.value.placeholderTextAllClassEnded = text;
            this.onChanged();
          }
        })
      }
      EditorToggleRow({
        label: '同时显示明天的课',
        isOn: this.value.showTomorrowSchedules,
        onToggle: (next: boolean) => {
          this.value.showTomorrowSchedules = next;
          this.onChanged();
        }
      })
      EditorToggleRow({
        label: '高亮有临时调整的课',
        isOn: this.value.highlightChangedClass,
        onToggle: (next: boolean) => {
          this.value.highlightChangedClass = next;
          this.onChanged();
        }
      })
      EditorTextField({
        label: '行距倍数',
        placeholder: '1 是正常行距',
        value: String(this.value.scheduleSpacing),
        onCommit: (text: string) => {
          const spacing: number = Number.parseFloat(text);
          if (!Number.isNaN(spacing) && spacing > 0) {
            this.value.scheduleSpacing = spacing;
            this.onChanged();
          }
        }
      })
    }
    .width('100%')
  }
}

@ComponentV2
struct RollingSettings {
  @Param value: RollingPayload = new RollingPayload();
  @Event onChanged: () => void = () => {};

  build() {
    Column() {
      EditorTextField({
        label: '速度',
        value: String(this.value.speedPixelPerSecond),
        onCommit: (text: string) => {
          const speed: number = Number.parseFloat(text);
          if (!Number.isNaN(speed) && speed !== 0) {
            this.value.speedPixelPerSecond = speed;
            this.onChanged();
          }
        }
      })
      EditorToggleRow({
        label: '允许暂停',
        isOn: this.value.isPauseEnabled,
        onToggle: (next: boolean) => {
          this.value.isPauseEnabled = next;
          this.onChanged();
        }
      })
      if (this.value.isPauseEnabled) {
        EditorTextField({
          label: '暂停时长',
          value: String(this.value.pauseSeconds),
          onCommit: (text: string) => {
            const seconds: number = Number.parseFloat(text);
            if (!Number.isNaN(seconds) && seconds > 0) {
              this.value.pauseSeconds = seconds;
              this.onChanged();
            }
          }
        })
      }
      Text('按规则暂停与停止要等规则判定（P8）落地后才能在这里配。')
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .padding({ top: 4, bottom: 4 })
    }
    .width('100%')
  }
}

@ComponentV2
struct SlideSettings {
  @Param value: SlidePayload = new SlidePayload();
  @Event onChanged: () => void = () => {};

  build() {
    Column() {
      EditorTextField({
        label: '停留秒数',
        value: String(this.value.slideSeconds),
        onCommit: (text: string) => {
          const seconds: number = Number.parseFloat(text);
          if (!Number.isNaN(seconds) && seconds > 0) {
            this.value.slideSeconds = seconds;
            this.onChanged();
          }
        }
      })
      EditorToggleRow({
        label: '带动画切换',
        isOn: this.value.isAnimationEnabled,
        onToggle: (next: boolean) => {
          this.value.isAnimationEnabled = next;
          this.onChanged();
        }
      })
      Text('切换方式、按规则暂停与停止要等规则判定（P8）落地后才能在这里配。')
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .padding({ top: 4, bottom: 4 })
    }
    .width('100%')
  }
}

/** 容器（分组 / 堆叠）没有自己的设置，只有子组件。 */
@ComponentV2
struct NoSettings {
  @Param hint: string = '';

  build() {
    EditorEmptyHint({ text: this.hint })
  }
}

// ------------------------------------------------------------------ 壳

/**
 * 单个组件的设置页。
 *
 * 它不是路由页，是 ComponentLayoutPane 里内联展开的一块。用内联而不是推一个
 * NavDestination：位置（ComponentLocation）在展开前后不能变，而走路由就得把
 * 它塞进路由参数里再取回来，取回来的那个可能已经因为别的改动而失效。
 */
@ComponentV2
export struct ComponentSettingsPane {
  @Require @Param vm: ComponentLayoutViewModel;
  @Require @Param location: ComponentLocation;
  @Param displayName: string = '';
  @Param componentGuid: string = '';
  @Event onClose: () => void = () => {};

  /**
   * 当前设置视图。
   *
   * 每次写回之后整体替换：payload 不是 @ObservedV2，就地改字段不触发重绘，
   * 而重新读一次还顺带把写回后的值（可能是被夹过的）显示出来。
   */
  @Local payload: ComponentPayload = new ComponentPayload();
  @Local nameCache: string = '';
  @Local hideOnRule: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    const component: ComponentSettings | undefined = this.vm.componentAt(this.location);
    this.payload = this.vm.readPayloadAt(this.location);
    this.nameCache = component === undefined ? '' : component.nameCache;
    this.hideOnRule = component !== undefined && component.hideOnRule;
  }

  /**
   * 把改动写回布局。
   *
   * 写回失败说明这个位置已经不存在了（别的改动把它移走了），那就重新读一遍，
   * 让界面回到与布局一致的状态，而不是继续显示一份已经不存在的设置。
   */
  private commit(): void {
    if (!this.vm.writePayloadAt(this.location, this.payload)) {
      this.reload();
    }
  }

  private onChanged(): void {
    this.commit();
  }

  @Builder
  private body() {
    if (this.componentGuid === COMPONENT_CLOCK) {
      ClockSettings({ value: this.payload as ClockPayload, onChanged: () => { this.onChanged(); } })
    } else if (this.componentGuid === COMPONENT_TEXT) {
      TextSettings({ value: this.payload as TextPayload, onChanged: () => { this.onChanged(); } })
    } else if (this.componentGuid === COMPONENT_COUNTDOWN) {
      CountDownSettings({ value: this.payload as CountDownPayload, onChanged: () => { this.onChanged(); } })
    } else if (this.componentGuid === COMPONENT_WEATHER) {
      WeatherSettings({ value: this.payload as WeatherPayload, onChanged: () => { this.onChanged(); } })
    } else if (this.componentGuid === COMPONENT_SCHEDULE) {
      ScheduleSettings({ value: this.payload as SchedulePayload, onChanged: () => { this.onChanged(); } })
    } else if (this.componentGuid === COMPONENT_ROLLING) {
      RollingSettings({ value: this.payload as RollingPayload, onChanged: () => { this.onChanged(); } })
    } else if (this.componentGuid === COMPONENT_SLIDE) {
      SlideSettings({ value: this.payload as SlidePayload, onChanged: () => { this.onChanged(); } })
    } else if (this.componentGuid === COMPONENT_GROUP || this.componentGuid === COMPONENT_STACK) {
      NoSettings({ hint: '这个容器没有自己的设置，配置的是它里面的组件。' })
    } else if (this.componentGuid === COMPONENT_SEPARATOR) {
      NoSettings({ hint: '分割线没有可设置的项。' })
    } else {
      NoSettings({
        hint: `组件 id ${this.componentGuid} 没有被识别，设置原样保留。`
      })
    }
  }

  build() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(26)
          .fontColor($r('app.color.ch_text_primary'))
          .width(32)
          .onClick(() => {
            this.onClose();
          })
        Column() {
          Text(this.displayName)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ch_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('第 ' + (this.location.lineIndex + 1) + ' 行')
            .fontSize(11)
            .fontColor($r('app.color.ch_text_hint'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .height(48)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 8, right: 12 })

      Scroll() {
        Column() {
          EditorCard({ title: '组件' })
          EditorTextField({
            label: '自定义名',
            value: this.nameCache,
            placeholder: '留空则用组件自己的名字',
            onCommit: (text: string) => {
              this.nameCache = text;
              this.vm.setNameCache(this.location, text);
            }
          })
          EditorToggleRow({
            label: '按规则隐藏',
            hint: '规则成立时这个组件不显示。判定按打开页面的那一刻的课表。',
            isOn: this.hideOnRule,
            onToggle: (next: boolean) => {
              this.hideOnRule = next;
              this.vm.setHideOnRule(this.location, next);
            }
          })
          if (this.hideOnRule) {
            RulesetEditorView({
              vm: this.vm,
              location: this.location,
              isLine: false,
              title: '这块内容的隐藏规则'
            })
          }

          EditorCard({
            title: t('pane_settings_title'),
            hint: t('pane_extra_fields_hint')
          })
          this.body()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.start_window_background'))
  }
}
