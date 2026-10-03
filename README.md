<!--markdownlint-disable MD001 MD033 MD041 MD051-->

<div align="center">

# <img src="Resources/classisland.svg" height="28" width="28"/> ClassyHarmony

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-API%2012%2B-black?style=flat-square)](https://developer.huawei.com/consumer/cn/doc/harmonyos-references)
[![ArkTS](https://img.shields.io/badge/ArkTS-strict-blue?style=flat-square)](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides)
[![Tests](https://img.shields.io/badge/tests-16%20suites%20%E2%80%A2%203888%20asserts-brightgreen?style=flat-square)](#开发)
[![Repo size](https://img.shields.io/github/repo-size/Yukino-fox/ClassyHarmony?style=flat-square&color=3cb371)](https://github.com/Yukino-fox/ClassyHarmony)
[![GitHub Repo Languages](https://img.shields.io/github/languages/top/Yukino-fox/ClassyHarmony?style=flat-square)](https://github.com/Yukino-fox/ClassyHarmony)
[![License](https://img.shields.io/badge/license-GPL--3.0-3fb950?style=flat-square)](https://www.gnu.org/licenses/gpl-3.0.html)

</div>

>[!IMPORTANT]
>
>本项目基于[ClassIsland](https://github.com/ClassIsland/ClassIsland)，亦可称为是classisland的鸿蒙移植版。

<div align="center">

ClassIsland 是一款适用于班级多媒体屏幕的跨平台课表信息显示工具，可以在 Windows PC、Mac 及 Linux 设备屏幕上显示各种信息。<br/>
本应用的名字灵感源于 iOS 灵动岛（Dynamic Island）功能。

**ClassyHarmony 是它的鸿蒙原生重写。** 

#### [🌐 上游官网](https://classisland.tech/) | [📚 上游文档](https://docs.classisland.tech) | [🚀 上游下载](https://classisland.tech/download) 

</div>

> [!NOTE]
> 外显名沿用 `ClassIsland`，
> 工程标识与 bundle 才是 `ClassyHarmony` / `com.yukinofox.classyharmony` —— 两者刻意不合并，
> 详见 [`docs/branding.md`](docs/branding.md)。

## 功能

> [!TIP]
>
> 本表按「鸿蒙侧实际做到哪一步」标注：
> `- [x]` 已实现，`- [ ]` 未移植（多为桌面平台专属）。

### 课表信息显示

- [x] 显示当天的课表、当前进行课程的信息，手机 / 平板 / 2in1 三形态自适应
- [x] 在上下课等重要时间点发出提醒，支持提前量、额度降级与差异比对
- [x] 提醒可搭配 [TTS 语音朗读](entry/src/main/ets/speech)，走系统引擎
- [x] 自选课表隐藏条件与临时隐藏：面板按规则隐藏 + 手动隐藏行，不影响授课
- [ ] 鼠标穿透 _（桌面平台专属）_

### 课表编辑与管理

- [x] 科目 / 时间表 / 课表 / 课表群 / 预定调课五个分页的编辑工具
- [x] 档案 JSON 导入与导出，**与桌面版逐字节互通**
- [x] 多周轮换、快速录入时间表、自定义设置
- [x] 单日 / 跨天临时换课
- [x] 提前预定要临时启用的课表（临时层）
- [ ] 从 Excel 表格或 [CSES](https://github.com/SmartTeachCN/CSES) 导入课表、导出到 Excel

### 自定义

- [x] 通过组件自定义显示的内容：时钟、日期、课程表、倒计时、天气简报、文本、分割线
- [x] 容器组件支持嵌套、多行与轮播 / 滚动：分组、堆叠、轮播、滚动
- [x] 通过组件布局编辑页自由增删、排序与配置
- [x] 通过声明式扩展（`.cipx`）扩展组件 / 触发器 / 行动 / 通知提供者 / 主题
- [x] 明暗主题：跟随系统 / 浅色 / 深色三档
- [ ] 主题系统高度定制主界面外观 _（仅实现了明暗，未实现自定义配色）_

### 其它功能

- [x] 通过自动化在特定事件发生时 / 特定时间自动执行某些操作（显示提醒、等待时长、跳转设置页等）
- [x] 显示当前的天气信息、降雨倒计时与天气简报，支持按定位取天气，
      气象预警按上游同样的规则筛选与去重
- [x] NTP 自动同步软件时间，手动对齐并显示偏差
- [x] 桌面卡片（今日课程表），卡片上的推导全部在 `common_core` 纯函数里
- [x] **跨设备公开状态**：其他应用可通过 Want 查询当前课程与档案摘要（鸿蒙侧新增）
- [x] 中文 / English 双语，随系统语言切换
- [ ] 使用密码等认证方式保护应用设置和课表配置
- [ ] 自动软件更新
- [ ] 集控管理 _（上游亦未发布）_

## 开始使用

**首先，请确保您的设备满足以下要求：**

- HarmonyOS 5.0（API 12）及以上
- 支持的设备形态：`phone` / `tablet` / `2in1`
- 已开启开发者模式与 USB / 无线调试

> [!IMPORTANT]
> **本项目不提供下载渠道，只能自行构建后侧载。**
>
> 构建前必须先把调试签名接进工程 —— 签名材料只能来自 AppGallery Connect，
> 自签 p7b 过不了设备侧的 CMS 校验。实测结论与完整步骤见
> **[`docs/signing.md`](docs/signing.md)**。


## 获取帮助＆加入社区

本项目是个人向的重写，没有独立的社区。遇到问题：

- 先确认是不是本工程的问题，还是上游共有的行为 —— 上游文档在
  [docs.classisland.tech](https://docs.classisland.tech)
- 确认是本工程的 Bug 或有新功能想法，请
  [提交 Issue](https://github.com/Yukino-fox/ClassyHarmony/issues)
- 上游本体的问题请到 [ClassIsland/ClassIsland](https://github.com/ClassIsland/ClassIsland/issues) 反馈， ~~虽然说我也不知道上游会出现什么问题就是了~~
-

## 开发

```
AppScope/            应用级配置（bundle、图标、app_name）
│
common_shared/  HAR  共享数据层 ← 对应 ClassIsland.Shared
│                   档案数据模型、自研 JSON 内核、集合、枚举、多语言 I18n
│                   禁止依赖 UI / 音频 / 媒体 / 后台任务（卡片进程会引用它）
│
common_core/    HAR  核心引擎层 ← 对应 ClassIsland.Core
│                   依赖 common_shared
│                   课表引擎与状态机、编辑改动层、面板渲染模型、规则与自动化、
│                   提醒编排、精确时间、天气、语音、插件注册表、组件布局、IPC 协议
│                   纯函数为主，可脱离设备单独测
│
entry/          HAP  应用壳与平台接线
                  ArkUI 页面、ViewModel、Ability / 卡片扩展、系统能力调用
```

依赖方向单向向下：`entry → common_core → common_shared`，**没有反向依赖**。

### 常用命令

| 目的 | 命令 |
| --- | --- |
| 构建 HAP | `hvigorw --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon` |
| 构建 HAR | `hvigorw --mode module -p product=default -p buildMode=debug assembleHar --no-daemon` |
| 代码检查 | `codelinter -c code-linter.json5 -p default .` |
| 单元测试台 | `bash tools/nodetest/run.sh` |
| 装模拟器 | `bash tools/run-on-emulator.sh` |
| 生成应用图标 | `bash tools/make-app-icon.sh` |

### 测试

```bash
bash tools/nodetest/run.sh
```


**怎么做的**：脚本把 `common_shared` / `common_core` 的**真实源码**拷进临时工作区，
用 `tsc` 剥掉类型后在 Node 里跑 —— 这些文件只用 TypeScript 层语法
（class / 类型标注 / 泛型 / enum），剥类型后运行期语义与 ArkTS 一致。
三份 `string.json` 会合并成一张资源表喂给桩，所以断言里写的**是中文原文而不是 key**，
与真机表现一致。

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
| 自动化链路 | 268 | cron、触发器、判据、条件恢复 |
| 精确时间 | 186 | NTP 纪元换算、偏差公式、冻结 |
| 语音朗读 | 195 | UTF-8 / MD5 / 提供方选择 / 队列 |
| 天气 | 325 | 码表、预警筛选、日出日落、简报 |
| 跨设备 | 83 | 会话 ID、事件映射、快照编解码 |
| 后台保活 | 25 | 长时任务类型选择、错误码翻译 |
| 插件系统 | 467 | 版本闸、校验、日程、模板、装卸、端到端 |

> ArkTS 语言层合规性由 codelinter 把关，测试台抓「逻辑错」，两者互补。

### 进度

| 阶段 | 内容 |
| --- | --- |
| P0 | 基线工程脚手架（4 模块） |
| P1 | 档案数据模型 + 自研 JSON 内核 |
| P2 | 课表引擎与课程状态机 |
| P3 | 应用内课表页 |
| P4 | 科目 / 课表 / 作息 / 课表群编辑，档案改动层 |
| P5 | 桌面卡片（今日课程表） |
| P6 | 课前提醒 |
| P7 | 信息面板：组件布局编排、布局编辑、面板渲染 |
| P8 | 规则模型 + 三态求值器 + 面板按规则隐藏 + 自动化链路 |
| P9 | 通知系统 |
| P10 | 设置页与设置项扩展、明暗主题、宽屏收口 |
| P11 | NTP 精确时间、TTS 朗读、天气、跨设备公开状态、后台保活 |
| P12 | 声明式插件系统（core 校验 / 存储 / `.cipx` 迁移 / 设置页 UI） |
| i18n | 全工程 UI 文案 `t()` / `tf()` 化，中英双语资源 |


### 文档

| 文档 | 内容 |
| --- | --- |
| [`docs/branding.md`](docs/branding.md) | 外显名与图标：分层图标两处 label、底板配色、生成脚本 |
| [`docs/signing.md`](docs/signing.md) | 签名与构建：为什么必须用 AGC 材料、离线签名的天花板 |
| [`docs/widget.md`](docs/widget.md) | 桌面卡片：分层结构、三种「不报错只是空白」的坑 |

## 致谢

本项目受到 [ClassIsland](https://github.com/ClassIsland/ClassIsland) 的启发，
没有它就没有这个重写 —— 感谢 [HelloWRC](https://github.com/HelloWRC) 与
[全体贡献者](https://github.com/ClassIsland/ClassIsland/graphs/contributors) 的工作。

上游项目又受 [DuguSand/class_form](https://github.com/DuguSand/class_form) 启发而开发。

本仓库**不含上游任何源代码**，属于独立重写实现：
模型 JSON 结构、规则语义、cron 解析、预警去重顺序等行为按上游观测对齐，
其余全部按 ArkTS 的语法约束与生命周期重写。

## 许可证

本项目全部模块（`common_shared` / `common_core` / `entry` 及工具脚本）基于
[GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html) 获得许可，
与上游一致（见各模块 `oh-package.json5` 的 `license` 字段）。

## Stars 历史

[![Star 历史](https://starchart.cc/Yukino-fox/ClassyHarmony.svg?variant=adaptive)](https://starchart.cc/Yukino-fox/ClassyHarmony)

<div align="center">

如果这个项目对您有帮助，请点亮 Star ⭐

</div>
