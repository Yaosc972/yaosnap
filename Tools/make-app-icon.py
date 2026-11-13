#!/usr/bin/env python3
"""从图标资源包生成 AppIcon.icns 与状态栏图标。

两条约定：
- 应用图标必须是**满幅**的：macOS 26 会自己套圆角与留白，再自己画圆角反而
  会变成「浅色底板里嵌一块黑方块」（实测过）。macOS 12–15 上直接显示直角方块，
  所以这里只保证满幅、黑底、S 居中。
- 状态栏图是模板图，18pt 下软边会糊，剪影的 alpha 要先拉陡。

用法：
    python3 Tools/make-app-icon.py <资源包目录> [--preview 输出目录]
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
# 资源截图的底色（与资源包 AppIcon-Black 一致）。
BACKDROP = (0, 0, 0, 255)
# S 在画布上占的比例，留出呼吸空间。
LOGO_RATIO = 0.74

ICONSET_SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

# 状态栏/菜单里是模板图，只要 S 的剪影，颜色由系统定。
STATUS_SIZES = [("StatusBarIcon.png", 18), ("StatusBarIcon@2x.png", 36)]
MENU_SIZES = [("MenuItemIcon.png", 16), ("MenuItemIcon@2x.png", 32)]


def compose_app_icon(logo: Image.Image) -> Image.Image:
    """满幅黑底 + 居中的 S。圆角与留白交给系统。"""
    canvas = Image.new("RGBA", (CANVAS, CANVAS), BACKDROP)
    side = int(CANVAS * LOGO_RATIO)
    scaled = logo.copy()
    scaled.thumbnail((side, side), Image.LANCZOS)
    canvas.alpha_composite(scaled, ((CANVAS - scaled.width) // 2, (CANVAS - scaled.height) // 2))
    # 满幅图标不要透明通道：留一行 alpha 反而会被系统当成异形图标再加一层底板。
    return canvas.convert("RGB")


def sharpen_alpha(alpha: Image.Image, low: int = 96, high: int = 168) -> Image.Image:
    """把中间的半透明拉成陡坡：菜单栏图标只有 18pt，软边会糊成一团。"""
    def curve(value: int) -> int:
        if value <= low:
            return 0
        if value >= high:
            return 255
        return int((value - low) * 255 / (high - low))

    return alpha.point(curve)


def silhouette(logo: Image.Image, size: int) -> Image.Image:
    """模板图：黑色剪影 + 原始 alpha，系统会按明暗自动着色。"""
    scaled = logo.copy()
    scaled.thumbnail((size, size), Image.LANCZOS)
    ink = Image.new("RGBA", scaled.size, (0, 0, 0, 255))
    ink.putalpha(sharpen_alpha(scaled.getchannel("A")))
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(ink, ((size - scaled.width) // 2, (size - scaled.height) // 2))
    return canvas


def write_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "PNG")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pack", help="图标资源包目录（含 PNG/ 与 macOS/）")
    parser.add_argument("--out", default="Resources", help="输出目录")
    parser.add_argument("--preview", default="/tmp/yaosnap-verify/evidence")
    args = parser.parse_args()

    pack = Path(args.pack).expanduser()
    out = Path(args.out)
    logo = Image.open(pack / "PNG" / "Logo-Transparent-1024.png").convert("RGBA")

    icon = compose_app_icon(logo)
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        for name, size in ICONSET_SIZES:
            write_png(icon.resize((size, size), Image.LANCZOS), iconset / name)
        icns = Path(tmp) / "AppIcon.icns"
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)
        shutil.copyfile(icns, out / "AppIcon.icns")

    for name, size in STATUS_SIZES:
        write_png(silhouette(logo, size), out / name)
    for name, size in MENU_SIZES:
        write_png(silhouette(logo, size), out / name)

    preview = Path(args.preview)
    write_png(icon, preview / "app-icon-1024.png")
    write_png(icon.resize((256, 256), Image.LANCZOS), preview / "app-icon-256.png")
    print("WROTE", out / "AppIcon.icns")
    print("PREVIEW", preview / "app-icon-1024.png")


if __name__ == "__main__":
    main()