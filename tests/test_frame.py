import numpy as np
import pytest

from rawforge import RawFrame
from rawforge.frame import CFA_NONE


def test_mosaic_must_be_2d():
    with pytest.raises(ValueError):
        RawFrame(data=np.zeros((4, 4, 3)), cfa_pattern="RGGB")


def test_rgb_frame_must_be_3_channel():
    with pytest.raises(ValueError):
        RawFrame(data=np.zeros((4, 4)), cfa_pattern=CFA_NONE)


def test_unknown_cfa_pattern_rejected():
    with pytest.raises(ValueError):
        RawFrame(data=np.zeros((4, 4)), cfa_pattern="XYZW")


def test_cfa_masks_cover_every_pixel_once():
    frame = RawFrame(data=np.zeros((6, 6)), cfa_pattern="RGGB")
    masks = frame.cfa_masks()
    total = masks["R"].astype(int) + masks["G"].astype(int) + masks["B"].astype(int)
    assert (total == 1).all()
    assert masks["R"][0, 0] and masks["G"][0, 1] and masks["G"][1, 0] and masks["B"][1, 1]
    assert masks["G"].sum() == 2 * masks["R"].sum()


def test_serializable_metadata_is_jsonable():
    import json

    frame = RawFrame(data=np.zeros((4, 4)), cfa_pattern="BGGR", metadata={"f": 1.8, "x": object()})
    meta = frame.serializable_metadata()
    json.dumps(meta)  # must not raise
    assert "x" not in meta["metadata"]  # non-serializable values dropped
