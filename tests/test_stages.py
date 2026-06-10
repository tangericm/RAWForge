import numpy as np

from rawforge import PipelineContext, RawFrame
from rawforge.frame import CFA_NONE
from rawforge.stages import BilinearDemosaic, BlackLevel, GrayWorldWB, SRGBEncode


def ctx() -> PipelineContext:
    return PipelineContext()


def test_black_level_recovers_normalized_values(flat_mosaic, flat_rgb):
    out = BlackLevel().process(flat_mosaic, ctx())
    assert out.white_level == 1.0
    assert out.black_level == (0.0, 0.0, 0.0, 0.0)
    # The mosaic should now hold the original [0,1] CFA samples.
    masks = out.cfa_masks()
    for color, channel in zip("RGB", range(3)):
        np.testing.assert_allclose(
            out.data[masks[color]], flat_rgb[..., channel][masks[color]], atol=1e-4
        )


def test_bilinear_demosaic_constant_scene_is_exact(flat_mosaic, flat_rgb):
    normalized = BlackLevel().process(flat_mosaic, ctx())
    rgb = BilinearDemosaic().process(normalized, ctx())
    assert rgb.cfa_pattern == CFA_NONE
    assert rgb.data.shape == flat_rgb.shape
    np.testing.assert_allclose(rgb.data, flat_rgb, atol=1e-4)


def test_gray_world_equalizes_channel_means(flat_rgb):
    frame = RawFrame(data=flat_rgb, cfa_pattern=CFA_NONE)
    out = GrayWorldWB().process(frame, ctx())
    means = out.data.reshape(-1, 3).mean(axis=0)
    np.testing.assert_allclose(means[0], means[1], atol=1e-4)
    np.testing.assert_allclose(means[2], means[1], atol=1e-4)
    assert "applied_wb_gains" in out.metadata


def test_srgb_encode_endpoints_and_monotonicity():
    ramp = np.linspace(0, 1, 64, dtype=np.float32).reshape(8, 8)[..., None].repeat(3, axis=2)
    frame = RawFrame(data=ramp, cfa_pattern=CFA_NONE)
    out = SRGBEncode().process(frame, ctx())
    assert out.data.min() == 0.0
    np.testing.assert_allclose(out.data.max(), 1.0, atol=1e-6)
    flat = out.data[..., 0].flatten()
    assert (np.diff(flat) >= 0).all()
    # Gamma encoding brightens mid-tones.
    assert out.data[4, 0, 0] > ramp[4, 0, 0]
