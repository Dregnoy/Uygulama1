"""Generate realistic poorly-framed, blurry, tilted, and poorly-exposed training
samples in `dataset/kotu/` from clean photos in `dataset/iyi/`.

Usage:
    python scripts/generate_bad_samples.py --good dataset/iyi --bad dataset/kotu
"""

import argparse
from pathlib import Path
import random

from PIL import Image, ImageEnhance, ImageFilter


IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".heic"}


def make_bad_crop(img: Image.Image, rng: random.Random) -> Image.Image:
    w, h = img.size
    # Crop off top or side to simulate cut-off head / awkward framing
    top_cut = rng.uniform(0.18, 0.30) if rng.random() < 0.6 else 0.0
    side_cut = rng.uniform(0.18, 0.30) if top_cut == 0.0 else 0.0
    left = int(w * side_cut)
    top = int(h * top_cut)
    right = w if side_cut == 0.0 else w
    bottom = int(h * (0.88 if top_cut == 0.0 else 1.0))
    cropped = img.crop((left, top, right, bottom))
    return cropped.resize((w, h), Image.Resampling.BICUBIC)


def make_tilted(img: Image.Image, rng: random.Random) -> Image.Image:
    angle = rng.choice([-14, -10, 10, 14])
    return img.rotate(angle, resample=Image.Resampling.BICUBIC, expand=False)


def make_blurry(img: Image.Image, rng: random.Random) -> Image.Image:
    radius = rng.uniform(2.8, 5.0)
    return img.filter(ImageFilter.GaussianBlur(radius=radius))


def make_bad_exposure(img: Image.Image, rng: random.Random) -> Image.Image:
    enhancer = ImageEnhance.Brightness(img)
    factor = rng.uniform(0.28, 0.45) if rng.random() < 0.6 else rng.uniform(1.55, 1.85)
    return enhancer.enhance(factor)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate synthetic bad framing/lighting samples")
    parser.add_argument("--good", type=Path, default=Path("dataset/iyi"), help="Folder of good photos")
    parser.add_argument("--bad", type=Path, default=Path("dataset/kotu"), help="Output folder for bad samples")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    if not args.good.exists():
        raise SystemExit(f"Good dataset folder not found: {args.good}")

    args.bad.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)

    transforms = [
        ("crop", make_bad_crop),
        ("tilt", make_tilted),
        ("blur", make_blurry),
        ("exp", make_bad_exposure),
    ]

    sources = [p for p in args.good.rglob("*") if p.suffix.lower() in IMAGE_EXTENSIONS]
    if not sources:
        raise SystemExit(f"No images found in {args.good}")

    created = 0
    for src in sources:
        with Image.open(src) as img:
            rgb = img.convert("RGB")
            for tag, fn in rng.sample(transforms, k=2):
                bad_img = fn(rgb, rng)
                out_path = args.bad / f"{src.stem}_{tag}.jpg"
                bad_img.save(out_path, quality=88)
                created += 1

    print(f"Generated {created} bad samples in: {args.bad}")


if __name__ == "__main__":
    main()
