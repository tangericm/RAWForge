"""Tone curve / transfer function stages."""

from __future__ import annotations

from ..color import srgb_encode
from ..frame import RawFrame
from ..pipeline import PipelineContext, PipelineStage, register_stage


@register_stage
class SRGBEncode(PipelineStage):
    """Apply the standard sRGB opto-electronic transfer function to linear RGB."""

    def process(self, frame: RawFrame, ctx: PipelineContext) -> RawFrame:
        if frame.is_mosaic:
            raise ValueError("SRGBEncode expects a demosaiced (RGB) frame")

        out = frame.with_data(srgb_encode(frame.data))
        # Tells preview rendering not to display-encode a second time.
        out.metadata = {**frame.metadata, "display_encoded": True}
        return out
