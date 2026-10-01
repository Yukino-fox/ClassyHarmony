/**
 * 通知服务封装（entry 侧）。
 *
 * 职责：
 *  1. 申请通知权限（requestEnableNotification）
 *  2. 发布本地通知（publish）——给自动化行动用
 *  3. 按分类选通知渠道类型（SlotType）
 *  4. 取消通知
 *
 * 为什么不直接在各处调用 notificationManager
 * ----------------------------------------
 *  - 权限申请、渠道注册是一次性初始化，集中管理避免重复；
 *  - 通知 ID 分配、分类到渠道的映射需要统一策略；
 *  - 朗读挂载点唯一（见 maybeSpeak），散出去会变成「同一句话念两遍」。
 *
 * 渠道为什么只能选类型
 * ------------------
 * API 10 起应用不能再自定义渠道的响铃/震动/锁屏可见性（那是系统权限
 * ohos.permission.NOTIFICATION_CONTROLLER），`addSlot()` 也只收一个
 * SlotType。所以这里做的是「按语义挑一个最接近的类型」，具体声响表现交给
 * 用户的通知设置，应用不越权。
 */
import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { resolveSpeechService } from '../speech/SpeechService';

const DOMAIN: number = 0x0000;
const TAG: string = 'NotificationService';

/** 通知分类，决定渠道类型。 */
export enum NotificationCategory {
  /** 课前提醒：响铃、震动、锁屏显示。 */
  ClassReminder = 'class_reminder',
  /** 自动化行动「显示通知」。 */
  Automation = 'automation',
  /**
   * 天气提醒：自动化行动「显示天气提醒」发的预报 / 预警。
   *
   * 与 Automation 分开是因为来源不同，用户想静音天气提醒时不该连带把自动化
   * 的提醒也静音掉。桌面版天气是独立的一个 NotificationProvider，这里对应
   * 一个独立渠道。
   */
  Weather = 'weather',
  /** 系统级：App 更新、同步完成等。 */
  System = 'system'
}

/** 发布通知的参数。 */
export interface NotificationOptions {
  /** 标题。 */
  title: string;
  /** 正文。 */
  content: string;
  /** 附加说明（副文本），可省。 */
  subText?: string;
  /** 持续性通知：不可划掉。默认 false。 */
  ongoing?: boolean;
  /** 着色（ARGB）。不填则由系统着色。 */
  color?: number;
  /**
   * 要朗读的文本。不填则用 content。
   *
   * 单独留一个字段而不是直接念 content：桌面版的提醒内容有「大字遮罩」与
   * 「正文」两部分，各自决定要不要朗读，而念的是遮罩那一句短话。
   */
  speechText?: string;
  /**
   * 这一条内容自己是否允许朗读。默认 true。
   *
   * 对应桌面版 NotificationContent.IsSpeechEnabled —— 默认就是 true，也就是说
   * 「能不能念」由全局那一层（AllowNotificationSpeech，默认关）决定。
   */
  speechEnabled?: boolean;
}

/**
 * 分类 → 渠道类型。
 *
 * 取值是「语义最接近」而不是「完全对应」：应用改不了渠道的声光表现，只能挑
 * 一个系统预设类型。SOCIAL_COMMUNICATION 会响铃震动（提醒用），
 * SERVICE_INFORMATION / CONTENT_INFORMATION 是普通信息（自动化 / 天气），
 * OTHER_TYPES 是最低干扰（系统）。
 */
function slotTypeFor(category: NotificationCategory): notificationManager.SlotType {
  switch (category) {
    case NotificationCategory.ClassReminder:
      return notificationManager.SlotType.SOCIAL_COMMUNICATION;
    case NotificationCategory.Automation:
      return notificationManager.SlotType.SERVICE_INFORMATION;
    case NotificationCategory.Weather:
      return notificationManager.SlotType.CONTENT_INFORMATION;
    default:
      return notificationManager.SlotType.OTHER_TYPES;
  }
}

