"""Tone curve / transfer function stages."""

from __future__ import annotations

import numpy as np

from ..frame import RawFrame
from ..pipeline import PipelineContext, PipelineStage, register_stage


@register_stage
class SRGBEncode(PipelineStage):
    """Apply the standard sRGB opto-electronic transfer function to linear RGB."""

    def process(self, frame: RawFrame, ctx: PipelineContext) -> RawFrame:
        if frame.is_mosaic:
            raise ValueError("SRGBEncode expects a demosaiced (RGB) frame")

        linear = np.clip(frame.data, 0.0, 1.0)
        encoded = np.where(
            linear <= 0.0031308,
            12.92 * linear,
            1.055 * np.power(linear, 1.0 / 2.4) - 0.055,
        ).astype(np.float32)
        return frame.with_data(encoded)
