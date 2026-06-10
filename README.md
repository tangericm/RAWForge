# RAWForge

A modular, device-agnostic RAW image processing (ISP) pipeline. Every stage — black level, demosaic, white balance, tone mapping — is a swappable plugin defined behind one interface, so classical, learned, and hybrid pipelines can be configured, compared, and extended without touching core code.

**Who it's for:** computational photography researchers who want to benchmark a new stage inside a realistic full pipeline, students who want to see what each ISP stage actually does, and photographers who want a hackable, scriptable RAW developer.

## Quickstart

```bash
pip install -e ".[raw,dev]"          # rawpy extra needed for real camera files
rawforge run photo.dng -c configs/minimal.yaml
# → runs/<job-id>/output.png + metadata.json
```

Pipelines are YAML:

```yaml
stages:
  - type: BlackLevel
  - type: BilinearDemosaic
  - type: GrayWorldWB
  - type: SRGBEncode
```

Swap any stage for your own by subclassing `PipelineStage` and registering it — see `rawforge/stages/`.

## Status

Early development. Current: DNG/ARW/CR3 ingestion (standard Bayer), black level, bilinear demosaic, gray-world WB, sRGB encode. See [PLAN.md](PLAN.md) for the roadmap (Malvar/AHD demosaic, burst merge, learned stages, benchmark CLI, and eventually a self-hosted web UI).

## Development

Tests run on synthetic Bayer data — no camera files or `rawpy` required:

```bash
pip install -e ".[dev]"
pytest
```
