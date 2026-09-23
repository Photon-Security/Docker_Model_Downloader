<p align="center">
  <img src="assets/logo.png" alt="Docker Model Downloader logo" width="160" />
</p>

# Docker Model Downloader

Interactive downloader for Docker `ai/*` GGUF models, designed for importing the downloaded blobs into other local runtimes such as Ollama and llama.cpp.

Why this exists:
  - Docker Desktop's model GUI can fail to fetch model metadata even when the `docker model` CLI still works.
  - `docker model pull` can fail on unreliable or corporate networks; this script automatically retries downloads.
  - Docker can be an allowed route for GGUF downloads where Ollama, Hugging Face, or ModelScope are blocked.
  - Downloaded Docker GGUF blobs can then be reused in Ollama, llama.cpp, or other GGUF-compatible apps.
  - The script identifies GGUF blobs to simplify importing into Ollama or llama.cpp, with richer metadata when `llama-gguf` or `gguf_dump` is available.
  - The catalog tells you whether a model will actually run on **your** machine before you spend the download on finding out.


![Bash](https://img.shields.io/badge/bash-3.2%2B-4EAA25?logo=gnu-bash&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-10.14%2B-000000?logo=apple&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Enelass/Docker_Model_Downloader?display_name=tag)](https://github.com/Enelass/Docker_Model_Downloader/releases)

Interactive script to download GGUF AI models via Docker, locate the downloaded GGUF files, and import them into other local runtimes.

![Docker Model Downloader demo](assets/DockerModelDownloader-small.gif)

## Support

Donate to support this work: [Ko-fi Enelass](https://ko-fi.com/enelass)

## Capabilities

- **Download Docker AI models**: browse the live Docker Hub `ai/*` catalog, select a model, inspect all available tags/variants, and pull the exact variant you want.
- **See what fits your machine**: a **Fit** column rates every model against the memory actually available for weights on this box, and an estimated **tok/s** says whether it will feel usable. See [Fit and tok/s](#fit-and-toks).
- **Search and filter**: `[f]` filters the catalog by name or description, `[r]` hides everything that will not run here, and the two compose.
- **Progressive load**: the table appears in about 10 seconds while per-model sizes keep downloading in the background behind a progress bar; `[u]` folds in whatever has landed so far.
- **Recover from flaky pulls**: retries `docker model pull` failures automatically, which helps on unreliable or corporate networks.
- **Survive a proxy that Docker's Model Runner ignores**: when a pull fails because the runner cannot resolve the registry, the script downloads the model itself with curl and installs it into Docker's model store. See [Proxied networks](#proxied-networks).
- **Repair blank metadata**: some tags are published with an empty config blob, so `docker model ls` shows the model with no parameters, quantization or architecture and a **CREATED** of *56 years ago*. The script reads those facts back out of the GGUF and writes the metadata Docker should have shipped. See [Blank metadata in `docker model ls`](#blank-metadata-in-docker-model-ls).
- **Inspect local downloads**: scan `~/.docker/models/blobs/sha256/` for completed GGUF blobs, list incomplete downloads separately, and show useful metadata such as role, architecture, size, context length, quantization, tensor count, and cropped path.
- **Use optional llama.cpp metadata tooling**: detects `llama-gguf` from `brew install llama.cpp`, while still using `gguf_dump` when available. Downloads do not require either tool.
- **Reuse Docker GGUF blobs elsewhere**: prints Ollama import commands and file locations so downloaded Docker models can be used with Ollama, llama.cpp, or other GGUF-compatible runtimes.
- **macOS compatibility filtering**: hides vLLM-only Docker model entries on macOS because those variants are not compatible there.

## Prerequisites

- **Bash** (macOS ships Bash 3.2)
- **Docker Desktop** (required) must be installed and running
- **jq** (used to parse the Docker Hub API)
- **Ollama** (optional) to run the downloaded models
- **llama-gguf** (from `brew install llama.cpp`) or **gguf_dump** (optional) for richer downloaded-model metadata and more precise GGUF matching

## Installation & Usage

Run with a single command:

```bash
bash <(curl -s https://raw.githubusercontent.com/Enelass/Docker_Model_Downloader/refs/heads/main/download_docker_model.sh)
```

## Changelog / Releases

- Changelog: `CHANGELOG.md`
- Release process: `RELEASING.md`

## Features

- Fetches an up-to-date list of Docker Hub `ai/*` models every run
- Starts with a keyboard-selectable action menu for downloading models or checking local downloads
- Shows the catalog as `#  Model Name  Parameters  Fit  tok/s  Pulls  Description`, adapting column widths to the terminal
- Rates every model against the memory this machine can actually give to weights, with an estimated decode speed
- Fills gaps in Docker's metadata from models.dev without ever overwriting what Docker reports
- Renders the table after ~10 seconds and keeps sizing models in the background behind a progress bar
- Lists Docker model variants, not only the default tag, with parameters, quantization, context, VRAM, tool-calling, and size when Docker metadata provides it
- Filters vLLM-only entries on macOS because they are not compatible there
- Checks locally downloaded Docker GGUF blobs without starting a download, including grouped metadata, cropped paths, incomplete downloads, and an optional purge action
- Retries failed model downloads automatically
- Rebuilds missing model-store metadata from the GGUF header when a tag is published with an empty config blob
- Allows cancelling an active download with Ctrl+C and returning to variant selection
- Shows spinner feedback while retrieving models, variants, and local metadata
- Automatic GGUF file detection with `llama-gguf` or `gguf_dump`
- Ready-to-use Ollama import commands

## Fit and tok/s

The **Fit** column compares the smallest GGUF build a repo ships against the memory
available for weights on this machine — on Apple Silicon that is the Metal wired limit
(`iogpu.wired_limit_mb`, or ~75% of unified memory when unset), on Linux the NVIDIA VRAM
reported by `nvidia-smi` when a card is present. A model needs roughly `size × 1.15 + 1 GB`
resident once KV cache and runtime overhead are counted.

| | Meaning |
|---|---|
| ✅ | fits comfortably — under 60% of the budget |
| 🟡 | fits, but with little headroom for a long context |
| 🟠 | over the accelerator budget; runs on CPU instead, slowly |
| ❌ | larger than total memory — will not run |
| `-` | no GGUF build published, so no verdict |
| `..` | size still being fetched — press `[u]` to fold it in |

The size shown is the **smallest** GGUF build in the repo, so the verdict is a best case;
larger quantisations of the same model need more.

**tok/s figures are estimates, not measurements.** They model decode as memory-bandwidth
bound — `bandwidth × efficiency ÷ resident bytes`, with MoE models counted on their active
experts only — and are capped at 200. A speed is shown only for models that fit the
accelerator budget; past it the work moves to the CPU, which this model does not describe.
Press `[h]` in the catalog for the detected specs and the thresholds in use.

## Where the metadata comes from

Everything in the table is derived from public APIs at runtime and cached for 7 days under
`${XDG_CACHE_HOME:-~/.cache}/docker_model_downloader/`. No data is bundled with the script.

| Column / value | Source | Notes |
|---|---|---|
| Model list, Pulls, Description | `hub.docker.com/v2/repositories/ai/?page_size=100` | Anonymous requests are refused past offset 100, so the catalog is assembled from two orderings |
| Parameters | tag names from `hub.docker.com/v2/repositories/ai/<name>/tags` | Docker encodes size in the tag: `20b`, `120b`, `270m`, `1.7b`, `1t` |
| MoE active parameters | the same tag names | `26b-a4b`, `2.4t-a95b` — feeds the speed estimate |
| Model size (drives **Fit**) | `full_size` in that same tags response | Free: no extra request beyond the one already made for Parameters |
| Which tags carry real GGUF weights | `registry-1.docker.io/v2/ai/<name>/manifests/<tag>`, token from `auth.docker.io` | Checks the `org.cncf.model.filepath` layer annotation. Needed because some model-looking tags ship only an MTP draft head or an `mmproj` projector — `ai/gemma4:12b-q8_0` is 611 MB, not 12B of weights |
| Empty Parameters / Description cells only | `models.dev/api.json` | **Gap-fill only.** A value Docker provides is never overwritten |
| Hardware specs | macOS: `sysctl hw.memsize machdep.cpu.brand_string hw.model iogpu.wired_limit_mb`, `system_profiler SPDisplaysDataType` · Linux: `/proc/meminfo`, `nvidia-smi` | Local probes; nothing leaves the machine |
| Memory bandwidth | built-in lookup table keyed on the chip string | M4 Pro 273 GB/s, M4 Max 546 GB/s, RTX 4090 1008 GB/s, … Unknown chip → tok/s shows `-` rather than a fabricated number |
| tok/s | **computed, not fetched** | See [Fit and tok/s](#fit-and-toks) |
| Local blob metadata | `~/.docker/models/blobs/sha256/`, read with `llama-gguf` or `gguf_dump` when installed | Architecture, context length, quantization, tensor count |
| Metadata written back into the model store | the GGUF header, parsed with `od` and `awk` | Only when the registry published an empty config blob — see [Blank metadata in `docker model ls`](#blank-metadata-in-docker-model-ls) |

Caches: `param-ranges-v3.tsv` (one tab-separated record per model: name, parameter range,
smallest GGUF bytes, that tag, MoE active percentage) and `models-dev.json`. Delete either
to force a refetch; `[c]` clears filters, not caches.

## Proxied networks

On a network that blocks direct DNS and egress — a corporate MITM proxy, typically —
`docker model pull` can fail like this even though `docker pull` works fine:

```
failed to fetch oauth token: Post "https://auth.docker.io/token":
realm URL rejected: resolving realm hostname "auth.docker.io":
lookup auth.docker.io: no such host
```

Docker Desktop's **Model Runner does its own DNS** instead of using the proxy the daemon
is configured with. The daemon proxies, so image pulls succeed; the runner does not, so
model pulls fail before a packet leaves the machine.

The script detects this — `no such host`, `realm URL rejected`, `failed to authorize`,
`proxyconnect`, or an unknown CA — and stops retrying immediately rather than burning ten
attempts on an error that cannot resolve itself. It then downloads the model directly
with curl, which *does* honour `HTTPS_PROXY`, and installs it into Docker's own OCI store
at `~/.docker/models`:

- fetches the manifest and every blob, resuming interrupted transfers with `curl -C -`
- verifies each blob against the SHA-256 digest that names it, discarding and refetching on mismatch
- reuses blobs already in the store, so shared licences and weights are never downloaded twice
- writes atomically (`.part` then `mv`) and backs up `models.json` to `models.json.bak` before touching the index

A model installed this way is indistinguishable from a pulled one — it appears in
`docker model ls` with correct parameters, quantization and architecture, runs under
`docker model run`, and removes cleanly with `docker model rm`. Where the registry itself
publishes no metadata, the next section fills it in; that gap affects `docker model pull`
identically and is not a side effect of taking the curl path.

## Blank metadata in `docker model ls`

Some tags on Docker Hub ship a config blob with nothing in it — literally
`{"format":"gguf"}` — and the Model Runner has nothing else to read:

```
MODEL NAME                     PARAMETERS  QUANTIZATION  ARCHITECTURE  SIZE  CREATED
ai/nemotron-3.5-lightning                                                    56 years ago
```

Those blank columns are an **upstream publishing defect**, not a failed download. The blob
matches the digest that names it, so nothing is corrupt, and it is decided **per tag**:
`ai/qwen3:8B-Q4_K_M` is fully populated while `ai/qwen3:latest` is empty. `docker model
pull` lands exactly the same empty blob, which is why the repair runs after both download
paths rather than only after the curl fallback. `56 years ago` is Unix epoch 0 rendered as
a relative date.

Everything the blob should have said is in the GGUF, so the script reads it back out of the
weights and writes the config Docker should have published:

| Field | Where it comes from |
|---|---|
| `architecture`, `family` | `general.architecture` in the GGUF header |
| `quantization` | `general.file_type`, mapped through the `llama_ftype` enum (`15` → `MOSTLY_Q4_K_M`) |
| `paramSize` | **computed** — the sum over every tensor of the product of its dimensions, which is the only place a parameter count exists; GGUF does not store one |
| `diffIds` | the manifest's own layer digests |
| `createdAt` | the weight blob's mtime — when the artifact actually arrived on this machine |

Two fields are deliberately left out. `size` is inert in this schema: the Model Runner
derives the **SIZE** column from `paramSize` and silently drops any `size` key. And
`context_size` is omitted because a model advertising a 1,048,576-token context must not
have that become a runtime default here.

Only a blob that names **no architecture** is touched. A populated config is upstream's own
metadata and is never second-guessed, so the repair is a no-op on a healthy store, and
models with no GGUF to read (`ai/stable-diffusion` ships a `.dduf`) are skipped in silence.
Header parsing needs only `od` and `awk`, so this adds no dependency.

Rewriting the config changes its digest, which cascades: the manifest's config descriptor
changes, so the manifest digest changes, so the `models.json` entry and the bundle
directory name change with it. The script walks that whole chain, writes each file as
`.part` and `mv`s it into place, and takes the `models.json` swap as the commit point. The
bundle's weights are hardlinks, so renaming its directory moves no data. Before anything is
written, `models.json`, the manifest and the old config blob are copied to a `mktemp -d`
directory alongside a generated `RESTORE.txt` that undoes the change verbatim. The weights
are never touched.

Two environment variables tune it:

| Variable | Default | Effect |
|---|---|---|
| `REPAIR_MODEL_METADATA` | `1` | `0` disables the repair entirely |
| `GGUF_SCAN_BYTES` | `134217728` (128 MiB) | How far into the GGUF the header parser may read. It must pass the whole metadata block — a 150k-entry vocabulary alone can exceed 4 MiB — and into the tensor table |

A repair failure never fails a download: the model is already on disk and usable, it just
keeps the blank row it would have had anyway.

## Navigation

- **Startup menu**: Up/down arrows choose the action, Enter selects, and the downloader starts automatically after 5 seconds
- **Model list**: Left/right arrows navigate pages
- **Number + Enter**: Select model
- **f**: Search by name or description
- **r**: Toggle "only what fits this machine"
- **h**: Hardware panel and Fit legend
- **u**: Fold in sizes fetched in the background (shown only while a fetch is in flight)
- **c**: Clear search and filters
- **q**: Quit

That's it. Run the script, pick a model, and follow the on-screen instructions.

![Docker Model Downloader banner](assets/banner.png)
