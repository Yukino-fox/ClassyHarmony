/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 朗读队列。
 *
 * 这是桌面版 EdgeTtsService / GptSoVitsService 里那套
 * EnqueueSpeechQueue / ClearSpeechQueue / ProcessPlayerList 的抽出。抽出来
 * 的理由是它一半是「决定」一半是「等待」：
 *
 *   - 决定：队首这一项该跳过、该等、还是该播；作废的项要不要丢；
 *   - 等待：等云端合成完、等音频放完。
 *
 * 等待必须留在 entry（core 里不能有定时器与 I/O），但如果把「决定」也一起
 * 留在那里，它就变成了一个嵌在 async 循环里的 if 链，只能靠真机点一遍才知道
 * 对不对。分出来之后，「取消后不发声」「失败的项不阻塞后续项」这类断言可以在
 * Node 里逐条钉住。
 *
 * 队列语义（与桌面版逐条对齐）
 * --------------------------
 *   - 先进先出，不按优先级、不去重。同一句话入队两次就念两遍 —— 桌面版也是
 *     这样，而且这是对的：两节课都打了同一个铃，两声都该响。
 *   - 单消费者。`advance()` 由 entry 的 pump 循环串行调用，循环体自己保证
 *     重入（见 entry 侧 SpeechService 的 playing 标记）。
 *   - **不重排**。队首还在合成时，后面已经缓存好的项不会插队。桌面版的
 *     ProcessPlayerList 会 `await` 队首的下载任务，就是这个行为。插队会让
 *     朗读顺序与课表顺序错开，听起来像是念错了课。
 *   - 作废的项（超时、被 clear、生成失败）从队首静默丢弃，不影响后面的项。
 */

import { md5HexOfText } from 'common_shared';

/**
 * 单次合成的最长等待。
 *
 * 与桌面版一致（EdgeTtsService 里对下载任务用 15 秒超时）。超过之后这一项
 * 按失败处理并丢弃：一个过期的提醒晚 15 秒念出来，比不念更糟 —— 那时候课
 * 已经开始上了。
 */
export const SPEECH_GENERATION_TIMEOUT_MS: number = 15000;

/** 队列项的状态。 */
export enum SpeechItemState {
  /** 已入队，尚未开始合成。 */
  Waiting = 0,
  /** 正在合成。 */
  Generating = 1,
  /** 可播（已在缓存里或刚合成完）。 */
  Ready = 2,
  /** 合成失败或超时。 */
  Failed = 3
}

/** 队列项。 */
export interface SpeechItem {
  id: number;
  /** 要念的文本。 */
  text: string;
  /** 音频缓存文件路径。 */
  cachePath: string;
  state: SpeechItemState;
  /** 是否已被作废。作废的项一律不发声。 */
  cancelled: boolean;
}

/** 消费端的下一步。 */
export enum SpeechStepKind {
  /** 队列已空，可以结束本轮。 */
  Idle = 0,
  /** 队首可播。播完调 complete(id)。 */
  Play = 1,
  /** 队首还在合成。等完后 markState(id, Ready | Failed) 再 advance()。 */
  Wait = 2
}

/** advance() 的结论。 */
export interface SpeechStep {
  kind: SpeechStepKind;
  /** Play / Wait 时给出队首项。 */
  item: SpeechItem | undefined;
}

/**
 * 朗读队列。
 *
 * 只装状态，不做 I/O。所有方法都是同步的 —— 唯一的异步边界是调用方在收到
 * `Wait` 之后自己去做别的事，回来再 `advance()`。
 */
export class SpeechQueue {
  /** 先进先出。用数组 + shift，量级是「一条通知几个字」，不必上索引。 */
  private items: SpeechItem[] = [];
  private nextId: number = 1;
  /** 正在播的那一项的 id；0 表示没有。 */
  private currentId: number = 0;

  /**
   * 入队。
   *
   * @param cached 音频是否已经在缓存里。在的话直接是 Ready，省的调用方先跑
   *        一次「要不要合成」的判断 —— 那个判断本身就是这个状态的意义。
   * @returns 新项的 id。生成是异步的，调用方要拿这个 id 回来标记结果。
   */
  enqueue(text: string, cachePath: string, cached: boolean): SpeechItem {
    const item: SpeechItem = {
      id: this.nextId++,
      text: text,
      cachePath: cachePath,
      state: cached ? SpeechItemState.Ready : SpeechItemState.Waiting,
      cancelled: false
    };
    this.items.push(item);
    return item;
  }

  /** 队列里还没播完的项数（含正在播的那一项）。 */
  size(): number {
    return this.items.length;
  }

  isEmpty(): boolean {
    return this.items.length === 0;
  }

  /** 队列快照。给测试与调试用，返回的是副本，改它不影响队列。 */
  snapshot(): SpeechItem[] {
    const out: SpeechItem[] = [];
    for (let i: number = 0; i < this.items.length; i++) {
      const each: SpeechItem = this.items[i];
      out.push({
        id: each.id,
        text: each.text,
        cachePath: each.cachePath,
        state: each.state,
        cancelled: each.cancelled
      });
    }
    return out;
  }

  /** 正在播的那一项。 */
  current(): SpeechItem | undefined {
    return this.findById(this.currentId);
  }

  findById(id: number): SpeechItem | undefined {
    for (let i: number = 0; i < this.items.length; i++) {
      if (this.items[i].id === id) {
        return this.items[i];
      }
    }
    return undefined;
  }

