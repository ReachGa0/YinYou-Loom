#!/usr/bin/env python3
"""render_ui_frame.py —— 把 ui_render 测试台导出的整帧文本重建成 PNG

用途：RTL 里画出来的界面，先用仿真导出整帧（sim/out/ui_frame.txt，
每行 4 位十六进制 = 一个像素的 RGB565），再用本脚本转成图片肉眼核对
（"像素位置与布局表一致"这条验收标准就靠它）。

用法：
    python tools/render_ui_frame.py                       # 默认 1x + 3x
    python tools/render_ui_frame.py --zoom 4
"""

import argparse
import os
import sys

from PIL import Image

W, H = 320, 240


def rgb565_to_rgb888(v: int) -> tuple:
    r5 = (v >> 11) & 0x1F
    g6 = (v >> 5) & 0x3F
    b5 = v & 0x1F
    # 用位复制把 5/6 位拉到 8 位，避免整体偏暗
    r = (r5 << 3) | (r5 >> 2)
    g = (g6 << 2) | (g6 >> 4)
    b = (b5 << 3) | (b5 >> 2)
    return (r, g, b)


def main() -> int:
    ap = argparse.ArgumentParser(description="把整帧文本重建成 PNG")
    ap.add_argument("--infile", default="sim/out/ui_frame.txt")
    ap.add_argument("--outdir", default="tmp/ui_preview")
    ap.add_argument("--zoom", type=int, default=3)
    args = ap.parse_args()

    if not os.path.exists(args.infile):
        sys.exit(f"找不到整帧文件：{args.infile}（先跑 sim/tb_ui_render.v）")

    with open(args.infile, "r", encoding="ascii") as fp:
        raw = [ln.strip() for ln in fp if ln.strip()]
    if len(raw) != W * H:
        sys.exit(f"像素数不符：文件 {len(raw)} 行，期望 {W*H} 行")

    img = Image.new("RGB", (W, H))
    px = img.load()
    for i, line in enumerate(raw):
        px[i % W, i // W] = rgb565_to_rgb888(int(line, 16))

    os.makedirs(args.outdir, exist_ok=True)
    p1 = os.path.join(args.outdir, "ui_frame_1x.png")
    img.save(p1)

    z = args.zoom
    pz = os.path.join(args.outdir, f"ui_frame_{z}x.png")
    img.resize((W * z, H * z), Image.NEAREST).save(pz)

    print(f"1:1  → {p1}")
    print(f"{z}x  → {pz}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
