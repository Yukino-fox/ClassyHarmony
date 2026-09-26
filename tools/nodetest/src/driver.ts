/*
 * 字节级往返测试驱动。
 *
 * 为什么需要它：ArkTS 编译通过只能证明「代码合规」，不能证明「输出与桌面版
 * 逐字节一致」。本驱动在 Node 中直接跑 common_shared 的真实源码（仅经
 * TypeScript 剥类型，运行期语义与 ArkTS 一致），把 JSON 内核与模型的
 * 保真度问题暴露成可定位的断言失败。
 *
 * 三类判据：
 * 1. 黄金样本比对——profile-full.json 是全字段形态，逐字节往返必须相同。
 * 2. 真实产物比对——default-subjects.json 是 ClassIsland/Assets 下的实际
 *    序列化输出（但出自旧版，缺 10 个后来新增的字段）。它的价值在于
 *    Subjects 段落的真实形态，故只断言「第一个新增字段之前的前缀」一致。
 * 3. 不动点性质——对合成档案，往返两次的输出必须逐字节相同。这不依赖任何
 *    外部参照，能覆盖样本未触及的深层结构
 *    （TimeLayout/TimeLayoutItem/ClassPlan/ActionSet/OrderedSchedules）。
 */

import { readFileSync } from 'fs';
import { join } from 'path';

import { DateTimeValue } from '../../common_shared/src/main/ets/json/DateTimeValue';
import { Guid } from '../../common_shared/src/main/ets/json/Guid';
import { JsonReader } from '../../common_shared/src/main/ets/json/JsonReader';
import { JsonWriter } from '../../common_shared/src/main/ets/json/JsonWriter';
import { TimeSpanValue } from '../../common_shared/src/main/ets/json/TimeSpanValue';
import { ActionItem } from '../../common_shared/src/main/ets/models/Automation/ActionItem';
import { ActionSet } from '../../common_shared/src/main/ets/models/Automation/ActionSet';
import { ActionSetStatus } from '../../common_shared/src/main/ets/enums/ActionSetStatus';
import { ClassInfo } from '../../common_shared/src/main/ets/models/ClassInfo';
import { ClassPlan } from '../../common_shared/src/main/ets/models/ClassPlan';
import { ClassPlanGroup } from '../../common_shared/src/main/ets/models/ClassPlanGroup';
import { OrderedSchedule } from '../../common_shared/src/main/ets/models/OrderedSchedule';
import { Profile } from '../../common_shared/src/main/ets/models/Profile';
import { Subject } from '../../common_shared/src/main/ets/models/Subject';
import { TimeLayout } from '../../common_shared/src/main/ets/models/TimeLayout';
import { TimeLayoutItem } from '../../common_shared/src/main/ets/models/TimeLayoutItem';
import { TimeRule } from '../../common_shared/src/main/ets/models/TimeRule';

let passed: number = 0;
const failures: string[] = [];

function check(name: string, condition: boolean, detail: string = ''): void {
  if (condition) {
    passed++;
    return;
  }
  failures.push(detail.length > 0 ? `${name}\n    ${detail}` : name);
}

function checkEqual(name: string, actual: string, expected: string): void {
  if (actual === expected) {
    passed++;
    return;
  }
  failures.push(`${name}\n    期望: ${expected}\n    实际: ${actual}\n    ${firstDiff(expected, actual)}`);
}

/** 找出首个差异位置，便于定位而非整篇打印。 */
function firstDiff(expected: string, actual: string): string {
  const limit: number = Math.min(expected.length, actual.length);
  for (let i: number = 0; i < limit; i++) {
    if (expected.charAt(i) !== actual.charAt(i)) {
      const from: number = Math.max(0, i - 30);
      return `首个差异在第 ${i} 字节（偏移 ${from} 起）\n` +
        `    期望…${expected.substring(from, i + 30)}\n` +
        `    实际…${actual.substring(from, i + 30)}`;
    }
  }
  return `长度不同：期望 ${expected.length}，实际 ${actual.length}`;
}

