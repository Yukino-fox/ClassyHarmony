#!/usr/bin/env bash
#
# 由 Resources/classisland.svg 生成 HarmonyOS 应用图标全套资源。
#
# 产出（两个模块各一份，AppScope 与 entry 都要，缺一个装机就掉图标）：
#   resources/base/media/background.png     1024x1024 不透明底板
#   resources/base/media/foreground.png     1024x1024 透明前景层（居中 logo）
#   entry/.../media/startIcon.png             144x144  启动页图标（带底板）
#   resources/base/media/layered_image.json  分层图描述（已存在则不覆盖）
#
# 为什么要有这个脚本，而不是直接把 svg 拷进 media/：
#   1. 分层图标的**前景层不能满幅**。系统按遮罩裁形 + 前景层视差放大，
#      图形必须收在中心安全区内，否则圆形/圆角遮罩会切掉 logo 四角。
#      DevEco 模板自带的前景色内容只占画布 44.5%（96/216），本脚本默认取 50%，
#      介于模板与「看起来大一点」之间，可用 CONTENT_FRAC 调。
#   2. logo 主体是**浅灰**（#F6F6F6 / #959595），底板必须够暗才有对比度。
#      模板那套蓝底（#2C79F4）配上去对比度只有 1.4:1，不可用。
#   3. HarmonyOS 的 media 资源不支持 SVG 作应用图标，必须栅格化成 PNG。
#
# 幂等：可反复执行，覆盖式重写上面几个 PNG，不动其它资源。
#
# 调参（都可用环境变量覆盖）：
#   CONTENT_FRAC   前景层 logo 占画布边长的比例，默认 0.50
#   BG_TOP/BG_BOT  底板渐变上/下色，默认 #10495E / #061F2C
#   START_FRAC     启动页图标里 logo 的占比，默认 0.60
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SRC:-$ROOT/Resources/classisland.svg}"

CONTENT_FRAC="${CONTENT_FRAC:-0.50}"
BG_TOP="${BG_TOP:-#10495E}"
BG_BOT="${BG_BOT:-#061F2C}"
START_FRAC="${START_FRAC:-0.60}"

CANVAS=1024
RENDER=4096          # 先高分辨率渲染再缩，避免内缩时糊边
START_SIZE=144
ALPHA_TRIM=2         # alpha 高于此值才算内容，用来裁掉渐变尾巴

say() { printf '\033[1;36m%s\033[0m\n' "$*"; }
die() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

command -v inkscape >/dev/null || die "缺 inkscape（SVG 渲染）"
[ -f "$SRC" ] || die "找不到图标源文件 $SRC"
python3 -c 'import PIL' 2>/dev/null || die "缺 Pillow（python3 -m pip install Pillow）"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- 1. 源文件净化
# 源 svg 里的 <filter> 用的是 feDropShadow（SVG 2 原语）。Inkscape 1.x 不认这个
# 元素，遇到就把整张图渲染成全透明（实测 alpha 极值 (0,0)），且不报错。
# 顺带说明：本来也不该要这层阴影 —— 系统自己会给图标加阴影。
CLEAN="$TMP/clean.svg"
python3 - "$SRC" "$CLEAN" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8').read()
before = s
# 去掉 filter="url(#shadow)" 属性与 <filter> 定义块
s = re.sub(r'\s+filter="url\(#[^"]*\)"', '', s)
s = re.sub(r'<filter\b.*?</filter>', '', s, flags=re.S)
s = re.sub(r'<filter\b[^>]*/>', '', s)
# feDropShadow 兜底：万一还有别的 filter 引用残留
s = re.sub(r'\s*<feDropShadow\b.*?/>', '', s, flags=re.S)
open(dst, 'w', encoding='utf-8').write(s)
sys.exit(0 if s != before else 0)
PY
say "源文件已净化（剥掉不被 inkscape 1.x 支持的 feDropShadow）"

# ---------------------------------------------------------------- 2. 高分辨率渲染
say "渲染 SVG -> ${RENDER}x${RENDER} …"
inkscape --export-type=png --export-width="$RENDER" --export-height="$RENDER" \
         "$CLEAN" --export-filename="$TMP/logo.png" >/dev/null 2>&1 || true
[ -s "$TMP/logo.png" ] || die "inkscape 渲染失败"
python3 -c "
import sys
from PIL import Image
a = Image.open('$TMP/logo.png').convert('RGBA').getchannel('A')
lo, hi = a.getextrema()
sys.exit(0 if hi > 0 else 1)
" || die "渲染结果是全透明 —— 检查 $SRC 是不是还带了 inkscape 不支持的滤镜原语"

# ---------------------------------------------------- 3. 生成 1024 前景/底板/启动图
python3 - "$TMP" "$CANVAS" "$CONTENT_FRAC" "$BG_TOP" "$BG_BOT" "$START_SIZE" "$START_FRAC" "$ALPHA_TRIM" <<'PY'
import sys
from PIL import Image

