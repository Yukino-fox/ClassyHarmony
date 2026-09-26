/*
 * common_shared 导出入口。
 *
 * 对应 ClassIsland.Shared：纯数据模型 + JSON 编解码基座。
 *
 * 硬约束：本模块严禁依赖 UI、音频、媒体、后台任务等能力。
 * 小组件 FormExtensionAbility（10 秒不活动即被系统回收）会引用本模块，
 * 一旦在此链路引入被禁模块，卡片进程会异常退出。
 */

/* ---- 枚举 ---- */
export { TimeState } from './src/main/ets/enums/TimeState';
export { TempClassPlanGroupType } from './src/main/ets/enums/TempClassPlanGroupType';
export { ActionSetStatus, ActionSetStatusCodec } from './src/main/ets/enums/ActionSetStatus';

/* ---- JSON 编解码基座 ---- */
export { Guid } from './src/main/ets/json/Guid';
export { TimeSpanValue } from './src/main/ets/json/TimeSpanValue';
export { DateTimeValue } from './src/main/ets/json/DateTimeValue';
export {
  JsonNode,
  JsonMember,
  JsonObject,
  JsonArray,
  JsonString,
  JsonNumber,
  JsonBoolean,
  JsonNull
} from './src/main/ets/json/JsonNode';
export { JsonReader, JsonParseError } from './src/main/ets/json/JsonReader';
export { JsonWriter } from './src/main/ets/json/JsonWriter';
export { JsonValue } from './src/main/ets/json/JsonValue';

/* ---- 集合 ---- */
export { KeyedMap, KeyedMapEntry } from './src/main/ets/collections/KeyedMap';

/* ---- 数据模型 ---- */
export { ModelCodec } from './src/main/ets/models/ModelCodec';
export { ModelCloner } from './src/main/ets/models/ModelCloner';
export { ActionItem } from './src/main/ets/models/Automation/ActionItem';
export { ActionSet } from './src/main/ets/models/Automation/ActionSet';
export { Subject } from './src/main/ets/models/Subject';
export { TimeRule } from './src/main/ets/models/TimeRule';
export {
  TimeLayoutItem,
  TIME_TYPE_CLASS,
  TIME_TYPE_BREAK,
  TIME_TYPE_SEPARATOR,
  TIME_TYPE_ACTION
} from './src/main/ets/models/TimeLayoutItem';
export { TimeLayout } from './src/main/ets/models/TimeLayout';
export { ClassInfo } from './src/main/ets/models/ClassInfo';
export { ClassPlan } from './src/main/ets/models/ClassPlan';
export { ClassPlanGroup } from './src/main/ets/models/ClassPlanGroup';
export { OrderedSchedule } from './src/main/ets/models/OrderedSchedule';
export { Profile } from './src/main/ets/models/Profile';