function fixture(name: string): string {
  return readFileSync(join(__dirname, '..', 'fixtures', name), 'utf8');
}

// ---------------------------------------------------------------- 1. 黄金样本

function testGoldenProfile(): void {
  const original: string = fixture('profile-full.json');

  const once: string = Profile.stringify(Profile.parse(original));
  checkEqual('黄金样本：一次往返逐字节一致', once, original);

  const twice: string = Profile.stringify(Profile.parse(once));
  checkEqual('黄金样本：二次往返仍稳定', twice, original);
}

// ---------------------------------------------------------------- 2. 真实产物

/**
 * default-subjects.json 出自旧版 ClassIsland，其后新增的 10 个字段它没有。
 * 桌面版加载这份文件后保存同样会补上这些字段，所以「整份逐字节相同」从来
 * 不是桌面版行为——真正该锁住的是：真实产物里存在的那部分，一字不差。
 */
function testLegacyArtifact(): void {
  const original: string = fixture('default-subjects.json');
  const once: string = Profile.stringify(Profile.parse(original));

  const marker: string = '"TempClassPlanId":null';
  const at: number = once.indexOf(marker);
  check('旧版产物加载后补上了新增字段', at > 0, once.substring(0, 200));
  if (at <= 0) {
    return;
  }
  // 旧产物止于 OverlayClassPlanId，其后是 IsActive；取到两者之间的全部内容
  const prefixEnd: number = original.indexOf('"IsActive":false}');
  const prefix: string = original.substring(0, prefixEnd);
  checkEqual('旧版产物：新增字段之前的真实内容逐字节一致',
    once.substring(0, prefix.length), prefix);

  // 补上的字段必须按当前桌面版声明顺序出现
  const tail: string = once.substring(prefix.length);
  const expectedTail: string[] = [
    '"TempClassPlanId":null',
    '"TempClassPlanSetupTime":',
    '"ClassPlanGroups":{}',
    '"SelectedClassPlanGroupId":',
    '"TempClassPlanGroupId":null',
    '"TempClassPlanGroupExpireTime":',
    '"IsTempClassPlanGroupEnabled":false',
    '"TempClassPlanGroupType":1',
    '"Id":',
    '"OrderedSchedules":{}',
    '"IsActive":false}'
  ];
  let cursor: number = 0;
  for (const token of expectedTail) {
    const found: number = tail.indexOf(token, cursor);
    check(`旧版产物：补齐字段按声明顺序出现（${token}）`, found >= 0, tail);
    if (found < 0) {
      break;
    }
    cursor = found;
  }
}

// ---------------------------------------------------------------- 3. 不动点

/**
 * 合成一份「字段拉满」的档案，覆盖样本触及不到的分支：
 * 叠加、行动组、临时课表组、指定日程、小数秒等。
 */
