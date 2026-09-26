/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 今日课程表小组件的扩展侧。
 *
 * 这个类几乎不做计算，只管「什么时候重建、怎么把结果送出去」
 * -------------------------------------------------------
 * 算出来该显示什么在 common_core 的 WidgetBuilder 里（纯函数，有测试台覆盖）。
 * 这里只留三件事：读卡片规格、读档案、按需推送。任何推导搬到这里都会变成
 * 装机才能发现的问题 —— 而这个扩展 10 秒就被回收，没法在真机上反复调。
 *
 * 三种重建时机
 * ------------
 * 1. onAddForm：用户刚把卡片拖到桌面。这是唯一一次「一定会被调用」的机会。
 * 2. onUpdateForm：系统按 schedule 或 setFormNextRefreshTime 叫醒我们。
 * 3. onSizeChanged：卡片被拉成 4*4 了。
 *
 * 档案改动不靠这里
 * --------------
 * 主应用保存档案后自己调 formProvider.reloadAllForms，那会触发一次 onUpdateForm。
 * 让主应用直接推数据过来行不通：FormBindingData 的通道只在扩展运行时里，
 * 主应用拿不到别的进程的推送能力。
 *
 * 关于两个进程内缓存
 * ------------------
 * lastSignatures / dimensions 是模块级变量，看着像违反了「core 不可重入」的约束，
 * 其实不是：它们只是省掉「同一次拉起里重复推送」的缓存，进程一死就没了。
 * 跨进程重建时必然 miss，而那时也确实需要推。放这里比每次都 updateForm 好，
 * 因为 updateForm 会触发卡片重绘，重绘是用户看得见的闪烁。
 *
 * 卡片与扩展只隔一个 FormBindingData
 * ----------------------------------
 * 载荷是两个字符串字段（payload / dimension），不是模型本身：
 * FormBindingData 只认「键 -> 基本值」，塞一个模型进去要么编不过，要么编过了
 * 但卡面读不到。编解码在 common_core 的 WidgetCodec 里，有往返测试。
 */

import { Want } from '@kit.AbilityKit';
import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DateTimeValue } from 'common_shared';
import { WidgetCodec, WidgetDimension, WidgetModel } from 'common_core';
import { WidgetModelFactory } from './WidgetModelFactory';

const LOG_DOMAIN: number = 0x5701;
const LOG_TAG: string = 'FormAbility';

/** 本次进程生命周期内，每张卡片最后一次推出去的展示指纹。 */
const lastSignatures: Map<string, string> = new Map<string, string>();

/** 每张卡片当前的规格。onUpdateForm 拿不到 want，只能靠自己记。 */
const dimensions: Map<string, string> = new Map<string, string>();

/** onFormEvent 认识的消息。写成常量而不是散落的字面量，避免拼错时静默失效。 */
const EVENT_REFRESH: string = 'refresh';

export default class EntryFormAbility extends FormExtensionAbility {
  /**
   * 用户把卡片加到桌面时调用，返回首帧数据。
   *
   * 这一步失败的话卡片就是一片空白，而系统不会重试。所以读档案失败时也要
   * 返回一份合法载荷（内容是「课表读不出来」），空载荷的表现要差得多。
   */
  onAddForm(want: Want): formBindingData.FormBindingData {
    const dimension: string = EntryFormAbility.dimensionOf(want, WidgetDimension.COMPACT);
    const model: WidgetModel = this.buildModel(dimension);
    dimensions.set(EntryFormAbility.formIdOf(want, ''), dimension);
    return EntryFormAbility.bindingOf(model);
  }

