/*
 * 语音朗读测试台（UTF-8 / MD5 / 提供方选择 / 队列）。
 *
 * 这一层的失败模式分两类，都很安静：
 *
 *  1. 摘要错了。表现不是崩溃，而是「缓存永远不命中」—— 每次都重新合成一遍，
 *     只是慢一点，没有任何日志会指出这件事。所以 MD5 拿 RFC 1321 的官方向量
 *     逐条对，并把填充边界（55 / 56 / 57 / 64 字节）单独钉住：少补 0x80 这一
 *     位时，只有落在特定长度上的输入会算错，随手挑一句「hello world」测不出来。
 *  2. 队列语义错了。表现是「提醒晚了 / 说了不该说的 / 该说的没说」。这类错
 *     只在多条目、有取消、有失败的组合下才出现，所以覆盖重点放在组合上：
 *     队首卡住时后面的会不会插队、被取消的项会不会还出声、失败的项会不会
 *     把后面的堵死。
 *
 * 另外 UTF-8 要逐条对齐两处口径：与 TextEncoder、与 .NET 的 Encoding.UTF8。
 * 代理对必须合成成一个 4 字节序列（而不是两个 3 字节的 CESU-8），落单的代理
 * 必须编成 U+FFFD 而不是报错或丢弃 —— 这两条任意一条错了，两端就算不出同一个
 * 缓存键，而这是完全静默的。
 */

import {
  encodeUtf8
} from '../../common_shared/src/main/ets/text/Utf8';
import {
  md5Hex,
  md5HexOfText
} from '../../common_shared/src/main/ets/crypto/Md5';
import {
  DEFAULT_EDGE_TTS_VOICE,
  DEFAULT_SPEECH_PROVIDER,
  SPEECH_PROVIDER_EDGE_TTS,
  SPEECH_PROVIDER_GPT_SOVITS,
  SPEECH_PROVIDER_SYSTEM,
  SPEECH_VOLUME_MAX,
  SPEECH_VOLUME_MIN,
  SpeechResolution,
  clampSpeechVolume,
  findSpeechProvider,
  implementedSpeechProviders,
  resolveSpeechProvider,
  shouldSpeakNotification,
  speechProviderName
} from '../../common_core/src/main/ets/speech/SpeechProviders';
import {
  SPEECH_GENERATION_TIMEOUT_MS,
  SpeechItem,
  SpeechItemState,
  SpeechQueue,
  SpeechStep,
  SpeechStepKind,
  sanitizeSegment,
  speechCachePath
} from '../../common_core/src/main/ets/speech/SpeechQueue';

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
  check(name, actual === expected, `实际 ${actual}，期望 ${expected}`);
}

function checkNum(name: string, actual: number, expected: number): void {
  check(name, actual === expected, `实际 ${actual}，期望 ${expected}`);
}

// --------------------------------------------------------------- UTF-8

/** 字节序列的小写十六进制，用空格分隔，便于按字节对答案。 */
function hexOf(bytes: Uint8Array): string {
  const parts: string[] = [];
  for (let i: number = 0; i < bytes.length; i++) {
    let text: string = bytes[i].toString(16);
    if (text.length < 2) {
      text = `0${text}`;
    }
    parts.push(text);
  }
  return parts.join(' ');
}

/** 单个码点（用 padStart 之外的写法构造代理对，避免依赖 String.fromCodePoint）。 */
function utf16(units: number[]): string {
  let out: string = '';
  for (let i: number = 0; i < units.length; i++) {
    out += String.fromCharCode(units[i]);
  }
  return out;
}

function checkBytes(name: string, text: string, expected: string): void {
  checkEqual(name, hexOf(encodeUtf8(text)), expected);
}

