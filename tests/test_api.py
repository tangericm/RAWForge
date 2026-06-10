import json

from rawforge import run_job

MINIMAL_CONFIG = {
    "name": "minimal",
    "stages": [
        {"type": "BlackLevel"},
        {"type": "BilinearDemosaic"},
        {"type": "GrayWorldWB"},
        {"type": "SRGBEncode"},
    ],
}


def test_run_job_creates_job_directory(flat_mosaic, tmp_path):
    result = run_job(flat_mosaic, MINIMAL_CONFIG, runs_dir=tmp_path / "runs")

    assert result.job_dir.is_dir()
    assert result.output_path.name == "output.png"
    assert result.output_path.is_file()
    assert result.output_path.stat().st_size > 0

    meta = json.loads((result.job_dir / "metadata.json").read_text(encoding="utf-8"))
    assert meta["job_id"] == result.job_id
    assert meta["pipeline"]["name"] == "minimal"
    assert [s["type"] for s in meta["pipeline"]["stages"]] == [
        "BlackLevel",
        "BilinearDemosaic",
        "GrayWorldWB",
        "SRGBEncode",
    ]
    assert meta["input_frame"]["cfa_pattern"] == "RGGB"
    assert len(meta["timings"]) == 4


def test_run_job_progress_callback(flat_mosaic, tmp_path):
    events = []
    run_job(
        flat_mosaic,
        MINIMAL_CONFIG,
        runs_dir=tmp_path / "runs",
        progress=lambda stage, fraction: events.append(stage),
    )
    assert events[0] == "BlackLevel"
    assert events[-1] == "done"
