from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


def remove_green_screen(source: Path, target: Path) -> None:
    image = Image.open(source).convert("RGBA")
    output: list[tuple[int, int, int, int]] = []
    for red, green, blue, _ in image.getdata():
        dominance = green - max(red, blue)
        if green > 165 and dominance > 45:
            alpha = max(0, min(255, int(255 * (1 - (dominance - 45) / 155))))
            green = min(green, max(red, blue) + 18)
            output.append((red, green, blue, alpha))
        else:
            output.append((red, green, blue, 255))
    image.putdata(output)
    bbox = image.getbbox()
    if bbox:
        image = image.crop(bbox)
    target.parent.mkdir(parents=True, exist_ok=True)
    image.save(target, optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Remove a flat green screen.")
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    args = parser.parse_args()
    remove_green_screen(args.source, args.target)


if __name__ == "__main__":
    main()

