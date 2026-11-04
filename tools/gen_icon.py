#!/usr/bin/env python3
"""生成 AItrans 应用图标。

设计：圆角方形底 + 靛蓝到紫的渐变，中间两条「字幕条」——
上条为白色（原文），下条左白右薄荷绿（译文），暗示翻译。

产物：
    assets/icon/icon-1024.png   源图
    assets/icon/AppIcon.icns    macOS
    assets/icon/icon.ico        Windows（多尺寸）

用法：python3 tools/gen_icon.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "icon"
SIZE = 1024

TOP = (79, 70, 229)      # indigo-600
BOTTOM = (124, 58, 237)  # violet-600
WHITE = (255, 255, 255)
MINT = (52, 211, 153)    # emerald-400


def gradient(size: int) -> Image.Image:
    image = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        ratio = y / (size - 1)
        color = tuple(
            round(TOP[channel] + (BOTTOM[channel] - TOP[channel]) * ratio)
            for channel in range(3)
        )
        draw.line([(0, y), (size, y)], fill=color)
    return image


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def bar(draw: ImageDraw.ImageDraw, box, color, radius):
    draw.rounded_rectangle(box, radius=radius, fill=color)


def build(size: int = SIZE) -> Image.Image:
    base = gradient(size).convert("RGBA")
    # macOS 图标四周留白，圆角半径约为边长的 22%。
    margin = round(size * 0.055)
    plate = size - margin * 2
    mask = rounded_mask(plate, round(plate * 0.225))
    base = base.crop((0, 0, plate, plate))
    base.putalpha(mask)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(base, (margin, margin))

    draw = ImageDraw.Draw(canvas)
    unit = plate
    left = margin + unit * 0.19
    width = unit * 0.62
    height = unit * 0.125
    radius = height / 2

    # 上条：原文
    top_y = margin + unit * 0.335
    bar(draw, [left, top_y, left + width, top_y + height], WHITE, radius)

    # 下条：左半原文、右半译文，中间留一个缺口暗示转换
    low_y = margin + unit * 0.525
    gap = width * 0.055
    left_width = width * 0.54
    bar(draw, [left, low_y, left + left_width, low_y + height], WHITE, radius)
    bar(
        draw,
        [left + left_width + gap, low_y, left + width, low_y + height],
        MINT,
        radius,
    )

    # 底部一条更短的淡条，增加层次
    third_y = margin + unit * 0.715
    faint = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    faint_draw = ImageDraw.Draw(faint)
    bar(
        faint_draw,
        [left, third_y, left + width * 0.46, third_y + height * 0.68],
        WHITE + (135,),
        radius,
    )
    canvas = Image.alpha_composite(canvas, faint)

    return canvas


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    master = build()
    png = OUT / "icon-1024.png"
    master.save(png)
    print(f"wrote {png.relative_to(ROOT)}")

    # Windows .ico：多尺寸，包含 16/32/48/256 以保证任务栏与资源管理器清晰
    ico = OUT / "icon.ico"
    master.save(ico, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print(f"wrote {ico.relative_to(ROOT)}")

    # macOS .icns
    iconset = OUT / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for size_px, name in [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]:
        master.resize((size_px, size_px), Image.LANCZOS).save(iconset / name)

    import subprocess

    icns = OUT / "AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)
    print(f"wrote {icns.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
