/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 课前提醒设置。
 *
 * 这一页不碰课表草稿
 * ----------------
 * 编辑页其它分页都在改草稿，离开时要问「要不要保存」。提醒设置不是课表的一部分
 * （它进的是 preferences，见 AppPreferences 的头注），混进草稿会让两件不相干
 * 的东西共用一条保存链：用户只想改提前量，却被问「有未保存的课表改动」，
 * 而这个提示是假的 —— 那份草稿其实一个字都没动。所以这里自己读自己写自己存，
 * 不经过 ViewModel。
 *
 * 提前量用固定档位而不是输入框
 * --------------------------
 * 提前量的可选范围是 0 到 3600 秒，绝大多数用户只关心「大概提前多久」，
 * 而输入框会带来两个新问题：手机上不好用数字键盘、输错了（3600 而不是 60）
 * 提醒会在一小时前响，而界面上看不出任何异常。固定档位把可选范围收窄到
 * 覆盖两个默认值（室内 1 分钟、室外 10 分钟）的最小集合，代价是放弃
 * 「提前 2 分钟」这种精度 —— 那对本应用不是需求。
 *
 * 改完立刻同步
 * ------------
 * 提前量参与触发时刻的计算，不同步的话界面上写着「提前 5 分钟」而提醒还在
 * 按 1 分钟响。所以每一次改动都直接走一次同步，不设「应用」按钮 ——
 * 这个设置没有「改完先不改、以后再说」的中间状态。
 */

import { common } from '@kit.AbilityKit';
import { DateTimeValue } from 'common_shared';
import { t, tf } from 'common_core';
import { ReminderMode } from 'common_core';
import {
  EditorChip,
  EditorHeader,
  EditorToggleRow,
  EditorValueRow
} from '../../components/EditorWidgets';
import { AppPreferences } from '../../common/AppPreferences';
import { ProfileRepository } from '../../data/ProfileRepository';
import {
  SYNC_BUSY,
  SYNC_FAILED,
  SYNC_NOTIFICATIONS_OFF,
  ReminderSyncResult,
  syncReminders
} from '../../reminder/ReminderSyncService';
import {
  REMINDER_MODE_AUTO,
  REMINDER_MODE_COLLAPSED,
  REMINDER_MODE_SPECIFIC,
  ReminderSettings
} from '../../reminder/ReminderSettings';

/** 提前量档位（分钟）。0 表示上课那一刻才提醒。 */
const ADVANCE_CHOICES: number[] = [0, 1, 3, 5, 10];

/** 档位的中文名。0 档与其它档含义不同，单独说。 */
function advanceLabel(minutes: number): string {
  return minutes === 0 ? t('rm_on_time') : tf('rm_advance_min', `${minutes}`);
}

@ComponentV2
export struct ReminderPane {
  @Param stack: NavPathStack = new NavPathStack();

  /**
   * 设置副本。
   *
   * 从 @State 起步而不是直接读 preferences：写完要立刻反映到界面上，而
   * preferences 的写是同步的、读也是同步的，但「写完重读一遍」在每一次
   * 改动上都是多余的往返。
   */
  @Local private settings: ReminderSettings = new ReminderSettings();
  /** 同步进行中。用来把按钮置灰，避免连点。 */
  @Local private syncing: boolean = false;
  /** 上次同步的结论，照实显示。 */
  @Local private statusText: string = '';
  /** 上次同步有没有需要用户处理的问题（额度不够、权限没开）。 */
  @Local private statusIsWarning: boolean = false;
  /** 单双周偏差的提示。有它才显示。 */
  @Local private rotationHint: string = '';
  @Local private loaded: boolean = false;

  aboutToAppear(): void {
    const host: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.settings = ReminderSettings.load(new AppPreferences(host));
    this.loaded = true;
  }

