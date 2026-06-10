"""Run every RAW file in data/ through the minimal pipeline and report issues.

Usage: python scripts/smoke_data.py [data_dir]

Local smoke test against real camera files (not part of the pytest suite,
which stays synthetic). Prints one line per file plus loader diagnostics.
"""

from __future__ import annotations

import sys
import traceback
from pathlib import Path

import rawpy

from rawforge.api import run_job
from rawforge.io import RAW_EXTENSIONS


def diagnostics(path: Path) -> str:
    """Loader-relevant facts straight from LibRaw, for debugging mismatches."""
    with rawpy.imread(str(path)) as raw:
        sizes = raw.sizes
        return (
            f"color_desc={raw.color_desc.decode('ascii')} "
            f"pattern={raw.raw_pattern.tolist()} "
            f"margins=(top={sizes.top_margin}, left={sizes.left_margin}) "
            f"black={list(raw.black_level_per_channel)} white={raw.white_level}"
        )


def main(data_dir: str = "data") -> int:
    files = sorted(
        p for p in Path(data_dir).iterdir()
        if p.suffix.lower() in RAW_EXTENSIONS
    )
    if not files:
        print(f"no RAW files found in {data_dir}/")
        return 1

    ok = unsupported = failures = 0
    for path in files:
        try:
            result = run_job(path, "configs/minimal.yaml")
            ok += 1
            print(f"OK     {path.name}\n       -> {result.output_path}")
        except ValueError as e:
            # Clear loader rejections (linear DNG, exotic CFA) are expected.
            unsupported += 1
            print(f"UNSUP  {path.name}\n       {e}")
        except Exception as e:
            failures += 1
            print(f"FAIL   {path.name}\n       {type(e).__name__}: {e}")
            if "--trace" in sys.argv:
                traceback.print_exc()
        try:
            print(f"       {diagnostics(path)}")
        except Exception:
            pass

    print(f"\n{ok} ok, {unsupported} unsupported, {failures} failed (of {len(files)})")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "data"))
