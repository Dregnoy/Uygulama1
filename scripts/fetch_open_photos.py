"""Download open-license portrait & street photos from Wikimedia Commons Quality/Featured
categories into `dataset/iyi/` for aesthetic model training.

Usage:
    python scripts/fetch_open_photos.py --out dataset/iyi --limit 120
"""

import argparse
import json
from pathlib import Path
import time
import urllib.parse
import urllib.request

from PIL import Image


USER_AGENT = "SuperposeAIDatasetBuilder/1.0 (https://github.com/Dregnoy/Superpose-AI)"
CATEGORIES = [
    "Category:Quality_images_of_portraits",
    "Category:Quality_images_of_street_photography",
    "Category:Featured_pictures_of_people",
    "Category:Quality_images_of_people",
    "Category:Portrait_photographs",
    "Category:Featured_pictures_of_portraits",
    "Category:Quality_images_of_women",
    "Category:Quality_images_of_men",
]


def fetch_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def list_category_files(category: str, limit: int) -> list[str]:
    params = urllib.parse.urlencode(
        {
            "action": "query",
            "list": "categorymembers",
            "cmtitle": category,
            "cmtype": "file",
            "cmlimit": str(min(limit, 100)),
            "format": "json",
        }
    )
    data = fetch_json(f"https://commons.wikimedia.org/w/api.php?{params}")
    return [m["title"] for m in data.get("query", {}).get("categorymembers", [])]


def get_thumb_urls(titles: list[str]) -> list[tuple[str, str]]:
    results: list[tuple[str, str]] = []
    for i in range(0, len(titles), 25):
        batch = "|".join(titles[i : i + 25])
        params = urllib.parse.urlencode(
            {
                "action": "query",
                "titles": batch,
                "prop": "imageinfo",
                "iiprop": "url|mime",
                "iiurlwidth": "640",
                "format": "json",
            }
        )
        data = fetch_json(f"https://commons.wikimedia.org/w/api.php?{params}")
        for page in data.get("query", {}).get("pages", {}).values():
            info = (page.get("imageinfo") or [{}])[0]
            mime = info.get("mime", "")
            url = info.get("thumburl") or info.get("url")
            if url and mime in ("image/jpeg", "image/png"):
                results.append((page.get("title", "photo"), url))
    return results


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=Path("dataset/iyi"))
    parser.add_argument("--limit", type=int, default=120)
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    all_titles: list[str] = []
    per_cat = max(40, args.limit // len(CATEGORIES) + 15)
    for cat in CATEGORIES:
        try:
            all_titles.extend(list_category_files(cat, per_cat))
        except Exception as exc:
            print(f"Skipping {cat}: {exc}")

    # Deduplicate
    seen = set()
    unique_titles = [t for t in all_titles if not (t in seen or seen.add(t))]
    items = get_thumb_urls(unique_titles)

    saved = 0
    for idx, (_, url) in enumerate(items):
        if saved >= args.limit:
            break
        dest = args.out / f"open_photo_{idx:04d}.jpg"
        if dest.exists():
            saved += 1
            continue
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = resp.read()
            dest.write_bytes(data)
            with Image.open(dest) as img:
                img.verify()
            saved += 1
            if saved % 20 == 0:
                print(f"Downloaded {saved}/{args.limit}...")
            time.sleep(0.05)
        except Exception:
            if dest.exists():
                dest.unlink(missing_ok=True)

    print(f"Ready: {saved} verified photos in {args.out}")


if __name__ == "__main__":
    main()
