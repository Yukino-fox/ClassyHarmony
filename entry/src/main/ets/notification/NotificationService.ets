/**
 * 通知/推送服务封装（entry 侧）。
 *
 * 职责：
 *  1. 申请通知权限（requestEnableNotification）
 *  2. 发布本地通知（publishNotification）——给课前提醒、自动化行动用
 *  3. 管理通知渠道（NotificationSlot）——分类：提醒、自动化、系统
 *  4. 取消/更新通知
 *  5. 推送通道（Push Kit）——后续 P11+ 接入
 *
 * 为什么不直接在各处调用 notificationManager：
 *  - 权限申请、渠道创建是一次性初始化，集中管理避免重复
 *  - 通知 ID 分配、分组、优先级映射需要统一策略
 *  - 方便后续接入 Push Kit 时只改这里
 */
import { notificationManager, NotificationRequest, NotificationSlot, NotificationSlotType, NotificationConstant } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { resolveSpeechService } from '../speech/SpeechService';

const DOMAIN: number = 0x0000;
const TAG: string = 'NotificationService';

/** 通知分类，决定渠道、优先级、图标、震动等 */
export enum NotificationCategory {
  /** 课前提醒：高优先级、响铃、震动、锁屏显示 */
  ClassReminder = 'class_reminder',
  /** 自动化行动「显示通知」：默认优先级、可配置 */
  Automation = 'automation',
  /**
   * 天气提醒：自动化行动「显示天气提醒」发的预报 / 预警。
   *
   * 与 Automation 分开是因为来源不同，用户想静音天气提醒时不该连带把自动化
   * 的提醒也静音掉。桌面版天气是独立的一个 NotificationProvider，这里对应
   * 一个独立渠道。
   */
  Weather = 'weather',
  /** 系统级：App 更新、同步完成等，低优先级 */
  System = 'system'
}

/** 通知渠道配置 */
interface SlotConfig {
  type: NotificationSlotType;
  level: NotificationConstant.NotificationLevel;
  sound: string;
  vibrationEnabled: boolean;
  lightEnabled: boolean;
  lockscreenVisibility: NotificationConstant.LockscreenVisibility;
  badgeFlag: boolean;
  bypassDnd: boolean;
}

/** 预定义渠道配置（与桌面版 NotificationChannel 对齐） */
const SLOT_CONFIGS: Record<NotificationCategory, SlotConfig> = {
  [NotificationCategory.ClassReminder]: {
    type: NotificationSlotType.SOCIAL,
    level: NotificationConstant.NotificationLevel.HIGH,
    sound: '',
    vibrationEnabled: true,
    lightEnabled: true,
    lockscreenVisibility: NotificationConstant.LockscreenVisibility.PUBLIC,
    badgeFlag: true,
    bypassDnd: true
  },
  [NotificationCategory.Automation]: {
    type: NotificationSlotType.RECOMMENDATION,
    level: NotificationConstant.NotificationLevel.DEFAULT,
    sound: '',
    vibrationEnabled: true,
    lightEnabled: false,
    lockscreenVisibility: NotificationConstant.LockscreenVisibility.PUBLIC,
    badgeFlag: true,
    bypassDnd: false
  },
  [NotificationCategory.Weather]: {
    type: NotificationSlotType.RECOMMENDATION,
    level: NotificationConstant.NotificationLevel.DEFAULT,
    sound: '',
    vibrationEnabled: false,
    lightEnabled: false,
    lockscreenVisibility: NotificationConstant.LockscreenVisibility.PUBLIC,
    badgeFlag: false,
    bypassDnd: false
  },
  [NotificationCategory.System]: {
    type: NotificationSlotType.SERVICE,
    level: NotificationConstant.NotificationLevel.LOW,
    sound: '',
    vibrationEnabled: false,
    lightEnabled: false,
    lockscreenVisibility: NotificationConstant.LockscreenVisibility.SECRET,
    badgeFlag: false,
    bypassDnd: false
  }
};

