"""Display-ready previews of frames at any pipeline stage.

Frames mid-pipeline are not directly viewable: mosaics are single-channel in
sensor units, and everything before SRGBEncode is linear (near-black on
screen). This module renders an honest *visualization* — decimated, grayscale
for mosaics, display-encoded for linear data — without touching pipeline data.
"""

from __future__ import annotations

import numpy as np
from PIL import Image

from .color import srgb_encode
from .frame import RawFrame


def render_preview(frame: RawFrame, max_dim: int = 1024) -> Image.Image:
    """Render a frame as a small display-ready PIL image."""
    data = frame.data
    h, w = data.shape[:2]
    factor = max(1, -(-max(h, w) // max_dim))  # ceil division

    if frame.is_mosaic:
        # Keep the factor even so decimation samples one CFA position per
        # pixel; an odd factor mixes R/G/B samples into a checkerboard.
        if factor > 1 and factor % 2:
            factor += 1
        sub = data[::factor, ::factor]
        gray = np.clip(sub / max(frame.white_level, 1e-6), 0.0, 1.0)
        rgb = np.stack([gray] * 3, axis=-1)
        encoded = srgb_encode(rgb)  # raw values are linear
    else:
        sub = np.clip(data[::factor, ::factor], 0.0, 1.0)
        encoded = sub if frame.metadata.get("display_encoded") else srgb_encode(sub)

    img = Image.fromarray((encoded * 255.0 + 0.5).astype(np.uint8), "RGB")
    if max(img.size) > max_dim:
        img.thumbnail((max_dim, max_dim), Image.Resampling.BILINEAR)
    return img


def save_preview(frame: RawFrame, path, max_dim: int = 1024) -> None:
    render_preview(frame, max_dim=max_dim).save(str(path))