export class NotificationService {
  private readonly context: common.UIAbilityContext;
  private initialized: boolean = false;
  private notificationIdCounter: number = 1000; // 避开系统保留 ID
  /** 已注册过的渠道类型，避免重复 addSlot。 */
  private readonly createdSlots: Set<number> = new Set<number>();
  /** 点击通知回到本 Ability 用的 WantAgent；内容固定，建一次即可。 */
  private agent: WantAgent | undefined = undefined;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** 初始化：申请权限（幂等）。 */
  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }
    // 先置位再干活：本方法是 async 的，两个并发调用会在第一个 await 之前各跑
    // 一遍守卫。置位放前面，第二次调用直接返回。
    this.initialized = true;
    // 刻意**不** await，也不参与 initialized 的判定。
    //
    // requestEnableNotification 返回 void（回调式）。就算它返回 Promise，等它
    // 也等于等用户点完权限弹窗，那所有 await initialize() 的调用方都要卡到用户
    // 做决定为止。用户犹豫十秒，整条通知链路就停十秒。
    //
    // 语义定成「发起申请，链路继续可用」：权限没批下来时 publish 会失败，而失败
    // 只影响那一条通知；下一轮 tick 会再试。权限批下来的瞬间通知就能正常发出。
    notificationManager.requestEnableNotification(this.context, (err: BusinessError) => {
      if (err) {
        // 拒绝授权也走这里，不算错误：用户的选择，不是异常。
        hilog.warn(DOMAIN, TAG,
          'notification permission not granted: %{public}s', JSON.stringify(err));
      }
    });
    hilog.info(DOMAIN, TAG, 'NotificationService initialized');
  }

  /** 生成唯一通知 ID。 */
  private nextId(): number {
    return this.notificationIdCounter++;
  }

  /** 确保渠道已注册。注册失败不抛：publish 时系统也会按 notificationSlotType 兜底。 */
  private async ensureSlot(slotType: notificationManager.SlotType): Promise<void> {
    const key: number = slotType;
    if (this.createdSlots.has(key)) {
      return;
    }
    this.createdSlots.add(key);
    try {
      await notificationManager.addSlot(slotType);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'addSlot(%{public}d) failed: %{public}d',
        key, be.code);
    }
  }

  /** 点击通知回到本 Ability 的 WantAgent（懒建）。 */
  private async ensureWantAgent(): Promise<WantAgent> {
    if (this.agent !== undefined) {
      return this.agent;
    }
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    this.agent = await wantAgent.getWantAgent(info);
    return this.agent;
  }

  /** 发布通知（核心方法），返回通知 ID。 */
  async publish(category: NotificationCategory, options: NotificationOptions): Promise<number> {
    if (!this.initialized) {
      await this.initialize();
    }
    const id: number = this.nextId();
    const slotType: notificationManager.SlotType = slotTypeFor(category);
    await this.ensureSlot(slotType);

    const normal: notificationManager.NotificationBasicContent = {
      title: options.title,
      text: options.content,
      additionalText: options.subText ?? ''
    };
    const content: notificationManager.NotificationContent = {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: normal
    };
    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: slotType,
      content: content,
      deliveryTime: Date.now(),
      wantAgent: await this.ensureWantAgent()
    };
    if (options.ongoing === true) {
      request.isOngoing = true;
    }
    if (options.color !== undefined) {
      request.color = options.color;
      request.colorEnabled = true;
    }

    await notificationManager.publish(request);
    hilog.info(DOMAIN, TAG, 'Published notification id=%{public}d cat=%{public}s',
      id, category);

    // 朗读放在 publish 成功之后：通知没发出去还在那里念，用户会以为听错了。
    //
    // 「展示通知」是全应用唯一一处「一条提醒被呈现给用户」的地方（另一处是
    // 平台侧的课前提醒，那条由系统投递、应用不在场，念不了）。所以朗读挂在这里，
    // 与桌面版把它挂在 NotificationWorkerService 上是同一个位置。
    this.maybeSpeak(options);
    return id;
  }

  /**
   * 按开关决定要不要念、以及念哪一句。
   *
   * 吞掉异常：抛出去会让整条通知发不出去 —— 语音是增强能力，它坏了不该把提醒
   * 也弄没。
   */
  private maybeSpeak(options: NotificationOptions): void {
    let text: string = options.speechText ?? '';
    if (text.length === 0) {
      text = options.content;
    }
    if (text.length === 0) {
      return;
    }
    const enabled: boolean = options.speechEnabled ?? true;
    try {
      resolveSpeechService(this.context).notifyShown(enabled, text);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'speech enqueue failed: %{public}s', `${err}`);
    }
  }

  /** 取消单条通知。 */
  async cancel(id: number): Promise<void> {
    try {
      await notificationManager.cancel(id);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cancel(%{public}d) failed: %{public}d', id, be.code);
    }
  }

  /**
   * 取消某分类下所有通知。
   *
   * NotificationKit 不支持按渠道取消，只能全清。这里保留方法名是为了让调用点
   * 表达意图；真要精细控制得自己记录已发 ID。
   */
  async cancelCategory(category: NotificationCategory): Promise<void> {
    try {
      await notificationManager.cancelAll();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cancelAll failed for %{public}s: %{public}d',
        category, be.code);
    }
  }

  /** 通知权限是否已开。 */
  hasPermission(): boolean {
    try {
      return notificationManager.isNotificationEnabledSync();
    } catch (err) {
      return false;
    }
  }
}
