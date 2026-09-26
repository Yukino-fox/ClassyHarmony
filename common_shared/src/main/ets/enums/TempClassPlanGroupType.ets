/*
 * 临时课表组类型。值必须与桌面版一致——该枚举以整数写入 JSON。
 */
export enum TempClassPlanGroupType {
  /** 覆盖：完全替换所选课表组的课表。 */
  Override = 0,
  /** 继承：仅补充所选课表组中不存在的课表。 */
  Inherit = 1
}
