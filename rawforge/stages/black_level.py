"""Black level subtraction and normalization to [0, 1]."""

from __future__ import annotations

import numpy as np

from ..frame import RawFrame
from ..pipeline import PipelineContext, PipelineStage, register_stage


@register_stage
class BlackLevel(PipelineStage):
    """Subtract the per-CFA-position black level and normalize by white level.

    Output is a mosaic in [0, 1] with black_level zeroed and white_level 1.0.
    """

    def process(self, frame: RawFrame, ctx: PipelineContext) -> RawFrame:
        if not frame.is_mosaic:
            raise ValueError("BlackLevel expects a mosaic frame")

        h, w = frame.data.shape
        black = np.zeros((h, w), dtype=np.float32)
        for idx, level in enumerate(frame.black_level):
            row, col = divmod(idx, 2)
            black[row::2, col::2] = level

        scale = np.maximum(frame.white_level - black, 1e-6)
        normalized = np.clip((frame.data - black) / scale, 0.0, 1.0)

        out = frame.with_data(normalized)
        out.black_level = (0.0, 0.0, 0.0, 0.0)
        out.white_level = 1.0
        return out
