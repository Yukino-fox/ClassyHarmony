/*
 * common_core 导出入口。
 *
 * 对应 ClassIsland.Core：课表计算、课程状态机、规则与自动化、插件注册表。
 *
 * 与 common_shared 相同的硬约束：
 * 1. 严禁依赖 UI、音频、媒体、后台任务——小组件 Extension 会引用本模块。
 * 2. 必须可重入：每次实例化从磁盘加载 → 一次性计算 → 销毁。
 *    禁止跨实例共享可变单例状态。
 *    本阶段（P2）的引擎全部是「传入档案 + 传入时间」的静态纯函数，
 *    不含任何静态可变字段。
 */

/* ---- 课表引擎 ---- */
export { EngineSettings } from './src/main/ets/engine/EngineSettings';
export { WeekRotation } from './src/main/ets/engine/WeekRotation';
export { ClassPlanResolver, ResolvedClassPlan, ResolvedSource } from './src/main/ets/engine/ClassPlanResolver';
export { TempPlanManager } from './src/main/ets/engine/TempPlanManager';
export { LessonsSnapshot, StateEvent } from './src/main/ets/engine/LessonsSnapshot';
export { LessonsEngine } from './src/main/ets/engine/LessonsEngine';
export { ScheduleCell, ScheduleColumn, ScheduleGrid, ScheduleRow, EMPTY_SUBJECT_TEXT } from './src/main/ets/view/ScheduleGrid';
export { ScheduleGridBuilder } from './src/main/ets/view/ScheduleGridBuilder';
export { LayoutForm, layoutFormOf, SINGLE_COLUMN_MAX_WIDTH, GRID_FILL_MIN_WIDTH } from './src/main/ets/view/LayoutForm';

/* ---- 档案改动 ---- */
export { ScheduleMutations } from './src/main/ets/edit/ScheduleMutations';

/* ---- 时间段求交 ---- */
export {
  TimeRange,
  TimeSpanRow,
  newTimeSpanRow,
  timeRangeConflictIndex,
  timeRangeOverlap,
  timeRangeOverlapMinutes
} from './src/main/ets/edit/TimeRange';

/* ---- 编辑页视图数据 ---- */
export {
  ClassPlanGroupRow,
  ClassPlanRow,
  ClassSlotRow,
  EditorRows,
  OrderedScheduleRow,
  PlanEditRow,
  ProfileRow,
  SubjectRow,
  TimeLayoutRow,
  TimePointRow,
  parseClockText,
  parseDurationText
} from './src/main/ets/edit/EditorRows';

/* ---- 小组件视图数据 ---- */
export {
  WIDGET_REFRESH_MAX_MINUTES,
  WIDGET_REFRESH_MIN_MINUTES,
  WidgetBuilder,
  WidgetCodec,
  WidgetDimension,
  WidgetLesson,
  WidgetModel
} from './src/main/ets/view/WidgetModel';

/* ---- 展示用文本格式化 ---- */
export {
  formatClock,
  formatDuration,
  timeTypeName,
  weekDayName,
  weekDayShortName,
  weekRotationText
} from './src/main/ets/view/TextFormat';

/* ---- 提醒编排（P6）---- */
export {
  ReminderMode,
  ReminderAdvance,
  ReminderPlan,
  ReminderPlanItem,
  ReminderSnapshot,
  ReminderDiff,
  ReminderPlanner
} from './src/main/ets/reminder/ReminderPlan';
