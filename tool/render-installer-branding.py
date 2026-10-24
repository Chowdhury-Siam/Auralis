#!/usr/bin/env python3
"""Render installer branding from Auralis's existing app icon (Pillow only)."""
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(__file__).with_name("installer-assets")
SURFACE = "#19171E"
OUTLINE = "#36313E"
ACCENT = "#C7B5FF"
TEXT = "#F6F3FF"
MUTED = "#AAA4B5"


def font(size, bold=False):
    names = ("Segoe UI Bold.ttf", "DejaVuSans-Bold.ttf") if bold else ("Segoe UI.ttf", "DejaVuSans.ttf")
    for name in names:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    raise RuntimeError("Install Segoe UI or DejaVu Sans to regenerate installer artwork.")


def paste_icon(image, box):
    icon = Image.open(ROOT / "windows/runner/resources/app_icon.ico").convert("RGBA")
    icon.thumbnail((box[2], box[3]), Image.Resampling.LANCZOS)
    image.paste(icon, (box[0], box[1]), icon)


def waveform():
    scale = 4
    image = Image.new("RGB", (180 * scale, 108 * scale), SURFACE)
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((0, 0, image.width - 1, image.height - 1),
                           radius=18 * scale, fill="#211D29", outline=OUTLINE, width=scale)
    for bar in range(27):
        envelope = math.sin(math.pi * (bar + 1) / 28)
        height = 6 + 58 * envelope * (.55 + .45 * math.sin(bar * 1.7) ** 2)
        x = (15 + bar * 5.7) * scale
        draw.rounded_rectangle((x, (54 - height / 2) * scale,
                                x + 2.8 * scale, (54 + height / 2) * scale),
                               radius=1.4 * scale, fill=ACCENT if bar < 18 else MUTED)
    return image.resize((180, 108), Image.Resampling.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sidebar = Image.new("RGB", (244, 563), SURFACE)
    draw = ImageDraw.Draw(sidebar)
    paste_icon(sidebar, (32, 42, 92, 92))
    draw.text((32, 156), "Auralis", font=font(30, True), fill=TEXT)
    draw.text((32, 216), "Your music,", font=font(16), fill=MUTED)
    draw.text((32, 241), "your space.", font=font(16), fill=MUTED)
    sidebar.paste(waveform(), (32, 292))
    draw.text((32, 475), "MUSIC · YOUR WAY", font=font(11, True), fill=ACCENT)
    draw.text((32, 508), "Windows desktop", font=font(13), fill=MUTED)
    sidebar.save(OUT / "windows-sidebar.bmp")

    small = Image.new("RGB", (110, 110), SURFACE)
    paste_icon(small, (0, 0, 110, 110))
    small.save(OUT / "windows-icon.bmp")
    print(f"Rendered Auralis installer artwork in {OUT}")


if __name__ == "__main__":
    main()
