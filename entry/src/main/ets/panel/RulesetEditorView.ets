/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 「按规则隐藏」的规则集编辑器。
 *
 * 一份 UI 挂在两类宿主上
 * ----------------------
 * 桌面版为 ComponentSettings 与 MainWindowLineSettings 各写了一套界面，两套
 * 界面里的「规则集」部分长得一模一样（共用同一个 RulesetControl）。这边照抄
 * 那个结构：RulesetEditorView 只认「位置 + 是不是行」，规则集的增删改全部
 * 转发给 ComponentLayoutViewModel 上的同名方法。行与组件的差别只有两处 ——
 * 标题文案，和宿主不在了时的处理 —— 都不值得为它拆出第二份界面。
 *
 * 结论从哪来，为什么界面上不自己算
 * --------------------------------
 * 每条规则、每组、整个规则集的判定结论都来自 common_core 的 RuleEngine，
 * 由 RulesetEditor.build 合成到行数据上（见 RulesetEditModel.ets 的文件头）。
 * 这里一次都不重算：自己算的话，短路跳过的那些规则、停用的组、空组这三处
 * 结论会与面板实际用的那份不一致，而「编辑器说藏了、面板没藏」是用户没法
 * 自查的错误。
 *
 * 结论是打开时算的那一份，不跟着时钟走
 * ------------------------------------
 * 面板每秒重算一次，这个编辑器不 —— 课表状态随时钟变，逐秒重排整棵规则树会
 * 让正在点的控件跳走。所以结论旁边给了「重新判定」，并且默认形状下界面里
 * 每一处状态点都标了它是从哪来的（真 / 假 / 未判定），不让人以为那是实时值。
 *
 * 设置控件只做当前能算的那几种
 * ----------------------------
 * 13 条规则里有 9 条是窗口与天气的，桌面版靠 Win32 与和风天气才有数据，鸿蒙侧
 * 一个都没有（见 RuleCatalog 的 RuleSupport）。这 9 条在界面上照常列出、可以
 * 挑、可以配设置（配出来的值原样落盘，等 P11 接入数据源就能用），但控件置灰
 * 并标出「当前平台没有对应数据」—— 而不是从列表里藏起来。藏起来的话，用户从
 * 桌面版同步过来的一份配置里若有天气规则，这边会少几条，而界面上没有任何
 * 地方能解释这个差异。
 *
 * 判定为假的两种原因必须分开说
 * ----------------------------
 * 「这条规则没实现」与「这条规则没匹配上」在桌面版都表现为 State=1，从界面上
 * 完全分不开。用户在鸿蒙侧看到一条课表规则不成立，去面板上把课表调一遍还是
 * 不成立，就得怀疑是不是应用坏了。这两者的区别由 RuleEngine 的 reason 代码
 * 带出来（notImplemented / unknownRule / notMatched / handlerThrew），每条
 * 规则下面都照实写出来。
 */

import {
  CurrentSubjectRuleSettings,
  CurrentWeatherRuleSettings,
  Guid,
  RainTimeRuleSettings,
  RulesetLogicalMode,
  StringMatchingSettings,
  SunRiseSetRuleSettings,
  TimeState,
  TimeStateRuleSettings
} from 'common_shared';
import {
  ComponentLocation,
  RuleChoiceRow,
  RuleEditRow,
  RuleGroupEditRow,
  RuleReason,
  RuleSettingsKind,
  RuleSupport,
  RulesetEditModel,
  STATE_TRUE
} from 'common_core';
import {
  EditorCard,
  EditorChip,
  EditorEmptyHint,
  EditorTextField,
  EditorToggleRow
} from '../components/EditorWidgets';
import {
  ComponentLayoutViewModel,
  RuleSubjectChoice
} from '../viewmodel/ComponentLayoutViewModel';

/** 「当前时间状态」的一个候选项。值与桌面版 TimeState 枚举一致。 */
class TimeStateChoice {
  value: TimeState = TimeState.None;
  label: string = '';
}

/**
 * 建一个候选项。写成函数而不是对象字面量：ArkTS 不认字面量当类型（10605040）。
 */
function timeStateChoice(value: TimeState, label: string): TimeStateChoice {
  const out: TimeStateChoice = new TimeStateChoice();
  out.value = value;
  out.label = label;
  return out;
}

