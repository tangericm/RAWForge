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
    save_intermediates: bool = False,
    preview_max_dim: int = 1024,
) -> JobResult:
    """Develop one RAW input with one pipeline config.

    `source` may be a camera file path or an already-loaded RawFrame
    (dataset adapters and tests pass frames directly).

    With `save_intermediates`, a display-ready preview of the input and of
    every stage's output is written to <job_dir>/stages/ and listed in
    metadata.json — this is what the web UI's stage filmstrip renders.
    """
    report = progress or (lambda stage, fraction: None)

    if isinstance(source, RawFrame):
        frame = source
    else:
        report("Loading", 0.01)
        frame = load_raw(source)
    pipeline = Pipeline.from_config(config)

    job_id = _dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    job_dir = Path(runs_dir) / job_id
    job_dir.mkdir(parents=True, exist_ok=False)

    # Pipeline stages span 5%..90% of overall progress; loading and the
    # full-res output write are the phases on either side. The pipeline's own
    # terminal ("done", 1.0) is swallowed — run_job emits the real one.
    def scaled(stage: str, fraction: float) -> None:
        if fraction < 1.0:
            report(stage, 0.05 + fraction * 0.85)

    ctx = PipelineContext(progress=scaled)
    input_meta = frame.serializable_metadata()

    stage_previews: list[dict] = []
    on_stage = None
    if save_intermediates:
        from .preview import save_preview

        stages_dir = job_dir / "stages"
        stages_dir.mkdir()

        def snapshot(index: int, name: str, snap_frame: RawFrame) -> None:
            rel = f"stages/{index + 1:02d}-{name}.png"
            save_preview(snap_frame, job_dir / rel, max_dim=preview_max_dim)
            stage_previews.append({"index": index + 1, "name": name, "preview": rel})

        snapshot(-1, "Input", frame)
        on_stage = snapshot

    result = pipeline.run(frame, ctx, on_stage=on_stage)

    if result.is_mosaic:
        raise ValueError(
            "Pipeline ended on a mosaic frame — add a demosaic stage before output"
        )

    report("Saving output", 0.92)
    output_path = job_dir / "output.png"
    save_png(result.data, output_path)

    metadata = {
        "job_id": job_id,
        "created_at": _dt.datetime.now().isoformat(timespec="seconds"),
        "source": str(source) if not isinstance(source, RawFrame) else "<in-memory frame>",
        "pipeline": {"name": pipeline.name, "stages": pipeline.describe()},
        "input_frame": input_meta,
        "timings": ctx.timings,
        "stage_previews": stage_previews,
    }
    with open(job_dir / "metadata.json", "w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2)

    report("done", 1.0)
    return JobResult(
        job_id=job_id,
        job_dir=job_dir,
        output_path=output_path,
        timings=ctx.timings,
    )
