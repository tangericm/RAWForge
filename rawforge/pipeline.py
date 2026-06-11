"""Pipeline core: stage interface, context, registry, and YAML-config loading."""

from __future__ import annotations

import time
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Type

import yaml

from .frame import RawFrame

ProgressFn = Callable[[str, float], None]


@dataclass
class PipelineContext:
    """Shared state passed to every stage.

    `progress(stage_name, fraction)` is the hook a CLI progress bar uses today
    and a websocket/SSE channel will use in the web layer later.
    """

    progress: ProgressFn = lambda stage, fraction: None
    extras: dict[str, Any] = field(default_factory=dict)
    timings: list[dict[str, Any]] = field(default_factory=list)


class PipelineStage(ABC):
    """One ISP step. Subclass, implement process(), and decorate with @register_stage."""

    def __init__(self, **params: Any) -> None:
        self.params = params

    @property
    def name(self) -> str:
        return type(self).__name__

    @abstractmethod
    def process(self, frame: RawFrame, ctx: PipelineContext) -> RawFrame: ...


STAGE_REGISTRY: dict[str, Type[PipelineStage]] = {}


def register_stage(cls: Type[PipelineStage]) -> Type[PipelineStage]:
    """Class decorator making a stage addressable by name in YAML configs."""
    STAGE_REGISTRY[cls.__name__] = cls
    return cls


class Pipeline:
    def __init__(self, stages: list[PipelineStage], name: str = "pipeline") -> None:
        self.stages = stages
        self.name = name

    @classmethod
    def from_config(cls, config: str | Path | dict) -> "Pipeline":
        """Build a pipeline from a YAML file path or an already-parsed dict."""
        if isinstance(config, (str, Path)):
            with open(config, "r", encoding="utf-8") as f:
                config = yaml.safe_load(f)
        if not isinstance(config, dict) or "stages" not in config:
            raise ValueError("Pipeline config must be a mapping with a 'stages' list")

        # Importing the stages package registers the built-in stages.
        from . import stages as _builtin  # noqa: F401

        built: list[PipelineStage] = []
        for entry in config["stages"]:
            stage_type = entry.get("type")
            if stage_type not in STAGE_REGISTRY:
                raise ValueError(
                    f"Unknown stage type {stage_type!r}. "
                    f"Registered: {sorted(STAGE_REGISTRY)}"
                )
            built.append(STAGE_REGISTRY[stage_type](**entry.get("params", {})))
        return cls(built, name=config.get("name", "pipeline"))

    def run(
        self,
        frame: RawFrame,
        ctx: PipelineContext | None = None,
        on_stage: Callable[[int, str, RawFrame], None] | None = None,
    ) -> RawFrame:
        """Run all stages. `on_stage(index, name, frame)` fires after each stage
        with the intermediate result (used for per-stage preview snapshots)."""
        ctx = ctx or PipelineContext()
        total = len(self.stages)
        for i, stage in enumerate(self.stages):
            ctx.progress(stage.name, i / total)
            start = time.perf_counter()
            frame = stage.process(frame, ctx)
            ctx.timings.append(
                {"stage": stage.name, "seconds": round(time.perf_counter() - start, 4)}
            )
            if on_stage is not None:
                on_stage(i, stage.name, frame)
        ctx.progress("done", 1.0)
        return frame

    def describe(self) -> list[dict[str, Any]]:
        return [{"type": s.name, "params": s.params} for s in self.stages]