  /**
   * 系统要求刷新某张卡片。
   *
   * 顺带在这里申请下一次刷新：nextRefreshMinutes 是按「这份显示内容下一次会变
   * 是多久」算出来的，于是刷新时点自己跟着课表走，不需要额外的定时器或后台任务。
   */
  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    this.push(formId, this.buildModel(EntryFormAbility.dimensionOfCache(formId)));
  }

  /**
   * 卡片被用户拉成 4*4 了。规格变了就该按新容量重排 —— 沿用旧容量的话
   * 4*4 上只显示 3 节课，看起来就是「放大没用」。
   */
  onSizeChanged(formId: string, newDimension: formInfo.FormDimension, newRect: formInfo.Rect): void {
    const dimension: string = WidgetModelFactory.dimensionFromNumber(newDimension);
    dimensions.set(formId, dimension);
    this.push(formId, this.buildModel(dimension));
  }

  /**
   * 用户在卡片上触发了自定义事件。
   *
   * 只认一个 'refresh'：卡片上「点一下手动刷新」这类交互会走到这里。
   * 其余消息静默忽略而不是打日志 —— 系统会周期性发一些自己用的事件，
   * 逐条打日志会淹掉真正需要看的东西。
   */
  onFormEvent(formId: string, message: string): void {
    if (message !== EVENT_REFRESH) {
      return;
    }
    // 用户主动点的刷新不查缓存：哪怕内容没变，这次交互也要有反应。
    lastSignatures.delete(formId);
    this.push(formId, this.buildModel(EntryFormAbility.dimensionOfCache(formId)));
  }

  /** 卡片被移除。清掉缓存，否则 formId 被系统复用时会读到上一张卡片的指纹。 */
  onRemoveForm(formId: string): void {
    lastSignatures.delete(formId);
    dimensions.delete(formId);
  }

  /**
   * 告知系统卡片数据已就绪。
   *
   * 置 READY 的意义是「我渲染完了」：置 DEFAULT 的话系统会认为卡片还没准备好，
   * 桌面上的占位图会一直留着。
   */
  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  // ---------------------------------------------------------------- 内部

  private buildModel(dimension: string): WidgetModel {
    return WidgetModelFactory.build(this.context.filesDir, dimension, DateTimeValue.now());
  }

  private push(formId: string, model: WidgetModel): void {
    if (formId.length === 0) {
      return;
    }
    const signature: string = model.displaySignature();
    if (lastSignatures.get(formId) === signature) {
      return;
    }
    lastSignatures.set(formId, signature);
    dimensions.set(formId, model.dimension);

    EntryFormAbility.sendUpdate(formId, model);
  }

  private static sendUpdate(formId: string, model: WidgetModel): void {
    try {
      formProvider.updateForm(formId, EntryFormAbility.bindingOf(model)).then(() => {
        EntryFormAbility.scheduleNext(formId, model.nextRefreshMinutes);
      }).catch((err: BusinessError) => {
        // 推不动的常见原因是这张卡片刚被移除、或系统正在回收。两种都不该让
        // 扩展崩掉 —— 崩了会连带影响同一次拉起里其它卡片的回调。
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'updateForm 失败 formId=%{public}s code=%{public}d',
          formId, err.code);
      });
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'updateForm 同步抛异常 formId=%{public}s', formId);
    }
  }

  /** 申请在「内容下一次会变」的时候再叫醒一次。 */
  private static scheduleNext(formId: string, minutes: number): void {
    try {
      formProvider.setFormNextRefreshTime(formId, minutes).catch((err: BusinessError) => {
        // 申请失败只影响精度（退回到系统默认的刷新节奏），不影响现在显示的内容。
        hilog.info(LOG_DOMAIN, LOG_TAG, 'setFormNextRefreshTime 失败 formId=%{public}s', formId);
      });
    } catch (err) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'setFormNextRefreshTime 同步抛异常 formId=%{public}s', formId);
    }
  }

  /**
   * 把模型封成 FormBindingData。
   *
   * 用 Record 字面量而不是自定义类实例：官方文档与示例一律用 Record，
   * 键会被逐个注入卡片的 LocalStorage。传类实例能不能被逐字段拆开没有文档保证，
   * 不拿「装机发现卡片空白」去赌。
   *
   * 键名只能有字母数字下划线 —— @LocalStorageProp 的键带点号会被编译器拒绝。
   * payload / dimension 都满足。
   */
  private static bindingOf(model: WidgetModel): formBindingData.FormBindingData {
    const payload: Record<string, Object> = {
      'payload': WidgetCodec.encode(model),
      'dimension': model.dimension
    };
    return formBindingData.createFormBindingData(payload);
  }

  /**
   * 从 want 里取卡片规格。
   *
   * 平台在 onAddForm 传的是数字枚举（formInfo.FormParam.DIMENSION_KEY），
   * 而 form_config.json 与卡片自身用的是带星号的字符串。两种都认，
   * 认不出就落到调用方给的默认档 —— 宁可按 2*4 排（容量偏大，最多多显示一节），
   * 也不要按 1*1 排（少显示两节，用户以为后面没有课了）。
   */
  private static dimensionOf(want: Want, fallback: string): string {
    const parameters: Record<string, Object> | undefined = want.parameters;
    if (parameters === undefined) {
      return fallback;
    }
    const raw: Object | undefined = parameters[formInfo.FormParam.DIMENSION_KEY];
    if (raw === undefined) {
      return fallback;
    }
    // want 参数只允许基本类型，所以这里只能是 number 或 string。
    if (typeof raw === 'number') {
      return WidgetModelFactory.dimensionFromNumber(raw);
    }
    if (typeof raw === 'string') {
      return WidgetModelFactory.normalizeDimension(raw);
    }
    return fallback;
  }

  private static dimensionOfCache(formId: string): string {
    const known: string | undefined = dimensions.get(formId);
    return known === undefined ? WidgetDimension.COMPACT : known;
  }

  /** onAddForm 的 want 里带着 formId，记下来好让紧接着的 push 用上。 */
  private static formIdOf(want: Want, fallback: string): string {
    const parameters: Record<string, Object> | undefined = want.parameters;
    if (parameters === undefined) {
      return fallback;
    }
    const raw: Object | undefined = parameters[formInfo.FormParam.IDENTITY_KEY];
    return typeof raw === 'string' ? raw : fallback;
  }
}
