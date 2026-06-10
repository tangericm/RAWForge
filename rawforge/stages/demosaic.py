"""Demosaicing stages."""

from __future__ import annotations

import numpy as np

from ..frame import CFA_NONE, RawFrame
from ..pipeline import PipelineContext, PipelineStage, register_stage


def _box3_sum(arr: np.ndarray) -> np.ndarray:
    """Sum over each pixel's 3x3 neighborhood (zero-padded borders)."""
    padded = np.pad(arr, 1, mode="edge")
    out = np.zeros_like(arr, dtype=np.float32)
    for dr in range(3):
        for dc in range(3):
            out += padded[dr : dr + arr.shape[0], dc : dc + arr.shape[1]]
    return out


@register_stage
class BilinearDemosaic(PipelineStage):
    """Bilinear interpolation via normalized convolution over each color plane.

    Simple and artifact-prone (zippering on edges) but a correct baseline;
    Malvar-He-Cutler is the planned upgrade.
    """

    def process(self, frame: RawFrame, ctx: PipelineContext) -> RawFrame:
        if not frame.is_mosaic:
            raise ValueError("BilinearDemosaic expects a mosaic frame")

        masks = frame.cfa_masks()
        h, w = frame.data.shape
        rgb = np.zeros((h, w, 3), dtype=np.float32)

        for ch, color in enumerate("RGB"):
            mask = masks[color].astype(np.float32)
            values = frame.data * mask
            weight = _box3_sum(mask)
            rgb[:, :, ch] = _box3_sum(values) / np.maximum(weight, 1e-6)

        return frame.with_data(rgb, cfa_pattern=CFA_NONE)
