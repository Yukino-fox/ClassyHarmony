<div align="center">

# <img src="Resources/classisland.svg" height="28" width="28"/> ClassyHarmony

**ClassIsland 的 HarmonyOS 原生重写** —— ArkTS + ArkUI，零代码复用

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-API%2026-black)](https://developer.huawei.com/consumer/cn/doc/harmonyos-references)
[![ArkTS](https://img.shields.io/badge/ArkTS-strict-blue)](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides)
[![License](https://img.shields.io/badge/license-GPL--3.0-green)](https://www.gnu.org/licenses/gpl-3.0.html)

</div>

---

## 一、这是什么

[ClassIsland](https://github.com/ClassIsland/ClassIsland) 是一款跨平台课表信息显示工具。
本仓库把它**从零重写**成一个鸿蒙原生应用：不移植、不复用一行 C#，
`common_shared` / `common_core` / `entry` 全部按 ArkTS 的语法约束与生命周期重写，
但**档案 JSON 与桌面版逐字节互通** —— 手机上排好的课表丢回桌面版照样能读。

> **不做上架**，只在自己的设备上装 debug 包调试。

### 外显名与工程标识

两者**刻意不合并**，改名时别弄混（详见 [`docs/branding.md`](docs/branding.md)）：

| | 值 | 用在哪 |
| --- | --- | --- |
| 外显名 | `ClassIsland` | 桌面图标下方、应用列表、最近任务 |
| 工程标识 | `ClassyHarmony` | 目录名、日志 TAG、代码风格 |
| bundle | `com.yukinofox.classyharmony` | 安装包身份 |

---

## 二、当前状态

P0 → P12 全阶段已提交，全工程 UI 文案已 key 化。

| 阶段 | 内容 |
| --- | --- |
| P0 | 基线工程脚手架（4 模块） |
| P1 | 档案数据模型 + 自研 JSON 内核 |
| P2 | 课表引擎与课程状态机 |
| P3 | 应用内课表页（三形态自适应） |
| P4 | 科目 / 课表 / 作息 / 课表群编辑，档案改动层 |
| P5 | 桌面卡片（今日课程表） |
| P6 | 课前提醒 |
| P7 | 信息面板：组件布局编排、布局编辑、面板渲染 |
| P8 | 规则模型 + 三态求值器 + 面板按规则隐藏 + 自动化链路 |
| P9 | 通知系统 |
| P10 | 设置页与设置项扩展、主题服务、宽屏收口 |
| P11 | NTP 精确时间、TTS 朗读、天气、跨设备公开状态、后台保活 |
| P12 | 声明式插件系统（core 校验 / 存储 / `.cipx` 迁移 / 设置页 UI） |
| i18n | 全工程 UI 文案 `t()` / `tf()` 化，中英双语资源 |

**设备形态**：`phone` / `tablet` / `2in1`（`module.json5` 里 `deviceTypes` 就这三项）。

---

## 三、模块架构

```
AppScope/            应用级配置（bundle、图标、app_name）
│
common_shared/  HAR   共享数据层  ← 对应 ClassIsland.Shared
│                    档案数据模型、自研 JSON 内核、集合、枚举、多语言 I18n
│                    无 UI / 无音频 / 无媒体 / 无后台任务依赖
│
common_core/    HAR   核心引擎层  ← 对应 ClassIsland.Core
│                    依赖 common_shared
│                    课表引擎、状态机、编辑改动层、面板渲染模型、
│                    规则与自动化、提醒编排、精确时间、天气、
│                    语音、插件注册表、组件布局、IPC 协议
│                    纯函数为主，可脱离设备单独测
│
entry/          HAP   应用壳与平台接线
                       ArkUI 页面、ViewModel、Ability / 卡片扩展、
                       系统能力调用（通知、后台、文件、分布式、TTS）
```

依赖方向单向向下：`entry → common_core → common_shared`，**没有反向依赖**。

页面（`main_pages.json`）：

```
pages/Index            主界面（今日课表 + 信息面板）
pages/Editor           编辑页导航壳 → editor/ 七个分页
pages/Panel            信息面板布局编辑
pages/Automation       自动化列表
pages/WorkflowEditor   工作流编辑
pages/Settings         设置页
```

扩展能力：`EntryFormAbility`（桌面卡片）、`EntryBackupAbility`（备份恢复）。

### 代码规模

| 模块 | `.ets` 文件 | 行数 |
| --- | ---: | ---: |
| `common_shared` | 35 | ~6.2k |
| `common_core` | 53 | ~16.1k |
| `entry` | 68 | ~21.0k |
| `tools/nodetest`（TypeScript） | 16 | ~16.2k |

---

## 四、构建与安装

### 依赖

- DevEco Studio **26.0.0.621**（SDK API **26**）
- `node`（测试台用 `tsc` 剥类型）
- 仓库根的 `.env` 记着 `DEVECO_HOME`，`.certs/` 与 `~/.ohos/config/` 存签名材料，**均不入库**

### 真机

```bash
export DEVECO_SDK_HOME=/mnt/data/devecostudio-26.0.0.621/sdk

# 1. 构建签名包
hvigorw --mode module -p product=default -p module=entry@default \
        -p buildMode=debug assembleHap --no-daemon

# 2. 连设备（无线调试）+ 安装
hdc tconn 192.168.3.2:35015
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap

# 3. 拉起来
hdc shell aa start -a EntryAbility -b com.yukinofox.classyharmony
```

HAR 单独出包用 `assembleHar`；代码风格检查：

```bash
codelinter -c code-linter.json5 -p default .
```

### 模拟器

```bash
bash tools/run-on-emulator.sh                # 默认 127.0.0.1:5557
EMU_SERIAL=127.0.0.1:5555 tools/run-on-emulator.sh
SKIP_BUILD=1 tools/run-on-emulator.sh        # 只装不编
```

模拟器镜像最高只到 HarmonyOS 6.1.1（API 24），脚本会临时把
`compatibleSdkVersion` 降到 24 编一版，**装完自动还原**（失败也还原）。

### 签名

调试签名必须来自 AGC，自签 p7b 过不了设备侧 `bm` 的 CMS 校验
（`code:9568257 fail to verify pkcs7 file`）。实测结论与签名链详见
[`docs/signing.md`](docs/signing.md)，相关脚本：

```bash
bash tools/apply-signing.sh        # 把 DevEco 自动签名材料接进 build-profile.json5
bash tools/selftest-signing.sh     # 复现「构建不验签、装机才验签」的实验
```

---

## 五、测试

```bash
bash tools/nodetest/run.sh
```

**为什么不上设备测**：ArkTS 侧要走 Local Test（`ohosTest`），但工程含 HAR 模块，
没有华为侧 p7b 材料时连任务图都建不起来；而本机模拟器是 API 24，装不下目标 26 的包。

**怎么做的**：脚本把 `common_shared` / `common_core` 的**真实源码**拷进临时工作区，
用 `tsc` 剥掉类型后在 Node 里跑 —— 这些文件只用 TypeScript 层语法
（class / 类型标注 / 泛型 / enum），剥类型后运行期语义与 ArkTS 一致。
`string.json` 会按模块合并成一张资源表喂给桩，所以断言里写的**是中文原文，不是 key**，
与真机上的表现一致。

当前 **16 套 / 3888 项断言**，全绿退出码 0：

| 套件 | 项数 | 覆盖 |
| --- | ---: | --- |
| 字节级往返 | 94 | JSON 编解码保真 |
| 课表引擎 | 192 | 状态机、轮转、临时层 |
| 课表网格 | 161 | 网格视图数据推导 |
| 档案改动 | 605 | 改动自洽性与落盘往返 |
| 小组件 | 120 | 卡片推导与编解码 |
| 课前提醒 | 135 | 触发时刻、额度降级、差异比对 |
| 组件布局 | 339 | 往返保真、注册表、增删移 |
| 面板渲染 | 264 | 倒计时格式、样式合成、深度上限 |
| 规则求值 | 429 | 三态、短路、逐层取反 |
| 自动化链路 | 268 | cron、八触发器、四判据、条件恢复 |
| 精确时间 | 186 | NTP 纪元换算、偏差公式、冻结 |
| 语音朗读 | 195 | UTF-8 / MD5 / 提供方选择 / 队列 |
| 天气 | 325 | 码表、预警筛选、日出日落、简报 |
| 跨设备 | 83 | 会话 ID、事件映射、快照编解码 |
| 后台保活 | 25 | 长时任务类型选择、错误码翻译 |
| 插件系统 | 467 | 版本闸、校验、日程、模板、装卸、端到端 |

> ArkTS 语言层合规性由 codelinter 把关，测试台抓「逻辑错」，两者互补。

---

## 六、多语言

- `t('key')` 取文案，`tf('key', a, b)` 带 `{0}` / `{1}` 占位，逐个 `replace`
- 实现在 `common_shared/src/main/ets/i18n/I18n.ets`，走 `resourceManager.getStringByNameSync`，
  语言回落由资源管理器接管，切换语言时 `clearCache()`
- 资源按模块落：`common_shared` → `common_shared` 6 键、`common_core` → 314 键、`entry` → 816 键，
  `base`（中文）与 `en_US`（英文）键名必须一一对应
- **不分 key 的**：`hilog.` / `throw` / `problems.push` 这类日志与异常、
  数据哨兵（`（未命名档案）`、`（临时层）`、`是`/`否`）、`Subject.ets` 的复姓数据表

---

## 七、文档

| 文档 | 内容 |
| --- | --- |
| [`docs/branding.md`](docs/branding.md) | 外显名与图标：分层图标两处 label、底板配色、生成脚本 |
| [`docs/signing.md`](docs/signing.md) | 签名与构建：为什么必须用 AGC 材料、离线签名的天花板 |
| [`docs/widget.md`](docs/widget.md) | 桌面卡片：分层结构、三种「不报错只是空白」的坑 |

---

## 八、与桌面版的互通

`common_shared` 的模型编解码是**按桌面版 JSON 结构手写的**，落盘时顶层字段用
PascalCase 扁平结构，天气 / 扩展清单 / 插件清单用 camelCase —— 与桌面版读写同一批字段。
测试台的 `字节级往返` / `档案改动` 两套断言就是这件事的守门员：
任何让 JSON 变样的改动都会在装机之前被拦下。

---

## 九、许可

GPL-3.0（见各模块 `oh-package.json5` 的 `license` 字段）。

上游 [ClassIsland](https://github.com/ClassIsland/ClassIsland) 同为 GPL-3.0。
本仓库不含其任何源代码，属于独立重写实现。
