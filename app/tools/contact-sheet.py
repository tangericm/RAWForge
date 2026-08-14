#!/usr/bin/env python3
"""Tiles simulator screenshots into one labelled contact sheet.

There is no Pillow, no ImageMagick and no PyObjC on this machine, so the PNG
decoder below is the counterpart to the encoder in `make-icon.py`. Between them
they are cheaper than a toolchain dependency, and they keep the design artifacts
reproducible from a command rather than assembled by hand.

    python3 tools/contact-sheet.py out.png a.png b.png ...
"""

import struct
import sys
import zlib
from pathlib import Path

SCALE = 3                 # integer downsample; 1206x2622 -> 402x874
GAP = 18
MARGIN = 22
LABEL_H = 34
BACKGROUND = (0x16, 0x18, 0x1E)
LABEL_BG = (0x2A, 0x2E, 0x38)
LABEL_FG = (0xF2, 0xF4, 0xF8)

# A 5x7 bitmap for the digits used as panel numbers. Anything more would mean
# shipping a font to draw four characters.
DIGITS = {
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    "3": ["####.", "....#", "....#", ".###.", "....#", "....#", "####."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
}


def read_png(path):
    """Returns (width, height, rows) with rows as RGB bytes."""
    data = Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path} is not a PNG"
    pos, idat, width = 8, b"", None
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            width, height, depth, colour = struct.unpack(">IIBB", body[:10])
            assert depth == 8, f"{path}: only 8-bit is handled, got {depth}"
            assert colour in (2, 6), f"{path}: unexpected colour type {colour}"
            channels = 3 if colour == 2 else 4
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
        pos += 12 + length

    raw = zlib.decompress(idat)
    stride = width * channels
    rows, previous, offset = [], bytearray(stride), 0
    for _ in range(height):
        filt = raw[offset]
        line = bytearray(raw[offset + 1:offset + 1 + stride])
        offset += 1 + stride
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = previous[i]
            c = previous[i - channels] if i >= channels else 0
            if filt == 1:
                line[i] = (line[i] + a) & 0xFF
            elif filt == 2:
                line[i] = (line[i] + b) & 0xFF
            elif filt == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        previous = line
        if channels == 4:                       # drop alpha; the shots are opaque
            rows.append(bytes(b for i, b in enumerate(line) if i % 4 != 3))
        else:
            rows.append(bytes(line))
    return width, height, rows


def downsample(width, height, rows, factor):
    w, h = width // factor, height // factor
    out = []
    for y in range(h):
        block = rows[y * factor:(y + 1) * factor]
        line = bytearray()
        for x in range(w):
            r = g = b = 0
            for src in block:
                base = x * factor * 3
                for k in range(factor):
                    r += src[base + k * 3]
                    g += src[base + k * 3 + 1]
                    b += src[base + k * 3 + 2]
            n = factor * factor
            line += bytes((r // n, g // n, b // n))
        out.append(bytes(line))
    return w, h, out


def write_png(path, width, rows):
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, body):
        payload = tag + body
        return (struct.pack(">I", len(body)) + payload
                + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF))

    Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, len(rows), 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b""))


def main():
    out, sources = sys.argv[1], sys.argv[2:]
    panels = []
    for s in sources:
        w, h, rows = read_png(s)
        panels.append(downsample(w, h, rows, SCALE))

    pw, ph = panels[0][0], panels[0][1]
    cols = 2 if len(panels) > 2 else len(panels)
    rows_of = (len(panels) + cols - 1) // cols
    cell_h = LABEL_H + ph
    sheet_w = MARGIN * 2 + cols * pw + (cols - 1) * GAP
    sheet_h = MARGIN * 2 + rows_of * cell_h + (rows_of - 1) * GAP

    canvas = [bytearray(bytes(BACKGROUND) * sheet_w) for _ in range(sheet_h)]

    def blit(px, py, w, h, src_rows):
        for y in range(h):
            canvas[py + y][(px + 0) * 3:(px + w) * 3] = src_rows[y]

    def fill(px, py, w, h, colour):
        run = bytes(colour) * w
        for y in range(h):
            canvas[py + y][px * 3:(px + w) * 3] = run

    def digit(px, py, ch, size):
        glyph = DIGITS[ch]
        for gy, line in enumerate(glyph):
            for gx, on in enumerate(line):
                if on == "#":
                    fill(px + gx * size, py + gy * size, size, size, LABEL_FG)

    for i, (w, h, rws) in enumerate(panels):
        cx = MARGIN + (i % cols) * (pw + GAP)
        cy = MARGIN + (i // cols) * (cell_h + GAP)
        fill(cx, cy, pw, LABEL_H, LABEL_BG)
        digit(cx + 12, cy + 7, str(i + 1), 3)
        blit(cx, cy + LABEL_H, w, h, rws)

    write_png(out, sheet_w, [bytes(r) for r in canvas])
    print(f"wrote {out} — {sheet_w}x{sheet_h}, {len(panels)} panels")


if __name__ == "__main__":
    main()