/**
 * 五个时间状态，值与桌面版一致。
 *
 * PrepareOnClass 标了「不会命中」：桌面版已经没有处理器会产生这个状态
 * （TimeStateHandler 只按 IsOnClass 派生，AppConfig 那边的 PrepareOnClass
 * 分支留的是空实现），但枚举值不能删 —— 桌面版配过的文件里可能有它，
 * 删了这个值就变成「不认识的枚举」，只能原样透传。
 */
const TIME_STATE_CHOICES: TimeStateChoice[] = [
  timeStateChoice(TimeState.None, '无课程'),
  timeStateChoice(TimeState.OnClass, '上课中'),
  timeStateChoice(TimeState.PrepareOnClass, '准备上课（不会命中）'),
  timeStateChoice(TimeState.Breaking, '课间休息'),
  timeStateChoice(TimeState.AfterSchool, '已放学')
];

/** 时间状态的中文名。时间状态的值来自文件，认不出来时给「未知（n）」而不是空串。 */
function timeStateLabel(state: number): string {
  for (const choice of TIME_STATE_CHOICES) {
    if (choice.value === state) {
      return choice.label;
    }
  }
  return `未知状态（${state}）`;
}

/**
 * 判定原因的中文说明。
 *
 * 代码取自 RuleReason 常量而不是字面量 —— 这串值同时被 core 写进轨迹，界面
 * 自己再抄一遍就迟早会抄错，而抄错的表现是「界面上什么都不显示」，很难查。
 */
function reasonText(reason: string): string {
  if (reason === RuleReason.NotChosen) {
    return '还没挑规则';
  }
  if (reason === RuleReason.UnknownRule) {
    return '当前平台不认识这条规则，判为不成立';
  }
  if (reason === RuleReason.NotImplemented) {
    return '当前平台没有这条规则要的数据，判为不成立';
  }
  if (reason === RuleReason.HandlerThrew) {
    return '判定时出错，按不成立处理';
  }
  if (reason === RuleReason.Matched) {
    return '成立';
  }
  if (reason === RuleReason.NotMatched) {
    return '不成立';
  }
  if (reason === RuleReason.GroupEmpty) {
    return '组里没有挑过规则，整组不参与判定';
  }
  if (reason === RuleReason.NoRuleset) {
    return '还没配规则';
  }
  if (reason === RuleReason.GroupDisabled) {
    return '这一组已停用，不参与判定';
  }
  if (reason === RuleReason.ShortCircuited) {
    // 这一条/这一组压根没被判定过。必须明说，否则用户会以为它没成立而去重配 ——
    // 而实际上它成不成立根本没影响结果，前面的规则已经定论了。
    return '没轮到判定（前面的已经定论了）';
  }
  return '';
}

/**
 * 一条规则当前设置的可读摘要。
 *
 * 给「这条规则在当前平台跑不了」的规则用：那 9 条的控件是灰的，用户仍然需要
 * 看到自己在桌面版配了什么 —— 只给一句「不可用」的话，一份从桌面版同步过来
 * 的配置在这边就变成了无法核对的黑箱。
 *
 * 顺序按判断的确定性从高到低：能确定类型的先判。
 */
function settingsSummary(row: RuleEditRow): string {
  const settings: Object = row.settings;
  if (settings instanceof TimeStateRuleSettings) {
    const pick: TimeStateRuleSettings = settings;
    return `时间状态：${timeStateLabel(pick.state)}`;
  }
  if (settings instanceof CurrentSubjectRuleSettings) {
    const pick: CurrentSubjectRuleSettings = settings;
    const text: string = pick.subjectId.toString();
    return text.length > 0 ? `科目：${text}` : '科目：没选';
  }
  if (settings instanceof StringMatchingSettings) {
    const pick: StringMatchingSettings = settings;
    const text: string = pick.text.length > 0 ? pick.text : '（空）';
    return `文本：${text}${pick.useRegex ? '（按正则）' : ''}`;
  }
  if (settings instanceof RainTimeRuleSettings) {
    const pick: RainTimeRuleSettings = settings;
    return `${pick.isRemainingTime ? '还剩' : '已过'} ${pick.rainTimeMinutes} 分钟`;
  }
  if (settings instanceof SunRiseSetRuleSettings) {
    const pick: SunRiseSetRuleSettings = settings;
    return `${pick.isSunset ? '日落后' : '日出前'} ${pick.timeMinutes} 分钟`;
  }
  if (settings instanceof CurrentWeatherRuleSettings) {
    const pick: CurrentWeatherRuleSettings = settings;
    return `天气类型 ${pick.weatherId}${pick.isFuzzyMatch ? '（模糊）' : ''}`;
  }
  return '';
}