  /**
   * 标记一项的状态。
   *
   * 找不到（已被 clear 丢掉）就什么都不做：合成是异步的，回来的时候这一项
   * 可能已经因为「用户清空了队列」而不在了，那不是错误。
   */
  markState(id: number, state: SpeechItemState): void {
    const item: SpeechItem | undefined = this.findById(id);
    if (item === undefined) {
      return;
    }
    item.state = state;
  }

  /**
   * 播完一项，把它从队列里摘掉。
   *
   * 桌面版是在出队时（播放前）就摘掉的，这里改成播完再摘。差别体现在
   * clear() 上：桌面版清空时正在播的那一项已经不在队列里，所以它单独维护了
   * `_currentPlayInfo` 才取消得掉。这里让它留在队列里，clear() 就只需遍历
   * 一处，少一个必须与队列同步的字段。
   */
  complete(id: number): void {
    this.remove(id);
    if (this.currentId === id) {
      this.currentId = 0;
    }
  }

  /**
   * 作废所有未播完的项（含正在播的那一项）。
   *
   * @returns 所有被作废的 id。调用方拿它去中止还在跑的合成任务 ——
   *        这里只改状态，不负责取消 I/O（core 不碰 I/O）。
   */
  cancelAll(): number[] {
    const ids: number[] = [];
    for (let i: number = 0; i < this.items.length; i++) {
      const item: SpeechItem = this.items[i];
      ids.push(item.id);
      if (!item.cancelled) {
        item.cancelled = true;
        item.state = SpeechItemState.Failed;
      }
    }
    return ids;
  }

  /**
   * 推进队列，报告下一步。
   *
   * 会**就地丢弃**队首那些作废或失败的项 —— 这是有意为之：它们唯一的作用
   * 就是阻塞后面的项，而队列没有历史查询需求。丢弃集中在这一处，别的地方
   * 不需要知道「跳过的项还在不在」。
   *
   * 剩下两种情形都不消费队首：Play 时调用方要播完才 complete，Wait 时调用方
   * 要等合成完再回来。把消费推迟到明确知道结果之后，是为了让队列里始终留着
   * 「这一项还没了结」，而 clear() 能靠这一点覆盖到它。
   */
  advance(): SpeechStep {
    while (this.items.length > 0) {
      const head: SpeechItem = this.items[0];
      if (head.cancelled || head.state === SpeechItemState.Failed) {
        this.items.shift();
        continue;
      }
      break;
    }

    if (this.items.length === 0) {
      this.currentId = 0;
      return { kind: SpeechStepKind.Idle, item: undefined };
    }

    const head: SpeechItem = this.items[0];
    if (head.state === SpeechItemState.Ready) {
      this.currentId = head.id;
      return { kind: SpeechStepKind.Play, item: head };
    }
    return { kind: SpeechStepKind.Wait, item: head };
  }

  private remove(id: number): void {
    for (let i: number = 0; i < this.items.length; i++) {
      if (this.items[i].id === id) {
        this.items.splice(i, 1);
        return;
      }
    }
  }
}

/**
 * 拼缓存文件路径。
 *
 * 目录布局与桌面版一致：`{缓存根}/{提供方目录}/{音色}/{md5}`（EdgeTTS 无
 * 后缀，GPT-SoVITS 是 .wav）。保持一致是为了「同一条文本在两端算出同一个
 * 文件名」—— 将来看缓存目录整体同步过去时能直接命中。
 *
 * @param cacheRoot entry 侧的 cacheDir。
 * @param provider 提供方信息，给出目录名与后缀。
 * @param voice 音色名。会做一次路径分隔符清洗，见下。
 */
export function speechCachePath(cacheRoot: string, provider: SpeechProviderCacheLayout,
  voice: string, text: string): string {
  return `${trimSlash(cacheRoot)}/${provider.cacheFolder}/${sanitizeSegment(voice)}/${md5HexOfText(text)}${provider.cacheExtension}`;
}

/** speechCachePath 只需要提供方的这两个字段（便于测试时手造）。 */
export interface SpeechProviderCacheLayout {
  cacheFolder: string;
  cacheExtension: string;
}

/**
 * 清洗路径中的一段。
 *
 * 桌面版直接把音色名交给 Path.Combine，音色名里带 `..` 或分隔符就会写到缓存
 * 目录外面去。音色名来自设置（GPT-SoVITS 那边是用户自建的目录名），值得挡
 * 一下。这里把分隔符与冒号换成下划线，并把整段是 `..` 的情形换掉 —— 不清洗
 * 的话，`../../../filesDir` 这种值能在沙箱里造出文件。
 *
 * 清洗只影响非法值。正常音色（`zh-CN-XiaoxiaoNeural`、`your_voice_name`）
 * 原样通过，所以与桌面版的路径仍然一致。
 */
export function sanitizeSegment(value: string): string {
  let out: string = '';
  for (let i: number = 0; i < value.length; i++) {
    const ch: string = value.charAt(i);
    // NUL 用码值判，不用 '\0' 字面量：ArkTS 对八进制式转义的字面量收得更紧，
    // 而这里要表达的只是「一个不能进文件名的字节」。
    if (ch === '/' || ch === '\\' || ch === ':' || value.charCodeAt(i) === 0) {
      out += '_';
    } else {
      out += ch;
    }
  }
  const trimmed: string = out.trim();
  if (trimmed.length === 0 || trimmed === '.' || trimmed === '..') {
    return '_';
  }
  return trimmed;
}

function trimSlash(value: string): string {
  let end: number = value.length;
  while (end > 0 && value.charAt(end - 1) === '/') {
    end--;
  }
  return value.substring(0, end);
}
