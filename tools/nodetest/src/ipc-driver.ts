/*
 * 跨设备 / 公开查询测试台（会话 ID / 事件映射 / 快照合成 / 编解码 / 新鲜度 / 档案摘要）。
 *
 * P11d 的失败模式几乎全是「安静地错」：
 *
 *   1. 会话 ID 清洗规则和系统约束不一致（系统只收字母/数字/下划线，且最长
 *      128）。表现是 `setSessionId` 抛 401，界面上只看到「同步不可用」，
 *      而用户根本不知道自己粘贴的那个 UUID 哪里不对。
 *   2. 事件映射漏一档。表现是「上课事件」传成了「状态变化」，接收方该弹的
 *      提醒不弹，或者反过来一直弹。
 *   3. 快照的字段名写成 PascalCase。表现是另一台设备解析出来一堆空值，
 *      而本地一切正常 —— 没有任何东西会报错。
 *   4. 倒计时秒数换算错（`TimeSpanValue` 是 100ns tick，不是毫秒）。
 *      表现是所有剩余时间都差 10000 倍。
 *   5. 新鲜度判据把「从没发布过」（updatedAt=0）当成新鲜。表现是接收方拿着
 *      一份默认快照当真实数据用。
 *
 * 所以下面每条都对着协议定义取答案。
 */

import { DateTimeValue } from '../../common_shared/src/main/ets/json/DateTimeValue';
import { TimeSpanValue } from '../../common_shared/src/main/ets/json/TimeSpanValue';
import { KeyedMap } from '../../common_shared/src/main/ets/collections/KeyedMap';
import { Profile } from '../../common_shared/src/main/ets/models/Profile';
import { ClassPlan } from '../../common_shared/src/main/ets/models/ClassPlan';
import { Subject } from '../../common_shared/src/main/ets/models/Subject';
import { TimeState } from '../../common_shared/src/main/ets/enums/TimeState';
import { LessonsSnapshot } from '../../common_core/src/main/ets/engine/LessonsSnapshot';
import {
  DISTRIBUTED_SESSION_ID_MAX_LENGTH,
  PublicNotifyIds,
  isValidDistributedSessionId,
  normalizeDistributedSessionId
} from '../../common_core/src/main/ets/ipc/PublicProtocol';
import {
  PublicLessonState,
  PublicProfileBrief,
  PublicStateCodec,
  PublicStateSource,
  buildPublicLessonState,
  buildPublicProfileBrief,
  eventIdForTransition,
  isPublicStateStale
} from '../../common_core/src/main/ets/ipc/PublicState';

let passed: number = 0;
const failures: string[] = [];

function check(name: string, condition: boolean, detail: string = ''): void {
  if (condition) {
    passed++;
  } else {
    failures.push(detail.length === 0 ? name : `${name} —— ${detail}`);
  }
}

function checkEqual(name: string, actual: string, expected: string): void {
  check(name, actual === expected, `实际「${actual}」，期望「${expected}」`);
}

function checkNum(name: string, actual: number, expected: number): void {
  check(name, actual === expected, `实际 ${actual}，期望 ${expected}`);
}

function checkBool(name: string, actual: boolean, expected: boolean): void {
  check(name, actual === expected, `实际 ${actual}，期望 ${expected}`);
}

function dt(text: string): DateTimeValue {
  const value: DateTimeValue | undefined = DateTimeValue.tryParse(text);
  return value === undefined ? DateTimeValue.minValue() : value;
}

// --------------------------------------------------------------- 会话 ID

