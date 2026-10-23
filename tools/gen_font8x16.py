#!/usr/bin/env python3
"""gen_font8x16.py —— 生成 8x16 ASCII 点阵字库（2.4 寸 ST7789 横屏 UI 用）

为什么需要它
------------
UI 的表头 / 选项 / 按键提示全部用 8x16 点阵显示。旧屏（1.3 寸 SH1106）的字模是
手写 case，缺 5 6 7 8 和 L 等字符（见 docs/19 案例 7 区）。这里改成"离线可复现"：
用系统等宽字体栅格化 96 个 ASCII 字符（0x20-0x7F），生成 $readmemh 直接可读的
hex，并自检"每个字母 / 数字都非空、空格为空"。

产物
----
data/fonts/font8x16.hex     96 字符 x 16 行 = 1536 行，每行 1 字节（2 位大写十六进制）
                            地址 = (字符码 - 0x20) * 16 + 行号
                            行内 bit7 = 最左像素，bit0 = 最右像素
tmp/font_preview/*.png      仅供肉眼校验，不是 RTL 依赖，可不提交

用法
----
    python tools/gen_font8x16.py
    python tools/gen_font8x16.py --size 15 --threshold 120
    python tools/gen_font8x16.py --font C:/Windows/Fonts/consola.ttf --no-preview

注：本机没有系统 Python，可用工作区自带运行时：
    C:/Users/<user>/.codex/.../codex-primary-runtime/dependencies/python/python.exe
"""

import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFont

# ---- 字库几何（与 docs/22 布局表、RTL 必须保持一致）----
FIRST_CODE = 0x20
LAST_CODE = 0x7F
CELL_W = 8
CELL_H = 16
BASELINE_ROW = 12      # 0 起：基线在第 12 行，第 12-15 行留给 g j p q y 的降部
SS = 4                 # 超采样倍数（渲染后再缩小 + 阈值化，得到稳定笔画）

FONT_CANDIDATES = [
    "C:/Windows/Fonts/consola.ttf",        # Consolas
    "C:/Windows/Fonts/cascadiamono.ttf",   # Cascadia Mono
    "C:/Windows/Fonts/lucon.ttf",          # Lucida Console
    "C:/Windows/Fonts/cour.ttf",           # Courier New
]

# ---- UI 布局（设备像素，原点左上角；与 docs/22 的坐标表一致）----
LAYOUT = {
    "screen_w": 320,
    "screen_h": 240,
    "wave_y0": 0,
    "wave_y1": 127,
    "sep1_y": (128, 129),
    "hdr_y": (130, 145),
    "opt_y0": 146,
    "opt_rows": 4,
    "opt_step": 16,
    "sep2_y": (210, 211),
    "hint_y": (212, 227),
    "cols": [(0, 105), (107, 212), (214, 319)],
    "text_pad": 4,
}

HDR = ["TONE", "FX", "MODE"]
OPTS = [["SINE", "SQUARE"], ["DRY", "CHORUS"], ["ONE", "TRI"]]
SELECTED = [0, 1, 1]          # 预览用：当前 SINE / CHORUS / TRI
HINTS = ["S1 TIMBRE", "S2 FX", "SW MODE"]
SCALE_TEXT = "C MAJ"          # 本轮占位

# 预览配色（也是 RTL 要用的调色板草案）
C_BG = (0, 0, 0)
C_SEP = (56, 56, 56)
C_HDR = (0, 224, 224)
C_TXT = (235, 235, 235)
C_HINT = (140, 140, 140)
C_WAVE = (0, 220, 255)
C_MID = (0, 70, 0)
C_SCALE = (255, 208, 0)
C_SEL_BG = (240, 240, 240)
C_SEL_TX = (0, 0, 0)


def pick_font(requested):
    """返回 (路径, 字体对象工厂)。字体对象要按尺寸创建，所以返回路径。"""
    if requested:
        if not os.path.exists(requested):
            sys.exit(f"找不到字体文件：{requested}")
        return requested
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return path
    sys.exit("没找到可用的等宽 TTF，请用 --font 指定路径")


def render_cell(font, ch, threshold):
    """把一个字符栅格化成 16 个字节（每字节 8 像素，bit7 最左）。"""
    img = Image.new("L", (CELL_W * SS, CELL_H * SS), 0)
    draw = ImageDraw.Draw(img)
    advance = font.getlength(ch)
    ascent, _descent = font.getmetrics()
    x = (CELL_W * SS - advance) / 2.0          # 水平居中于 8 px 单元格
    y = BASELINE_ROW * SS - ascent             # 让基线落在 BASELINE_ROW
    draw.text((x, y), ch, fill=255, font=font, anchor="la")
    small = img.resize((CELL_W, CELL_H), Image.LANCZOS)
    px = small.load()
    rows = []
    for r in range(CELL_H):
        byte = 0
        for c in range(CELL_W):
            if px[c, r] >= threshold:
                byte |= 0x80 >> c
        rows.append(byte)
    return rows