function buildFullProfile(): Profile {
  const subjectId: Guid = Guid.fromCanonical('97d0bf3f-137f-4f8a-87d6-ff387063bbd3');
  const layoutId: Guid = Guid.fromCanonical('5cda50df-2f24-47b1-8f81-e5579ef56539');
  const planId: Guid = Guid.fromCanonical('8f2b1c3d-4e5f-4a6b-9c8d-7e6f5a4b3c2d');
  const groupId: Guid = ClassPlanGroup.defaultGroupGuid();

  const breakItem: TimeLayoutItem = new TimeLayoutItem();
  breakItem.startTime = TimeSpanValue.fromHoursMinutes(7, 50);
  breakItem.endTime = TimeSpanValue.fromHoursMinutes(8, 10);
  breakItem.timeType = 0;
  breakItem.breakName = '早读结束';

  const morningItem: TimeLayoutItem = new TimeLayoutItem();
  morningItem.startTime = TimeSpanValue.fromHoursMinutes(8, 10);
  morningItem.endTime = TimeSpanValue.fromHoursMinutes(8, 55);
  morningItem.timeType = 1;

  // 行动组停在已落定状态（IsOn），这样往返才是不动点。
  // 瞬时状态（Invoking/Reverting）会让 IsWorking 与落盘的 Status 互相矛盾，
  // 桌面版同样如此——单列为一项测试，不混进不动点判据。
  const actionSet: ActionSet = new ActionSet();
  actionSet.name = '铃声';
  actionSet.isEnabled = true;
  actionSet.isRevertEnabled = true;
  actionSet.status = ActionSetStatus.IsOn;
  actionSet.guid = Guid.fromCanonical('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');

  const actionItem: ActionItem = new ActionItem();
  actionItem.isCompleted = false;
  actionItem.id = 'Ring';
  actionItem.settings = JsonReader.parse('{"Sound":"Bell","Volume":0.8}');
  actionSet.actions = [actionItem];

  // 第二项不设 Settings，验证 null 时字段被省略
  const noSettingsItem: ActionItem = new ActionItem();
  noSettingsItem.isCompleted = true;
  noSettingsItem.id = 'Stop';
  actionSet.actions.push(noSettingsItem);

  morningItem.actionSet = actionSet;

  // 小数秒与极小偏移，覆盖 TimeSpan 的分数与符号分支
  const afternoonItem: TimeLayoutItem = new TimeLayoutItem();
  afternoonItem.startTime = TimeSpanValue.fromHours(14)
    .add(TimeSpanValue.parseOrZero('00:00:00.1234567'));
  afternoonItem.endTime = TimeSpanValue.fromHours(14)
    .add(TimeSpanValue.fromMinutes(45))
    .subtract(TimeSpanValue.fromTicks(1));
  afternoonItem.timeType = 2;
  afternoonItem.isHideDefault = true;
  afternoonItem.defaultClassId = subjectId;

  const layout: TimeLayout = new TimeLayout();
  layout.name = '秋季作息';
  layout.isOverlay = true;
  layout.overlaySourceId = layoutId;
  layout.layouts = [breakItem, morningItem, afternoonItem];

  const rule: TimeRule = new TimeRule();
  rule.weekDay = 1;
  rule.weekCountDiv = 0;
  rule.weekCountDivTotal = 2;

  const info: ClassInfo = new ClassInfo();
  info.subjectId = subjectId;
  info.isChangedClass = true;
  info.isEnabled = true;

  const plan: ClassPlan = new ClassPlan();
  plan.name = '周一课表';
  plan.timeLayoutId = layoutId;
  plan.timeRule = rule;
  plan.classes = [info];
  plan.isOverlay = true;
  plan.overlaySourceId = planId;
  plan.overlaySetupTime = new DateTimeValue(2026, 9, 26, 7, 5, 3);
  plan.isEnabled = true;
  plan.associatedGroup = groupId;

  const subject: Subject = new Subject();
  subject.name = '语文';
  subject.initial = '语';
  subject.teacherName = '张老师';
  subject.isOutDoor = false;

  const group: ClassPlanGroup = new ClassPlanGroup();
  group.name = '默认';
  group.isGlobal = true;

  const schedule: OrderedSchedule = new OrderedSchedule();
  schedule.classPlanId = planId;

  const profile: Profile = new Profile();
  profile.name = '全字段档案';
  profile.timeLayouts.set(layoutId.toString(), layout);
  profile.classPlans.set(planId.toString(), plan);
  profile.subjects.set(subjectId.toString(), subject);
  profile.classPlanGroups.set(groupId.toString(), group);
  profile.isOverlayClassPlanEnabled = true;
  profile.overlayClassPlanId = planId;
  profile.tempClassPlanId = planId;
  profile.tempClassPlanSetupTime = new DateTimeValue(2026, 9, 26, 8, 0, 0);
  profile.selectedClassPlanGroupId = groupId;
  profile.tempClassPlanGroupId = groupId;
  profile.tempClassPlanGroupExpireTime = new DateTimeValue(2026, 10, 1, 0, 0, 0);
  profile.isTempClassPlanGroupEnabled = true;
  profile.tempClassPlanGroupType = 1;
  profile.id = Guid.fromCanonical('12345678-1234-1234-1234-123456789abc');
  profile.orderedSchedules.set('2026-09-28T00:00:00', schedule);
  profile.bindReferences();
  return profile;
}

