import numpy as np

from rawforge import RawFrame
from rawforge.color import srgb_encode
from rawforge.frame import CFA_NONE
from rawforge.preview import render_preview


def test_mosaic_preview_is_grayscale_rgb(flat_mosaic):
    img = render_preview(flat_mosaic, max_dim=64)
    assert img.mode == "RGB"
    assert max(img.size) <= 64
    arr = np.asarray(img)
    np.testing.assert_array_equal(arr[..., 0], arr[..., 1])  # gray: channels equal


def test_linear_rgb_preview_is_display_encoded(flat_rgb):
    frame = RawFrame(data=flat_rgb, cfa_pattern=CFA_NONE)
    img = np.asarray(render_preview(frame, max_dim=64), dtype=np.float32) / 255.0
    # Display encoding brightens linear mid-tones (0.5 -> ~0.735).
    assert img[0, 0, 0] > 0.7


def test_encoded_frame_preview_not_double_encoded(flat_rgb):
    frame = RawFrame(
        data=flat_rgb, cfa_pattern=CFA_NONE, metadata={"display_encoded": True}
    )
    img = np.asarray(render_preview(frame, max_dim=64), dtype=np.float32) / 255.0
    np.testing.assert_allclose(img[0, 0, 0], 0.5, atol=0.01)


def test_preview_downscales_large_frames():
    big = RawFrame(data=np.zeros((1200, 1600), dtype=np.float32), white_level=1.0)
    img = render_preview(big, max_dim=400)
    assert max(img.size) <= 400


def test_srgb_lut_matches_exact_curve():
    x = np.linspace(0, 1, 1000, dtype=np.float32)
    exact = np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(x, 1 / 2.4) - 0.055)
    np.testing.assert_allclose(srgb_encode(x), exact, atol=2e-4)
