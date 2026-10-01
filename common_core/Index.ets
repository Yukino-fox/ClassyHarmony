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

/* ---- 主界面组件布局 ---- */
export {
  ComponentDescriptor,
  ComponentCatalog,
  COMPONENT_CLOCK,
  COMPONENT_COUNTDOWN,
  COMPONENT_DATE,
  COMPONENT_GROUP,
  COMPONENT_ROLLING,
  COMPONENT_SCHEDULE,
  COMPONENT_SEPARATOR,
  COMPONENT_SLIDE,
  COMPONENT_STACK,
  COMPONENT_TEXT,
  COMPONENT_WEATHER
} from './src/main/ets/components/ComponentCatalog';
export {
  ComponentPayload,
  ContainerPayload,
  ClockPayload,
  CountDownPayload,
  TextPayload,
  WeatherPayload,
  SchedulePayload,
  RollingPayload,
  SlidePayload
} from './src/main/ets/components/ComponentPayloads';
export {
  ComponentLayoutMutations,
  ComponentLocation
} from './src/main/ets/components/ComponentLayoutMutations';

/* ---- 面板渲染模型（P7c）---- */
export {
  PanelNode,
  PanelNodeKind,
  PanelLine,
  PanelLesson,
  PanelModel,
  PanelWidthKind,
  PanelBuilder
} from './src/main/ets/panel/PanelModel';

/* ---- 规则引擎（P8a）---- */
export {
  RuleInfo,
  RuleCatalog,
  RuleSettingsKind,
  RuleSupport
} from './src/main/ets/rules/RuleCatalog';
export {
  RuleContext,
  RuleEngine,
  RuleGroupVerdict,
  RuleReason,
  RuleVerdict,
  RulesetVerdict,
  STATE_NONE,
  STATE_FALSE,
  STATE_TRUE
} from './src/main/ets/rules/RuleEngine';
export { RulesetMutations } from './src/main/ets/rules/RulesetMutations';
export {
  RuleChoiceRow,
  RuleEditRow,
  RuleGroupEditRow,
  RulesetEditModel,
  RulesetEditor
} from './src/main/ets/rules/RulesetEditModel';

/* ---- 自动化链路（P8c）---- */
export {
  TriggerInfo,
  TriggerCatalog,
  TriggerSettingsKind,
  TriggerSupport
} from './src/main/ets/automation/TriggerCatalog';
export {
  ActionInfo,
  ActionCatalog,
  ActionSettingsKind,
  ActionSupport
} from './src/main/ets/automation/ActionCatalog';
export { CronExpression } from './src/main/ets/automation/CronExpression';
export {
  AutomationEngine,
  AutomationReason,
  AutomationRun,
  AutomationTick,
  AutomationTickResult,
  TriggerVerdict
} from './src/main/ets/automation/AutomationEngine';
export {
  AutomationDefaults,
  DEFAULT_ACTION_SET_NAME,
  WorkflowMutations
} from './src/main/ets/automation/WorkflowMutations';

/* ---- 自动化运行时（P8c2）---- */
export { AutomationSettings } from './src/main/ets/automation/AutomationSettings';

/* ---- 数据仓库（P8c2）---- */
export { ProfileRepository } from './src/main/ets/data/ProfileRepository';

/* ---- 精确时间（P11a）---- */
export {
  NTP_EPOCH_OFFSET_SECONDS,
  NTP_PACKET_SIZE,
  NtpParseResult,
  NtpReject,
  NtpResponse,
  buildNtpRequest,
  ntpDelayMillis,
  ntpOffsetMillis,
  parseNtpResponse
} from './src/main/ets/time/NtpProtocol';
export {
  BACKWARD_HOLD_LIMIT_MS,
  ExactClock,
  MAX_ACCEPTABLE_DELAY_MS,
  SYSTEM_JUMP_THRESHOLD_MS,
  SyncOutcome
} from './src/main/ets/time/ExactClock';
export {
  DailyAutoAdjustPlan,
  elapsedWholeDays,
  planDailyAutoAdjust
} from './src/main/ets/time/DailyAutoAdjust';

/* ---- 语音朗读（P11b）---- */

export {
  SPEECH_PROVIDER_SYSTEM,
  SPEECH_PROVIDER_EDGE_TTS,
  SPEECH_PROVIDER_GPT_SOVITS,
  DEFAULT_SPEECH_PROVIDER,
  DEFAULT_EDGE_TTS_VOICE,
  SPEECH_VOLUME_MIN,
  SPEECH_VOLUME_MAX,
  SpeechProviderInfo,
  SPEECH_PROVIDERS,
  SpeechResolution,
  findSpeechProvider,
  speechProviderName,
  resolveSpeechProvider,
  implementedSpeechProviders,
  shouldSpeakNotification,
  clampSpeechVolume
} from './src/main/ets/speech/SpeechProviders';
export {
  SPEECH_GENERATION_TIMEOUT_MS,
  SpeechItemState,
  SpeechStepKind,
  SpeechItem,
  SpeechStep,
  SpeechQueue,
  SpeechProviderCacheLayout,
  speechCachePath,
  sanitizeSegment
} from './src/main/ets/speech/SpeechQueue';

/* ---- 天气（P11c）---- */

