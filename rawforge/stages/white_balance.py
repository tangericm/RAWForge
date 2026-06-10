"""White balance stages."""

from __future__ import annotations

import numpy as np

from ..frame import RawFrame
from ..pipeline import PipelineContext, PipelineStage, register_stage


@register_stage
class GrayWorldWB(PipelineStage):
    """Gray-world white balance: scale R and B so channel means match G."""

    def process(self, frame: RawFrame, ctx: PipelineContext) -> RawFrame:
        if frame.is_mosaic:
            raise ValueError("GrayWorldWB expects a demosaiced (RGB) frame")

        rgb = frame.data
        means = rgb.reshape(-1, 3).mean(axis=0)
        green = max(means[1], 1e-6)
        gains = np.array(
            [green / max(means[0], 1e-6), 1.0, green / max(means[2], 1e-6)],
            dtype=np.float32,
        )
        balanced = np.clip(rgb * gains, 0.0, 1.0)

        out = frame.with_data(balanced)
        out.metadata = {**frame.metadata, "applied_wb_gains": gains.tolist()}
        return out