def render_cell_mono(font, ch):
    """单色渲染（FreeType 1 位 + hinting）：小字号笔画更锐利。

    走的是另一条路：不做超采样，直接让 FreeType 把字形网格贴合到整数像素，
    再用 getbbox() 给出的墨迹原点把点阵搬进 8x16 单元格。
    """
    ascent, _descent = font.getmetrics()
    advance = font.getlength(ch)
    x_off = int(round((CELL_W - advance) / 2.0))
    y_off = BASELINE_ROW - ascent
    bx0, by0, _bx1, _by1 = font.getbbox(ch)
    mask = font.getmask(ch, mode="1")
    mw, mh = mask.size
    rows = [0] * CELL_H
    for r in range(mh):
        for c in range(mw):
            if not mask.getpixel((c, r)):
                continue
            px = x_off + bx0 + c
            py = y_off + by0 + r
            if 0 <= px < CELL_W and 0 <= py < CELL_H:
                rows[py] |= 0x80 >> px
    return rows


def build_font(font_path, size, threshold, mode):
    font = ImageFont.truetype(font_path, size * SS if mode == "ss" else size)
    bits = {}
    for code in range(FIRST_CODE, LAST_CODE + 1):
        ch = chr(code)
        if mode == "mono":
            bits[code] = render_cell_mono(font, ch)
        else:
            bits[code] = render_cell(font, ch, threshold)
    return bits


def write_hex(path, bits):
    lines = []
    for code in range(FIRST_CODE, LAST_CODE + 1):
        for byte in bits[code]:
            lines.append(f"{byte:02X}")
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="ascii", newline="\n") as fp:
        fp.write("\n".join(lines) + "\n")
    return len(lines)


def verify_hex(path, bits):
    """回读 hex，逐字节比对，确认没有写坏。"""
    with open(path, "r", encoding="ascii") as fp:
        raw = [ln.strip() for ln in fp if ln.strip()]
    expect = []
    for code in range(FIRST_CODE, LAST_CODE + 1):
        expect.extend(bits[code])
    if len(raw) != len(expect):
        return False, f"行数不符：文件 {len(raw)} 行，期望 {len(expect)} 行"
    for i, (line, value) in enumerate(zip(raw, expect)):
        if len(line) != 2:
            return False, f"第 {i + 1} 行不是 2 位十六进制：{line!r}"
        if int(line, 16) != value:
            return False, f"第 {i + 1} 行不符：{line} != {value:02X}"
    return True, f"{len(raw)} 行逐字节一致"


def coverage(bits):
    """统计每个字符的点亮像素数，返回 (空字符列表, 字符->像素数)。"""
    counts = {}
    blanks = []
    for code in range(FIRST_CODE, LAST_CODE + 1):
        count = sum(bin(b).count("1") for b in bits[code])
        counts[chr(code)] = count
        if count == 0:
            blanks.append(chr(code))
    return blanks, counts


def draw_glyph(draw, bits, code, x, y, zoom, color):
    rows = bits.get(code)
    if rows is None:
        return
    for r, byte in enumerate(rows):
        for c in range(CELL_W):
            if byte & (0x80 >> c):
                x0 = (x + c) * zoom
                y0 = (y + r) * zoom
                draw.rectangle([x0, y0, x0 + zoom - 1, y0 + zoom - 1], fill=color)


def draw_text(draw, bits, x, y, text, color, zoom):
    for i, ch in enumerate(text):
        draw_glyph(draw, bits, ord(ch), x + i * CELL_W, y, zoom, color)