function testFullProfileFixedPoint(): void {
  const first: string = Profile.stringify(buildFullProfile());
  const second: string = Profile.stringify(Profile.parse(first));
  checkEqual('合成档案：往返两次逐字节一致（不动点）', second, first);

  // 字段顺序是对桌面版最硬的约束之一，单独按序列出并锁住顺序关系
  const order: string[] = [
    'Name', 'TimeLayouts', 'ClassPlans', 'Subjects', 'IsOverlayClassPlanEnabled',
    'OverlayClassPlanId', 'TempClassPlanId', 'TempClassPlanSetupTime',
    'ClassPlanGroups', 'SelectedClassPlanGroupId', 'TempClassPlanGroupId',
    'TempClassPlanGroupExpireTime', 'IsTempClassPlanGroupEnabled',
    'TempClassPlanGroupType', 'Id', 'OrderedSchedules', 'IsActive'
  ];
  let cursor: number = 0;
  for (const name of order) {
    const found: number = first.indexOf(`"${name}"`, cursor);
    check(`Profile 字段顺序：${name}`, found >= 0, first);
    if (found < 0) {
      break;
    }
    cursor = found;
  }

  // 废弃字段仍需落盘：StartSecond/EndSecond 标了 Obsolete(error) 但没标
  // JsonIgnore，反射照常序列化，漏写会导致与桌面版不一致
  check('TimeLayoutItem.StartSecond/EndSecond 仍落盘为空串',
    first.indexOf('"StartSecond":"","EndSecond":""') >= 0, first);

  // Settings 为 null 时整个字段被省略（条件序列化）
  check('ActionItem.Settings 为 null 时字段被省略',
    first.indexOf('"Id":"Stop","IsActive":false') >= 0, first);

  // ActionSet 序列化字段名是 Actions 而不是 ActionItems
  check('ActionSet 字段名为 Actions', first.indexOf('"Actions":') >= 0, first);

  // Guid 键一律小写
  const groupKey: string = ClassPlanGroup.defaultGroupGuid().toString();
  check('Guid 键归一为小写',
    first.indexOf(groupKey) >= 0 && first.indexOf(groupKey.toUpperCase()) < 0, first);

  // 深夜时刻的天数进位
  check('TimeSpan 跨日输出天数段',
    first.indexOf('"StartTime":"14:00:00.1234567"') >= 0, first);
}

/**
 * 行动组的瞬时状态：落盘时 Status 被折叠，但 IsWorking 仍按实时状态算出。
 * 桌面版行为一致——读回来 Status 已是 Normal，下次保存就写成 false。
 * 故这项只断言单次输出，不要求不动点。
 */
function testTransientActionSet(): void {
  const profile: Profile = buildFullProfile();
  const plan: ClassPlan = profile.classPlans.values()[0];
  const layout: TimeLayout = profile.timeLayouts.values()[0];
  const item: TimeLayoutItem = layout.layouts[1];
  (item.actionSet as ActionSet).status = ActionSetStatus.Invoking;

  const output: string = Profile.stringify(profile);
  check('瞬时状态：Status 折叠为 0 而 IsWorking 为 true',
    output.indexOf('"Status":0,"IsWorking":true') >= 0, output);
  // 折叠只针对 Invoking/Reverting；已落定状态原值写出
  const settled: string = Profile.stringify(buildFullProfile());
  check('已落定状态：Status 原值 2 写出',
    settled.indexOf('"Status":2,"IsWorking":false') >= 0, settled);
}

// ---------------------------------------------------------------- 4. 格式基座

