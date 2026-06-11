"""RAWForge webapp entry point.

Run from the repo root:  uvicorn app:app
The engine (rawforge/) stays server-agnostic; this layer is routes + static UI.
"""

from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from routes.api import router
from services.jobs import RUNS_DIR, UPLOADS_DIR

RUNS_DIR.mkdir(exist_ok=True)
UPLOADS_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="RAWForge")
app.include_router(router, prefix="/api")
app.mount("/runs", StaticFiles(directory=str(RUNS_DIR)), name="runs")
app.mount("/", StaticFiles(directory=str(Path("static")), html=True), name="static")