function testUtf8(): void {
  // 空串编出 0 字节，而不是一个空字节。
  checkNum('空串编码为 0 字节', encodeUtf8('').length, 0);

  // ASCII 一字节。
  checkBytes('ASCII 单字节', 'abc', '61 62 63');
  checkBytes('U+0000 也要编出来', utf16([0]), '00');
  checkBytes('U+007F 是一字节上界', utf16([0x7f]), '7f');

  // 两字节段。
  checkBytes('U+0080 进入两字节', utf16([0x80]), 'c2 80');
  checkBytes('U+00E9 (é)', 'é', 'c3 a9');
  checkBytes('U+07FF 是两字节上界', utf16([0x7ff]), 'df bf');

  // 三字节段。
  checkBytes('U+0800 进入三字节', utf16([0x800]), 'e0 a0 80');
  checkBytes('U+4E2D (中)', '中', 'e4 b8 ad');
  checkBytes('U+FFFD (替换字符)', utf16([0xfffd]), 'ef bf bd');
  checkBytes('U+FFFF 是三字节上界', utf16([0xffff]), 'ef bf bf');

  // 四字节段：代理对必须合成。
  checkBytes('U+10000 进入四字节', utf16([0xd800, 0xdc00]), 'f0 90 80 80');
  checkBytes('U+1F600 (😀)', '😀', 'f0 9f 98 80');
  checkBytes('U+10FFFF 是四字节上界', utf16([0xdbff, 0xdfff]), 'f4 8f bf bf');

  // 落单代理编成 U+FFFD。
  checkBytes('落单高位代理', utf16([0xd800]), 'ef bf bd');
  checkBytes('落单低位代理', utf16([0xdc00]), 'ef bf bd');
  // 高位后面跟的不是低位：高位先变 FFFD，后面的字符照常编。
  checkBytes('高位后跟普通字符', utf16([0xd800, 0x0041]), 'ef bf bd 41');
  // 高位后面又跟一个高位：第一个变 FFFD，第二个继续按高位判（后面无低位）也变 FFFD。
  checkBytes('连续两个高位代理', utf16([0xd800, 0xd800]), 'ef bf bd ef bf bd');
  checkBytes('低位在前高位在后', utf16([0xdc00, 0xd800]), 'ef bf bd ef bf bd');

  // 字节数按码点算而不是按 UTF-16 码元算：一个 emoji 是 2 个码元但 4 个字
  // 节。若按码元各编各的会得到 6 字节（CESU-8），这里必须是 4。
  checkNum('emoji 是 4 字节而非 6 字节', encodeUtf8('😀').length, 4);
  checkNum('中英混排字节数', encodeUtf8('A中B').length, 1 + 3 + 1);
}

// --------------------------------------------------------------- MD5

