"""Input/output: camera RAW ingestion (via rawpy) and rendered-image writing."""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image

from .frame import KNOWN_CFA_PATTERNS, RawFrame

RAW_EXTENSIONS = {".dng", ".arw", ".cr2", ".cr3", ".nef", ".raf", ".rw2", ".orf"}


def load_raw(path: str | Path) -> RawFrame:
    """Load a camera RAW file into a normalized RawFrame.

    Requires the `rawpy` extra: pip install rawforge[raw]
    """
    try:
        import rawpy
    except ImportError as e:  # pragma: no cover - exercised only without the extra
        raise ImportError(
            "Reading camera RAW files requires rawpy. Install with: pip install rawforge[raw]"
        ) from e

    path = Path(path)
    with rawpy.imread(str(path)) as raw:
        # Linear / already-demosaiced DNGs (e.g. Adobe "rgb" variants, some
        # lossy-compressed phone DNGs) have no Bayer pattern to process.
        if raw.raw_pattern is None:
            raise ValueError(
                f"{path.name} has no Bayer mosaic - it appears to be a linear "
                "(already-demosaiced) DNG. Only standard Bayer RAWs are supported for now."
            )

        mosaic = raw.raw_image_visible.astype(np.float32).copy()

        color_desc = raw.color_desc.decode("ascii")  # e.g. "RGBG"
        # NOTE: we treat raw_pattern as describing the visible area's origin.
        # LibRaw's COLOR() is documented in visible-area coordinates, and all
        # cameras verified so far (even-margin Canon, zero-margin iPhones,
        # including a BGGR iPhone SE) render correctly. If an odd-margin camera
        # ever shows a 1-pixel color checkerboard, revisit this with
        # raw.sizes.top_margin/left_margin parity.
        pattern_idx = np.asarray(raw.raw_pattern)
        # Map the second green (often a distinct index) to plain "G".
        letters = ["G" if color_desc[i] == "G" else color_desc[i] for i in pattern_idx.flatten()]
        cfa_pattern = "".join(letters)
        if cfa_pattern not in KNOWN_CFA_PATTERNS:
            raise ValueError(
                f"Unsupported CFA pattern {cfa_pattern!r} in {path.name} "
                "(only standard Bayer is supported for now)"
            )

        black_per_channel = list(raw.black_level_per_channel)
        black_level = tuple(float(black_per_channel[i]) for i in pattern_idx.flatten())

        cam_wb = list(raw.camera_whitebalance)
        g = cam_wb[1] if cam_wb[1] else 1.0
        wb_gains = (cam_wb[0] / g, 1.0, cam_wb[2] / g)

        ccm = np.asarray(raw.color_matrix, dtype=np.float32)[:3, :3]
        if not np.any(ccm):
            ccm = None

        return RawFrame(
            data=mosaic,
            cfa_pattern=cfa_pattern,
            black_level=black_level,  # type: ignore[arg-type]
            white_level=float(raw.white_level),
            wb_gains=wb_gains,
            ccm=ccm,
            metadata={"source_file": path.name},
        )


def save_png(data: np.ndarray, path: str | Path) -> None:
    """Write an H x W x 3 float array in [0, 1] as an 8-bit PNG."""
    if data.ndim != 3 or data.shape[2] != 3:
        raise ValueError("save_png expects an H x W x 3 RGB array")
    img = (np.clip(data, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
    Image.fromarray(img, mode="RGB").save(str(path))