function testSessionId(): void {
  // 连字符、点、空格、中文全部丢掉，剩下的字母数字下划线保留。
  checkEqual('连字符被丢掉',
    normalizeDistributedSessionId('3f2504e0-4f89-11d3', 'fb'), '3f2504e04f8911d3');
  checkEqual('点与空格被丢掉',
    normalizeDistributedSessionId('a.b c', 'fb'), 'abc');
  checkEqual('中文被丢掉',
    normalizeDistributedSessionId('会话ab', 'fb'), 'ab');
  checkEqual('下划线保留',
    normalizeDistributedSessionId('a_b_c', 'fb'), 'a_b_c');
  checkEqual('数字保留',
    normalizeDistributedSessionId('12345', 'fb'), '12345');

  // 清洗后为空退回落值，且落值同样被清洗。
  checkEqual('空串退回落值', normalizeDistributedSessionId('', 'fallback'), 'fallback');
  checkEqual('全是非法字符也退回落值',
    normalizeDistributedSessionId('---', 'fallback'), 'fallback');
  checkEqual('落值里的非法字符也被清洗',
    normalizeDistributedSessionId('', 'fb-1.2'), 'fb12');
  checkEqual('落值也是非法字符时得到空串',
    normalizeDistributedSessionId('---', '---'), '');

  // 上限 128。
  let long: string = '';
  for (let i: number = 0; i < 200; i++) {
    long += 'a';
  }
  checkNum('超长被截到 128', normalizeDistributedSessionId(long, 'fb').length,
    DISTRIBUTED_SESSION_ID_MAX_LENGTH);
  checkNum('常量就是 128', DISTRIBUTED_SESSION_ID_MAX_LENGTH, 128);

  // 合法性判定。
  checkBool('普通 ID 合法', isValidDistributedSessionId('abc_123'), true);
  checkBool('空串不合法', isValidDistributedSessionId(''), false);
  checkBool('带连字符不合法', isValidDistributedSessionId('a-b'), false);
  checkBool('带空格不合法', isValidDistributedSessionId('a b'), false);
  checkBool('带中文不合法', isValidDistributedSessionId('会话'), false);
  checkBool('刚好 128 合法',
    isValidDistributedSessionId(long.substring(0, 128)), true);
  checkBool('129 不合法', isValidDistributedSessionId(long.substring(0, 129)), false);

  // 规范化的结果一定合法（除非输入两个来源都清洗成了空）。
  const normalized: string = normalizeDistributedSessionId('3f2504e0-4f89', 'fb');
  checkBool('规范化结果合法', isValidDistributedSessionId(normalized), true);
}

// --------------------------------------------------------------- 事件映射

function testEventMap(): void {
  checkEqual('无迁移不产生事件', eventIdForTransition(undefined), PublicNotifyIds.NONE);
  checkEqual('上课事件', eventIdForTransition(TimeState.OnClass), PublicNotifyIds.ON_CLASS);
  checkEqual('课间事件', eventIdForTransition(TimeState.Breaking),
    PublicNotifyIds.ON_BREAKING_TIME);
  checkEqual('放学事件', eventIdForTransition(TimeState.AfterSchool),
    PublicNotifyIds.ON_AFTER_SCHOOL);
  checkEqual('无课落到状态变化', eventIdForTransition(TimeState.None),
    PublicNotifyIds.CURRENT_TIME_STATE_CHANGED);
  checkEqual('准备上课落到状态变化', eventIdForTransition(TimeState.PrepareOnClass),
    PublicNotifyIds.CURRENT_TIME_STATE_CHANGED);

  // 事件 ID 必须与桌面版 IpcRoutedNotifyIds 逐字一致（跨端约定）。
  checkEqual('上课 ID 逐字一致', PublicNotifyIds.ON_CLASS,
    'classisland.lessonsService.onClass');
  checkEqual('课间 ID 逐字一致', PublicNotifyIds.ON_BREAKING_TIME,
    'classisland.lessonsService.onBreakingTime');
  checkEqual('放学 ID 逐字一致', PublicNotifyIds.ON_AFTER_SCHOOL,
    'classisland.lessonsService.onAfterSchool');
  checkEqual('状态变化 ID 逐字一致', PublicNotifyIds.CURRENT_TIME_STATE_CHANGED,
    'classisland.lessonsService.currentTimeStateChanged');
}

// --------------------------------------------------------------- 快照合成

function makeSnapshot(): LessonsSnapshot {
  const snapshot: LessonsSnapshot = new LessonsSnapshot();
  snapshot.state = TimeState.OnClass;
  snapshot.isClassPlanEnabled = true;
  snapshot.isClassPlanLoaded = true;
  snapshot.isLessonConfirmed = true;
  snapshot.currentSubject = new Subject();
  snapshot.currentSubject.name = '数学';
  snapshot.nextClassSubject = new Subject();
  snapshot.nextClassSubject.name = '语文';
  snapshot.onClassLeftTime = TimeSpanValue.fromSeconds(90);
  snapshot.onBreakingTimeLeftTime = TimeSpanValue.zero();
  snapshot.transitionTo = TimeState.OnClass;
  return snapshot;
}

