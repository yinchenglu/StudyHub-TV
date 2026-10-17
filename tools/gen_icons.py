"""生成 StudyHub TV 的启动图标和电视横幅。

为什么不用现成图片：
  这个项目要保证「克隆下来就能在 CI 里出包」，仓库里不该出现
  来源不明的二进制资源。图标用这个脚本现场画，改配色只要改下面几个常量。

用法（仓库根目录）：
  python tools/gen_icons.py

产物：
  android_custom/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png
  android_custom/res/drawable-xhdpi/tv_banner.png   （安卓 TV 桌面用，320×180）

实现说明：
  没有 PIL 依赖，自己写了个极简 PNG 编码（zlib + CRC）；
  形状用 3×3 超采样抗锯齿 —— 图标尺寸小，锯齿一眼就能看出来。
"""

import os
import struct
import zlib
from math import hypot

# ---------------------------------------------------------------- 配色
BG_TOP = (0x0C, 0x18, 0x22)
BG_BOT = (0x11, 0x2E, 0x38)
TEAL = (0x28, 0xC8, 0xA8)
TEAL_DARK = (0x1B, 0x8C, 0x9E)
WHITE = (0xF2, 0xF7, 0xF8)
INK = (0x06, 0x22, 0x2B)

SS = 3  # 超采样倍数


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def in_round_rect(x, y, x0, y0, x1, y1, r):
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return hypot(x - cx, y - cy) <= r


def in_triangle(x, y, p0, p1, p2):
    def sign(a, b, c):
        return (a[0] - c[0]) * (b[1] - c[1]) - (b[0] - c[0]) * (a[1] - c[1])

    d1 = sign((x, y), p0, p1)
    d2 = sign((x, y), p1, p2)
    d3 = sign((x, y), p2, p0)
    has_neg = d1 < 0 or d2 < 0 or d3 < 0
    has_pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (has_neg and has_pos)


def render(w, h, shade):
    """shade(x, y) -> (r,g,b) | None，坐标是 0..1 归一化"""
    pix = []
    inv = 1.0 / (SS * SS)
    for y in range(h):
        row = bytearray()
        for x in range(w):
            acc = [0, 0, 0]
            for sy in range(SS):
                for sx in range(SS):
                    u = (x + (sx + 0.5) / SS) / w
                    v = (y + (sy + 0.5) / SS) / h
                    c = shade(u, v)
                    if c is None:
                        c = (0, 0, 0)
                    acc[0] += c[0]
                    acc[1] += c[1]
                    acc[2] += c[2]
            row += bytes((
                int(acc[0] * inv),
                int(acc[1] * inv),
                int(acc[2] * inv),
            ))
        pix.append(row)
    return pix


def write_png(path, w, h, rows):
    raw = bytearray()
    for r in rows:
        raw.append(0)
        raw.extend(r)

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    blob = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(blob)
    print("  ->", path, f"({w}x{h}, {len(blob)} B)")


# ---------------------------------------------------------------- 图形

def icon_shade(u, v):
    """方形图标：深色圆角底 + 青色播放三角 + 一圈细边"""
    bg = lerp(BG_TOP, BG_BOT, v)
    if not in_round_rect(u, v, 0.0, 0.0, 1.0, 1.0, 0.20):
        return None  # 圆角外透明（旧系统上会显示为圆形/方形遮罩）

    # 外圈细描边（让图标在深色桌面上有边界）
    if not in_round_rect(u, v, 0.035, 0.035, 0.965, 0.965, 0.18):
        return TEAL_DARK

    # 播放三角
    tri = [(0.38, 0.26), (0.38, 0.74), (0.78, 0.50)]
    if in_triangle(u, v, *tri):
        return TEAL if v < 0.62 else lerp(TEAL, TEAL_DARK, v)

    # 三角后面垫一层暗色，形成"屏幕"感
    if in_round_rect(u, v, 0.26, 0.19, 0.86, 0.81, 0.09):
        return None if in_triangle(u, v, *tri) else (0x0A, 0x1C, 0x24)

    return bg


def banner_shade(u, v):
    """电视横幅 320×180：左边图标，右边三条菜单条"""
    bg = lerp(BG_TOP, BG_BOT, v)
    if in_round_rect(u, v, 0.0, 0.0, 1.0, 1.0, 0.0):
        pass

    # 底部一条青色细线（横幅常见的品牌线）
    if 0.90 < v < 0.925:
        return TEAL_DARK

    # 左侧图标区
    if in_round_rect(u, v, 0.055, 0.18, 0.245, 0.78, 0.05):
        tri = [(0.108, 0.30), (0.108, 0.66), (0.208, 0.48)]
        if in_triangle(u, v, *tri):
            return TEAL
        return (0x0A, 0x1C, 0x24)

    # 右侧三条"菜单项"（第一条高亮，暗示"选中"）
    bars = [(0.30, 0.30, 0.55), (0.30, 0.46, 0.78), (0.30, 0.62, 0.66)]
    for i, (x0, y0, x1) in enumerate(bars):
        if in_round_rect(u, v, x0, y0, x1, y0 + 0.075, 0.035):
            return TEAL if i == 0 else (0x2A, 0x3A, 0x46)
    return bg


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    res = os.path.join(root, "android_custom", "res")

    sizes = {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }
    for dpi, size in sizes.items():
        rows = render(size, size, icon_shade)
        write_png(os.path.join(res, f"mipmap-{dpi}", "ic_launcher.png"), size, size, rows)

    # 电视桌面横幅固定 320×180（xhdpi 密度）
    rows = render(320, 180, banner_shade)
    write_png(os.path.join(res, "drawable-xhdpi", "tv_banner.png"), 320, 180, rows)


if __name__ == "__main__":
    main()