function testTimeSpan(): void {
  checkEqual('TimeSpan 零值', TimeSpanValue.fromHoursMinutes(0, 0).toString(), '00:00:00');
  checkEqual('TimeSpan 小时补零', TimeSpanValue.fromHours(1).toString(), '01:00:00');
  checkEqual('TimeSpan 超过 1 天进位', TimeSpanValue.fromHours(25).toString(), '1.01:00:00');
  checkEqual('TimeSpan 天数不补零', TimeSpanValue.fromHours(25 + 12).toString(), '1.13:00:00');
  checkEqual('TimeSpan 负号作用于整体', TimeSpanValue.fromHours(-26).toString(), '-1.02:00:00');
  checkEqual('TimeSpan 小数固定 7 位',
    TimeSpanValue.parseOrZero('00:00:00.5').toString(), '00:00:00.5000000');
  checkEqual('TimeSpan 小数为 0 时省略',
    TimeSpanValue.parseOrZero('00:00:00.0000000').toString(), '00:00:00');
  checkEqual('TimeSpan 天数与小数同时存在',
    TimeSpanValue.parseOrZero('1.12:00:00.5').toString(), '1.12:00:00.5000000');
  checkEqual('TimeSpan 往返 1.12:00:00',
    TimeSpanValue.parseOrZero('1.12:00:00').toString(), '1.12:00:00');
  checkEqual('TimeSpan 容忍省略秒', TimeSpanValue.parseOrZero('8:00').toString(), '08:00:00');

  // STJ 的 schema 允许 2 位小时（"\d{2}"），故 25:00:00 合法，读入后按 1.01 输出
  checkEqual('TimeSpan 25 小时归一化', TimeSpanValue.parseOrZero('25:00:00').toString(), '1.01:00:00');
  check('TimeSpan 拒绝非法分钟', TimeSpanValue.tryParse('00:70:00') === undefined);
  check('TimeSpan 拒绝非法秒', TimeSpanValue.tryParse('00:00:70') === undefined);
  check('TimeSpan 拒绝 8 位小数', TimeSpanValue.tryParse('00:00:00.12345678') === undefined);
  check('TimeSpan 拒绝空串', TimeSpanValue.tryParse('') === undefined);
  check('TimeSpan 拒绝纯数字', TimeSpanValue.tryParse('12345') === undefined);
  check('TimeSpan 拒绝多余段', TimeSpanValue.tryParse('1:2:3:4') === undefined);
}

function testGuid(): void {
  checkEqual('Guid.Empty', Guid.empty().toString(), '00000000-0000-0000-0000-000000000000');
  checkEqual('Guid 大写归一为小写',
    Guid.parseOrEmpty('ACAF4EF0-E261-4262-B941-34EA93CB4369').toString(),
    'acaf4ef0-e261-4262-b941-34ea93cb4369');
  checkEqual('Guid N 格式补连字符',
    Guid.parseOrEmpty('acaf4ef0e2614262b94134ea93cb4369').toString(),
    'acaf4ef0-e261-4262-b941-34ea93cb4369');
  checkEqual('Guid B 格式去括号',
    Guid.parseOrEmpty('{acaf4ef0-e261-4262-b941-34ea93cb4369}').toString(),
    'acaf4ef0-e261-4262-b941-34ea93cb4369');
  check('Guid 空白串按 Empty 读', Guid.parseOrEmpty('   ').isEmpty());
  check('Guid 非法输入按 Empty 读', Guid.parseOrEmpty('not-a-guid').isEmpty());
  check('Guid null 按 Empty 读', Guid.parseOrEmpty(null).isEmpty());
}

function testDateTime(): void {
  checkEqual('DateTime 无小数部分',
    new DateTimeValue(2026, 9, 26, 8, 0, 0).toString(), '2026-09-26T08:00:00');
  checkEqual('DateTime 小数补足 7 位',
    new DateTimeValue(2026, 9, 26, 8, 0, 0, 1234567).toString(), '2026-09-26T08:00:00.1234567');
  checkEqual('DateTime MinValue',
    DateTimeValue.minValue().toString(), '0001-01-01T00:00:00');
  checkEqual('DateTime 往返',
    DateTimeValue.parseOrMin('2026-09-26T08:00:00').toString(), '2026-09-26T08:00:00');
  // 读入遇时区后缀时保留墙上时钟并丢弃偏移，避免隐式时区破坏往返
  checkEqual('DateTime 丢弃时区后缀保留墙上时钟',
    DateTimeValue.parseOrMin('2026-09-26T08:00:00Z').toString(), '2026-09-26T08:00:00');
  checkEqual('DateTime 丢弃偏移量',
    DateTimeValue.parseOrMin('2026-09-26T08:00:00+08:00').toString(), '2026-09-26T08:00:00');
}

