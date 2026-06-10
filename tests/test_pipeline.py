import numpy as np
import pytest

from rawforge import Pipeline, PipelineContext

MINIMAL_CONFIG = {
    "name": "minimal",
    "stages": [
        {"type": "BlackLevel"},
        {"type": "BilinearDemosaic"},
        {"type": "GrayWorldWB"},
        {"type": "SRGBEncode"},
    ],
}


def test_from_config_rejects_unknown_stage():
    with pytest.raises(ValueError, match="Unknown stage"):
        Pipeline.from_config({"stages": [{"type": "DoesNotExist"}]})


def test_from_config_yaml_file(tmp_path):
    cfg = tmp_path / "p.yaml"
    cfg.write_text("name: t\nstages:\n  - type: BlackLevel\n", encoding="utf-8")
    pipeline = Pipeline.from_config(cfg)
    assert pipeline.name == "t"
    assert [s["type"] for s in pipeline.describe()] == ["BlackLevel"]


def test_end_to_end_on_synthetic_mosaic(flat_mosaic):
    pipeline = Pipeline.from_config(MINIMAL_CONFIG)
    events = []
    ctx = PipelineContext(progress=lambda stage, fraction: events.append((stage, fraction)))

    result = pipeline.run(flat_mosaic, ctx)

    assert result.data.shape == (*flat_mosaic.data.shape, 3)
    assert not result.is_mosaic
    assert result.data.min() >= 0.0 and result.data.max() <= 1.0
    assert not np.isnan(result.data).any()

    # Progress fired once per stage plus the final "done".
    assert len(events) == len(pipeline.stages) + 1
    assert events[-1] == ("done", 1.0)
    # A timing entry per stage.
    assert [t["stage"] for t in ctx.timings] == [s.name for s in pipeline.stages]
