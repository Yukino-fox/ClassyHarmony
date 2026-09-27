# 品牌与外显

本文件记录 ClassyHarmony 的**外显名与图标**约定。这套约定对本工作区后续的
鸿蒙工程一律适用。

## 一、外显名：`ClassIsland`

与桌面端对齐（`ClassIsland/ClassIsland/ClassIsland.csproj` 里
`<AssemblyName>ClassIsland</AssemblyName>`）。工程目录名、bundle 名、
代码里的日志 TAG 仍叫 `ClassyHarmony` / `classyharmony` —— 那是工程标识，
不是外显名，两者刻意不合并。

外显名有两处，**必须同时改**，漏一处会在某些场景露出旧名：

| 位置 | 资源 | 作用 |
| --- | --- | --- |
| `AppScope/resources/base/element/string.json` → `app_name` | `$string:app_name` | 桌面图标下方、应用列表、最近任务 |
| `entry/src/main/resources/base/element/string.json` → `EntryAbility_label` | `$string:EntryAbility_label` | ability 级 label，会在部分启动器/任务卡片上**覆盖** app 级 label |

`AppScope/app.json5` 的 `vendor` 也从模板遗留的 `example` 改成 `yukinoFox`
（对应 `com.yukinofox.*`）。

## 二、图标

源文件：`Resources/classisland.svg`（矢量，与桌面端 `Assets/AppLogo.ico` 同源图形；
`.ico` 最大只有 256×256，SVG 才是可放大的那一份）。

生成：`tools/make-app-icon.sh`。**不要手改生成出来的 PNG**，改 SVG 或改脚本参数。

```bash
CONTENT_FRAC=0.60 bash tools/make-app-icon.sh   # 当前取值 0.60
```

产物：

| 文件 | 尺寸 | 谁引用 |
| --- | --- | --- |
| `AppScope/resources/base/media/{foreground,background}.png` | 1024×1024 | `app.json5` 的 `$media:layered_image` |
| `entry/src/main/resources/base/media/{foreground,background}.png` | 1024×1024 | `module.json5` 的 `$media:layered_image` |
| `entry/src/main/resources/base/media/startIcon.png` | 144×144 | `module.json5` 的 `startWindowIcon` |

AppScope 与 entry **各要一份**：两处都写 `$media:layered_image`，但资源不共享，
只在各自模块的 `media/` 下解析。`startIcon` 只有 `module.json5` 引用，
AppScope 侧不放（那是没人读的死资源）。

### 三条不能想当然的实测结论

**1. 源 SVG 里的 `feDropShadow` 必须剥掉，否则渲染结果是全透明。**
该元素是 SVG 2 原语，Inkscape 1.x 不认，遇到就把整张图渲染成
`alpha 极值 (0,0)` 的空图，**且只打一行 warning 不报错**（脚本里已做净化，
并断言渲染结果非全透明）。顺带说明：本层阴影本来也不该要，系统自己会给图标加阴影。

**2. 前景层不能满幅。** 系统按遮罩裁形并对前景层做视差放大，图形要收在中心安全区内。
参考 DevEco 模板：它自带的 `foreground.png` 内容只占画布 **44.5%**（96/216）。
本工程取 `CONTENT_FRAC=0.60`，比模板大一点、观感更满，但仍在中心区内。

**3. 底板必须够暗。** logo 主体是浅灰（`#F6F6F6` / `#959595`），
模板那套蓝底（`#2C79F4`）配上去对比度只有约 1.4:1，不可用。
当前用深青蓝渐变 `#10495E → #061F2C`，与 logo 的青色 `#00BFFF` 呼应，
最暗处对浅灰约 5.2:1、最亮处约 3.1:1。

### 打包后会被缩到 512

`assembleHap` 的资源编译阶段会把 `media` 里的 PNG 统一压到 **512×512**
（这是资源工具的固定行为，`resOptions` 只有 `compression` 一项、管的是
json/xml 文本资源，改不了）。512 仍高于鸿蒙最大启动器图标（约 432），
不需要绕。

## 三、改名/改图标后的验证顺序

```bash
bash tools/make-app-icon.sh                                  # 1. 重新生成
hvigorw ... -p module=entry@default assembleHap              # 2. 构建
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell snapshot_display -f /data/local/tmp/s.jpeg        # 3. 回桌面截图肉眼核对
```

第 3 步只需要「装得上 + 桌面有图标」，**不需要把应用拉起来** ——
所以在真机被占用、或拉起被应用管控拦下时，图标照样能核对。