  private async apply(): Promise<void> {
    if (this.syncing) {
      return;
    }
    this.syncing = true;
    const host: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const result: ReminderSyncResult =
        await syncReminders(host, new ProfileRepository(host.filesDir), nowValue());
      this.report(result);
    } catch (err) {
      // 走到这里说明胶水层里有预料之外的异常。仍然要给用户一句人话，
      // 而不是让界面停在「同步中」。
      this.statusText = t('rm_sync_failed');
      this.statusIsWarning = true;
      this.rotationHint = '';
    } finally {
      this.syncing = false;
    }
  }

  /** 把同步结果翻译成一行给用户看的话。 */
  private report(result: ReminderSyncResult): void {
    this.rotationHint = result.hasRotation
      ? t('rm_biweekly_note')
      : '';
    if (result.status === SYNC_BUSY) {
      this.statusText = t('rm_syncing');
      this.statusIsWarning = false;
      return;
    }
    if (result.status === SYNC_NOTIFICATIONS_OFF) {
      this.statusText = result.message;
      this.statusIsWarning = true;
      return;
    }
    if (result.status === SYNC_FAILED) {
      this.statusText = result.message.length > 0 ? result.message : t('rm_sync_failed');
      this.statusIsWarning = true;
      return;
    }
    if (result.message.length > 0 && result.failedCount > 0) {
      // message 优先：额度不够、权限被关这类是根因，而 failedCount 只是症状。
      this.statusText = tf('rm_sync_partial', result.message, `${result.failedCount}`);
      this.statusIsWarning = true;
      return;
    }
    if (result.failedCount > 0) {
      this.statusText = tf('rm_dropped_count', `${result.failedCount}`);
      this.statusIsWarning = true;
      return;
    }
    if (result.plannedCount === 0) {
      this.statusText = t('rm_nothing_to_remind');
      this.statusIsWarning = false;
      return;
    }
    const shape: string = result.mode === ReminderMode.Specific ? t('rm_shape_specific') : t('rm_shape_merged');
    this.statusText = tf('rm_planned', `${result.plannedCount}`, shape) +
      (result.droppedCount > 0 ? tf('rm_quota_more', `${result.droppedCount}`) : '');
    this.statusIsWarning = result.droppedCount > 0;
  }

  private saveThenSync(): void {
    const host: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.settings.save(new AppPreferences(host));
    this.apply();
  }

  private pickAdvance(isIndoor: boolean, minutes: number): void {
    if (isIndoor) {
      this.settings.advanceIndoorSeconds = minutes * 60;
    } else {
      this.settings.advanceOutdoorSeconds = minutes * 60;
    }
    this.saveThenSync();
  }

  private pickMode(mode: number): void {
    this.settings.modeOverride = mode;
    this.saveThenSync();
  }

  private toggleEnabled(isOn: boolean): void {
    this.settings.enabled = isOn;
    this.saveThenSync();
  }

  private modeLabel(): string {
    if (this.settings.modeOverride === REMINDER_MODE_SPECIFIC) {
      return t('rm_shape_specific');
    }
    if (this.settings.modeOverride === REMINDER_MODE_COLLAPSED) {
      return t('rm_shape_merged');
    }
    return t('rm_mode_auto');
  }

  @Builder
  private advanceRow(label: string, hint: string, isIndoor: boolean) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.ch_text_primary'))
        .width('100%')
      Text(hint)
        .fontSize(11)
        .fontColor($r('app.color.ch_text_hint'))
        .width('100%')
        .margin({ top: 2, bottom: 6 })
      Row() {
        ForEach(ADVANCE_CHOICES, (minutes: number) => {
          EditorChip({
            text: advanceLabel(minutes),
            tone: this.currentAdvance(isIndoor) === minutes ? 1 : 0,
            onTap: () => {
              this.pickAdvance(isIndoor, minutes);
            }
          })
          if (minutes !== ADVANCE_CHOICES[ADVANCE_CHOICES.length - 1]) {
            Text(' ').fontSize(4)
          }
        }, (minutes: number) => `${minutes}`)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  private currentAdvance(isIndoor: boolean): number {
    const seconds: number = isIndoor
      ? this.settings.advanceIndoorSeconds
      : this.settings.advanceOutdoorSeconds;
    // 设置里可能是 2 分钟这种不在档位里的值（手改 preferences 或旧版本留下
    // 的）。选不中任何档位时按「都不选中」处理，而不是就近高亮一个 ——
    // 高亮一个不等于当前值的档位，用户一点就被改掉了。
    return Math.round(seconds / 60);
  }

  build() {
    NavDestination() {
      Column() {
        EditorHeader({ title: t('rm_title'), stack: this.stack })

        if (!this.loaded) {
          Blank()
        } else {
          Scroll() {
            Column() {
              EditorToggleRow({
                label: t('rm_enable'),
                hint: t('rm_use_system_hint'),
                isOn: this.settings.enabled,
                onToggle: (isOn: boolean) => {
                  this.toggleEnabled(isOn);
                }
              })

              Divider().color($r('app.color.ch_outline')).margin({ top: 8, bottom: 8 })

              if (this.settings.enabled) {
                this.advanceRow(t('rm_advance_indoor'), t('rm_advance_indoor_hint'), true)
                Divider().color($r('app.color.ch_outline'))
                this.advanceRow(t('rm_advance_outdoor'), t('rm_advance_outdoor_hint'), false)
                Divider().color($r('app.color.ch_outline')).margin({ top: 8, bottom: 8 })

                EditorValueRow({
                  label: t('rm_shape'),
                  value: this.modeLabel()
                })
                Text(t('rm_shape_desc'))
                  .fontSize(11)
                  .fontColor($r('app.color.ch_text_hint'))
                  .width('100%')
                  .margin({ top: 2, bottom: 6 })
                Row() {
                  EditorChip({
                    text: t('rm_mode_auto'),
                    tone: this.settings.modeOverride === REMINDER_MODE_AUTO ? 1 : 0,
                    onTap: () => {
                      this.pickMode(REMINDER_MODE_AUTO);
                    }
                  })
                  Text(' ').fontSize(4)
                  EditorChip({
                    text: t('rm_shape_specific'),
                    tone: this.settings.modeOverride === REMINDER_MODE_SPECIFIC ? 1 : 0,
                    onTap: () => {
                      this.pickMode(REMINDER_MODE_SPECIFIC);
                    }
                  })
                  Text(' ').fontSize(4)
                  EditorChip({
                    text: t('rm_shape_merged'),
                    tone: this.settings.modeOverride === REMINDER_MODE_COLLAPSED ? 1 : 0,
                    onTap: () => {
                      this.pickMode(REMINDER_MODE_COLLAPSED);
                    }
                  })
                }
                .width('100%')
              }
            }
            .width('100%')
            .padding({ left: 14, right: 14, bottom: 8 })
          }
          .layoutWeight(1)
          .align(Alignment.Top)
        }

        Column() {
          Text(this.statusText.length > 0 ? this.statusText : ' ')
            .fontSize(11)
            .fontColor(this.statusIsWarning
              ? $r('app.color.ch_text_secondary')
              : $r('app.color.ch_text_hint'))
            .width('100%')
          if (this.rotationHint.length > 0) {
            Text(this.rotationHint)
              .fontSize(11)
              .fontColor($r('app.color.ch_text_hint'))
              .width('100%')
              .margin({ top: 4 })
          }
          Row() {
            Text(t('rm_resync_now'))
              .fontSize(13)
              .fontColor(this.syncing
                ? $r('app.color.ch_text_hint')
                : $r('app.color.ch_accent'))
              .onClick(() => {
                if (!this.syncing) {
                  this.saveThenSync();
                }
              })
          }
          .width('100%')
          .margin({ top: 8 })
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 8, bottom: 12 })
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
  }
}

/** 当前时刻。抽出来是为了把 `now` 的来源收在一处。 */
function nowValue(): DateTimeValue {
  return DateTimeValue.now();
}
