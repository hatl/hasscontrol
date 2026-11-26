#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["resvg-py==0.5.0", "pillow==13.0.0"]
# ///
"""Renders the large entity icons for the devices whose screen is 320 px or more on its smaller side.

usage: uv run tools/icons-render/render.py [--widget DIR] [--xml-only] [--check]   (from widget/)

Run it after adding or changing a master, and commit the PNGs and drawables.xml it writes (the
compiler reads those, not the SVGs). tools/icons/check.py compares the masters with the 60x60 PNGs,
tools/icons/sources.tsv says where each master came from.

The entity icons in resources/drawables/ are 60x60 bitmaps, drawn as they are: 21 % of a fenix 7X's
280 px screen, but 13 % of a 454 px one. resources-hires/ gives the larger screens the same icons at
the fenix 7X proportion; monkey.jungle attaches it to them. For every SVG master
resources-hires/drawables/<name>.svg (a white glyph, named like the PNG it stands for) this script

  1. renders resources-hires/drawables/<name>.png at twice the size of resources/drawables/<name>.png,
     every pixel the glyph covers made opaque in its colour times its coverage (see below), and
  2. writes resources-hires/drawables/drawables.xml, which redefines the bitmap ids of
     resources/drawables/drawables.xml that have such a PNG, with scaleX="<size of the PNG / 280>%".
     The resource compiler then scales each icon to that share of the screen width at build time:
     68 px at 320, 100 px at 466, 103 px at 480.

Why not let the compiler read the SVG, and why opaque edges (measured with SDK 9.3.0, 2026-11):
  * The bitmap format of most of these devices has no alpha plane (fenix 9 Pro, Forerunner 265,
    Venu, ...): there the compiler keeps no partial transparency - a pixel is drawn or not, in the
    colour it has. A white glyph with soft alpha edges, which is what an SVG renders to (the
    compiler's own SVG path included), comes out with hard, stair-stepped edges.
  * 17 of the 64 devices keep an alpha plane: those whose compiler.json has alphaBlendingSupport
    true and enhancedGraphicSupport not true (Venu Sq 2, vivoactive 5, Forerunner 165/70, the
    Edge 550/850/1050/1060 and Explore 3, Montana 7xx, ...). There a pixel is blended by its alpha.
  * A pixel of coverage a is therefore written opaque, in colour c*a: on black - the ground of
    every icon but the list's selected row - that is the exact antialiased picture on both kinds of
    device, and the meters' faint display window (fill-opacity 0.11) stays a faint grey. Colour
    premultiplied by a with alpha a, as the mdi_*.png of resources/drawables are, came out right
    only without an alpha plane: with one an edge was drawn c*a*a, thin and dark, and the meters'
    window black. The price is a dark rim where the ground is not black - the navy selected row
    of the list - which COVERAGE_CUTOFF keeps at the level the premultiplied edges had there
    (measured on the Venu Sq 2 and Forerunner 165, nearly none on the fenix 9 Pro; not visible at
    1x on any of them).
  * Its scaling samples without averaging: from a master four times the final size the edges come
    out almost as stepped again. Twice the base size (120 px, scaled to 57-86 % of it) keeps them.

The large icons are stored compressed (compress="true"): uncompressed they made the .prg 2.3 times
as large (debug builds: fenix 9 Pro 0.86 -> 1.99 MB, Edge 1050 1.10 -> 2.73 MB), compressed it is
smaller than before (release builds: fenix 9 Pro 0.68 -> 0.21 MB, Edge 1050 0.92 -> 0.39 MB). A
loaded icon is the same - same pixels, same heap: 14 kB for 83 px on a Venu, 32 kB for 103 px with
an alpha channel on a Montana 7xx, 320 bytes on Connect IQ 4+ where bitmaps live in the graphics
pool. The store package (.iq, a 7-zip archive of all the .prg files) grows all the same - 21.7 ->
28.8 MB - as it compressed the old uncompressed icons well.

--xml-only skips the rendering and only writes drawables.xml from the PNGs that are there.
--check renders nothing and writes nothing: it lists the icons of resources/drawables that have no
master in resources-hires yet (those stay 60x60 on the large screens) and exits 1 if there are any.
"""
import argparse
import io
import os
import re
import sys

import resvg_py
from PIL import Image, ImageChops

# The screen the 60x60 icons were drawn for: the fenix 7X's 280 px. The large set keeps that
# proportion, so an icon of the base set that is N px wide gets scaleX = N / 280.
REFERENCE_SCREEN = 280
# Bitmaps of resources/drawables/drawables.xml that are not entity icons. The launcher icon is sized
# by the compiler for every device anyway.
SKIP_IDS = {"LauncherIcon"}
# Coverage (0-255) up to which a pixel stays transparent: the faintest edge pixels, which on the
# list's navy selected row would only add to the dark rim (see the top of this file). Below 27, the
# coverage of the meters' display window, or that window disappears.
COVERAGE_CUTOFF = 20

# <bitmap .../> or <bitmap ...>children (a <palette>)</bitmap>
BITMAP = re.compile(r'<bitmap\s+([^>]*?)\s*(?:/>|>(.*?)</bitmap>)', re.S)
ATTR = re.compile(r'(\w+)="([^"]*)"')


