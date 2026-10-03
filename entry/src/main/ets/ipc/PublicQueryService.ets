/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 公开查询入口（entry 侧，Want 显式匹配）。
 *
 * 桌面版里，外部进程经命名管道问 ClassIsland「现在上什么课」，服务端在
 * `ClassIsland/` 里实现 `IPublicLessonsService`。鸿蒙上进程间通信换成 Want：
 * 外部应用用 `startAbilityForResult` 显式匹配本应用（action 见
 * `PublicWantActions`），本应用在 `onNewWant` 里收到后立即
 * `terminateSelfWithResult` 把结果 Want 送回去。
 *
 * 为什么不常驻一个服务等别人连
 * --------------------------
 * 鸿蒙没有「后台常驻的 IPC 服务端」这种形态。`UIAbility` 被 Want 拉起时本来
 * 就会走 onCreate / onNewWant，用它做「一次询问一次回答」正合适；而
 * distributedDataObject 那条路是反向的（我们去推），也不需要对方来连。
 *
 * 为什么从磁盘现算而不是读内存
 * --------------------------
 * 查询可能发生在冷启动（`onCreate` 带 Want）—— 那时 ViewModel 还没装配。
 * 而且公开状态的权威来源本来就是 profile.json（见 ProfileRepository 顶上写
 * 的可重入约束），现读现算反而更简单、更不容易拿到过期快照。代价是每次查询
 * 解析一遍档案，而查询是低频的外部动作，可以接受。
 */

import { Want } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LessonsEngine, PublicProfileBrief, PublicStateCodec, PublicStateSource, PublicWantActions, PublicWantKeys, buildPublicLessonState, buildPublicProfileBrief, t } from 'common_core';
import { LessonsSnapshot } from 'common_core';
import { DateTimeValue, Profile } from 'common_shared';
import { ProfileRepository } from '../data/ProfileRepository';
import { defaultEngineSettings } from '../common/AppSettings';
import { resolveDistributedStateService } from './DistributedStateService';

const DOMAIN: number = 0x0000;
const TAG: string = 'PublicQuery';

/** 这个 Want 是不是一条公开查询。 */
export function isPublicQuery(want: Want): boolean {
  const action: string | undefined = want.action;
  return action === PublicWantActions.QUERY_LESSON_STATE
    || action === PublicWantActions.QUERY_PROFILE_BRIEF;
}

/**
 * 处理一条公开查询，返回要送回给调用方的结果 Want。
 *
 * 不是公开查询时返回 undefined —— 调用方据此决定「不接管这次 Want」。
 * 任何一步失败都不抛：把中文原因放进 `RESULT_MESSAGE`，调用方照样能拿到
 * 一个结构完整的 Want，而不是一个空的失败。
 */
export function buildPublicQueryResult(context: common.UIAbilityContext,
  want: Want): Want | undefined {
  const action: string | undefined = want.action;
  if (action !== PublicWantActions.QUERY_LESSON_STATE
    && action !== PublicWantActions.QUERY_PROFILE_BRIEF) {
    return undefined;
  }

  let profile: Profile | undefined = undefined;
  try {
    const repo: ProfileRepository = new ProfileRepository(context.filesDir);
    if (repo.exists()) {
      profile = repo.load();
      // load() 出来的是「原样解析」的那份，派生状态（每节课绑到哪个时间点等）
      // 是空的，引擎算之前要自己刷一遍 —— 与小组件、面板预览同一个坑。
      profile.refreshDerivedState();
    }
  } catch (error) {
    hilog.warn(DOMAIN, TAG, 'load profile failed: %{public}s', `${error}`);
    profile = undefined;
  }

  if (profile === undefined) {
    return failureResult(t('pq_no_profile'));
  }

  const source: PublicStateSource = new PublicStateSource();
  source.deviceName = resolveDistributedStateService(context).currentDeviceName();
  source.profileName = profile.name;
  const now: DateTimeValue = DateTimeValue.now();

  let json: string = '';
  try {
    if (action === PublicWantActions.QUERY_LESSON_STATE) {
      const settings = defaultEngineSettings(now);
      const snapshot: LessonsSnapshot = LessonsEngine.compute(profile, settings, now);
      json = PublicStateCodec.encodeLessonState(buildPublicLessonState(snapshot, source, now));
    } else {
      const brief: PublicProfileBrief = buildPublicProfileBrief(profile, source, now);
      json = PublicStateCodec.encodeProfileBrief(brief);
    }
  } catch (error) {
    hilog.warn(DOMAIN, TAG, 'build query result failed: %{public}s', `${error}`);
    return failureResult(t('pq_build_failed'));
  }

  return successResult(json);
}

/** 成功：`ok=true` + 紧凑 JSON。 */
function successResult(json: string): Want {
  const parameters: Record<string, Object> = {};
  parameters[PublicWantKeys.RESULT_OK] = true;
  parameters[PublicWantKeys.RESULT_JSON] = json;
  const result: Want = { parameters: parameters };
  return result;
}

/** 失败：`ok=false` + 中文原因（可显示）。 */
function failureResult(message: string): Want {
  const parameters: Record<string, Object> = {};
  parameters[PublicWantKeys.RESULT_OK] = false;
  parameters[PublicWantKeys.RESULT_MESSAGE] = message;
  const result: Want = { parameters: parameters };
  return result;
}