export {
  WEATHER_TEXT_UNKNOWN,
  WeatherCodeEntry,
  WEATHER_CODE_TABLE,
  weatherTextByCode,
  expandWeatherCode,
  isWeatherCodeMatched,
  isUnknownWeatherCode
} from './src/main/ets/weather/WeatherCodes';
export {
  SunTimes,
  filterWeatherAlerts,
  tryGetSunTimes,
  minutesToApproxTime,
  windDirectionDegrees,
  aqiLevelName
} from './src/main/ets/weather/WeatherLogic';
export {
  WeatherSnapshot,
  currentWeatherSatisfied,
  tomorrowWeatherSatisfied,
  hasWeatherAlertSatisfied,
  rainTimeSatisfied,
  sunRiseSetSatisfied,
  weatherRuleSatisfied
} from './src/main/ets/weather/WeatherRules';
export {
  WeatherAlertBrief,
  WeatherBrief,
  buildWeatherBrief,
  WEATHER_MAIN_KIND_CONDITION,
  WEATHER_MAIN_KIND_HUMIDITY,
  WEATHER_MAIN_KIND_WIND,
  WEATHER_MAIN_KIND_AQI,
  WEATHER_MAIN_KIND_PRESSURE,
  WEATHER_MAIN_KIND_FEELS_LIKE
} from './src/main/ets/weather/WeatherBrief';
export {
  PublicNotifyIds,
  PublicWantActions,
  PublicWantKeys,
  DISTRIBUTED_SESSION_ID_MAX_LENGTH,
  normalizeDistributedSessionId,
  isValidDistributedSessionId
} from './src/main/ets/ipc/PublicProtocol';
export {
  PublicStateSource,
  PublicLessonState,
  PublicProfileBrief,
  eventIdForTransition,
  buildPublicLessonState,
  buildPublicProfileBrief,
  isPublicStateStale,
  PublicStateCodec
} from './src/main/ets/ipc/PublicState';

/* ---- 后台保活（P11e）---- */

export {
  KEEP_ALIVE_MODE_MULTI_DEVICE,
  KEEP_ALIVE_MODE_TASK_KEEPING,
  KeepAlivePlan,
  planKeepAlive,
  keepAliveErrorText
} from './src/main/ets/background/KeepAlivePolicy';

/* ---- 声明式插件系统（P12）---- */

export {
  PLUGIN_API_VERSION,
  PLUGIN_API_MIN_VERSION,
  SemVer,
  ApiCompatibility,
  checkPluginApiVersion,
  isValidPluginId
} from './src/main/ets/plugins/PluginApi';
export {
  ExtensionKind,
  PluginActionKind,
  PluginScheduleKind,
  EXTENSION_KINDS,
  extensionKindField,
  PLUGIN_COMPONENT_KINDS,
  TriggerExtension,
  ActionExtension,
  NotificationProviderExtension,
  ThemeExtension,
  ComponentExtension,
  ExtensionManifest,
  ExtensionManifestCodec,
  ComponentExtensionCodec,
  TriggerExtensionCodec,
  ActionExtensionCodec,
  NotificationProviderExtensionCodec,
  ThemeExtensionCodec
} from './src/main/ets/plugins/PluginManifest';
export {
  PluginIssueCode,
  PluginIssueSeverity,
  MAX_ENTRIES_PER_KIND,
  MAX_MANIFEST_TEXT_LENGTH,
  PLUGIN_THEME_MODES,
  PluginIssue,
  PluginSandbox,
  defaultPluginSandbox,
  validateManifest,
  validateManifestTextLength,
  hasBlockingIssues,
  blockingIssues,
  summarizeIssues,
  isHexColor,
  scheduleProblem
} from './src/main/ets/plugins/PluginValidation';
export {
  PLUGIN_REASON_FIRED,
  PLUGIN_REASON_NOT_YET,
  PLUGIN_REASON_BAD_SETTINGS,
  MAX_EVERY_MINUTES,
  SECONDS_PER_DAY,
  PluginSchedule,
  PluginScheduleVerdict,
  evaluatePluginSchedule,
  scheduleSettingsProblem,
  parsePluginSchedule,
  parseScheduleKindText,
  scheduleOfExtension,
  scheduleText,
  formatSecondOfDay,
  settingsOfTriggerExtension
} from './src/main/ets/plugins/PluginSchedule';
export {
  PluginTriggerVerdict,
  judgePluginTrigger
} from './src/main/ets/plugins/PluginTriggerEval';
export {
  PLUGIN_CATEGORIES,
  PLUGIN_CATEGORY_AUTOMATION,
  PLUGIN_CATEGORY_CLASS_REMINDER,
  PLUGIN_CATEGORY_WEATHER,
  PLUGIN_CATEGORY_SYSTEM,
  PluginNotificationPlan,
  PluginSettingPlan,
  PluginActionPlan,
  planPluginAction,
  parseActionKindText,
  normalizeCategory,
  settingsOfActionExtension
} from './src/main/ets/plugins/PluginActionEval';
export {
  PLUGIN_TEMPLATE_PLACEHOLDERS,
  PluginTemplateContext,
  renderPluginTemplate,
  pluginTemplatePlaceholders,
  unresolvedPlaceholders
} from './src/main/ets/plugins/PluginTemplate';
export {
  ExtensionEntryRecord,
  PluginRecord,
  ExtensionRegistry
} from './src/main/ets/plugins/ExtensionRegistry';
export {
  PluginInstallResult,
  installPlugin,
  uninstallPlugin,
  uninstallAllPlugins,
  defaultSettingsOfPluginTrigger,
  defaultSettingsOfPluginAction,
  PLUGIN_INACTIVE_REMINDER,
  inactiveReminder
} from './src/main/ets/plugins/PluginInstaller';
export { componentDecoderOfKind } from './src/main/ets/components/ComponentCatalog';
