"""Turns the ALERION Update logo artwork into transparent app icons.

Usage: python tools/make_icon.py <logo image> [assets dir]

The artwork has a white background and a soft outer glow. A plain "white to alpha"
would also punch holes into the glossy highlights inside the arrows, so the background
is found by flood-filling near-white pixels from the image border; only pixels close to
that background get a soft colour-to-alpha edge, everything inside stays opaque.
"""
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

BG_THRESHOLD = 232   # min(r, g, b) above this counts as background candidate
EDGE_BAND = 21       # px around the background that get a soft edge (odd, MaxFilter size)


def remove_background(img: Image.Image) -> Image.Image:
    rgb = img.convert("RGB")
    w, h = rgb.size
    # candidate mask: 255 where all channels are near white
    r, g, b = (ch.point(lambda v: 255 if v > BG_THRESHOLD else 0) for ch in rgb.split())
    mask = ImageChops.darker(ImageChops.darker(r, g), b)

    # flood fill background (value 128) from every border pixel that is a candidate
    draw = ImageDraw.Draw(mask)
    px = mask.load()
    border = [(x, 0) for x in range(w)] + [(x, h - 1) for x in range(w)] + \
             [(0, y) for y in range(h)] + [(w - 1, y) for y in range(h)]
    for x, y in border:
        if px[x, y] == 255:
            ImageDraw.floodfill(mask, (x, y), 128, thresh=0)
    background = mask.point(lambda v: 255 if v == 128 else 0)
    near_bg = background.filter(ImageFilter.MaxFilter(EDGE_BAND))

    src = rgb.load()
    bgp = background.load()
    nearp = near_bg.load()
    out = Image.new("RGBA", (w, h))
    op = out.load()
    for y in range(h):
        for x in range(w):
            if bgp[x, y]:
                op[x, y] = (0, 0, 0, 0)
                continue
            cr_, cg_, cb_ = src[x, y]
            if not nearp[x, y]:
                op[x, y] = (cr_, cg_, cb_, 255)
                continue
            # colour-to-alpha against white for the soft glow edge
            a = max(255 - cr_, 255 - cg_, 255 - cb_)
            if a == 0:
                op[x, y] = (0, 0, 0, 0)
                continue
            f = 255.0 / a
            op[x, y] = (
                max(0, min(255, int(round(255 - (255 - cr_) * f)))),
                max(0, min(255, int(round(255 - (255 - cg_) * f)))),
                max(0, min(255, int(round(255 - (255 - cb_) * f)))),
                a,
            )
    return out


def square(img: Image.Image, margin: float = 0.04) -> Image.Image:
    bbox = img.split()[3].point(lambda v: 255 if v > 10 else 0).getbbox()
    img = img.crop(bbox)
    side = int(max(img.size) * (1 + 2 * margin))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(img, ((side - img.width) // 2, (side - img.height) // 2), img)
    return canvas


def main() -> None:
    source = Path(sys.argv[1])
    assets = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    img = Image.open(source)
    # Artwork that already has a transparent background is used as-is.
    has_alpha = img.mode in ("RGBA", "LA") or "transparency" in img.info
    if has_alpha and img.convert("RGBA").getpixel((0, 0))[3] == 0:
        logo = square(img.convert("RGBA"))
    else:
        logo = square(remove_background(img))
    master = logo.resize((1024, 1024), Image.LANCZOS)
    master.save(assets / "logo.png")
    master.resize((256, 256), Image.LANCZOS).save(assets / "icon.png")
    sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
    frames = []
    for s in sizes:
        f = master.resize((s, s), Image.LANCZOS)
        if s <= 32:
            f = f.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=1))
        frames.append(f)
    frames[-1].save(assets / "icon.ico", format="ICO", sizes=[(s, s) for s in sizes], append_images=frames[:-1])
    print(f"written: {assets / 'icon.ico'}, icon.png, logo.png")


if __name__ == "__main__":
    main()