@ComponentV2
export struct RulesetEditorView {
  @Require @Param vm: ComponentLayoutViewModel;
  @Require @Param location: ComponentLocation;
  /** 宿主是一行而不是一个组件。桌面版的行规则与组件规则字段同名同义。 */
  @Param isLine: boolean = false;
  /** 卡片标题。行与组件的措辞不同，省得用户在两页看到同一个「隐藏规则」。 */
  @Param title: string = '隐藏规则';

  /**
   * 当前规则集的编辑态。
   *
   * 每次改动之后整体重建：行数据不是 @ObservedV2，就地改字段不触发重绘，而
   * 改完一条规则之后规则集的形状（下标、结论）全都变了，本来就该整份换掉。
   */
  @Local model: RulesetEditModel = new RulesetEditModel();

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.model = this.isLine
      ? this.vm.lineRuleModel(this.location.lineIndex)
      : this.vm.ruleModelFor(this.location);
  }

  /** 状态点的颜色。成立用主题强调色，不成立与未判定都用弱化色。 */
  private dotColor(state: number): ResourceColor {
    if (state === STATE_TRUE) {
      return $r('app.color.ch_next');
    }
    return $r('app.color.ch_outline');
  }

  @Builder
  private stateDot(state: number) {
    Circle()
      .width(8)
      .height(8)
      .borderRadius(4)
      .fill(this.dotColor(state))
      .margin({ right: 6 })
  }

  /**
   * 整个规则集的结论。
   *
   * 单独一行放在最上面，因为它是唯一一句「配完之后面板会怎样」的话，而它不在
   * 任何一组里 —— 用户改完组内的东西要往回滚好几屏才看得到结论的话，就等于
   * 没有结论。
   */
  @Builder
  private verdict() {
    Row() {
      this.stateDot(this.model.state)
      Column() {
        Text(this.model.satisfied ? '现在会把它藏起来' : '现在不会藏')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.model.satisfied
            ? $r('app.color.ch_text_primary') : $r('app.color.ch_text_secondary'))
        Text(this.verdictHint())
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      EditorChip({ text: '重新判定', onTap: () => { this.reload(); } })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 4, bottom: 8 })
  }

  /** 结论行下面那行小字。空组与停用组要分开说，否则用户不知道该动哪一个开关。 */
  private verdictHint(): string {
    if (this.model.groups.length === 0) {
      return '还没有任何一组规则，这块内容会一直显示。';
    }
    const enabled: number = this.enabledGroupCount();
    if (enabled === 0) {
      return '所有组都停用了，这块内容会一直显示。';
    }
    if (this.model.isEmpty) {
      return '结论是打开这个页面的那一刻算的，课表变了要重新判定。';
    }
    return `结论是打开这个页面的那一刻算的，共 ${enabled} 组参与判定，课表变了要重新判定。`;
  }

  private enabledGroupCount(): number {
    let out: number = 0;
    for (const group of this.model.groups) {
      if (group.isEnabled) {
        out++;
      }
    }
    return out;
  }

  /** 规则集级：组合方式 + 整体取反。 */
  @Builder
  private rulesetOptions() {
    Row() {
      Text('各组怎么算')
        .fontSize(13)
        .fontColor($r('app.color.ch_text_secondary'))
        .width(76)
      EditorChip({
        text: '任一组成立',
        tone: this.model.mode === RulesetLogicalMode.Or ? 1 : 0,
        onTap: () => {
          this.vm.setRulesetMode(this.location, this.isLine, RulesetLogicalMode.Or);
          this.reload();
        }
      })
      EditorChip({
        text: '所有组都成立',
        tone: this.model.mode === RulesetLogicalMode.And ? 1 : 0,
        onTap: () => {
          this.vm.setRulesetMode(this.location, this.isLine, RulesetLogicalMode.And);
          this.reload();
        }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 4, bottom: 4 })

    EditorToggleRow({
      label: '整体取反',
      hint: '所有组算完之后把结论反过来。桌面版 Ruleset.IsReversed。',
      isOn: this.model.isReversed,
      onToggle: (next: boolean) => {
        this.vm.setRulesetReversed(this.location, this.isLine, next);
        this.reload();
      }
    })
  }

  /** 一个规则组。 */
  @Builder
  private groupCard(group: RuleGroupEditRow) {
    Column() {
      Row() {
        this.stateDot(group.state)
        Text(`第 ${group.groupIndex + 1} 组`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ch_text_primary'))
          .layoutWeight(1)
        if (!group.isEnabled) {
          Text('已停用')
            .fontSize(11)
            .fontColor($r('app.color.ch_text_hint'))
            .margin({ right: 8 })
        }
        EditorChip({
          text: group.isReversed ? '已取反' : '取反',
          onTap: () => {
            this.vm.setRuleGroupReversed(this.location, this.isLine, group.groupIndex,
              !group.isReversed);
            this.reload();
          }
        })
        EditorChip({
          text: '删组',
          tone: 1,
          onTap: () => {
            this.vm.removeRuleGroup(this.location, this.isLine, group.groupIndex);
            this.reload();
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 4, bottom: 2 })

      Row() {
        Text('组内怎么算')
          .fontSize(13)
          .fontColor($r('app.color.ch_text_secondary'))
          .width(76)
        EditorChip({
          text: '任一条成立',
          tone: group.mode === RulesetLogicalMode.Or ? 1 : 0,
          onTap: () => {
            this.vm.setRuleGroupMode(this.location, this.isLine, group.groupIndex,
              RulesetLogicalMode.Or);
            this.reload();
          }
        })
        EditorChip({
          text: '全部成立',
          tone: group.mode === RulesetLogicalMode.And ? 1 : 0,
          onTap: () => {
            this.vm.setRuleGroupMode(this.location, this.isLine, group.groupIndex,
              RulesetLogicalMode.And);
            this.reload();
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 2, bottom: 2 })

      EditorToggleRow({
        label: '启用这一组',
        hint: '停用后这一组不参与判定，配置留着不动。',
        isOn: group.isEnabled,
        onToggle: (next: boolean) => {
          this.vm.setRuleGroupEnabled(this.location, this.isLine, group.groupIndex, next);
          this.reload();
        }
      })

      ForEach(group.rules, (rule: RuleEditRow) => {
        this.ruleRow(rule)
      }, (rule: RuleEditRow) => `${rule.groupIndex}-${rule.ruleIndex}`)

      Row() {
        EditorChip({
          text: '加一条规则',
          onTap: () => {
            this.vm.addRule(this.location, this.isLine, group.groupIndex, group.rules.length, '');
            this.reload();
          }
        })
        // 组内换序对判定没有任何影响（组内规则是与/或的关系，顺序无关），
        // 而桌面版也没提供，所以这里不给按钮 —— 给了就是让用户以为顺序有意义。
        Text('组内规则的先后不影响判定')
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 6, bottom: 2 })
    }
    .width('100%')
    .backgroundColor($r('app.color.ch_surface_weak'))
    .borderRadius(8)
    .padding({ left: 10, right: 10, top: 4, bottom: 8 })
    .margin({ bottom: 8 })
  }

  /** 组内一条规则。 */
  @Builder
  private ruleRow(rule: RuleEditRow) {
    Column() {
      Row() {
        this.stateDot(rule.state)
        Text(rule.displayName)
          .fontSize(13)
          .fontColor(rule.isUnchosen
            ? $r('app.color.ch_text_hint') : $r('app.color.ch_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        EditorChip({
          text: rule.isReversed ? '已取反' : '取反',
          onTap: () => {
            this.vm.setRuleReversed(this.location, this.isLine, rule.groupIndex, rule.ruleIndex,
              !rule.isReversed);
            this.reload();
          }
        })
        EditorChip({
          text: '删',
          tone: 1,
          onTap: () => {
            this.vm.removeRule(this.location, this.isLine, rule.groupIndex, rule.ruleIndex);
            this.reload();
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 4, bottom: 2 })

      Text('换成…')
        .fontSize(12)
        .fontColor($r('app.color.ch_accent'))
        .padding({ top: 2, bottom: 2 })
        .bindMenu(this.ruleMenu(rule))

      this.ruleSettings(rule)

      if (reasonText(rule.reason).length > 0) {
        Text(reasonText(rule.reason))
          .fontSize(11)
          .fontColor(rule.state === STATE_TRUE
            ? $r('app.color.ch_next') : $r('app.color.ch_text_hint'))
          .width('100%')
          .padding({ top: 2, bottom: 2 })
      }
    }
    .width('100%')
    .padding({ top: 2, bottom: 4 })
  }

  /** 规则选择器。 */
  @Builder
  private ruleMenu(rule: RuleEditRow) {
    Menu() {
      ForEach(this.vm.ruleChoices(), (choice: RuleChoiceRow) => {
        MenuItem({ content: this.choiceLabel(choice) }).onChange(() => {
          this.vm.setRuleId(this.location, this.isLine, rule.groupIndex, rule.ruleIndex, choice.id);
          this.reload();
        })
      }, (choice: RuleChoiceRow) => choice.id)
    }
  }

  /** 不可用的规则在菜单里就标出来。选不选得到另说，不标的话用户是在盲选。 */
  private choiceLabel(choice: RuleChoiceRow): string {
    if (choice.id.length === 0 || choice.support === RuleSupport.Implemented) {
      return choice.displayName;
    }
    return `${choice.displayName}（当前平台不可用）`;
  }

  /**
   * 一条规则的设置区。
   *
   * 分三种情形：能算的给控件、能算但值来自别的档案的照常给控件、不能算的给
   * 「不可用」加一份只读摘要。分派按 settingsKind 而不是按对象类型 ——
   * 未注册规则的 settings 是个空对象，判类型只会全部落到兜底分支。
   */
  @Builder
  private ruleSettings(rule: RuleEditRow) {
    if (!rule.isSettingsEditable) {
      Column() {
        Text(rule.settingsHint)
          .fontSize(11)
          .fontColor($r('app.color.ch_text_hint'))
          .width('100%')
        if (settingsSummary(rule).length > 0) {
          Text(settingsSummary(rule))
            .fontSize(11)
            .fontColor($r('app.color.ch_text_secondary'))
            .width('100%')
            .padding({ top: 2 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (rule.settingsKind === RuleSettingsKind.TimeState) {
      this.timeStateFields(rule)
    } else if (rule.settingsKind === RuleSettingsKind.CurrentSubject) {
      this.subjectFields(rule)
    } else if (rule.settingsKind === RuleSettingsKind.StringMatching) {
      this.stringFields(rule)
    } else {
      Text(rule.settingsHint)
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
    }
  }

  /** 「当前时间状态」：一个下拉。 */
  @Builder
  private timeStateFields(rule: RuleEditRow) {
    Row() {
      Text('时间状态')
        .fontSize(13)
        .fontColor($r('app.color.ch_text_secondary'))
        .width(76)
      Text(timeStateLabel(this.timeStateOf(rule).state))
        .fontSize(13)
        .fontColor($r('app.color.ch_text_primary'))
        .layoutWeight(1)
      Text('选择…')
        .fontSize(12)
        .fontColor($r('app.color.ch_accent'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 2, bottom: 2 })
    .bindMenu(this.timeStateMenu(rule))
  }

  @Builder
  private timeStateMenu(rule: RuleEditRow) {
    Menu() {
      ForEach(TIME_STATE_CHOICES, (choice: TimeStateChoice) => {
        MenuItem({ content: choice.label }).onChange(() => {
          const settings: TimeStateRuleSettings = this.timeStateOf(rule);
          settings.state = choice.value;
          this.vm.writeRuleSettings(this.location, this.isLine, rule.groupIndex, rule.ruleIndex,
            settings);
          this.reload();
        })
      }, (choice: TimeStateChoice) => `${choice.value}`)
    }
  }

  /** 「科目是」：一个下拉 + 课表没载入时的提示。 */
  @Builder
  private subjectFields(rule: RuleEditRow) {
    Row() {
      Text('科目')
        .fontSize(13)
        .fontColor($r('app.color.ch_text_secondary'))
        .width(76)
      Text(this.subjectLabel(this.subjectOf(rule).subjectId))
        .fontSize(13)
        .fontColor(this.subjectOf(rule).subjectId.isEmpty()
          ? $r('app.color.ch_text_hint') : $r('app.color.ch_text_primary'))
        .layoutWeight(1)
      Text('选择…')
        .fontSize(12)
        .fontColor($r('app.color.ch_accent'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 2, bottom: 2 })
    .bindMenu(this.subjectMenu(rule))
  }

  @Builder
  private subjectMenu(rule: RuleEditRow) {
    Menu() {
      MenuItem({ content: '（不选任何科目）' }).onChange(() => {
        const settings: CurrentSubjectRuleSettings = this.subjectOf(rule);
        settings.subjectId = Guid.empty();
        this.vm.writeRuleSettings(this.location, this.isLine, rule.groupIndex, rule.ruleIndex,
          settings);
        this.reload();
      })
      ForEach(this.vm.subjectChoices(), (choice: RuleSubjectChoice) => {
        MenuItem({ content: choice.name }).onChange(() => {
          const settings: CurrentSubjectRuleSettings = this.subjectOf(rule);
          settings.subjectId = Guid.parseOrEmpty(choice.guid);
          this.vm.writeRuleSettings(this.location, this.isLine, rule.groupIndex, rule.ruleIndex,
            settings);
          this.reload();
        })
      }, (choice: RuleSubjectChoice) => choice.guid)
    }
  }

  /**
   * 选中的科目显示成名字而不是 GUID。
   *
   * 科目表的键是小写带连字符的 GUID，显示出来是「语文」与
   * 「a3b2f1e0-…」的区别。这里查不到就退回 GUID 本身：查不到意味着档案换了
   * 或者这条是从别的机器同步来的，界面上得让用户看见那个值，好去另一台机器上
   * 核对，而不是给一句「未找到」让他以为配丢了。
   */
  private subjectLabel(picked: Guid): string {
    if (picked.isEmpty()) {
      return '没选';
    }
    const wanted: string = picked.toString();
    for (const choice of this.vm.subjectChoices()) {
      if (choice.guid === wanted) {
        return choice.name;
      }
    }
    return wanted;
  }

  /** 文本匹配：文本 + 是否按正则。 */
  @Builder
  private stringFields(rule: RuleEditRow) {
    EditorTextField({
      label: '匹配文本',
      value: this.stringOf(rule).text,
      placeholder: '要匹配的字符串',
      onCommit: (text: string) => {
        this.stringOf(rule).text = text;
        this.vm.writeRuleSettings(this.location, this.isLine, rule.groupIndex, rule.ruleIndex,
          this.stringOf(rule));
        this.reload();
      }
    })
    EditorToggleRow({
      label: '按正则解释',
      hint: '桌面版同样不加分段复用标志，表达式写错一律当作不匹配。',
      isOn: this.stringOf(rule).useRegex,
      onToggle: (next: boolean) => {
        this.stringOf(rule).useRegex = next;
        this.vm.writeRuleSettings(this.location, this.isLine, rule.groupIndex, rule.ruleIndex,
          this.stringOf(rule));
        this.reload();
      }
    })
  }

  /**
   * 取一条规则的强类型设置。
   *
   * 行数据上那个字段的类型是 Object（core 不该把 7 个设置类的并集摆在
   * 行数据上 —— 那样每加一种设置都要改所有读它的地方）。这里按已知的
   * settingsKind 强转，不是盲转：分派处（ruleSettings）已经判过 kind，而
   * core 那边 RuleCatalog.settingsOf 对同一个 id 永远给同一个类。
   */
  private timeStateOf(rule: RuleEditRow): TimeStateRuleSettings {
    return rule.settings as TimeStateRuleSettings;
  }

  private subjectOf(rule: RuleEditRow): CurrentSubjectRuleSettings {
    return rule.settings as CurrentSubjectRuleSettings;
  }

  private stringOf(rule: RuleEditRow): StringMatchingSettings {
    return rule.settings as StringMatchingSettings;
  }

  build() {
    Column() {
      EditorCard({ title: this.title })
      this.verdict()
      this.rulesetOptions()

      if (this.model.groups.length === 0) {
        EditorEmptyHint({ text: '还没有规则组。加一组之后才能往里填规则。' })
      }

      ForEach(this.model.groups, (group: RuleGroupEditRow) => {
        this.groupCard(group)
      }, (group: RuleGroupEditRow) => `${group.groupIndex}`)

      Row() {
        EditorChip({
          text: '加一组',
          onTap: () => {
            this.vm.addRuleGroup(this.location, this.isLine, this.model.groups.length);
            this.reload();
          }
        })
      }
      .width('100%')
      .padding({ top: 2, bottom: 8 })
    }
    .width('100%')
  }
}