function testMd5(): void {
  // RFC 1321 附录 A.5 的七条官方向量。
  checkEqual('MD5 空串', md5Hex(encodeUtf8('')), 'd41d8cd98f00b204e9800998ecf8427e');
  checkEqual('MD5 "a"', md5Hex(encodeUtf8('a')), '0cc175b9c0f1b6a831c399e269772661');
  checkEqual('MD5 "abc"', md5Hex(encodeUtf8('abc')), '900150983cd24fb0d6963f7d28e17f72');
  checkEqual('MD5 "message digest"', md5Hex(encodeUtf8('message digest')),
    'f96b697d7cb7938d525a2f31aaf161d0');
  checkEqual('MD5 a-z', md5Hex(encodeUtf8('abcdefghijklmnopqrstuvwxyz')),
    'c3fcd3d76192e4007dfb496cca67e13b');
  checkEqual('MD5 A-Za-z0-9',
    md5Hex(encodeUtf8('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789')),
    'd174ab98d277d9f5a5611c2c9f419d9f');
  checkEqual('MD5 80 个数字', md5Hex(encodeUtf8('1234567890'.repeat(8))),
    '57edf4a22be3c955ac49da2e2107b67a');

  /*
   * 填充边界。长度 55 时原文 + 0x80 + 长度字段恰好填满一个 64 字节块；
   * 56 时就多出一整块。写错填充的实现通常在 56 处出错（忘了「长度恰好
   * 是 56 也要补」），而 54 / 57 两侧能把这个错夹出来。
   */
  checkEqual('MD5 54 字节', md5Hex(encodeUtf8('a'.repeat(54))),
    'eced9e0b81ef2bba605cbc5e2e76a1d0');
  checkEqual('MD5 55 字节（恰好填满一块）', md5Hex(encodeUtf8('a'.repeat(55))),
    'ef1772b6dff9a122358552954ad0df65');
  checkEqual('MD5 56 字节（要多补一块）', md5Hex(encodeUtf8('a'.repeat(56))),
    '3b0c8ac703f828b04c6c197006d17218');
  checkEqual('MD5 57 字节', md5Hex(encodeUtf8('a'.repeat(57))),
    '652b906d60af96844ebd21b674f35e93');
  checkEqual('MD5 63 字节', md5Hex(encodeUtf8('a'.repeat(63))),
    'b06521f39153d618550606be297466d5');
  checkEqual('MD5 64 字节（整一块）', md5Hex(encodeUtf8('a'.repeat(64))),
    '014842d480b571495a4a0363793f7367');
  checkEqual('MD5 65 字节', md5Hex(encodeUtf8('a'.repeat(65))),
    'c743a45e0d2e6a95cb859adae0248435');
  checkEqual('MD5 119 字节', md5Hex(encodeUtf8('a'.repeat(119))),
    '8a7bd0732ed6a28ce75f6dabc90e1613');
  checkEqual('MD5 120 字节', md5Hex(encodeUtf8('a'.repeat(120))),
    '5f61c0ccad4cac44c75ff505e1f1e537');
  checkEqual('MD5 128 字节（两块）', md5Hex(encodeUtf8('a'.repeat(128))),
    'e510683b3f5ffe4093d021808bc6ff70');

  // 非 ASCII：摘要走的是 UTF-8 字节，不是 UTF-16 码元。若先按码元再摘要，
  // 这三条会全部对不上。
  checkEqual('MD5 中文', md5HexOfText('中文'), 'a7bac2239fcdcb3a067903d8077c4a07');
  checkEqual('MD5 中文标点', md5HexOfText('你好，世界'), 'dbefd3ada018615b35588a01e216ae6e');
  checkEqual('MD5 上课了', md5HexOfText('上课了'), 'fe2c17ba6318c8e23c34fd9fbeb24fe4');
  checkEqual('MD5 中英混排', md5HexOfText('A中B'), '1b172e5b28fbef1847b8d035db37d91b');
  // 四字节字符走 UTF-8（F0 9F 98 80），不是两个三字节的 CESU-8。
  checkEqual('MD5 emoji', md5HexOfText('😀'), '2a02eac39d716a70ecf37579185927b6');

  // md5HexOfText 必须就是 md5Hex(encodeUtf8(...))，不能自己另走一套编码。
  check('md5HexOfText 与 md5Hex∘encodeUtf8 一致',
    md5HexOfText('你好，世界😀') === md5Hex(encodeUtf8('你好，世界😀')));

  // 摘要永远是 32 位小写十六进制。
  checkNum('摘要长度 32', md5HexOfText('随便什么').length, 32);
  check('摘要是小写十六进制', /^[0-9a-f]{32}$/.test(md5HexOfText('随便什么')));

  // 差一个字符必须换一个摘要（不是「大致相同」）。
  check('差一个字符摘要不同', md5HexOfText('上课') !== md5HexOfText('下课'));
  // 大小写敏感。
  check('摘要大小写敏感', md5HexOfText('Abc') !== md5HexOfText('abc'));
  // 相同输入稳定。
  check('相同输入摘要稳定', md5HexOfText('同一句话') === md5HexOfText('同一句话'));
}

// --------------------------------------------------------------- 路径

function testCachePath(): void {
  const edge = { cacheFolder: 'EdgeTTS', cacheExtension: '' };
  const gpt = { cacheFolder: 'GPTSoVITS', cacheExtension: '.wav' };

  const expectedEdge: string =
    `/data/cache/EdgeTTS/zh-CN-XiaoxiaoNeural/${md5HexOfText('上课了')}`;
  checkEqual('EdgeTTS 路径（无后缀）',
    speechCachePath('/data/cache', edge, 'zh-CN-XiaoxiaoNeural', '上课了'), expectedEdge);
  checkEqual('GPT-SoVITS 路径（.wav）',
    speechCachePath('/data/cache', gpt, 'my_voice', '上课了'),
    `/data/cache/GPTSoVITS/my_voice/${md5HexOfText('上课了')}.wav`);

  // 根目录末尾的斜杠要收掉，否则会出现 '//'。
  checkEqual('根目录末尾斜杠被收掉',
    speechCachePath('/data/cache/', edge, 'v', 'x'), speechCachePath('/data/cache', edge, 'v', 'x'));
  checkEqual('根目录多个末尾斜杠被收掉',
    speechCachePath('/data/cache///', edge, 'v', 'x'), speechCachePath('/data/cache', edge, 'v', 'x'));

  // 稳定性与区分度。
  check('同文本同音色路径相同',
    speechCachePath('/c', edge, 'v', '上课') === speechCachePath('/c', edge, 'v', '上课'));
  check('不同文本路径不同',
    speechCachePath('/c', edge, 'v', '上课') !== speechCachePath('/c', edge, 'v', '下课'));
  check('不同音色路径不同',
    speechCachePath('/c', edge, 'v1', '上课') !== speechCachePath('/c', edge, 'v2', '上课'));
  check('不同提供方目录不同',
    speechCachePath('/c', edge, 'v', '上课') !== speechCachePath('/c', gpt, 'v', '上课'));

  // 文本不参与路径拼接，只出摘要 —— 所以文本里的 '/' 或 '..' 不会跑进路径。
  check('文本里的斜杠不进路径',
    speechCachePath('/c', edge, 'v', '../../etc/passwd').startsWith('/c/EdgeTTS/v/'));
}