tmp, canvas, content_frac, bg_top, bg_bot, start_size, start_frac, trim_thr = sys.argv[1:9]
canvas = int(canvas); start_size = int(start_size)
content_frac = float(content_frac); start_frac = float(start_frac)
trim_thr = int(trim_thr)

def hx(c):
    c = c.lstrip('#')
    return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4))

def fit_on_canvas(logo, size, frac, pad=None):
    """把 logo 的实际内容 bbox 缩放后居中贴到 size x size 的透明画布。"""
    a = logo.getchannel('A')
    mask = a.point(lambda v: 255 if v > trim_thr else 0)
    bb = mask.getbbox()
    if bb is None:
        raise SystemExit('logo 内容为空')
    cropped = logo.crop(bb)
    # pad：把裁剪边界外扩一点，保留极淡的渐变尾，别切出硬边
    if pad:
        m = pad
        box = (max(0, bb[0] - m), max(0, bb[1] - m),
               min(logo.width, bb[2] + m), min(logo.height, bb[3] + m))
        cropped = logo.crop(box)
    # 注意：Pillow 的 resize((t, t)) 是「拉伸到恰好 t×t」，不是「等比缩放进 t 方框」。
    # 这里 logo 是 237:170 的宽形，拉伸会明显变形，所以缩放比必须自己算。
    target = int(round(size * frac))
    scale = target / max(cropped.width, cropped.height)
    new = (max(1, round(cropped.width * scale)), max(1, round(cropped.height * scale)))
    scaled = cropped.resize(new, Image.LANCZOS)
    canvas_img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    canvas_img.paste(scaled, ((size - scaled.width) // 2, (size - scaled.height) // 2), scaled)
    return canvas_img

def vertical_gradient(size, top, bottom):
    """竖向渐变。逐行写，避免用 Image.linear_gradient 带来的额外依赖语义。"""
    w = h = size
    t, b = hx(top), hx(bottom)
    img = Image.new('RGB', (w, h))
    px = img.load()
    for y in range(h):
        f = y / (h - 1)
        c = tuple(int(round(t[i] + (b[i] - t[i]) * f)) for i in range(3))
        for x in range(w):
            px[x, y] = c
    return img.convert('RGBA')

logo = Image.open(f'{tmp}/logo.png').convert('RGBA')
print(f'  logo 内容 bbox@{logo.size}: '
      f'{logo.getchannel("A").point(lambda v: 255 if v > trim_thr else 0).getbbox()}')

fg = fit_on_canvas(logo, canvas, content_frac)
fg.save(f'{tmp}/foreground.png')

bg = vertical_gradient(canvas, bg_top, bg_bot)
bg.save(f'{tmp}/background.png')

# 启动页图标：小尺寸，底板直接铺满（与模板一致），logo 居中
start_bg = vertical_gradient(start_size, bg_top, bg_bot)
start_fg = fit_on_canvas(logo, start_size, start_frac)
start_bg.alpha_composite(start_fg)
start_bg.save(f'{tmp}/startIcon.png')

for f in ('foreground', 'background', 'startIcon'):
    p = f'{tmp}/{f}.png'
    im = Image.open(p)
    print(f'  {f}.png  {im.size[0]}x{im.size[1]}  {len(open(p,"rb").read())} 字节')
PY

# ---------------------------------------------------------------- 4. 落到两个模块
# AppScope 与 entry 各要一份 foreground/background：app.json5 与 module.json5
# 都引用 $media:layered_image，资源不共享，只在各自模块的 media/ 下解析。
for mod in AppScope/resources/base/media entry/src/main/resources/base/media; do
  mkdir -p "$ROOT/$mod"
  cp "$TMP/foreground.png" "$ROOT/$mod/foreground.png"
  cp "$TMP/background.png" "$ROOT/$mod/background.png"
  say "已写入 $mod/"
done
# startIcon 只给 entry：只有 module.json5 的 startWindowIcon 引用它，
# AppScope 侧放同名文件是没人读的死资源。
cp "$TMP/startIcon.png" "$ROOT/entry/src/main/resources/base/media/startIcon.png"
say "已写入 entry/src/main/resources/base/media/startIcon.png"

# layered_image.json 缺失时补上（正常仓库里都有，这里兜底）
for d in AppScope/resources/base/media entry/src/main/resources/base/media; do
  [ -f "$ROOT/$d/layered_image.json" ] ||
    printf '{\n  "layered-image":\n  {\n    "background" : "$media:background",\n    "foreground" : "$media:foreground"\n  }\n}' \
      > "$ROOT/$d/layered_image.json"
done

say "完成。下一步构建：assembleHap 后装机看桌面图标。"
