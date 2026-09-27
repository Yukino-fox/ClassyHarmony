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

const DOMAIN: number = 0x0000;
const TAG: string = 'NotificationService';

/** 通知分类，决定渠道、优先级、图标、震动等 */
export enum NotificationCategory {
  /** 课前提醒：高优先级、响铃、震动、锁屏显示 */
  ClassReminder = 'class_reminder',
  /** 自动化行动「显示通知」：默认优先级、可配置 */
  Automation = 'automation',
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
      // 申请通知权限（用户可能已授权，会直接返回）
      await notificationManager.requestEnableNotification(this.context, (err) => {
        if (err) {
          hilog.warn(DOMAIN, TAG, 'requestEnableNotification failed: %{public}s', JSON.stringify(err));
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
    return id;
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