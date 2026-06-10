"""Command-line interface: a thin client over rawforge.api."""

from __future__ import annotations

import argparse
import sys

from .api import run_job


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="rawforge", description="Modular RAW ISP pipeline")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="Develop a RAW file with a pipeline config")
    run.add_argument("input", help="Path to a RAW file (DNG, ARW, CR3, ...)")
    run.add_argument("-c", "--config", required=True, help="Pipeline YAML config")
    run.add_argument("-o", "--runs-dir", default="runs", help="Job output root (default: runs)")

    args = parser.parse_args(argv)

    if args.command == "run":
        def progress(stage: str, fraction: float) -> None:
            print(f"[{fraction:4.0%}] {stage}")

        try:
            result = run_job(args.input, args.config, runs_dir=args.runs_dir, progress=progress)
        except (ValueError, ImportError, FileNotFoundError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        print(f"job {result.job_id} -> {result.output_path}")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