function testSanitizeSegment(): void {
  // 正常音色原样通过（这是与桌面版路径保持一致的前提）。
  checkEqual('普通音色原样', sanitizeSegment('zh-CN-XiaoxiaoNeural'), 'zh-CN-XiaoxiaoNeural');
  checkEqual('下划线音色原样', sanitizeSegment('your_voice_name'), 'your_voice_name');
  checkEqual('中文音色原样', sanitizeSegment('默认音色'), '默认音色');

  // 路径分隔符与冒号。
  checkEqual('正斜杠换下划线', sanitizeSegment('a/b'), 'a_b');
  checkEqual('反斜杠换下划线', sanitizeSegment('a\\b'), 'a_b');
  checkEqual('冒号换下划线', sanitizeSegment('c:name'), 'c_name');
  checkEqual('NUL 换下划线', sanitizeSegment(utf16([0x61, 0, 0x62])), 'a_b');
  // 穿越片段整体被换掉。
  checkEqual('".." 被换掉', sanitizeSegment('..'), '_');
  checkEqual('"." 被换掉', sanitizeSegment('.'), '_');
  // '../../' 的每个分隔符换成下划线，得到 '.._.._' —— 它含 '..' 但不再是
  // 一个独立的穿越片段（段内的分隔符已经没了），所以落到「缓存根下某个名叫
  // .._.._ 的目录」里，出不了沙箱。这里断言的是这个保证本身，而不是逐字符
  // 的替换结果 —— 后者会随清洗规则的实现细节变，前者才是要守的。
  checkEqual('"../../" 只换分隔符', sanitizeSegment('../../'), '.._.._');
  checkEqual('空串被换掉', sanitizeSegment(''), '_');
  checkEqual('纯空白被换掉', sanitizeSegment('   '), '_');
  // 这三条是清洗存在的全部理由：结果不能逃出根目录。
  const dirty: string[] = ['../secret', '../../etc/passwd', 'a/../../b', 'C:\\Windows'];
  for (let i: number = 0; i < dirty.length; i++) {
    const cleaned: string = sanitizeSegment(dirty[i]);
    check(`清洗后无正斜杠：「${dirty[i]}」`, cleaned.indexOf('/') < 0);
    check(`清洗后无反斜杠：「${dirty[i]}」`, cleaned.indexOf('\\') < 0);
    check(`清洗后不是穿越片段：「${dirty[i]}」`, cleaned !== '..' && cleaned !== '.');
  }
}

// --------------------------------------------------------------- 提供方