def make_sheet(bits, path, zoom=4):
    """96 个字符的对照表：拼音网格 + 字符码，用于逐字肉眼校验。"""
    cols = 16
    tile_w = CELL_W + 2          # 设备像素：字形 + 间隙
    tile_h = CELL_H + 4          # 设备像素：字形 + 标注行
    rows = (LAST_CODE - FIRST_CODE + 1 + cols - 1) // cols
    img = Image.new("RGB", (cols * tile_w * zoom, rows * tile_h * zoom), (24, 24, 28))
    draw = ImageDraw.Draw(img)
    label_font = ImageFont.truetype(pick_font(None), 10)
    for idx, code in enumerate(range(FIRST_CODE, LAST_CODE + 1)):
        gx = (idx % cols) * tile_w + 1
        gy = (idx // cols) * tile_h + 1
        draw_glyph(draw, bits, code, gx, gy, zoom, (255, 255, 255))
        draw.text((gx * zoom, (gy + CELL_H + 1) * zoom - 10), f"{code:02X}{chr(code)}",
                  fill=(150, 150, 160), font=label_font)
    img.save(path)
    return path


def make_ui_preview(bits, path, zoom=3, amp=42, cycles=4.0):
    """用真实 8x16 字库画一遍完整界面 —— 上板前就能逐像素核对。"""
    import math

    lay = LAYOUT
    w, h = lay["screen_w"], lay["screen_h"]
    img = Image.new("RGB", (w * zoom, h * zoom), C_BG)
    draw = ImageDraw.Draw(img)

    def rect(x0, y0, x1, y1, color):
        draw.rectangle([x0 * zoom, y0 * zoom, (x1 + 1) * zoom - 1, (y1 + 1) * zoom - 1],
                       fill=color)

    # 波形带
    mid = (lay["wave_y0"] + lay["wave_y1"]) // 2
    prev = None
    for x in range(w):
        yv = mid - amp * math.sin(2 * math.pi * (cycles * x / w))
        if prev is not None:
            draw.line([x * zoom, prev * zoom, x * zoom, yv * zoom],
                      fill=C_WAVE, width=2 * zoom)
        prev = yv
    for x in range(0, w, 4):
        rect(x, mid, x + 1, mid, C_MID)

    rect(0, lay["sep1_y"][0], w - 1, lay["sep1_y"][1], C_SEP)
    rect(0, lay["sep2_y"][0], w - 1, lay["sep2_y"][1], C_SEP)

    for x0, x1 in lay["cols"]:
        rect(x1 + 1, lay["hdr_y"][0], x1 + 1, h - 1, C_SEP)

    for c, (x0, x1) in enumerate(lay["cols"]):
        pad = lay["text_pad"]
        draw_text(draw, bits, x0 + pad, lay["hdr_y"][0] + 1, HDR[c], C_HDR, zoom)
        for r in range(lay["opt_rows"]):
            y = lay["opt_y0"] + r * lay["opt_step"]
            if r >= len(OPTS[c]):
                continue
            if r == SELECTED[c]:
                rect(x0, y, x1, y + 15, C_SEL_BG)
                draw_text(draw, bits, x0 + pad, y + 1, OPTS[c][r], C_SEL_TX, zoom)
            else:
                draw_text(draw, bits, x0 + pad, y + 1, OPTS[c][r], C_TXT, zoom)
        draw_text(draw, bits, x0 + pad, lay["hint_y"][0] + 1, HINTS[c], C_HINT, zoom)

    # 右上角调式（占位）：黑底框，避免波形穿过时看不清
    tw = len(SCALE_TEXT) * CELL_W
    sx = w - lay["text_pad"] - tw
    rect(sx - 2, 4, w - 1, 19, C_BG)
    draw_text(draw, bits, sx, 4, SCALE_TEXT, C_SCALE, zoom)

    img.save(path)
    return path


def main():
    ap = argparse.ArgumentParser(description="生成 8x16 ASCII 点阵字库")
    ap.add_argument("--font", help="TTF/TTC 路径（默认自动挑系统等宽字体）")
    ap.add_argument("--size", type=int, default=14, help="设备像素字号（默认 14）")
    ap.add_argument("--mode", choices=["mono", "ss"], default="mono",
                    help="mono=FreeType 1 位渲染（默认，锐利）；ss=超采样+阈值")
    ap.add_argument("--threshold", type=int, default=128, help="二值化阈值 0-255（默认 128）")
    ap.add_argument("--out", default="data/fonts/font8x16.hex", help="hex 输出路径")
    ap.add_argument("--preview-dir", default="tmp/font_preview", help="预览 PNG 输出目录")
    ap.add_argument("--no-preview", action="store_true", help="只生成 hex，不出预览图")
    args = ap.parse_args()

    font_path = pick_font(args.font)
    bits = build_font(font_path, args.size, args.threshold, args.mode)

    lines = write_hex(args.out, bits)
    ok, detail = verify_hex(args.out, bits)
    blanks, counts = coverage(bits)

    print(f"字体      : {font_path}")
    print(f"字号/模式 : {args.size} px / {args.mode}"
          + (f" / 阈值 {args.threshold}" if args.mode == "ss" else ""))
    print(f"hex       : {args.out}（{lines} 行）")
    print(f"回读校验  : {'OK' if ok else '失败'} —— {detail}")

    # 旧屏字模缺字符的教训：这几个人工点名
    watch = ["0", "1", "5", "6", "7", "8", "9", "L", "M", "O", "S", "W", " "]
    print("抽样像素数: " + "  ".join(f"'{c}'={counts[c]}" for c in watch))
    real_blanks = [c for c in blanks if c != " "]
    if real_blanks:
        print("警告：以下字符渲染为空 -> " + " ".join(f"0x{ord(c):02X}" for c in real_blanks))
    else:
        print("覆盖率    : 除空格外无空字符（96 字符全部有笔画）")

    if not args.no_preview:
        os.makedirs(args.preview_dir, exist_ok=True)
        sheet = make_sheet(bits, os.path.join(args.preview_dir, "font_sheet.png"))
        ui = make_ui_preview(bits, os.path.join(args.preview_dir, "ui_preview_font.png"), zoom=3)
        ui1 = make_ui_preview(bits, os.path.join(args.preview_dir, "ui_preview_font_1x.png"), zoom=1)
        print(f"预览图    : {sheet}")
        print(f"           {ui}")
        print(f"           {ui1}  （320x240 原始像素，用图片查看器 1:1 看才是真尺寸）")
    return 0 if ok and not real_blanks else 1


if __name__ == "__main__":
    sys.exit(main())
