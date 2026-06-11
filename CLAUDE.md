# RAWForge

Modular RAW ISP pipeline in Python. Every processing step is a `PipelineStage` plugin; YAML configs define stage order. A FastAPI webapp (`app.py` + `routes/` + `services/` + `static/`) wraps the engine for local use.

## Commands

- Setup: `python -m venv .venv; .venv\Scripts\pip install -e ".[raw,web,dev]"`
- Tests: `.venv\Scripts\python -m pytest --basetemp=.pytest_tmp` — the `--basetemp` flag is required on this machine (default `%TEMP%` location hits a Windows permission error)
- Real-file smoke test: `.venv\Scripts\python scripts\smoke_data.py` — runs every RAW in `data/` through the pipeline, reports OK/UNSUP/FAIL with loader diagnostics
- CLI: `.venv\Scripts\rawforge run "data\file.dng" -c configs\minimal.yaml`
- Webapp: `.venv\Scripts\uvicorn app:app` from the repo root, then http://127.0.0.1:8000

## Architecture rules

- `rawforge/` never imports server/UI code. All front ends (CLI, webapp) call `rawforge.api.run_job()`.
- A job is a pure function of (input, config) → `runs/<job-id>/` containing `output.png`, `metadata.json`, and `stages/*.png` previews. That directory layout is the contract the web UI renders — change it in `api.py` and the frontend together.
- New stages: subclass `PipelineStage`, decorate with `@register_stage`, reference by class name in YAML. Mosaic vs RGB state is tracked via `frame.cfa_pattern` (`"NONE"` = demosaiced).
- Configs and results stay JSON/YAML-serializable (no pickled objects across interfaces).
- CI tests are synthetic-only (no rawpy, no camera files; see `tests/conftest.py`). Real-file verification is `scripts/smoke_data.py`, run locally.

## Gotchas

- `rawpy` is the optional `[raw]` extra, lazily imported in `rawforge/io.py`. The loader raises a clear `ValueError` for linear (already-demosaiced) DNGs — only standard Bayer is supported.
- Pipeline data before `SRGBEncode` is linear and looks near-black if displayed directly; previews apply a display transform (`rawforge/preview.py`). `SRGBEncode` sets `metadata["display_encoded"]` so previews don't double-encode.
- `PLAN.md` (the roadmap) and `.gitignore` are intentionally untracked.
- PowerShell: quote paths containing spaces/parentheses.
