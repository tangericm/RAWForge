"""Job execution and listing for the webapp.

No database: completed jobs live in runs/ (metadata.json per job, written by
rawforge.api.run_job); this module only tracks in-flight state in memory and
caps concurrency. RAW processing is CPU/RAM-heavy, so one worker by default.
"""

from __future__ import annotations

import json
import shutil
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

from rawforge.api import run_job

RUNS_DIR = Path("runs")
DATA_DIR = Path("data")
UPLOADS_DIR = DATA_DIR / "uploads"
CONFIGS_DIR = Path("configs")


class JobManager:
    def __init__(self, max_workers: int = 1) -> None:
        self._executor = ThreadPoolExecutor(max_workers=max_workers)
        self._active: dict[str, dict] = {}  # ticket -> live status
        self._lock = threading.Lock()

    # -- submission ---------------------------------------------------------

    def submit(self, file_path: Path, config_path: Path) -> str:
        ticket = uuid.uuid4().hex[:8]
        with self._lock:
            self._active[ticket] = {
                "ticket": ticket,
                "status": "queued",
                "stage": "",
                "progress": 0.0,
                "file": file_path.name,
                "config": config_path.stem,
                "job_id": None,
                "error": None,
                "created_at": datetime.now().isoformat(timespec="seconds"),
            }
        self._executor.submit(self._run, ticket, file_path, config_path)
        return ticket

    def _run(self, ticket: str, file_path: Path, config_path: Path) -> None:
        def on_progress(stage: str, fraction: float) -> None:
            with self._lock:
                entry = self._active.get(ticket)
                if entry is not None:
                    entry.update(status="running", stage=stage, progress=fraction)

        try:
            result = run_job(
                file_path,
                config_path,
                runs_dir=RUNS_DIR,
                progress=on_progress,
                save_intermediates=True,
            )
            del result  # job is now visible via the runs/ scan
            with self._lock:
                self._active.pop(ticket, None)
        except Exception as e:
            with self._lock:
                entry = self._active.get(ticket)
                if entry is not None:
                    entry.update(status="error", error=f"{type(e).__name__}: {e}")

    # -- queries ------------------------------------------------------------

    def active(self) -> list[dict]:
        with self._lock:
            return [dict(v) for v in self._active.values()]

    def dismiss(self, ticket: str) -> bool:
        """Remove a finished/errored in-memory entry (UI 'dismiss' button)."""
        with self._lock:
            return self._active.pop(ticket, None) is not None

    @staticmethod
    def completed() -> list[dict]:
        """All finished jobs, newest first, summarized from runs/ metadata."""
        jobs = []
        if not RUNS_DIR.is_dir():
            return jobs
        for meta_path in RUNS_DIR.glob("*/metadata.json"):
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            jobs.append(
                {
                    "job_id": meta.get("job_id", meta_path.parent.name),
                    "created_at": meta.get("created_at", ""),
                    "source": Path(meta.get("source", "?")).name,
                    "pipeline": meta.get("pipeline", {}).get("name", "?"),
                    "stage_count": len(meta.get("stage_previews", [])),
                    "seconds": round(
                        sum(t.get("seconds", 0) for t in meta.get("timings", [])), 2
                    ),
                }
            )
        jobs.sort(key=lambda j: j["created_at"], reverse=True)
        return jobs

    @staticmethod
    def detail(job_id: str) -> dict | None:
        meta_path = RUNS_DIR / job_id / "metadata.json"
        if not meta_path.is_file():
            return None
        return json.loads(meta_path.read_text(encoding="utf-8"))

    @staticmethod
    def delete(job_id: str) -> bool:
        job_dir = RUNS_DIR / job_id
        if not job_dir.is_dir():
            return False
        shutil.rmtree(job_dir)
        return True


manager = JobManager(max_workers=1)
