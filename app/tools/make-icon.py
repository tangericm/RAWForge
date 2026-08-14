#!/usr/bin/env python3
"""Generates the app icon.

Kept as a script rather than a committed binary blob so the icon has the same
property as everything else here: it is reproducible and its definition is
readable. No Pillow, no ImageMagick — the encoder below is a few dozen lines of
zlib and struct, which is cheaper than a toolchain dependency on this machine.

The mark is the Bayer mosaic the app exists to capture — R, G, G, B in a 2x2
quad — inside an aperture ring. Run:

    python3 tools/make-icon.py
"""

import struct
import zlib
from pathlib import Path

SIZE = 1024
SS = 4                      # supersample factor, downsampled for antialiasing
N = SIZE * SS
CENTRE = N / 2

BACKGROUND_TOP = (0x15, 0x18, 0x1F)
BACKGROUND_BOTTOM = (0x08, 0x09, 0x0D)
RING = (0xEC, 0xEE, 0xF2)

# The mosaic, in CFA order: R and B on one diagonal, the two greens on the
# other. Muted rather than saturated so it reads as an instrument, not a toy.
RED = (0xD9, 0x4B, 0x50)
GREEN = (0x4F, 0xB8, 0x76)
BLUE = (0x4B, 0x7C, 0xE0)

DISC_RADIUS = 0.335 * N
RING_INNER = 0.375 * N
RING_OUTER = 0.415 * N
GAP = 0.012 * N             # the seam between quadrants


def quadrant_colour(x, y):
    left, top = x < CENTRE, y < CENTRE
    if top and left:
        return RED
    if top and not left:
        return GREEN
    if not top and left:
        return GREEN
    return BLUE


def render():
    rows = []
    for y in range(N):
        row = bytearray()
        t = y / (N - 1)
        base = tuple(
            round(a + (b - a) * t) for a, b in zip(BACKGROUND_TOP, BACKGROUND_BOTTOM)
        )
        dy = y - CENTRE
        for x in range(N):
            dx = x - CENTRE
            r2 = dx * dx + dy * dy
            if RING_INNER * RING_INNER <= r2 <= RING_OUTER * RING_OUTER:
                px = RING
            elif r2 <= DISC_RADIUS * DISC_RADIUS:
                # The seam keeps the four cells legible at 60 px.
                px = base if abs(dx) < GAP or abs(dy) < GAP else quadrant_colour(x, y)
            else:
                px = base
            row += bytes(px)
        rows.append(bytes(row))
    return rows


def downsample(rows):
    """Box filter from N to SIZE — this is where the curves get their edges."""
    out = []
    for y in range(SIZE):
        row = bytearray()
        block = rows[y * SS:(y + 1) * SS]
        for x in range(SIZE):
            r = g = b = 0
            for sub in block:
                base = x * SS * 3
                for k in range(SS):
                    r += sub[base + k * 3]
                    g += sub[base + k * 3 + 1]
                    b += sub[base + k * 3 + 2]
            n = SS * SS
            row += bytes((r // n, g // n, b // n))
        out.append(bytes(row))
    return out


def write_png(path, rows):
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        body = tag + data
        return (struct.pack(">I", len(data)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    Path(path).write_bytes(png)


if __name__ == "__main__":
    target = Path(__file__).resolve().parent.parent / \
        "RAWForge/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    write_png(target, downsample(render()))
    print(f"wrote {target}")
