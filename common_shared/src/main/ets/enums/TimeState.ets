/*
 * 时刻表状态机状态。值必须与桌面版一致——该枚举以整数写入 JSON。
 */
export enum TimeState {
  /** 无课程。 */
  None = 0,
  /** 上课中。 */
  OnClass = 1,
  /** 上课准备中（临近上课）。 */
  PrepareOnClass = 2,
  /** 课间休息中。 */
  Breaking = 3,
  /** 已放学。 */
  AfterSchool = 4
}