export class NotificationService {
  private readonly context: common.UIAbilityContext;
  private initialized: boolean = false;
  private notificationIdCounter: number = 1000; // 避免与系统保留 ID 冲突

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** 初始化：创建渠道、申请权限（幂等） */
  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }
    try {
      // 创建所有渠道
      for (const [cat, cfg] of Object.entries(SLOT_CONFIGS)) {
        const slot: NotificationSlot = {
          slotType: cfg.type,
          level: cfg.level,
          sound: cfg.sound,
          vibrationEnabled: cfg.vibrationEnabled,
          lightEnabled: cfg.lightEnabled,
          lockscreenVisibility: cfg.lockscreenVisibility,
          badgeFlag: cfg.badgeFlag,
          bypassDnd: cfg.bypassDnd,
          description: `ClassIsland ${cat} 通知`
        };
        await notificationManager.addNotificationSlot(this.context, slot);
      }
      // 申请通知权限。刻意**不** await，也不参与 initialized 的判定。
      //
      // requestEnableNotification 是回调式的，返回 void —— await 它是空转。
      // 更要紧的是：就算它返回 Promise，等它也等于等用户点完权限弹窗，
      // 那 initialize() 的 Promise 就要挂到用户做决定为止，initialized 一直是
      // false，所有 await initialize() 的调用方全部卡住。用户在弹窗上犹豫十秒，
      // 整个通知链路就停十秒。
      //
      // 所以语义定成「发起申请，链路继续可用」：权限没批下来时 publish 会失败，
      // 而失败只影响那一条通知；下一轮 tick 会再试。渠道（slot）已经建好了，
      // 权限批下来的瞬间通知就能正常发出，不需要重建任何东西。
      notificationManager.requestEnableNotification(this.context, (err) => {
        if (err) {
          // 拒绝授权也走这里，不算错误：用户的选择，不是异常
          hilog.warn(DOMAIN, TAG,
            'notification permission not granted: %{public}s', JSON.stringify(err));
        }
      });
      this.initialized = true;
      hilog.info(DOMAIN, TAG, 'NotificationService initialized');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'initialize failed: %{public}s', `${err}`);
      throw err;
    }
  }

  /** 生成唯一通知 ID */
  private nextId(): number {
    return this.notificationIdCounter++;
  }

  /** 发布通知（核心方法） */
  async publish(category: NotificationCategory, options: {
    title: string;
    content: string;
    subText?: string;
    actionText?: string;          // 点击打开的页面路由
    actionParams?: Record<string, Object>;
    wantAgent?: any;              // 自定义 WantAgent
    smallIcon?: number;           // 资源 ID
    largeIcon?: number;
    progress?: number;            // 进度条（0-100）
    count?: number;               // 叠加计数
    ongoing?: boolean;            // 持续性通知（不可划掉）
    color?: number;               // ARGB
    deliveryTime?: number;        // 定时投递（毫秒时间戳）
    /**
     * 要朗读的文本。不填则用 content。
     *
     * 单独留一个字段而不是直接念 content：桌面版的提醒内容里有「大字遮罩」
     * 和「正文」两部分，各自决定要不要朗读（IsMaskSpeechEnabled /
     * IsContentSpeechEnabled），而念的是遮罩那一句短话。详情见 execShowNotification。
     */
    speechText?: string;
    /**
     * 这一条内容自己是否允许朗读。默认 true。
     *
     * 对应桌面版 NotificationContent.IsSpeechEnabled —— 默认就是 true，
     * 也就是说「能不能念」由全局那一层（AllowNotificationSpeech，默认关）
     * 决定，而不是由内容这一层。
     */
    speechEnabled?: boolean;
  }): Promise<number> {
    if (!this.initialized) {
      await this.initialize();
    }
    const id: number = this.nextId();
    const slotName: string = category;
    const slotType: NotificationSlotType = SLOT_CONFIGS[category].type;

    const request: NotificationRequest = {
      id,
      slotName,
      slotType,
      content: {
        contentType: NotificationConstant.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: options.title,
          text: options.content,
          additionalText: options.subText ?? ''
        }
      },
      deliveryTime: options.deliveryTime ?? Date.now(),
      color: options.color,
      progress: options.progress,
      count: options.count ?? 1,
      ongoing: options.ongoing ?? false,
      removalAllowed: !options.ongoing
    };

    // 点击跳转
    if (options.actionText) {
      // 这里需要根据 actionText 构建 Want，简化：传给主页面处理
      // 实际可用 wantAgent
    }

    await notificationManager.publishNotification(request);
    hilog.info(DOMAIN, TAG, 'Published notification id=%{public}d cat=%{public}s', id, category);

    // 朗读。放在 publish 成功之后：通知没发出去还在那里念，用户会以为听错了。
    //
    // 「展示通知」这里是全应用唯一一处「一条提醒被呈现给用户」的地方（另一处
    // 是平台侧的课前提醒，那条由系统投递、应用不在场，念不了）。所以朗读挂在
    // 这里，与桌面版把它挂在 NotificationWorkerService 上是同一个位置。
    this.maybeSpeak(options);
    return id;
  }

  /**
   * 按开关决定要不要念，以及念哪一句。
   *
   * 抛出去会让整条通知发不出去 —— 语音是增强能力，它坏了不该把提醒也弄没。
   */
  private maybeSpeak(options: {
    content: string;
    speechText?: string;
    speechEnabled?: boolean;
  }): void {
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

  /** 取消单条通知 */
  async cancel(id: number): Promise<void> {
    await notificationManager.cancelNotificationById(id);
  }

  /** 取消某分类下所有通知 */
  async cancelCategory(category: NotificationCategory): Promise<void> {
    await notificationManager.cancelAllNotifications();
    // 这里只能全取消，NotificationKit 暂不支持按 slot 取消
    // 如需精细控制需记录已发 ID
  }

  /** 更新通知（同 ID 重新 publish） */
  async update(id: number, options: Parameters<NotificationService['publish']>[1]): Promise<void> {
    // NotificationKit 的 publish 同 ID 即为更新
    await this.publish(NotificationCategory.System, { ...options, title: options.title, content: options.content });
  }

  /** 检查通知权限 */
  async hasPermission(): Promise<boolean> {
    // 简化：尝试发一个测试通知
    try {
      const testId = this.nextId();
      await notificationManager.publishNotification({
        id: testId,
        slotName: NotificationCategory.System,
        slotType: NotificationSlotType.SERVICE,
        content: { contentType: NotificationConstant.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT, normal: { title: 't', text: 't' } },
        deliveryTime: Date.now()
      });
      await this.cancel(testId);
      return true;
    } catch {
      return false;
    }
  }
}