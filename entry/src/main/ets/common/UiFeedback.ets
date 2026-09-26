/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 界面的轻量反馈：轻提示与二次确认。
 *
 * 为什么要包一层而不是各处直接调
 * ---------------------------
 * 1. showToast / showAlertDialog 都声明了 @throws。ArkTS 的 linter 会给
 *    「调用可能抛异常的函数而未 try/catch」报 WARN。包一次之后，几十处调用点
 *    都不再各自要写一遍 try/catch，也不会有人漏掉某一处。
 * 2. 提示框出不来（窗口正在切换、页签被系统回收）时，吞掉异常而不是让它冒到
 *    点击回调里。点击回调里抛出未捕获异常，ArkUI 的表现是界面上「点了没反应」
 *    加上日志里一条看不懂的栈，而这里丢掉的东西只是一个提示框。
 * 3. 确认框的按钮措辞在这里统一。破坏性操作的确认文案必须说清会波及什么，
 *    这个约定写在一处比散落在几十个点击回调里靠得住。
 *
 * 配色上「确认」与「取消」都取强调色而不分正反：这两栏是「这次操作的两个出口」，
 * 不是「对错」。真正区分正反的是按钮文案（动词 vs 取消），色觉障碍用户看的是
 * 文案。破坏性按钮本身已经在正文里用红色系文案标注过了（见 EditorDeleteButton），
 * 这里再给一层颜色区分只会让人以为颜色有额外含义。
 */

import { UIContext } from '@kit.ArkUI';

export class UiFeedback {
  /**
   * 轻提示。
   *
   * @param context 组件的 UIContext
   * @param message 文案
   */
  static toast(context: UIContext, message: string): void {
    if (message.length === 0) {
      return;
    }
    try {
      context.getPromptAction().showToast({ message: message });
    } catch (err) {
      return;
    }
  }

  /**
   * 二次确认。
   *
   * @param context 组件的 UIContext
   * @param title 标题
   * @param message 正文。破坏性操作要写清会波及什么，不要只写「确定删除吗」
   * @param okText 确认按钮文案。破坏性操作用动词（「删除」），不用「确定」
   * @param onOk 确认后要做的事
   */
  static confirm(context: UIContext, title: string, message: string, okText: string,
    onOk: () => void): void {
    try {
      context.showAlertDialog({
        title: title,
        message: message,
        buttons: [
          { value: '取消', action: () => {} },
          {
            value: okText,
            fontColor: $r('app.color.ch_accent'),
            action: () => {
              onOk();
            }
          }
        ]
      });
    } catch (err) {
      return;
    }
  }

  /**
   * 三选一确认，用于「有未保存改动时按返回」这类需要给「直接放弃」一个出口的场景。
   *
   * 三个按钮不是凑数：只给「保存」和「取消」的话，用户想放弃改动就找不到路，
   * 只能被弹窗逼着保存或者退回上一个页面再想办法。
   *
   * @param context 组件的 UIContext
   * @param title 标题
   * @param message 正文
   * @param discardText 放弃按钮的文案，必须说清会丢什么
   * @param onDiscard 放弃
   * @param onSave 保存
   */
  static confirmDiscardOrSave(context: UIContext, title: string, message: string,
    discardText: string, onDiscard: () => void, onSave: () => void): void {
    try {
      context.showAlertDialog({
        title: title,
        message: message,
        buttons: [
          {
            value: discardText,
            fontColor: $r('app.color.ch_accent'),
            action: () => {
              onDiscard();
            }
          },
          { value: '取消', action: () => {} },
          {
            value: '保存',
            fontColor: $r('app.color.ch_accent'),
            action: () => {
              onSave();
            }
          }
        ]
      });
    } catch (err) {
      return;
    }
  }
}