function testProviders(): void {
  // 默认值与桌面版 Settings.cs:1847 逐字一致。
  checkEqual('默认提供方沿用桌面版', DEFAULT_SPEECH_PROVIDER, 'classisland.speech.edgeTts');
  checkEqual('默认音色沿用桌面版', DEFAULT_EDGE_TTS_VOICE, 'zh-CN-XiaoxiaoNeural');

  // id 字面量。GPT-SoVITS 那边是连字符不是驼峰，写错了就解析不到。
  checkEqual('系统 TTS id', SPEECH_PROVIDER_SYSTEM, 'classisland.speech.system');
  checkEqual('EdgeTTS id', SPEECH_PROVIDER_EDGE_TTS, 'classisland.speech.edgeTts');
  checkEqual('GPT-SoVITS id', SPEECH_PROVIDER_GPT_SOVITS, 'classisland.speech.gpt-sovits');

  /*
   * 本端实现了哪些。本阶段只有系统 TTS。
   *
   * 这里刻意断言另外两个**是** false：把它们标成 implemented 会让设置页显示
   * 成可用，用户选了之后一无所获 —— 而「选了不生效」比「选不了」难查得多。
   * 将来实现了一个就把这里一起改掉，让测试提醒去补 integration。
   */
  const impl: string[] = implementedSpeechProviders();
  check('系统 TTS 已实现（本阶段唯一）', impl.indexOf(SPEECH_PROVIDER_SYSTEM) >= 0);
  check('只有系统 TTS 标为已实现', impl.length === 1);
  check('EdgeTTS 未实现（微软私有协议）', impl.indexOf(SPEECH_PROVIDER_EDGE_TTS) < 0);
  check('GPT-SoVITS 未实现（需 HTTP + 音频渲染）',
    impl.indexOf(SPEECH_PROVIDER_GPT_SOVITS) < 0);
  check('未实现的提供方仍留在目录里（设置页要显示出来并注明）',
    findSpeechProvider(SPEECH_PROVIDER_EDGE_TTS) !== undefined);

  // 查名字。
  checkEqual('按 id 查显示名', speechProviderName(SPEECH_PROVIDER_SYSTEM), '系统 TTS');
  checkEqual('未知 id 原样返回', speechProviderName('classisland.speech.other'), 'classisland.speech.other');
  check('未知 id findSpeechProvider 返回 undefined',
    findSpeechProvider('nope') === undefined);

  // 缓存布局：EdgeTTS 无后缀，GPT-SoVITS 是 .wav。这两条要与桌面版一致。
  checkNum('EdgeTTS 无后缀', findSpeechProvider(SPEECH_PROVIDER_EDGE_TTS)!.cacheExtension.length, 0);
  checkEqual('GPT-SoVITS 后缀', findSpeechProvider(SPEECH_PROVIDER_GPT_SOVITS)!.cacheExtension, '.wav');

  /*
   * 解析：请求可用 → 用它；请求不可用而系统 TTS 可用 → 回退；
   * 都不可用 → 空串（静默）。
   */
  const bothAvailable: string[] = [SPEECH_PROVIDER_SYSTEM, SPEECH_PROVIDER_GPT_SOVITS];

  const direct: SpeechResolution = resolveSpeechProvider(SPEECH_PROVIDER_GPT_SOVITS, bothAvailable);
  checkEqual('请求可用则用它', direct.providerId, SPEECH_PROVIDER_GPT_SOVITS);
  check('请求可用不算回退', !direct.fellBack);

  // 默认值（EdgeTTS）本端不可用 —— 这是最常走的一条路径，必须有回退。
  const fallback: SpeechResolution = resolveSpeechProvider(DEFAULT_SPEECH_PROVIDER, bothAvailable);
  checkEqual('默认 EdgeTTS 回退到系统 TTS', fallback.providerId, SPEECH_PROVIDER_SYSTEM);
  check('回退被标记出来', fallback.fellBack);

  // 换一个不在表里的插件 id：同样回退，同样标记。
  const unknown: SpeechResolution = resolveSpeechProvider('some.plugin.provider', bothAvailable);
  checkEqual('未知插件 id 回退到系统 TTS', unknown.providerId, SPEECH_PROVIDER_SYSTEM);
  check('未知插件 id 标记回退', unknown.fellBack);

  // 空串是「没设过」，不是「用户选了一个不存在的东西」—— 回退但不标记，
  // 免得设置页对着一个空值说「你选的提供方不可用」。
  const unset: SpeechResolution = resolveSpeechProvider('', bothAvailable);
  checkEqual('空值也回退到系统 TTS', unset.providerId, SPEECH_PROVIDER_SYSTEM);
  check('空值不标记回退', !unset.fellBack);

  // 系统 TTS 也不可用（设备上没装引擎）→ 静默。
  const noneAvailable: string[] = [SPEECH_PROVIDER_GPT_SOVITS];
  const silent: SpeechResolution = resolveSpeechProvider(DEFAULT_SPEECH_PROVIDER, noneAvailable);
  checkEqual('系统 TTS 也不可用则静默', silent.providerId, '');
  check('静默不算回退', !silent.fellBack);

  // 只有请求的那个可用时照常用它。
  const onlyEdge: string[] = [SPEECH_PROVIDER_EDGE_TTS];
  checkEqual('只有 EdgeTTS 可用时用它',
    resolveSpeechProvider(SPEECH_PROVIDER_EDGE_TTS, onlyEdge).providerId, SPEECH_PROVIDER_EDGE_TTS);
  // 请求的不可用、系统也不可用、但 GPT-SoVITS 可用 —— 不回退到它。
  checkEqual('不回退到系统 TTS 以外的提供方',
    resolveSpeechProvider(SPEECH_PROVIDER_EDGE_TTS, [SPEECH_PROVIDER_GPT_SOVITS]).providerId, '');

  // 可用列表为空。
  checkEqual('可用列表为空则静默', resolveSpeechProvider('x', []).providerId, '');

  // 音量夹取。
  checkNum('音量 -1 夹到 0', clampSpeechVolume(-1), SPEECH_VOLUME_MIN);
  checkNum('音量 2 夹到 1', clampSpeechVolume(2), SPEECH_VOLUME_MAX);
  checkNum('音量 0.5 保持', clampSpeechVolume(0.5), 0.5);
  checkNum('音量 0 保持', clampSpeechVolume(0), 0);
  checkNum('音量 1 保持', clampSpeechVolume(1), 1);
  /*
   * 非有限值（NaN / ±Infinity）一律回落到**默认音量**，而不是夹到最近的边界。
   * 区别在于 -Infinity：夹边界会得到 0（静音），而静音与「设置文件坏了」难以
   * 区分 —— 用户看到一个音量滑块在中间，却没有声音。回落到默认值与桌面版的
   * 默认值一致，坏值退化成「刚装好的样子」，这是可解释的。
   */
  checkNum('音量 NaN 回落默认音量', clampSpeechVolume(Number.NaN), SPEECH_VOLUME_MAX);
  checkNum('音量 +Infinity 回落默认音量',
    clampSpeechVolume(Number.POSITIVE_INFINITY), SPEECH_VOLUME_MAX);
  checkNum('音量 -Infinity 回落默认音量（不是静音）',
    clampSpeechVolume(Number.NEGATIVE_INFINITY), SPEECH_VOLUME_MAX);
  check('默认音量就是满音量', SPEECH_VOLUME_MAX === 1);
}