def base_bitmaps(widget):
    """(id, filename, other attributes, children or None) for every entity icon of
    resources/drawables/drawables.xml."""
    xml = open(os.path.join(widget, "resources", "drawables", "drawables.xml")).read()
    xml = re.sub(r"<!--.*?-->", "", xml, flags=re.S)
    found = BITMAP.findall(xml)
    if len(found) != xml.count("<bitmap"):
        sys.exit(f"resources/drawables/drawables.xml: read {len(found)} of its {xml.count('<bitmap')} <bitmap>"
                 " elements - teach base_bitmaps() the form it has missed")
    out = []
    for attr_text, children in found:
        attrs = dict(ATTR.findall(attr_text))
        if attrs["id"] in SKIP_IDS:
            continue
        rest = [(k, v) for k, v in ATTR.findall(attr_text) if k not in ("id", "filename")]
        out.append((attrs["id"], attrs["filename"], rest, children.strip() or None))
    return out


def render(svg, png, size):
    """SVG -> square PNG of `size` px: every pixel of coverage a > COVERAGE_CUTOFF opaque in colour
    c*a, the rest transparent black (see the top of this file). resvg, as in tools/icons/check.py."""
    raw = resvg_py.svg_to_bytes(svg_string=open(svg).read(), width=size, height=size)
    im = Image.open(io.BytesIO(bytes(raw))).convert("RGBA")
    if im.size != (size, size):
        sys.exit(f"{svg}: rendered as {im.size[0]}x{im.size[1]}, expected {size}x{size} (is the SVG square?)")
    alpha = im.getchannel("A")
    rgb = ImageChops.multiply(im.convert("RGB"), Image.merge("RGB", (alpha, alpha, alpha)))
    covered = alpha.point(lambda a: 255 if a > COVERAGE_CUTOFF else 0)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(rgb, mask=covered)
    out.putalpha(covered)
    out.save(png, optimize=True)


def write_xml(widget, entries):
    lines = [
        "<resources>",
        "    <drawables>",
        "        <!-- Generated by tools/icons-render/render.py from the SVG masters in this folder:",
        "             edit those or the script, not this file. The entity icons of",
        "             resources/drawables/drawables.xml once more, for the screens of 320 px and",
        "             more (attached per screen size in monkey.jungle), scaled by the compiler to",
        "             the share of the screen width a 60x60 icon has on the fenix 7X's 280 px.",
        "             scaleX alone keeps them square: scaleY follows it, as a share of the width",
        "             too. (With both given, Y would be a share of the height - an oval on the",
        "             rectangular screens. All of them are portrait, so the width is the smaller",
        "             side.) Compressed, as they would make the .prg more than twice as large.",
        "             An icon without a master here stays 60x60 on those screens. -->",
    ]
    for bid, fname, rest, children, scale in entries:
        head = f'        <bitmap id="{bid}" filename="{fname}" scaleX="{scale}"' \
               + "".join(f' {k}="{v}"' for k, v in rest) + ' compress="true"'
        lines.append(head + (f">{children}</bitmap>" if children else " />"))
    lines += ["    </drawables>", "</resources>", ""]
    path = os.path.join(widget, "resources-hires", "drawables", "drawables.xml")
    open(path, "w").write("\n".join(lines))
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--widget", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."),
                    help="the widget directory (default: the one this script is in)")
    ap.add_argument("--xml-only", action="store_true", help="write drawables.xml from the PNGs that are there")
    ap.add_argument("--check", action="store_true", help="list the icons without a master; exit 1 if any")
    a = ap.parse_args()
    widget = os.path.abspath(a.widget)
    base_dir = os.path.join(widget, "resources", "drawables")
    hires_dir = os.path.join(widget, "resources-hires", "drawables")
    bitmaps = base_bitmaps(widget)

    if a.check:
        missing = [f for _, f, _, _ in bitmaps
                   if not os.path.exists(os.path.join(hires_dir, os.path.splitext(f)[0] + ".svg"))]
        for f in missing:
            print(f"no master: resources-hires/drawables/{os.path.splitext(f)[0]}.svg")
        print(f"{len(bitmaps) - len(missing)} of {len(bitmaps)} icons have a master")
        sys.exit(1 if missing else 0)

    jobs = []
    for bid, fname, rest, children in bitmaps:
        stem = os.path.splitext(fname)[0]
        svg = os.path.join(hires_dir, stem + ".svg")
        if os.path.exists(svg):
            size = 2 * Image.open(os.path.join(base_dir, fname)).size[0]
            jobs.append((svg, os.path.join(hires_dir, stem + ".png"), size))
    if not a.xml_only:
        for svg, png, size in jobs:
            render(svg, png, size)
        print(f"rendered {len(jobs)} icons")

    entries = []
    for bid, fname, rest, children in bitmaps:
        png = os.path.join(hires_dir, os.path.splitext(fname)[0] + ".png")
        if not os.path.exists(png):
            continue
        width = Image.open(os.path.join(base_dir, fname)).size[0]
        entries.append((bid, os.path.basename(png), rest, children, f"{width * 100 / REFERENCE_SCREEN:.1f}%"))
    path = write_xml(widget, entries)
    print(f"wrote {path}: {len(entries)} of {len(bitmaps)} icons")


if __name__ == "__main__":
    main()
