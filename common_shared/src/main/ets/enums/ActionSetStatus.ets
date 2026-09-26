/*
 * 行动组运行状态。值必须与桌面版一致——该枚举以整数写入 JSON。
 *
 * 桌面版为它注册了 ActionSetStatusJsonConverter，写出前会折叠运行态：
 *   Invoking -> Normal
 *   Reverting -> IsOn
 * 目的是不把「正在执行」这种瞬时态持久化到磁盘。
 * 复刻该折叠逻辑，见 toPersisted()。
 */
export enum ActionSetStatus {
  /** 正常。 */
  Normal = 0,
  /** 正在执行触发。 */
  Invoking = 1,
  /** 已开启（恢复流程中）。 */
  IsOn = 2,
  /** 正在恢复。 */
  Reverting = 3
}

export class ActionSetStatusCodec {
  /** 写出用：折叠瞬时运行态。 */
  static toPersisted(status: number): number {
    if (status === ActionSetStatus.Invoking) {
      return ActionSetStatus.Normal;
    }
    if (status === ActionSetStatus.Reverting) {
      return ActionSetStatus.IsOn;
    }
    return status;
  }

  /** 读入用：与 toPersisted 互逆，折叠掉的态不再还原为运行态。 */
  static fromPersisted(status: number): number {
    return ActionSetStatusCodec.toPersisted(status);
  }

  /**
   * 解析读入值。
   * 桌面版同时接受整数与枚举名字符串，这里一并容忍。
   */
  static parse(raw: number | string): number {
    if (typeof raw === 'string') {
      const text: string = raw;
      if (text === 'Normal') {
        return ActionSetStatus.Normal;
      }
      if (text === 'Invoking') {
        return ActionSetStatus.Normal;
      }
      if (text === 'IsOn') {
        return ActionSetStatus.IsOn;
      }
      if (text === 'Reverting') {
        return ActionSetStatus.IsOn;
      }
      return ActionSetStatus.Normal;
    }
    return ActionSetStatusCodec.toPersisted(Math.trunc(raw));
  }
}