function testNotificationGate(): void {
  // 三个开关全开才朗读。桌面版 NotificationWorkerService.cs:178 是这三个的与。
  check('三项全开 → 朗读', shouldSpeakNotification(true, true, true));

  // 任一关掉都不朗读。逐条列出来，因为这正是「默认静默」被打破的地方。
  check('全局关 → 不朗读', !shouldSpeakNotification(false, true, true));
  check('内容关 → 不朗读', !shouldSpeakNotification(true, false, true));
  check('通知朗读总开关关（桌面版默认）→ 不朗读',
    !shouldSpeakNotification(true, true, false));
  check('两项关 → 不朗读', !shouldSpeakNotification(true, false, false));
  check('仅总开关开 → 不朗读', !shouldSpeakNotification(false, false, true));
  check('全关 → 不朗读', !shouldSpeakNotification(false, false, false));
}

// --------------------------------------------------------------- 队列

/** 建一个队列 + 一个默认缓存路径，缩短测试里的样板。 */
function makeQueue(): SpeechQueue {
  return new SpeechQueue();
}

function testQueueBasics(): void {
  const queue: SpeechQueue = makeQueue();
  checkNum('空队列大小为 0', queue.size(), 0);
  check('空队列 isEmpty', queue.isEmpty());
  checkNum('空队列 advance 得到 Idle', queue.advance().kind, SpeechStepKind.Idle);
  check('空队列没有 current', queue.current() === undefined);

  // 未缓存 → Waiting；已缓存 → Ready。
  const pending: SpeechItem = queue.enqueue('第一句', '/c/a1', false);
  const ready: SpeechItem = queue.enqueue('第二句', '/c/a2', true);
  checkNum('未缓存项进入 Waiting', pending.state, SpeechItemState.Waiting);
  checkNum('已缓存项直接 Ready', ready.state, SpeechItemState.Ready);
  check('id 递增', ready.id > pending.id);
  checkNum('队列大小', queue.size(), 2);
  check('队列非空', !queue.isEmpty());

  // 队首未就绪 → Wait，且不消费。注意第二项已经 Ready 了也不许插队。
  const first: SpeechStep = queue.advance();
  checkNum('队首未就绪 → Wait', first.kind, SpeechStepKind.Wait);
  check('Wait 给出的是队首', first.item!.id === pending.id);
  checkNum('Wait 不消费队列', queue.size(), 2);
  check('Wait 时没有 current', queue.current() === undefined);

  // 标记就绪后再推进 → Play。
  queue.markState(pending.id, SpeechItemState.Ready);
  const play: SpeechStep = queue.advance();
  checkNum('就绪后 → Play', play.kind, SpeechStepKind.Play);
  check('Play 给出队首', play.item!.id === pending.id);
  check('Play 时 current 是它', queue.current()!.id === pending.id);
  checkEqual('Play 项的文本', play.item!.text, '第一句');

  // 播完摘掉，轮到第二项。
  queue.complete(pending.id);
  checkNum('播完后队列少一项', queue.size(), 1);
  check('播完后 current 清空', queue.current() === undefined);

  const second: SpeechStep = queue.advance();
  checkNum('第二项就绪直接 Play', second.kind, SpeechStepKind.Play);
  check('第二项是队首了', second.item!.id === ready.id);
  queue.complete(ready.id);
  checkNum('全部播完 → Idle', queue.advance().kind, SpeechStepKind.Idle);
  check('全部播完后 isEmpty', queue.isEmpty());
}