function testLessonState(): void {
  const source: PublicStateSource = new PublicStateSource();
  source.deviceName = 'Mate 60';
  source.profileName = '默认';
  const now: DateTimeValue = dt('2026-10-01T10:30:00');

  const state: PublicLessonState = buildPublicLessonState(makeSnapshot(), source, now);

  checkEqual('设备名透传', state.deviceName, 'Mate 60');
  checkEqual('档案名透传', state.profileName, '默认');
  checkEqual('无课表时课表名为空', state.classPlanName, '');
  checkBool('启用状态透传', state.isClassPlanEnabled, true);
  checkBool('加载状态透传', state.isClassPlanLoaded, true);
  checkBool('已确认透传', state.isLessonConfirmed, true);
  checkNum('状态数值透传', state.currentState, TimeState.OnClass);
  checkEqual('当前科目', state.currentSubjectName, '数学');
  checkEqual('下一科科目', state.nextClassSubjectName, '语文');
  checkEqual('无时间点时起点为零', state.currentTimeLayoutStart, '00:00:00');
  checkEqual('无时间点时终点为零', state.currentTimeLayoutEnd, '00:00:00');
  checkNum('倒计时按 tick 换算成秒', state.onClassLeftSeconds, 90);
  checkNum('课间倒计时为零', state.onBreakingTimeLeftSeconds, 0);
  checkEqual('事件为上课', state.lastEvent, PublicNotifyIds.ON_CLASS);
  checkNum('更新时刻取自 now', state.updatedAt, now.toLocalMillis());

  // 有课表名时带上。
  const withPlan: LessonsSnapshot = makeSnapshot();
  const plan: ClassPlan = new ClassPlan();
  plan.name = '周三课表';
  withPlan.currentClassPlan = plan;
  checkEqual('课表名带上', buildPublicLessonState(withPlan, source, now).classPlanName, '周三课表');

  // 内容键忽略 updatedAt 与 lastEvent。
  const a: PublicLessonState = buildPublicLessonState(makeSnapshot(), source,
    dt('2026-10-01T10:30:00'));
  const b: PublicLessonState = buildPublicLessonState(makeSnapshot(), source,
    dt('2026-10-01T10:31:00'));
  checkEqual('内容键忽略更新时刻', a.contentKey(), b.contentKey());

  const c: PublicLessonState = buildPublicLessonState(makeSnapshot(), source, now);
  c.currentSubjectName = '英语';
  check('科目变了内容键跟着变', a.contentKey() !== c.contentKey());
}

// --------------------------------------------------------------- 编解码

function testCodec(): void {
  const source: PublicStateSource = new PublicStateSource();
  source.deviceName = '表';
  source.profileName = 'P';
  const now: DateTimeValue = dt('2026-10-01T10:30:00');
  const original: PublicLessonState = buildPublicLessonState(makeSnapshot(), source, now);

  const text: string = PublicStateCodec.encodeLessonState(original);
  // 键名必须是 camelCase（线上格式约定）。
  check('编码含 camelCase 键 currentSubjectName',
    text.indexOf('"currentSubjectName"') >= 0, text.substring(0, 120));
  check('编码不含 PascalCase 键', text.indexOf('"CurrentSubjectName"') < 0);

  const decoded: PublicLessonState | undefined = PublicStateCodec.decodeLessonState(text);
  check('能解回来', decoded !== undefined);
  if (decoded !== undefined) {
    checkEqual('往返后内容键一致', decoded.contentKey(), original.contentKey());
    checkNum('往返后更新时刻一致', decoded.updatedAt, original.updatedAt);
    checkEqual('往返后事件一致', decoded.lastEvent, original.lastEvent);
    checkEqual('往返后设备名一致', decoded.deviceName, original.deviceName);
  }

  // 坏 JSON 不抛，返回 undefined。
  check('坏 JSON 返回 undefined',
    PublicStateCodec.decodeLessonState('{不是 json') === undefined);
  check('数组不是对象也返回 undefined',
    PublicStateCodec.decodeLessonState('[1,2,3]') === undefined);

  // 缺字段时回落默认值。
  const sparse: PublicLessonState | undefined =
    PublicStateCodec.decodeLessonState('{"currentState":3}');
  check('缺字段能解', sparse !== undefined);
  if (sparse !== undefined) {
    checkNum('缺字段用默认状态', sparse.currentState, 3);
    checkEqual('缺字段用空科目', sparse.currentSubjectName, '');
    checkNum('缺字段用零更新时刻', sparse.updatedAt, 0);
  }
}

