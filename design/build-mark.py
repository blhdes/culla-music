#!/usr/bin/env python3
"""Builds every Culla Music mark file from the workshop line (L1, 2026-11-13).

    mark=B ring=0.275 stroke=0.145 gap=77 turn=317 sit=0.000 dot=0.065
    caps=round accent=#0A09EF bg=#EEF0F3 ink=#FFFFFF pad=0.10

Sizes are fractions of the 1024 canvas (ring and dot are radii). Angles are
degrees, 0 = right, clockwise. The ring's stroke is turned into a filled
outline, so every file holds filled shapes only (Icon Composer wants that).

Run from the repo root:  python3 design/build-mark.py
"""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DESIGN = ROOT / "design"
ASSETS = ROOT / "CullaMusic/CullaMusic/Assets.xcassets"

# The line, as numbers.
U, C = 1024, 512
RING, STROKE, GAP, TURN, DOT, PAD = 0.275, 0.145, 77, 317, 0.065, 0.10
ACCENT, BG, INK = "#0A09EF", "#EEF0F3", "#FFFFFF"

R, W, D = RING * U, STROKE * U, DOT * U
R_OUT, R_IN, CAP = R + W / 2, R - W / 2, W / 2
A0, A1 = TURN + GAP / 2, TURN + 360 - GAP / 2  # the ring runs clockwise A0 -> A1


def n(v: float) -> str:
    return f"{round(v, 2):g}"


def pt(r: float, deg: float) -> str:
    a = math.radians(deg)
    return f"{n(C + r * math.cos(a))} {n(C + r * math.sin(a))}"


# Open ring with round ends: outer arc, end cap, inner arc back, start cap.
RING_PATH = (
    f"M{pt(R_OUT, A0)}"
    f"A{n(R_OUT)} {n(R_OUT)} 0 1 1 {pt(R_OUT, A1)}"
    f"A{n(CAP)} {n(CAP)} 0 0 1 {pt(R_IN, A1)}"
    f"A{n(R_IN)} {n(R_IN)} 0 1 0 {pt(R_IN, A0)}"
    f"A{n(CAP)} {n(CAP)} 0 0 1 {pt(R_OUT, A0)}Z"
)
DOT_PATH = f"M{n(C - D)} {C}A{n(D)} {n(D)} 0 1 0 {n(C + D)} {C}A{n(D)} {n(D)} 0 1 0 {n(C - D)} {C}Z"

# In-app crop: the glyph plus PAD of empty margin on each side.
HALF = R_OUT / (1 - 2 * PAD)
CROP = f"{n(C - HALF)} {n(C - HALF)} {n(2 * HALF)} {n(2 * HALF)}"


def svg(view_box: str, size: float, *paths: tuple[str, str]) -> str:
    body = "".join(f'\n  <path fill="{fill}" d="{d}"/>' for fill, d in paths)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{n(size)}" height="{n(size)}" '
        f'viewBox="{view_box}">{body}\n</svg>\n'
    )


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    print("wrote", path.relative_to(ROOT))


def image_set(name: str, svg_name: str, svg_text: str, template: bool) -> None:
    folder = ASSETS / f"{name}.imageset"
    write(folder / svg_name, svg_text)
    contents = {
        "images": [{"filename": svg_name, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {
            "preserves-vector-representation": True,
            "template-rendering-intent": "template" if template else "original",
        },
    }
    write(folder / "Contents.json", json.dumps(contents, indent=2, separators=(",", " : ")) + "\n")


FULL = f"0 0 {U} {U}"
CROPPED = 2 * HALF

# Icon Composer layers: full 1024 canvas, back to front. The background
# (BG) is a fill colour in AppIcon.icon/icon.json, not a file. The same two
# files are copied into the .icon bundle, which is what Xcode builds.
ICON_ASSETS = ROOT / "CullaMusic/CullaMusic/AppIcon.icon/Assets"
for name, fill, d in (("1-glyph.svg", INK, RING_PATH), ("2-accent.svg", ACCENT, DOT_PATH)):
    write(DESIGN / "icon-layers" / name, svg(FULL, U, (fill, d)))
    write(ICON_ASSETS / name, svg(FULL, U, (fill, d)))

# Masters for everything else (website, store, docs).
write(DESIGN / "culla-mark.svg", svg(CROP, CROPPED, ("#000000", RING_PATH), ("#000000", DOT_PATH)))
write(DESIGN / "culla-mark-color.svg", svg(CROP, CROPPED, ("#000000", RING_PATH), (ACCENT, DOT_PATH)))

# In-app: the same two layers as the icon, sharing one crop so they stack
# exactly. The ring is a template (follows .primary); the dot keeps its blue.
image_set("CullaMarkRing", "culla-mark-ring.svg", svg(CROP, CROPPED, ("#000000", RING_PATH)), template=True)
image_set("CullaMarkDot", "culla-mark-dot.svg", svg(CROP, CROPPED, (ACCENT, DOT_PATH)), template=False)