function testQueueOrder(): void {
  // FIFO：三项全 Ready，必须按入队顺序播。
  const queue: SpeechQueue = makeQueue();
  const a: SpeechItem = queue.enqueue('A', '/c/a', true);
  const b: SpeechItem = queue.enqueue('B', '/c/b', true);
  const c: SpeechItem = queue.enqueue('C', '/c/c', true);

  const order: string[] = [];
  for (let guard: number = 0; guard < 10; guard++) {
    const step: SpeechStep = queue.advance();
    if (step.kind === SpeechStepKind.Idle) {
      break;
    }
    order.push(step.item!.text);
    queue.complete(step.item!.id);
  }
  checkEqual('FIFO 顺序', order.join(''), 'ABC');
  check('a 排在 b 前', a.id < b.id && b.id < c.id);

  // 不去重：同一句话入队两次就念两遍。两节课打同一个铃，两声都该响。
  const dup: SpeechQueue = makeQueue();
  dup.enqueue('同一句', '/c/x', true);
  dup.enqueue('同一句', '/c/x', true);
  checkNum('同一文本重复入队不去重', dup.size(), 2);
  const firstDup: SpeechStep = dup.advance();
  checkEqual('重复项第一条', firstDup.item!.text, '同一句');
  dup.complete(firstDup.item!.id);
  const secondDup: SpeechStep = dup.advance();
  checkNum('重复项第二条仍会播', secondDup.kind, SpeechStepKind.Play);
  check('两条是不同 id', secondDup.item!.id !== firstDup.item!.id);
}

function testQueueSkip(): void {
  // 失败的项静默丢弃，不阻塞后面的项。
  const queue: SpeechQueue = makeQueue();
  const bad: SpeechItem = queue.enqueue('坏的', '/c/bad', false);
  const good: SpeechItem = queue.enqueue('好的', '/c/good', true);

  queue.markState(bad.id, SpeechItemState.Failed);
  const step: SpeechStep = queue.advance();
  checkNum('失败的项被跳过，直接播下一项', step.kind, SpeechStepKind.Play);
  check('播的是下一项', step.item!.id === good.id);
  checkNum('失败的项已离开队列', queue.size(), 1);

  // 中途某项失败：队首 Ready 先播，播完后失败的被跳过。
  const mid: SpeechQueue = makeQueue();
  const first: SpeechItem = mid.enqueue('一', '/c/1', true);
  const second: SpeechItem = mid.enqueue('二', '/c/2', false);
  const third: SpeechItem = mid.enqueue('三', '/c/3', true);
  checkNum('先播第一项', mid.advance().kind, SpeechStepKind.Play);
  mid.complete(first.id);
  checkNum('第二项未就绪 → Wait', mid.advance().kind, SpeechStepKind.Wait);
  mid.markState(second.id, SpeechItemState.Failed);
  const afterFail: SpeechStep = mid.advance();
  checkNum('第二项失败后直接播第三项', afterFail.kind, SpeechStepKind.Play);
  check('播的是第三项', afterFail.item!.id === third.id);
}

function testQueueCancel(): void {
  const queue: SpeechQueue = makeQueue();
  const a: SpeechItem = queue.enqueue('一', '/c/1', true);
  const b: SpeechItem = queue.enqueue('二', '/c/2', true);
  const c: SpeechItem = queue.enqueue('三', '/c/3', false);

  // 先让第一项进入播放中。
  const playing: SpeechStep = queue.advance();
  check('第一项在播', queue.current()!.id === a.id);

  const cancelled: number[] = queue.cancelAll();
  checkNum('取消返回全部项', cancelled.length, 3);
  check('取消含正在播的那一项', cancelled.indexOf(a.id) >= 0);
  check('取消含未就绪的那一项', cancelled.indexOf(c.id) >= 0);
  check('取消含排队中的那项', cancelled.indexOf(b.id) >= 0);

  // 全部作废，下一次推进直接 Idle。
  checkNum('取消后 advance → Idle', queue.advance().kind, SpeechStepKind.Idle);
  check('取消后队列空', queue.isEmpty());
  check('取消后没有 current', queue.current() === undefined);

  // 取消之后再 markState 不许把项复活。
  queue.markState(b.id, SpeechItemState.Ready);
  checkNum('取消后 markState 不复活', queue.advance().kind, SpeechStepKind.Idle);

  // 队列取消后仍可继续用。
  const d: SpeechItem = queue.enqueue('四', '/c/4', true);
  const after: SpeechStep = queue.advance();
  checkNum('取消后重新入队仍可播', after.kind, SpeechStepKind.Play);
  check('播的是新入队的那项', after.item!.id === d.id);
}

