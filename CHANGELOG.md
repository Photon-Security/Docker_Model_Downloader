# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- GGUF metadata tools are now optional and no longer block browsing or downloading Docker models.
- Pull failures caused by DNS, proxy, or authorisation problems are no longer retried ten times; they are detected on the first attempt and explained.

### Added
- Local downloaded-model checks now list incomplete downloads and offer an optional purge action.
- Active model downloads can now be cancelled with Ctrl+C, returning to variant selection without stopping Docker Desktop.
- Fit verdict and estimated tok/s per model, derived from detected hardware, with an `[h]` hardware panel.
- `[f]` search, `[r]` fits-only filter, and a `[u]` refresh for sizes still arriving in the background.
- The model table now renders in about ten seconds while remaining sizes download behind a progress bar.
- Empty Parameters and Description cells are filled from models.dev, without ever overwriting a value Docker provides.
- Registry fallback: when Docker Desktop's Model Runner cannot reach the registry through a configured proxy, the model is downloaded with curl and installed into `~/.docker/models` — resumable, digest-verified, and indistinguishable from a normal pull.
- Metadata repair: some tags on Docker Hub ship an empty config blob (`{"format":"gguf"}`), so `docker model ls` lists the model with blank parameters, quantization, architecture and size, and a **CREATED** of *56 years ago*. Those facts are now read back out of the GGUF header and written into the model store as the config Docker should have published. The defect is upstream and per-tag — `ai/qwen3:8B-Q4_K_M` is populated while `ai/qwen3:latest` is empty — and `docker model pull` lands the same empty blob, so the repair runs after both download paths. Only a config naming no architecture is touched; a populated one is never second-guessed, and a model with no GGUF is skipped. Header parsing uses `od` and `awk`, adding no dependency. The new config digest cascades through the manifest, `models.json` and the bundle directory; every write is `.part`-then-`mv`, the originals are backed up to a `mktemp -d` directory with a generated `RESTORE.txt`, and the weights are never touched. `REPAIR_MODEL_METADATA=0` disables it; `GGUF_SCAN_BYTES` bounds the header read.

## [0.6.0] - 2026-06-15

### Added
- Startup action menu for downloading models or checking locally downloaded Docker GGUF blobs.
- Docker Hub variant listing so users can pick tags beyond `latest`.
- Download retry handling for `docker model pull` with a 5 second delay and 10 attempts by default.
- Spinner feedback while retrieving model lists, variants, and local metadata.
- Local GGUF inventory view with grouped model metadata, cropped paths, and incomplete-download skipping.
- Support for `llama-gguf` from Homebrew's `llama.cpp` package, while keeping `gguf_dump` support when available.

### Changed
- Renamed the project and documentation to Docker Model Downloader.
- Show 20 models per page and crop long model names to keep the table readable.
- Use left/right arrows for model-list pagination.
- Filter vLLM-only Docker model entries on macOS because they are not compatible there.
- README now documents the full downloader, retry, local-inspection, and GGUF reuse capabilities.

## [0.5.2] - 2026-03-10

### Changed
- README now uses images from `assets/` (banner, logo, demo GIF).

## [0.5.1] - 2026-03-10

### Added
- MIT license file.

## [0.1.0] - 2025-12-18

### Added
- Initial interactive downloader script (`download_docker_model.sh`).
- Basic README with one-line install/run instructions.

## [0.2.0] - 2025-12-18

### Changed
- README updates (demo/wording).

## [0.3.0] - 2025-12-18

### Changed
- README updates (demo/wording).

## [0.4.0] - 2025-12-18

### Changed
- README updates (demo/wording).

## [0.5.0] - 2026-03-10

### Added
- `.gitignore` for common OS/editor/temp files.
- `jq` prerequisite documented.

### Changed
- Script now fetches the Docker Hub `ai/*` model list on each run (no hardcoded list).
- README now embeds the animated demo GIF.