function testJsonKernel(): void {
  // System.Text.Json 默认 JavaScriptEncoder：非 Basic Latin 一律 \uXXXX 且大写十六进制
  checkEqual('中文转义为大写 \\uXXXX',
    JsonWriter.writeCompact(JsonReader.parse('{"k":"\\u8bed\\u6587"}')), '{"k":"\\u8BED\\u6587"}');
  // HTML 敏感字符亦被转义，且必须是 4 位十六进制——
  // 写成 5 位（如 \u000E9）会被解析器读成 U+000E 加一个字面字符，静默改数据
  checkEqual('HTML 敏感字符转义为 4 位',
    JsonWriter.writeCompact(JsonReader.parse('{"k":"&<>\'"}')), '{"k":"\\u0026\\u003C\\u003E\\u0027"}');
  checkEqual('加号与反引号亦转义',
    JsonWriter.writeCompact(JsonReader.parse('{"k":"+`"}')), '{"k":"\\u002B\\u0060"}');
  // 两/三位十六进制码点必须补足到 4 位
  checkEqual('两位十六进制补足 4 位',
    JsonWriter.writeCompact(JsonReader.parse('{"k":"\\u00e9"}')), '{"k":"\\u00E9"}');
  checkEqual('三位十六进制补足 4 位',
    JsonWriter.writeCompact(JsonReader.parse('{"k":"\\u0e00"}')), '{"k":"\\u0E00"}');
  // 数字保留原始字面量，这是字节级往返的关键
  checkEqual('数字保留原始字面量',
    JsonWriter.writeCompact(JsonReader.parse('{"a":1.500,"b":1e3,"c":0.0}')),
    '{"a":1.500,"b":1e3,"c":0.0}');
  checkEqual('负零与指数原样',
    JsonWriter.writeCompact(JsonReader.parse('{"a":-0.0,"b":1E+2}')),
    '{"a":-0.0,"b":1E+2}');
  checkEqual('字符串内 Basic Latin 原样输出',
    JsonWriter.writeCompact(JsonReader.parse('{"k":"a~b!"}')), '{"k":"a~b!"}');
  checkEqual('转义序列还原为字符',
    JsonWriter.writeCompact(JsonReader.parse('{"k":"\\n\\t\\"\\\\"}')), '{"k":"\\n\\t\\"\\\\"}');
  checkEqual('控制字符转义为短式',
    JsonWriter.writeCompact(JsonReader.parse('{"k":"\\u0001"}')), '{"k":"\\u0001"}');
  checkEqual('斜杠不转义',
    JsonWriter.writeCompact(JsonReader.parse('{"k":"a/b"}')), '{"k":"a/b"}');
  checkEqual('空对象与空数组',
    JsonWriter.writeCompact(JsonReader.parse('{"a":{},"b":[],"c":null}')),
    '{"a":{},"b":[],"c":null}');
  checkEqual('键顺序按插入序保留',
    JsonWriter.writeCompact(JsonReader.parse('{"z":1,"a":2}')), '{"z":1,"a":2}');
}

// ---------------------------------------------------------------- 入口

testGoldenProfile();
testLegacyArtifact();
testFullProfileFixedPoint();
testTransientActionSet();
testTimeSpan();
testGuid();
testDateTime();
testJsonKernel();

console.log(`通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('');
  for (const failure of failures) {
    console.log(`✗ ${failure}`);
  }
  process.exit(1);
}
