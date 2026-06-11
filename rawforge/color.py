"""Shared color/transfer-function helpers."""

from __future__ import annotations

import numpy as np

# The curve's max slope is ~12.92 (at the dark end), so a nearest-neighbor
# LUT errs by up to slope * step / 2. 65536 entries keeps that under 1e-4 —
# invisible at 8-bit and safe for future 16-bit output. 256 KB, built once.
_LUT_SIZE = 65536
_lut_cache: np.ndarray | None = None


def _srgb_lut() -> np.ndarray:
    global _lut_cache
    if _lut_cache is None:
        x = np.linspace(0.0, 1.0, _LUT_SIZE, dtype=np.float64)
        _lut_cache = np.where(
            x <= 0.0031308,
            12.92 * x,
            1.055 * np.power(x, 1.0 / 2.4) - 0.055,
        ).astype(np.float32)
    return _lut_cache


def srgb_encode(linear: np.ndarray) -> np.ndarray:
    """sRGB OETF via lookup table — ~10x faster than np.power on full frames."""
    lut = _srgb_lut()
    idx = (np.clip(linear, 0.0, 1.0) * (_LUT_SIZE - 1) + 0.5).astype(np.uint16)
    return lut[idx]
