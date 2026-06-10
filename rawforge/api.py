"""Programmatic facade: every front end (CLI today, web later) goes through here.

A processing run is a *job*: pure function of (input, config) producing a
structured output directory under runs/ that any UI can render.
"""

from __future__ import annotations

import datetime as _dt
import json
import uuid
from dataclasses import dataclass
from pathlib import Path

from .frame import RawFrame
from .io import load_raw, save_png
from .pipeline import Pipeline, PipelineContext, ProgressFn


@dataclass
class JobResult:
    job_id: str
    job_dir: Path
    output_path: Path
    timings: list[dict]


def run_job(
    source: str | Path | RawFrame,
    config: str | Path | dict,
    runs_dir: str | Path = "runs",
    progress: ProgressFn | None = None,
) -> JobResult:
    """Develop one RAW input with one pipeline config.

    `source` may be a camera file path or an already-loaded RawFrame
    (dataset adapters and tests pass frames directly).
    """
    frame = source if isinstance(source, RawFrame) else load_raw(source)
    pipeline = Pipeline.from_config(config)

    job_id = _dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    job_dir = Path(runs_dir) / job_id
    job_dir.mkdir(parents=True, exist_ok=False)

    ctx = PipelineContext(progress=progress or (lambda stage, fraction: None))
    input_meta = frame.serializable_metadata()
    result = pipeline.run(frame, ctx)

    if result.is_mosaic:
        raise ValueError(
            "Pipeline ended on a mosaic frame — add a demosaic stage before output"
        )

    output_path = job_dir / "output.png"
    save_png(result.data, output_path)

    metadata = {
        "job_id": job_id,
        "created_at": _dt.datetime.now().isoformat(timespec="seconds"),
        "source": str(source) if not isinstance(source, RawFrame) else "<in-memory frame>",
        "pipeline": {"name": pipeline.name, "stages": pipeline.describe()},
        "input_frame": input_meta,
        "timings": ctx.timings,
    }
    with open(job_dir / "metadata.json", "w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2)

    return JobResult(
        job_id=job_id,
        job_dir=job_dir,
        output_path=output_path,
        timings=ctx.timings,
    )