function testQueueNoReorder(): void {
  /*
   * 不重排。队首还在合成时，后面已经缓存好的项不许插队 —— 桌面版的
   * ProcessPlayerList 会 await 队首的下载任务，就是这个行为。插队会让朗读
   * 顺序与课表顺序错开，听起来像是念错了课。
   */
  const queue: SpeechQueue = makeQueue();
  const slow: SpeechItem = queue.enqueue('慢的', '/c/slow', false);
  queue.enqueue('快的', '/c/fast', true);

  for (let i: number = 0; i < 3; i++) {
    const step: SpeechStep = queue.advance();
    checkNum('队首合成中反复推进仍是 Wait', step.kind, SpeechStepKind.Wait);
    check('Wait 始终指着慢的那一项', step.item!.id === slow.id);
  }
  checkNum('反复 Wait 不消费队列', queue.size(), 2);

  // 慢的好了之后仍然是它先播。
  queue.markState(slow.id, SpeechItemState.Ready);
  const step: SpeechStep = queue.advance();
  checkNum('慢的好了先播', step.kind, SpeechStepKind.Play);
  check('先播的是慢的那项', step.item!.id === slow.id);
}

function testQueueSnapshot(): void {
  const queue: SpeechQueue = makeQueue();
  const item: SpeechItem = queue.enqueue('原文', '/c/x', false);

  const snap: SpeechItem[] = queue.snapshot();
  checkNum('快照条数', snap.length, 1);
  checkEqual('快照文本', snap[0].text, '原文');
  checkNum('快照状态', snap[0].state, SpeechItemState.Waiting);

  // 改快照不影响队列。
  snap[0].text = '改过的';
  snap[0].cancelled = true;
  checkEqual('改快照不影响队列里的文本', queue.findById(item.id)!.text, '原文');
  check('改快照不影响队列里的作废标记', !queue.findById(item.id)!.cancelled);
  check('快照是副本不是同一对象', snap[0] !== queue.findById(item.id));
}

function testQueueStateMarking(): void {
  const queue: SpeechQueue = makeQueue();
  const item: SpeechItem = queue.enqueue('x', '/c/x', false);

  // Waiting → Generating → Ready。中间态只影响 advance 的分支（都走 Wait）。
  queue.markState(item.id, SpeechItemState.Generating);
  checkNum('Generating 也走 Wait', queue.advance().kind, SpeechStepKind.Wait);
  checkNum('Generating 状态已写入', queue.findById(item.id)!.state, SpeechItemState.Generating);
  queue.markState(item.id, SpeechItemState.Ready);
  checkNum('Ready 后走 Play', queue.advance().kind, SpeechStepKind.Play);

  // 对不存在的 id 标记状态：静默忽略（合成回来时项可能已被清掉）。
  queue.markState(9999, SpeechItemState.Ready);
  check('对不存在的 id markState 不抛异常', true);
  queue.complete(9999);
  check('对不存在的 id complete 不抛异常', true);
  checkNum('对不存在的 id 操作后队列不变', queue.size(), 1);
}

function testQueueTimeoutConstant(): void {
  /*
   * 15 秒与桌面版一致。钉住它是因为这个值同时约束着别处：合成超时=提醒的
   * 时效窗口，一次迟到的朗读比不朗读更糟（课已经开始上了）。改动它需要
   * 连着复核提醒链路，所以不该是随手调的数。
   */
  checkNum('合成超时 15 秒', SPEECH_GENERATION_TIMEOUT_MS, 15000);
}

// --------------------------------------------------------------- 入口

testUtf8();
testMd5();
testCachePath();
testSanitizeSegment();
testProviders();
testNotificationGate();
testQueueBasics();
testQueueOrder();
testQueueSkip();
testQueueCancel();
testQueueNoReorder();
testQueueSnapshot();
testQueueStateMarking();
testQueueTimeoutConstant();

console.log(`语音朗读 通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('');
  for (const failure of failures) {
    console.log(`✗ ${failure}`);
  }
}
