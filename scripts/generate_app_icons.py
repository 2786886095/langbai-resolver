from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "client/assets/images/langbai_avatar.png"
MASTER = ROOT / "client/assets/images/langbai_app_icon.png"


def compose(size: int = 1024, *, safe: bool = False) -> Image.Image:
    source = Image.open(SOURCE).convert("RGBA")
    image = Image.new("RGB", (size, size))
    pixels = image.load()
    start = (248, 249, 255)
    end = (111, 130, 255)
    for y in range(size):
        for x in range(size):
            amount = (x + y) / (2 * (size - 1))
            pixels[x, y] = tuple(
                round(a + (b - a) * amount) for a, b in zip(start, end)
            )

    draw = ImageDraw.Draw(image)
    inset = round(size * (0.17 if safe else 0.095))
    width = max(2, round(size * 0.018))
    draw.ellipse(
        (inset, inset, size - inset, size - inset),
        fill=(247, 249, 255),
        outline=(79, 101, 245),
        width=width,
    )

    avatar_size = round(size * (0.64 if safe else 0.81))
    avatar = source.resize((avatar_size, avatar_size), Image.Resampling.LANCZOS)
    offset = ((size - avatar_size) // 2, (size - avatar_size) // 2)
    image.paste(avatar, offset, avatar)
    return image


def save_png(image: Image.Image, path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.Resampling.LANCZOS).save(
        path, format="PNG", optimize=True
    )


def circular_icon(image: Image.Image) -> Image.Image:
    icon = image.convert("RGBA")
    mask = Image.new("L", icon.size, 0)
    ImageDraw.Draw(mask).ellipse((0, 0, icon.width - 1, icon.height - 1), fill=255)
    icon.putalpha(mask)
    return icon


def adaptive_foreground(size: int = 1024) -> Image.Image:
    source = Image.open(SOURCE).convert("RGBA")
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    avatar_size = round(size * 0.72)
    avatar = source.resize((avatar_size, avatar_size), Image.Resampling.LANCZOS)
    offset = ((size - avatar_size) // 2, (size - avatar_size) // 2)
    canvas.alpha_composite(avatar, offset)
    return canvas


def main() -> None:
    master = compose()
    maskable = compose(safe=True)
    round_master = circular_icon(master)
    foreground = adaptive_foreground()
    master.save(MASTER, format="PNG", optimize=True)

    android = {
        "mipmap-mdpi/ic_launcher.png": 48,
        "mipmap-hdpi/ic_launcher.png": 72,
        "mipmap-xhdpi/ic_launcher.png": 96,
        "mipmap-xxhdpi/ic_launcher.png": 144,
        "mipmap-xxxhdpi/ic_launcher.png": 192,
    }
    android_root = ROOT / "client/android/app/src/main/res"
    for name, size in android.items():
        save_png(master, android_root / name, size)
        round_name = name.replace("ic_launcher.png", "ic_launcher_round.png")
        save_png(round_master, android_root / round_name, size)
    save_png(
        foreground,
        android_root / "drawable-nodpi/ic_launcher_foreground_image.png",
        1024,
    )

    ios = {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    ios_root = ROOT / "client/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for name, size in ios.items():
        save_png(master, ios_root / name, size)

    web_root = ROOT / "client/web"
    save_png(master, web_root / "favicon.png", 32)
    save_png(master, web_root / "icons/Icon-192.png", 192)
    save_png(master, web_root / "icons/Icon-512.png", 512)
    save_png(maskable, web_root / "icons/Icon-maskable-192.png", 192)
    save_png(maskable, web_root / "icons/Icon-maskable-512.png", 512)

    macos_root = ROOT / "client/macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        save_png(master, macos_root / f"app_icon_{size}.png", size)

    windows_icon = ROOT / "client/windows/runner/resources/app_icon.ico"
    windows_icon.parent.mkdir(parents=True, exist_ok=True)
    master.resize((256, 256), Image.Resampling.LANCZOS).save(
        windows_icon,
        format="ICO",
        sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (40, 40),
               (48, 48), (64, 64), (128, 128), (256, 256)],
    )


if __name__ == "__main__":
    main()
