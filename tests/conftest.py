import numpy as np
import pytest

from rawforge import RawFrame

BLACK = 64.0
WHITE = 1023.0


def mosaic_from_rgb(rgb: np.ndarray, pattern: str = "RGGB") -> RawFrame:
    """Sample an RGB image through a Bayer CFA, in raw sensor units.

    Pixel values are black + value * (white - black), so BlackLevel
    normalization should recover the original [0, 1] values exactly.
    """
    h, w, _ = rgb.shape
    mosaic = np.zeros((h, w), dtype=np.float32)
    for idx, color in enumerate(pattern):
        row, col = divmod(idx, 2)
        ch = "RGB".index(color)
        mosaic[row::2, col::2] = rgb[row::2, col::2, ch]
    data = BLACK + mosaic * (WHITE - BLACK)
    return RawFrame(
        data=data,
        cfa_pattern=pattern,
        black_level=(BLACK,) * 4,
        white_level=WHITE,
    )


@pytest.fixture
def flat_rgb() -> np.ndarray:
    """A 16x16 constant-color scene: easy to verify after demosaic."""
    rgb = np.empty((16, 16, 3), dtype=np.float32)
    rgb[:] = (0.5, 0.25, 0.125)
    return rgb


@pytest.fixture
def flat_mosaic(flat_rgb) -> RawFrame:
    return mosaic_from_rgb(flat_rgb)
