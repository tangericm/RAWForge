"""RawFrame: the normalized container every pipeline stage consumes and produces."""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from typing import Any

import numpy as np

# CFA pattern strings are the 2x2 tile read row-major, e.g. "RGGB" means
#   R G
#   G B
KNOWN_CFA_PATTERNS = ("RGGB", "BGGR", "GRBG", "GBRG")

# Sentinel pattern for frames that are no longer mosaiced (post-demosaic RGB).
CFA_NONE = "NONE"


@dataclass
class RawFrame:
    """A RAW frame plus the metadata needed to develop it.

    `data` is float32 throughout the pipeline:
      - mosaic stage: H x W, in sensor units (loader does not normalize)
      - after demosaic: H x W x 3 RGB
    """

    data: np.ndarray
    cfa_pattern: str = "RGGB"
    # Black level per CFA tile position (row-major, same order as cfa_pattern).
    black_level: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)
    white_level: float = 1.0
    # As-shot white balance gains (R, G, B), if the source provided them.
    wb_gains: tuple[float, float, float] = (1.0, 1.0, 1.0)
    # 3x3 camera-RGB -> sRGB color correction matrix, or None if unknown.
    ccm: np.ndarray | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        self.data = np.asarray(self.data, dtype=np.float32)
        if self.cfa_pattern != CFA_NONE and self.cfa_pattern not in KNOWN_CFA_PATTERNS:
            raise ValueError(
                f"Unsupported CFA pattern {self.cfa_pattern!r}; "
                f"expected one of {KNOWN_CFA_PATTERNS} or {CFA_NONE!r}"
            )
        if self.cfa_pattern != CFA_NONE and self.data.ndim != 2:
            raise ValueError("Mosaic frames must be 2-D (H x W)")
        if self.cfa_pattern == CFA_NONE and not (self.data.ndim == 3 and self.data.shape[2] == 3):
            raise ValueError("Demosaiced frames must be H x W x 3")

    @property
    def is_mosaic(self) -> bool:
        return self.cfa_pattern != CFA_NONE

    def with_data(self, data: np.ndarray, *, cfa_pattern: str | None = None) -> "RawFrame":
        """Copy of this frame with new pixel data (and optionally a new CFA state)."""
        return replace(
            self,
            data=data,
            cfa_pattern=self.cfa_pattern if cfa_pattern is None else cfa_pattern,
        )

    def cfa_masks(self) -> dict[str, np.ndarray]:
        """Boolean H x W masks for each color plane of the mosaic ("R", "G", "B")."""
        if not self.is_mosaic:
            raise ValueError("cfa_masks() only applies to mosaic frames")
        h, w = self.data.shape
        masks = {c: np.zeros((h, w), dtype=bool) for c in "RGB"}
        for idx, color in enumerate(self.cfa_pattern):
            row, col = divmod(idx, 2)
            masks[color][row::2, col::2] = True
        return masks

    def serializable_metadata(self) -> dict[str, Any]:
        """Frame attributes as plain JSON-serializable types (for job metadata)."""
        return {
            "cfa_pattern": self.cfa_pattern,
            "shape": list(self.data.shape),
            "black_level": list(self.black_level),
            "white_level": float(self.white_level),
            "wb_gains": list(self.wb_gains),
            "ccm": self.ccm.tolist() if self.ccm is not None else None,
            "metadata": {k: v for k, v in self.metadata.items() if _is_jsonable(v)},
        }


def _is_jsonable(value: Any) -> bool:
    return isinstance(value, (str, int, float, bool, type(None), list, dict))
