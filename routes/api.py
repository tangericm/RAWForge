"""API endpoints — thin layer over services.jobs and the filesystem."""

from __future__ import annotations

import re
from pathlib import Path

import yaml
from fastapi import APIRouter, HTTPException, UploadFile
from pydantic import BaseModel

from rawforge.io import RAW_EXTENSIONS
from services.jobs import CONFIGS_DIR, DATA_DIR, UPLOADS_DIR, manager

router = APIRouter()

_JOB_ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$")


def _safe_data_path(rel: str) -> Path:
    """Resolve a client-supplied path and require it to stay inside data/."""
    path = (DATA_DIR / rel).resolve()
    if not path.is_relative_to(DATA_DIR.resolve()):
        raise HTTPException(400, "path escapes data/")
    if not path.is_file():
        raise HTTPException(404, f"no such file: {rel}")
    return path


# -- files -------------------------------------------------------------------


@router.get("/files")
def list_files() -> list[dict]:
    files = []
    for path in sorted(DATA_DIR.rglob("*")):
        if path.is_file() and path.suffix.lower() in RAW_EXTENSIONS:
            files.append(
                {
                    "name": path.name,
                    "path": path.relative_to(DATA_DIR).as_posix(),
                    "mb": round(path.stat().st_size / 1e6, 1),
                }
            )
    return files


@router.post("/uploads")
async def upload(file: UploadFile) -> dict:
    name = Path(file.filename or "upload").name  # strip any client path
    if Path(name).suffix.lower() not in RAW_EXTENSIONS:
        raise HTTPException(400, f"unsupported file type (expected one of {sorted(RAW_EXTENSIONS)})")
    UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
    dest = UPLOADS_DIR / name
    counter = 1
    while dest.exists():
        dest = UPLOADS_DIR / f"{Path(name).stem}-{counter}{Path(name).suffix}"
        counter += 1
    with dest.open("wb") as out:
        while chunk := await file.read(1 << 20):
            out.write(chunk)
    return {"name": dest.name, "path": dest.relative_to(DATA_DIR).as_posix()}


# -- configs -------------------------------------------------------------------


@router.get("/configs")
def list_configs() -> list[dict]:
    configs = []
    for path in sorted(CONFIGS_DIR.glob("*.yaml")):
        try:
            doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError:
            continue
        configs.append(
            {
                "name": doc.get("name", path.stem),
                "file": path.name,
                "stages": [s.get("type", "?") for s in doc.get("stages", [])],
            }
        )
    return configs


# -- jobs ----------------------------------------------------------------------


class JobRequest(BaseModel):
    file: str
    config: str


@router.post("/jobs")
def create_job(req: JobRequest) -> dict:
    file_path = _safe_data_path(req.file)
    config_path = (CONFIGS_DIR / Path(req.config).name).resolve()
    if not config_path.is_file() or config_path.suffix != ".yaml":
        raise HTTPException(404, f"no such config: {req.config}")
    ticket = manager.submit(file_path, config_path)
    return {"ticket": ticket}


@router.get("/jobs")
def list_jobs() -> dict:
    return {"active": manager.active(), "completed": manager.completed()}


@router.get("/jobs/{job_id}")
def job_detail(job_id: str) -> dict:
    if not _JOB_ID_RE.match(job_id):
        raise HTTPException(400, "invalid job id")
    meta = manager.detail(job_id)
    if meta is None:
        raise HTTPException(404, "no such job")
    return meta


@router.delete("/jobs/{job_id}")
def delete_job(job_id: str) -> dict:
    if not _JOB_ID_RE.match(job_id):
        raise HTTPException(400, "invalid job id")
    if not manager.delete(job_id):
        raise HTTPException(404, "no such job")
    return {"deleted": job_id}


@router.delete("/active/{ticket}")
def dismiss_active(ticket: str) -> dict:
    if not manager.dismiss(ticket):
        raise HTTPException(404, "no such ticket")
    return {"dismissed": ticket}