// --------------------------------------------------------------- 新鲜度

function testStaleness(): void {
  const now: DateTimeValue = dt('2026-10-01T10:30:00');
  const nowMillis: number = now.toLocalMillis();

  checkBool('从没发布过算过期', isPublicStateStale(0, now, 60), true);
  checkBool('负时刻算过期', isPublicStateStale(-1, now, 60), true);
  checkBool('刚发布不算过期', isPublicStateStale(nowMillis, now, 60), false);
  checkBool('30 秒前不算过期', isPublicStateStale(nowMillis - 30000, now, 60), false);
  checkBool('恰好 60 秒不算过期', isPublicStateStale(nowMillis - 60000, now, 60), false);
  checkBool('61 秒算过期', isPublicStateStale(nowMillis - 61000, now, 60), true);
  // 时钟回拨（接收方比发布方慢）：年龄为负，不算过期。
  checkBool('时钟回拨不算过期', isPublicStateStale(nowMillis + 5000, now, 60), false);
}

// --------------------------------------------------------------- 档案摘要

function testProfileBrief(): void {
  const profile: Profile = new Profile();
  profile.name = '档案 A';
  const planA: ClassPlan = new ClassPlan();
  planA.name = '周一';
  const planB: ClassPlan = new ClassPlan();
  planB.name = '周二';
  profile.classPlans.set('a', planA);
  profile.classPlans.set('b', planB);
  profile.subjects.set('s1', new Subject());
  profile.subjects.set('s2', new Subject());
  profile.subjects.set('s3', new Subject());

  const source: PublicStateSource = new PublicStateSource();
  source.deviceName = '平板';
  source.profileName = '';
  const now: DateTimeValue = dt('2026-10-01T10:30:00');

  const brief: PublicProfileBrief = buildPublicProfileBrief(profile, source, now);
  checkEqual('设备名透传', brief.deviceName, '平板');
  checkEqual('档案名从档案回落', brief.profileName, '档案 A');
  checkNum('课表数', brief.classPlanCount, 2);
  checkNum('科目数', brief.subjectCount, 3);
  checkNum('时间表数', brief.timeLayoutCount, 0);
  checkNum('课表名数', brief.classPlanNames.length, 2);
  check('课表名含周一', brief.classPlanNames.indexOf('周一') >= 0);
  check('课表名含周二', brief.classPlanNames.indexOf('周二') >= 0);

  // 有显式档案名时优先用它（跨端显示「另一台设备的档案名」）。
  const named: PublicStateSource = new PublicStateSource();
  named.profileName = '显式名';
  checkEqual('显式档案名优先',
    buildPublicProfileBrief(profile, named, now).profileName, '显式名');

  // 编解码往返。
  const text: string = PublicStateCodec.encodeProfileBrief(brief);
  check('摘要编码含 camelCase', text.indexOf('"classPlanCount"') >= 0);
  const decoded: PublicProfileBrief | undefined =
    PublicStateCodec.decodeProfileBrief(text);
  check('摘要能解回来', decoded !== undefined);
  if (decoded !== undefined) {
    checkNum('往返后课表数一致', decoded.classPlanCount, brief.classPlanCount);
    checkNum('往返后科目数一致', decoded.subjectCount, brief.subjectCount);
    checkNum('往返后名列表长度一致', decoded.classPlanNames.length,
      brief.classPlanNames.length);
  }

  // 空档案。
  const empty: PublicProfileBrief = buildPublicProfileBrief(new Profile(), source, now);
  checkNum('空档案课表数为零', empty.classPlanCount, 0);
  checkNum('空档案名列表为空', empty.classPlanNames.length, 0);
}

// --------------------------------------------------------------- 主入口

testSessionId();
testEventMap();
testLessonState();
testCodec();
testStaleness();
testProfileBrief();

if (failures.length > 0) {
  console.log(`跨设备：${failures.length} 项失败（共 ${passed + failures.length} 项）`);
  for (const failure of failures) {
    console.log(`  ✗ ${failure}`);
  }
  process.exit(1);
}
console.log(`跨设备：${passed} 项全部通过`);
