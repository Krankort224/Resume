from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("images", nargs="+", type=Path)
    parser.add_argument("--columns", type=int, default=4)
    parser.add_argument("--thumb-width", type=int, default=360)
    args = parser.parse_args()

    font = ImageFont.load_default(size=22)
    margin = 20
    label_height = 40
    thumbs: list[tuple[Path, Image.Image]] = []
    max_height = 0
    for path in args.images:
        with Image.open(path) as source:
            thumb = source.convert("RGB")
        thumb.thumbnail((args.thumb_width, args.thumb_width), Image.Resampling.LANCZOS)
        max_height = max(max_height, thumb.height)
        thumbs.append((path, thumb))

    rows = math.ceil(len(thumbs) / args.columns)
    cell_width = args.thumb_width + margin * 2
    cell_height = max_height + label_height + margin * 2
    sheet = Image.new("RGB", (cell_width * args.columns, cell_height * rows), "#d8d8d8")
    draw = ImageDraw.Draw(sheet)
    for index, (path, thumb) in enumerate(thumbs):
        col = index % args.columns
        row = index // args.columns
        x = col * cell_width + margin + (args.thumb_width - thumb.width) // 2
        y = row * cell_height + margin
        sheet.paste(thumb, (x, y))
        draw.text((col * cell_width + margin, y + max_height + 8), path.stem, fill="black", font=font)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(args.output, optimize=True)


if __name__ == "__main__":
    main()
