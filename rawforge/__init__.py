"""RAWForge: a modular, device-agnostic RAW ISP pipeline."""

from .api import JobResult, run_job
from .frame import RawFrame
from .pipeline import Pipeline, PipelineContext, PipelineStage, register_stage

__version__ = "0.1.0"

__all__ = [
    "JobResult",
    "Pipeline",
    "PipelineContext",
    "PipelineStage",
    "RawFrame",
    "register_stage",
    "run_job",
    "__version__",
]
