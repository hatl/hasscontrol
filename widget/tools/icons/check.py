#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["resvg-py==0.5.0", "pillow==13.0.0", "numpy==2.5.5"]
# ///
"""Checks the SVG masters in resources-hires/drawables against the 60x60 PNGs they stand for.

usage: uv run tools/icons/check.py [NAME ...] [--sheet OUT.png] [--max-mean N]   (from widget/)

For every <name>.svg (or the NAMEs given) it renders the SVG at the size of
resources/drawables/<name>.png and prints the mean and the largest difference of the two alpha
channels (0-255). It also refuses markup beyond the plain subset the masters keep to: one <svg>
with xmlns/width/height/viewBox, holding <path fill="#FFFFFF" d="..."> (fill-opacity allowed).
Exit status 1 for a missing PNG, a square mismatch, other markup, or a mean above --max-mean.

The numbers only catch a wrong glyph or a misplaced one. Most pairs differ in their soft edges
alone: the older icons were rendered with cairo and come within a mean of 1; the 38 grey-edged
mdi_*.png carry their antialiasing in the colour channels, with an alpha of about its square
(mean up to 6); the meters, binary_* and lock_changing come from blurrier PNGs (2-3);
mdi_numeric is set in Roboto Bold where the PNG shows Arial Bold (about 5). A thin
stroke that is off hardly moves a mean - look at the --sheet as well: old PNG | SVG at the
PNG's size | SVG at twice that, on a dark ground. sources.tsv says where each master came from.
"""
import argparse
import glob
import io
import os
import sys
import xml.etree.ElementTree as ET

import numpy as np
import resvg_py
from PIL import Image, ImageDraw

WIDGET = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
ALLOWED = {"svg": {"xmlns", "width", "height", "viewBox"}, "path": {"fill", "fill-opacity", "d"}}


def render(svg, size):
    png = resvg_py.svg_to_bytes(svg_string=svg, width=size, height=size)
    return np.array(Image.open(io.BytesIO(bytes(png))).convert("RGBA"))[..., 3].astype(np.float32)


def markup_problems(svg):
    problems = []
    for el in ET.fromstring(svg).iter():
        tag = el.tag.split("}")[-1]
        problems += [f"<{tag}>"] if tag not in ALLOWED else [f"{tag}@{a}" for a in el.attrib if a not in ALLOWED[tag]]
        if tag == "path" and el.get("fill", "").upper() != "#FFFFFF":
            problems.append(f'fill="{el.get("fill")}"')
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("names", nargs="*", help="basenames to check (default: every SVG master)")
    ap.add_argument("--sheet", help="also write a contact sheet to this PNG file")
    ap.add_argument("--max-mean", type=float, default=8.0, help="fail above this mean difference (default 8)")
    a = ap.parse_args()
    hires, base = os.path.join(WIDGET, "resources-hires", "drawables"), os.path.join(WIDGET, "resources", "drawables")
    names = a.names or sorted(os.path.basename(f)[:-4] for f in glob.glob(os.path.join(hires, "*.svg")))
    failed, tiles = False, []
    for n in names:
        svg = open(os.path.join(hires, n + ".svg"), encoding="utf-8").read()
        png = os.path.join(base, n + ".png")
        problems = markup_problems(svg)
        if not os.path.exists(png):
            problems.append("no PNG of that name in resources/drawables")
        else:
            ref = np.array(Image.open(png).convert("RGBA"))[..., 3].astype(np.float32)
            if ref.shape[0] != ref.shape[1]:
                problems.append(f"PNG is {ref.shape[1]}x{ref.shape[0]}, not square")
            else:
                diff = np.abs(render(svg, ref.shape[0]) - ref)
                if diff.mean() > a.max_mean:
                    problems.append(f"mean above {a.max_mean}")
                print(f"{n:28s} {ref.shape[0]}px  mean {diff.mean():5.2f}  max {diff.max():3.0f}")
                tiles.append((n, ref, svg))
        for p in problems:
            print(f"{n:28s} PROBLEM: {p}")
        failed |= bool(problems)
    if a.sheet and tiles:
        write_sheet(a.sheet, tiles)
    sys.exit(1 if failed else 0)


def write_sheet(path, tiles, cols=4):
    def tile(alpha):
        im = Image.new("RGB", alpha.shape[::-1], (32, 34, 40))
        im.paste((255, 255, 255), (0, 0), Image.fromarray(alpha.astype(np.uint8)))
        return im
    cw, ch = 4 * 64 + 30, 128 + 20
    sheet = Image.new("RGB", (cols * cw, -(-len(tiles) // cols) * ch), (20, 20, 24))
    draw = ImageDraw.Draw(sheet)
    for i, (n, ref, svg) in enumerate(tiles):
        x, y, s = (i % cols) * cw + 6, (i // cols) * ch + 4, ref.shape[0]
        for dx, im in ((0, tile(ref)), (s + 6, tile(render(svg, s))), (2 * s + 12, tile(render(svg, 2 * s)))):
            sheet.paste(im, (x + dx, y))
        draw.text((x, y + 2 * s + 2), n, fill=(240, 220, 120))
    sheet.save(path)
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
