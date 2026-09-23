#!/bin/bash
set -e
clear
# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m' # No Color

# Scanning performance tuning (bytes)
HEADER_BYTES=${HEADER_BYTES:-4194304}  # 4 MiB
MIN_SIZE_BYTES=${MIN_SIZE_BYTES:-1024}  # ignore tiny files
# Metadata repair reads further into a GGUF than HEADER_BYTES: past the whole
# metadata block, which a 150k-entry vocabulary alone can push beyond 4 MiB, and
# into the tensor table. 128 MiB covers every model tested and is read, not
# buffered, so the cost is I/O on a file that was just downloaded anyway.
GGUF_SCAN_BYTES=${GGUF_SCAN_BYTES:-134217728}  # 128 MiB
REPAIR_MODEL_METADATA=${REPAIR_MODEL_METADATA:-1}  # 0 disables the repair entirely
DOWNLOAD_RETRY_DELAY_SECONDS=${DOWNLOAD_RETRY_DELAY_SECONDS:-5}
DOWNLOAD_MAX_RETRIES=${DOWNLOAD_MAX_RETRIES:-10}
PATH_DISPLAY_WIDTH=${PATH_DISPLAY_WIDTH:-80}
KOFI_URL=${KOFI_URL:-"https://ko-fi.com/enelass"}
ACTIVE_PULL_PID=""
DOWNLOAD_CANCELLED=0

IS_MACOS=0
if [ "$(uname -s)" = "Darwin" ]; then
    IS_MACOS=1
fi


# Extract a GGUF KV value from header (header-limited, safe locale)
extract_kv_header() {
    local file="$1"
    local key="$2"
    LC_ALL=C head -c "$HEADER_BYTES" "$file" 2>/dev/null | LC_ALL=C strings | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C awk -v k="$key" 'BEGIN{f=0} index($0, k){f=1; next} f && NF{print; exit}'
}

extract_kv_exact() {
    local file="$1"
    local key="$2"
    LC_ALL=C head -c "$HEADER_BYTES" "$file" 2>/dev/null | LC_ALL=C strings | LC_ALL=C awk -v k="$key" '$0 == k { getline; print; exit }'
}

extract_arch_kv() {
    local file="$1"
    local arch="$2"
    local suffix="$3"

    if [ -z "$arch" ] || [ "$arch" = "-" ]; then
        return
    fi

    extract_kv_exact "$file" "${arch}.${suffix}"
}

extract_gguf_metadata() {
    local file="$1"

    case "$GGUF_TOOL" in
        gguf_dump)
            LC_ALL=C gguf_dump "$file" 2>/dev/null || true
            ;;
        llama-gguf)
            LC_ALL=C llama-gguf "$file" r n 2>/dev/null || true
            ;;
    esac

    LC_ALL=C head -c "$HEADER_BYTES" "$file" 2>/dev/null | LC_ALL=C strings || true
}

extract_tensor_count() {
    local file="$1"
    local output=""

    case "$GGUF_TOOL" in
        gguf_dump)
            output=$(LC_ALL=C gguf_dump "$file" 2>/dev/null || true)
            ;;
        llama-gguf)
            output=$(LC_ALL=C llama-gguf "$file" r n 2>/dev/null || true)
            ;;
    esac

    printf "%s" "$output" | LC_ALL=C awk '/n_tensors:/ { print $NF; exit }'
}

normalize_alnum_lower() {
    printf "%s" "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -d "[:space:]" | LC_ALL=C tr -cd "[:alnum:]"
}

is_incompatible_model_for_platform() {
    local name="$1"
    local lower_name

    if [ "$IS_MACOS" -eq 1 ]; then
        lower_name=$(printf "%s" "$name" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        case "$lower_name" in
            *vllm*) return 0 ;;
        esac
    fi

    return 1
}

# Normalize token to letters-only (lowercase)
normalize_letters() {
    printf "%s" "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z]//g'
}

format_size_gb() {
    local bytes="$1"
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        printf "-"
        return
    fi

    awk -v bytes="$bytes" 'BEGIN {
        gb = bytes / 1024 / 1024 / 1024
        rounded = int(gb * 10 + 0.5) / 10
        if (rounded == int(rounded)) {
            printf "%d GB", rounded
        } else {
            printf "%.1f GB", rounded
        }
    }'
}

truncate_text() {
    local value="$1"
    local width="$2"

    if [ "${#value}" -le "$width" ]; then
        printf "%s" "$value"
        return
    fi

    if [ "$width" -le 3 ]; then
        printf "%.*s" "$width" "$value"
        return
    fi

    printf "%.*s..." "$((width - 3))" "$value"
}

crop_middle() {
    local value="$1"
    local width="$2"
    local value_len=${#value}
    local prefix_len
    local suffix_len

    if [ "$value_len" -le "$width" ]; then
        printf "%s" "$value"
        return
    fi

    if [ "$width" -le 3 ]; then
        printf "%.*s" "$width" "$value"
        return
    fi

    prefix_len=$(( (width - 3) / 2 ))
    suffix_len=$(( width - 3 - prefix_len ))
    printf "%s...%s" "${value:0:$prefix_len}" "${value:$((value_len - suffix_len)):$suffix_len}"
}

# --- Registry fallback -----------------------------------------------------
#
# Docker Desktop's Model Runner resolves auth.docker.io itself instead of going
# through the proxy the daemon is configured with. On a network that blocks
# direct DNS - a corporate MITM proxy, typically - `docker model pull` fails
# with "no such host" while ordinary `docker pull` keeps working, because the
# daemon proxies and the runner does not.
#
# curl honours the proxy environment, so we can do the pull ourselves: fetch the
# manifest, fetch each blob, and write them into the same OCI store the Model
# Runner reads. Verified end to end - a model installed this way lists under
# `docker model ls`, runs under `docker model run`, and removes under
# `docker model rm` exactly like a pulled one.
#
# Every write is atomic (".part" then mv within the same directory) and every
# blob is checked against the digest that names it, so an interrupted run
# leaves a resumable part file and never a corrupt blob.

model_store_dir() {
    printf '%s/models' "${DOCKER_CONFIG:-$HOME/.docker}"
}

# Errors that will never resolve by trying again: the pull did not fail in
# flight, it failed before a packet left the machine. Retrying these ten times
# just spends fifty seconds proving the network is still misconfigured.
is_permanent_pull_failure() {
    local log="$1"
    [ -s "$log" ] || return 1
    grep -qE 'no such host|realm URL rejected|failed to authorize|proxyconnect|certificate signed by unknown authority' "$log" 2>/dev/null
}

registry_token() {
    local repo="$1"
    curl -fsSL --max-time 30 \
        "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
        2>/dev/null | jq -r '.token // empty' 2>/dev/null || true
}

# Fetch one blob into the store, resuming a previous attempt if there is one.
# Returns 0 when the blob is present and its digest checks out.
registry_fetch_blob() {
    local repo="$1" digest="$2" token="$3" label="$4"
    local blobs hex part got
    blobs="$(model_store_dir)/blobs/sha256"
    hex="${digest#sha256:}"
    part="$blobs/.$hex.part"

    if [ -f "$blobs/$hex" ]; then
        print_message "$GREEN" "  already in store: $label"
        return 0
    fi

    mkdir -p "$blobs" 2>/dev/null || true
    print_message "$YELLOW" "  fetching $label"
    if ! curl -fL --progress-bar -C - -o "$part" \
        "https://registry-1.docker.io/v2/${repo}/blobs/${digest}" \
        -H "Authorization: Bearer $token"; then
        print_message "$RED" "  transfer failed for $label (partial file kept for resume)"
        return 1
    fi

    got=$(shasum -a 256 "$part" 2>/dev/null | awk '{print $1}')
    if [ "$got" != "$hex" ]; then
        # A resumed transfer that appended to a stale part file lands here.
        # The part file is the only suspect, so drop it and let the caller retry
        # from zero rather than resuming onto known-bad bytes.
        rm -f "$part" 2>/dev/null || true
        print_message "$RED" "  checksum mismatch for $label - discarded"
        return 1
    fi

    mv -f "$part" "$blobs/$hex" || return 1
    return 0
}

registry_pull() {
    local reference="$1"
    local repo tag token manifest_file headers digest store files entry attempt
    local rc=0

    case "$reference" in
        *:*) repo="${reference%:*}"; tag="${reference##*:}" ;;
        *)   repo="$reference";      tag="latest" ;;
    esac
    case "$repo" in */*) : ;; *) repo="ai/$repo" ;; esac

    store="$(model_store_dir)"
    if [ ! -d "$store" ]; then
        print_message "$RED" "Docker model store not found at $store"
        return 1
    fi

    echo
    print_message "$GREEN" "Falling back to a direct registry download via curl (proxy-aware)."
    print_message "$YELLOW" "Pulling ${repo}:${tag}"
    echo

    token=$(registry_token "$repo")
    if [ -z "$token" ]; then
        print_message "$RED" "Could not obtain a registry token - curl cannot reach auth.docker.io either."
        print_message "$YELLOW" "Check that your proxy is up: \$HTTPS_PROXY is currently '${HTTPS_PROXY:-unset}'"
        return 1
    fi

    manifest_file=$(mktemp -t ddm_manifest) || return 1
    headers=$(mktemp -t ddm_headers) || return 1
    if ! curl -fsSL --max-time 30 -D "$headers" -o "$manifest_file" \
        "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" \
        -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'; then
        print_message "$RED" "Could not fetch the manifest for ${repo}:${tag}"
        rm -f "$manifest_file" "$headers"
        return 1
    fi

    digest=$(shasum -a 256 "$manifest_file" 2>/dev/null | awk '{print $1}')
    rm -f "$headers"
    if [ -z "$digest" ]; then
        rm -f "$manifest_file"
        return 1
    fi

    # Config blob first, then layers: it is tiny, and it is what `docker model ls`
    # reads every column except the tag from. (Its *contents* are sometimes empty
    # upstream - see the metadata repair below - but that is not a fetch problem.)
    for entry in $(jq -r '.config.digest, .layers[].digest' "$manifest_file" 2>/dev/null); do
        local label size
        size=$(jq -r --arg d "$entry" \
            '[.config, .layers[]] | map(select(.digest == $d)) | .[0].size // 0' \
            "$manifest_file" 2>/dev/null)
        label=$(jq -r --arg d "$entry" \
            '[.config, .layers[]] | map(select(.digest == $d)) | .[0].annotations["org.cncf.model.filepath"] // .[0].mediaType' \
            "$manifest_file" 2>/dev/null)
        # format_size_compact rounds anything under half a megabyte to "0MB",
        # which reads as an error next to a file that is about to download.
        if [ "${size:-0}" -ge 1048576 ] 2>/dev/null; then
            label="$label ($(format_size_compact "$size"))"
        fi

        attempt=0
        while true; do
            if registry_fetch_blob "$repo" "$entry" "$token" "$label"; then break; fi
            attempt=$(( attempt + 1 ))
            if [ "$attempt" -ge 3 ]; then
                print_message "$RED" "Giving up on $label after $attempt attempts."
                rm -f "$manifest_file"
                return 1
            fi
            print_message "$YELLOW" "  retrying ($attempt/3)..."
            sleep "$DOWNLOAD_RETRY_DELAY_SECONDS"
            # The token is good for a few minutes; a long blob can outlive it.
            token=$(registry_token "$repo")
        done
    done

    # Only now touch the store's index. Everything above is additive - unnamed
    # blobs are harmless - so a failure part way through leaves nothing to undo.
    mkdir -p "$store/manifests/sha256" 2>/dev/null || true
    cp "$manifest_file" "$store/manifests/sha256/.$digest.part" || { rm -f "$manifest_file"; return 1; }
    mv -f "$store/manifests/sha256/.$digest.part" "$store/manifests/sha256/$digest" || { rm -f "$manifest_file"; return 1; }

    files=$(jq -c '[.config.digest] + [.layers[].digest]' "$manifest_file" 2>/dev/null)
    rm -f "$manifest_file"
    [ -n "$files" ] || return 1

    if [ -f "$store/models.json" ]; then
        cp -p "$store/models.json" "$store/models.json.bak" 2>/dev/null || true
    else
        printf '{"models":[]}\n' > "$store/models.json" 2>/dev/null || true
    fi

    # Replacing any entry with the same id keeps a re-pull idempotent instead of
    # appending a duplicate that `docker model ls` would show twice.
    if jq --arg id "sha256:$digest" \
          --arg tag "docker.io/${repo}:${tag}" \
          --argjson files "$files" \
          '.models |= (map(select(.id != $id)) + [{id: $id, tags: [$tag], files: $files}])' \
          "$store/models.json" > "$store/.models.json.part" 2>/dev/null; then
        mv -f "$store/.models.json.part" "$store/models.json"
    else
        rm -f "$store/.models.json.part" 2>/dev/null || true
        print_message "$RED" "Could not update $store/models.json (previous copy kept)."
        return 1
    fi

    repair_model_metadata "$store" "$digest" || true

    echo
    print_message "$GREEN" "✅ Installed ${repo}:${tag} into the Docker model store."
    print_message "$YELLOW" "Verify with: docker model ls"
    return 0
}

# --- Metadata repair -------------------------------------------------------
#
# Some tags on Docker Hub ship a config blob with nothing in it - literally
# {"format":"gguf"} - and the Model Runner has nothing else to read, so
# `docker model ls` lists the model with blank PARAMETERS, QUANTIZATION,
# ARCHITECTURE and SIZE, and a CREATED of "56 years ago" (epoch 0).
#
# This is an upstream publishing defect, not a download problem. The blob we
# fetch matches the digest that names it, and it is per-tag: ai/qwen3:8B-Q4_K_M
# is fully populated while ai/qwen3:latest is empty. `docker model pull` lands
# exactly the same empty blob, which is why the repair runs after both download
# paths rather than only after the curl fallback.
#
# Everything the blob should have said is in the GGUF itself, so we read it back
# out of the weights and write the config Docker should have published. Only a
# blob that names no architecture is touched - a populated one is upstream's own
# metadata and is never second-guessed.

# general.file_type is llama.cpp's llama_ftype enum. These are the labels Docker
# stores as "quantization"; a value with no entry here is left out rather than
# guessed at.
ftype_label() {
    case "$1" in
        0)  printf 'ALL_F32' ;;
        1)  printf 'MOSTLY_F16' ;;
        2)  printf 'MOSTLY_Q4_0' ;;
        3)  printf 'MOSTLY_Q4_1' ;;
        4)  printf 'MOSTLY_Q4_1_SOME_F16' ;;
        7)  printf 'MOSTLY_Q8_0' ;;
        8)  printf 'MOSTLY_Q5_0' ;;
        9)  printf 'MOSTLY_Q5_1' ;;
        10) printf 'MOSTLY_Q2_K' ;;
        11) printf 'MOSTLY_Q3_K_S' ;;
        12) printf 'MOSTLY_Q3_K_M' ;;
        13) printf 'MOSTLY_Q3_K_L' ;;
        14) printf 'MOSTLY_Q4_K_S' ;;
        15) printf 'MOSTLY_Q4_K_M' ;;
        16) printf 'MOSTLY_Q5_K_S' ;;
        17) printf 'MOSTLY_Q5_K_M' ;;
        18) printf 'MOSTLY_Q6_K' ;;
        19) printf 'MOSTLY_IQ2_XXS' ;;
        20) printf 'MOSTLY_IQ2_XS' ;;
        21) printf 'MOSTLY_Q2_K_S' ;;
        22) printf 'MOSTLY_IQ3_XS' ;;
        23) printf 'MOSTLY_IQ3_XXS' ;;
        24) printf 'MOSTLY_IQ1_S' ;;
        25) printf 'MOSTLY_IQ4_NL' ;;
        26) printf 'MOSTLY_IQ3_S' ;;
        27) printf 'MOSTLY_IQ3_M' ;;
        28) printf 'MOSTLY_IQ2_S' ;;
        29) printf 'MOSTLY_IQ2_M' ;;
        30) printf 'MOSTLY_IQ4_XS' ;;
        31) printf 'MOSTLY_IQ1_M' ;;
        32) printf 'MOSTLY_BF16' ;;
        36) printf 'MOSTLY_TQ1_0' ;;
        37) printf 'MOSTLY_TQ2_0' ;;
        38) printf 'MOSTLY_MXFP4_MOE' ;;
        *)  return 1 ;;
    esac
}

# Read the GGUF binary header far enough to answer three questions the text
# helpers above cannot: the architecture, the quantization enum (a binary u32,
# invisible to `strings`), and the parameter count - which no GGUF stores, so it
# has to be summed over every tensor's dimensions.
#
# od | awk rather than a real language: this script's dependency list is bash,
# jq, awk, curl and shasum, and reading a header is not worth adding to it.
# Emits KEY=VALUE lines; exits non-zero if the file is not a parseable GGUF.
gguf_probe() {
    local file="$1"
    [ -f "$file" ] || return 1

    # od -v is mandatory: without it od collapses repeated lines to "*" and the
    # byte stream silently loses content. head bounds the read so a 25 GB file
    # costs only its header; awk exits as soon as the tensor table ends and the
    # upstream pipe stages take SIGPIPE.
    LC_ALL=C head -c "$GGUF_SCAN_BYTES" "$file" 2>/dev/null \
        | LC_ALL=C od -An -v -tu1 2>/dev/null \
        | LC_ALL=C awk '
    # Explicit init is load-bearing: an uninitialised bi subscripts buf as the
    # string "" while buf[bn++] subscripts it as the number 0, so the reader and
    # the writer disagree about the very first byte.
    BEGIN { bi = 0; bn = 0; bad = 0 }
    function refill(   k) {
        if ((getline) <= 0) { bad = 1; return 0 }
        for (k = 1; k <= NF; k++) buf[bn++] = $k + 0
        return 1
    }
    function b(   v) {
        if (bi >= bn) { if (!refill()) return 0 }
        v = buf[bi]; delete buf[bi]; bi++
        if (bi >= bn) { bi = 0; bn = 0 }
        return v
    }
    function uint(w,   i, v, m) {
        v = 0; m = 1
        for (i = 0; i < w; i++) { v += b() * m; m *= 256 }
        return v
    }
    # Skipping is the hot path - a 150k-entry vocabulary is megabytes of strings
    # nobody here reads. Whole od lines are swallowed without being turned into
    # array elements, so skipping costs one getline per 16 bytes instead of one
    # array store and delete per byte.
    function skip(n,   k) {
        while (n > 0 && bi < bn) { delete buf[bi]; bi++; n-- }
        if (bi >= bn) { bi = 0; bn = 0 }
        while (n > 0) {
            if ((getline) <= 0) { bad = 1; return }
            if (NF <= n) { n -= NF; continue }
            for (k = 1; k <= NF; k++) buf[bn++] = $k + 0
            while (n > 0) { delete buf[bi]; bi++; n-- }
            return
        }
    }
    function rdstr(   n, i, s) {
        n = uint(8); s = ""
        for (i = 0; i < n; i++) s = s sprintf("%c", b())
        return s
    }
    function twidth(t) {
        if (t == 0 || t == 1 || t == 7) return 1
        if (t == 2 || t == 3) return 2
        if (t == 4 || t == 5 || t == 6) return 4
        if (t == 10 || t == 11 || t == 12) return 8
        bad = 1; return 0
    }
    function skipval(t,   et, cnt, i) {
        if (t == 8) { skip(uint(8)); return }
        if (t == 9) {
            et = uint(4); cnt = uint(8)
            if (et == 9) { bad = 1; return }
            if (et == 8) { for (i = 0; i < cnt && !bad; i++) skip(uint(8)); return }
            skip(cnt * twidth(et)); return
        }
        skip(twidth(t))
    }
    function parse(   i, j, nd, key, t, nt, nkv, elems, ver) {
        if (b() != 71 || b() != 71 || b() != 85 || b() != 70) { bad = 1; return }
        ver = uint(4)
        if (ver < 2 || ver > 3) { bad = 1; return }
        nt = uint(8); nkv = uint(8)

        arch = ""; ftype = -1; ctx = 0
        for (i = 0; i < nkv && !bad; i++) {
            key = rdstr()
            t = uint(4)
            if (key == "general.architecture" && t == 8)               arch = rdstr()
            else if (key == "general.file_type" && (t == 4 || t == 5))  ftype = uint(4)
            else if (key ~ /\.context_length$/ && (t == 4 || t == 5))  ctx = uint(4)
            else skipval(t)
        }
        if (bad) return

        # Parameter count is not stored anywhere in a GGUF; it is the sum over
        # every tensor of the product of its dimensions.
        params = 0
        for (i = 0; i < nt && !bad; i++) {
            skip(uint(8))                                  # tensor name
            nd = uint(4)
            elems = 1
            for (j = 0; j < nd; j++) elems = elems * uint(8)
            skip(12)                                       # ggml type + offset
            params += elems
        }
        version = ver; tensors = nt; kv = nkv
    }
    NR == 1 {
        for (k = 1; k <= NF; k++) buf[bn++] = $k + 0
        parse()
        if (bad || arch == "") exit 1
        # %.0f, not %d: parameter counts exceed the 32-bit range awk %d truncates to.
        printf "version=%d\ntensors=%d\nkv=%d\narch=%s\nfile_type=%d\nparams=%.0f\ncontext=%d\n",
            version, tensors, kv, arch, ftype, params, ctx
        exit 0
    }
    ' 2>/dev/null
}

gguf_probe_field() {
    printf '%s\n' "$1" | awk -F= -v k="$2" '$1 == k { print $2; exit }'
}

# Which layer holds the weights, in three fallbacks, because the store spans two
# media-type generations and upstream annotates inconsistently:
#   1. the old dedicated gguf media type;
#   2. a CNCF weight layer whose filepath annotation ends in .gguf - needed
#      because a multimodal projector (model.mmproj) is typed as a weight layer
#      too and must not be picked;
#   3. the largest weight layer, for manifests that carry no filepath
#      annotations at all.
# Empty when the model has no GGUF at all, which is how a diffusers .dduf model
# gets skipped instead of mis-parsed.
manifest_gguf_digest() {
    local manifest="$1"
    jq -r '
        ( [ .layers[]
            | select(.mediaType == "application/vnd.docker.ai.gguf.v3") ]
          | sort_by(-.size) | .[0].digest )
        // ( [ .layers[]
               | select((.annotations["org.cncf.model.filepath"] // "") | endswith(".gguf")) ]
             | sort_by(-.size) | .[0].digest )
        // ( [ .layers[]
               | select(.mediaType | test("weight|gguf")) ]
             | sort_by(-.size) | .[0].digest )
        // empty
    ' "$manifest" 2>/dev/null
}

# True when the config names no architecture, in either schema generation: the
# older flat one and the nested "config" object both put it somewhere we look.
config_blob_is_blank() {
    local blob="$1" arch
    [ -f "$blob" ] || return 0
    arch=$(jq -r '(.config.architecture // .architecture) // empty' "$blob" 2>/dev/null) || arch=""
    [ -z "$arch" ]
}

# When the weights landed on this machine is the honest creation date for a blob
# we are synthesising now. Both stat and date differ between BSD and GNU, hence
# the pairs.
gguf_created_at() {
    local file="$1" epoch stamp
    epoch=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null) || epoch=""
    [ -n "$epoch" ] || epoch=$(date -u +%s)
    stamp=$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
            || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null) || stamp=""
    [ -n "$stamp" ] || stamp=$(date -u +%Y-%m-%dT%H:%M:%S)
    # The Model Runner writes nanoseconds here; seconds padded out parse the same.
    printf '%s.000000000Z' "$stamp"
}

# Synthesise the config blob for one model and walk the cascade a new config
# digest forces: blob -> manifest -> manifest digest -> models.json id and file
# list -> the bundle directory, which is named after the manifest digest too.
#
# Returns 0 when it repaired something, 2 when there was nothing to do (the
# common case - it runs after every download), 1 when it tried and failed. A
# failure here never fails a download: the model still works, it just lists
# without its metadata, exactly as it would have before.
repair_model_metadata() {
    local store="$1" manifest_digest="$2"
    local manifest config_ref config_blob gguf_ref gguf info
    local arch ftype params quant paramsize created diffids
    local tmp_config tmp_manifest new_config_digest new_config_size
    local new_manifest_digest backup old_bundle new_bundle files

    [ "${REPAIR_MODEL_METADATA:-1}" = "1" ] || return 2

    manifest="$store/manifests/sha256/$manifest_digest"
    [ -f "$manifest" ] || return 2

    config_ref=$(jq -r '.config.digest // empty' "$manifest" 2>/dev/null) || return 2
    [ -n "$config_ref" ] || return 2
    config_blob="$store/blobs/sha256/${config_ref#sha256:}"

    config_blob_is_blank "$config_blob" || return 2

    gguf_ref=$(manifest_gguf_digest "$manifest")
    [ -n "$gguf_ref" ] || return 2
    gguf="$store/blobs/sha256/${gguf_ref#sha256:}"
    [ -f "$gguf" ] || return 2

    echo
    print_message "$YELLOW" "This model was published with an empty metadata blob, so it would list"
    print_message "$YELLOW" "with no architecture, parameters or quantization. Reading them from the GGUF."

    start_spinner "  parsing GGUF header"
    info=$(gguf_probe "$gguf") || info=""
    stop_spinner

    if [ -z "$info" ]; then
        print_message "$RED" "  Could not read the GGUF header - leaving the metadata alone."
        return 1
    fi

    arch=$(gguf_probe_field "$info" arch)
    ftype=$(gguf_probe_field "$info" file_type)
    params=$(gguf_probe_field "$info" params)
    if [ -z "$arch" ] || [ -z "$params" ] || [ "$params" = "0" ]; then
        print_message "$RED" "  The GGUF header names no architecture - leaving the metadata alone."
        return 1
    fi

    quant=$(ftype_label "${ftype:--1}") || quant=""
    paramsize=$(awk -v p="$params" 'BEGIN { printf "%.2fB", p / 1000000000 }')
    created=$(gguf_created_at "$gguf")
    diffids=$(jq -c '[.layers[].digest]' "$manifest" 2>/dev/null) || diffids=""
    [ -n "$diffids" ] || return 1

    # Mirror the schema and key order the Model Runner writes for itself. Two
    # fields are deliberately absent, both because the Runner omits them too:
    #   size        - inert in this schema; the Runner renders paramSize instead.
    #   context_size - would become a runtime default, and a model advertising a
    #                  million tokens must not silently get one.
    # quantization is left out rather than guessed when file_type is unknown.
    tmp_config="$store/blobs/sha256/.$$.config.part"
    if ! jq -cn --arg created "$created" --arg arch "$arch" \
            --arg paramsize "$paramsize" --arg quant "$quant" --argjson diffids "$diffids" '
            {
              descriptor: { createdAt: $created, family: $arch },
              modelfs: { type: "layers", diffIds: $diffids },
              config: ({ architecture: $arch, format: "gguf", paramSize: $paramsize }
                       + (if $quant == "" then {} else { quantization: $quant } end))
            }' > "$tmp_config" 2>/dev/null; then
        rm -f "$tmp_config" 2>/dev/null || true
        print_message "$RED" "  Could not build the metadata blob - leaving it alone."
        return 1
    fi

    new_config_digest=$(shasum -a 256 "$tmp_config" 2>/dev/null | awk '{print $1}')
    new_config_size=$(wc -c < "$tmp_config" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$new_config_digest" ] || [ -z "$new_config_size" ]; then
        rm -f "$tmp_config" 2>/dev/null || true
        return 1
    fi

    tmp_manifest="$store/manifests/sha256/.$$.manifest.part"
    if ! jq -c --arg d "sha256:$new_config_digest" --argjson s "$new_config_size" \
            '.config.digest = $d | .config.size = $s' \
            "$manifest" > "$tmp_manifest" 2>/dev/null; then
        rm -f "$tmp_config" "$tmp_manifest" 2>/dev/null || true
        print_message "$RED" "  Could not rewrite the manifest - leaving the metadata alone."
        return 1
    fi
    new_manifest_digest=$(shasum -a 256 "$tmp_manifest" 2>/dev/null | awk '{print $1}')
    files=$(jq -c --arg c "sha256:$new_config_digest" '[$c] + [.layers[].digest]' "$tmp_manifest" 2>/dev/null)
    if [ -z "$new_manifest_digest" ] || [ -z "$files" ]; then
        rm -f "$tmp_config" "$tmp_manifest" 2>/dev/null || true
        return 1
    fi

    # Back the mutable state up before touching any of it. The weights are never
    # written to, so they need no backup and nothing here copies gigabytes.
    backup=$(mktemp -d -t ddm_metadata 2>/dev/null) || backup=""
    if [ -n "$backup" ]; then
        cp -p "$store/models.json" "$backup/models.json" 2>/dev/null || true
        cp -p "$manifest" "$backup/manifest-$manifest_digest" 2>/dev/null || true
        cp -p "$config_blob" "$backup/config-${config_ref#sha256:}" 2>/dev/null || true
        cat > "$backup/RESTORE.txt" <<EOF
Undo the metadata repair of manifest $manifest_digest:

  S="$store"
  cp "$backup/models.json" "\$S/models.json"
  cp "$backup/manifest-$manifest_digest" "\$S/manifests/sha256/$manifest_digest"
  cp "$backup/config-${config_ref#sha256:}" "\$S/blobs/sha256/${config_ref#sha256:}"
  [ -d "\$S/bundles/sha256/$new_manifest_digest" ] && mv "\$S/bundles/sha256/$new_manifest_digest" "\$S/bundles/sha256/$manifest_digest"
  cp "$backup/config-${config_ref#sha256:}" "\$S/bundles/sha256/$manifest_digest/config.json" 2>/dev/null
  rm -f "\$S/manifests/sha256/$new_manifest_digest" "\$S/blobs/sha256/$new_config_digest"

The weights are untouched by the repair and need no restore.
EOF
    fi

    # Additive writes first: nothing references either of these yet, so a failure
    # here leaves the model exactly as it was, just with two unnamed extra files.
    if ! mv -f "$tmp_config" "$store/blobs/sha256/$new_config_digest" \
       || ! mv -f "$tmp_manifest" "$store/manifests/sha256/$new_manifest_digest"; then
        rm -f "$tmp_config" "$tmp_manifest" 2>/dev/null || true
        print_message "$RED" "  Could not write the new metadata into the store."
        return 1
    fi

    # The bundle directory is named after the manifest digest and holds a copy of
    # the config plus hardlinks to the weights, so renaming it moves no data. It
    # is created lazily on first run, so it is often simply absent.
    old_bundle="$store/bundles/sha256/$manifest_digest"
    new_bundle="$store/bundles/sha256/$new_manifest_digest"
    if [ -d "$old_bundle" ] && [ ! -d "$new_bundle" ]; then
        if mv "$old_bundle" "$new_bundle" 2>/dev/null; then
            cp "$store/blobs/sha256/$new_config_digest" "$new_bundle/config.json" 2>/dev/null || true
        fi
    fi

    # The commit point: until models.json names the new manifest, none of the
    # above is visible to the Model Runner.
    if jq --arg old "sha256:$manifest_digest" \
          --arg new "sha256:$new_manifest_digest" \
          --argjson files "$files" \
          '.models |= map(if .id == $old then (.id = $new | .files = $files) else . end)' \
          "$store/models.json" > "$store/.models.json.part" 2>/dev/null; then
        mv -f "$store/.models.json.part" "$store/models.json"
    else
        rm -f "$store/.models.json.part" 2>/dev/null || true
        print_message "$RED" "  Could not update models.json - metadata left unrepaired."
        return 1
    fi

    # The superseded manifest is now unreferenced and is uniquely this model's,
    # so it goes. The old config blob stays: two models published with the same
    # empty blob share one digest, and deleting it would blank the other one.
    rm -f "$manifest" 2>/dev/null || true

    print_message "$GREEN" "  ${arch}, ${paramsize} parameters${quant:+, $quant}"
    [ -n "$backup" ] && print_message "$YELLOW" "  Previous metadata backed up in $backup"
    return 0
}

# Resolve a user-supplied reference the way registry_pull does, to the tag form
# models.json stores.
normalize_model_tag() {
    local reference="$1" repo tag
    # Split on the last colon only if it is in the tag, not in a registry:port.
    case "${reference##*/}" in
        *:*) repo="${reference%:*}"; tag="${reference##*:}" ;;
        *)   repo="$reference";      tag="latest" ;;
    esac
    case "$repo" in */*) : ;; *) repo="ai/$repo" ;; esac
    case "$repo" in *.*/*|localhost/*) : ;; *) repo="docker.io/$repo" ;; esac
    printf '%s:%s' "$repo" "$tag"
}

# Repair whichever model a reference names. Used after `docker model pull`,
# which reports success without saying what it wrote where.
repair_pulled_model() {
    local reference="$1" store want id
    [ "${REPAIR_MODEL_METADATA:-1}" = "1" ] || return 2

    store="$(model_store_dir)"
    [ -f "$store/models.json" ] || return 2

    want=$(normalize_model_tag "$reference")
    id=$(jq -r --arg t "$want" '
            [ .models[] | select((.tags // []) | index($t)) | .id ] | .[0] // empty
        ' "$store/models.json" 2>/dev/null) || id=""
    [ -n "$id" ] || return 2

    repair_model_metadata "$store" "${id#sha256:}"
}

pull_model_with_retries() {
    local model_reference="$1"
    local attempt=0
    local status=0
    local log

    log=$(mktemp -t ddm_pull) || log=""

    cancel_active_download() {
        DOWNLOAD_CANCELLED=1
        echo
        print_message "$YELLOW" "Download cancellation requested. Stopping docker model pull..."
        if [ -n "${ACTIVE_PULL_PID:-}" ] && kill -0 "$ACTIVE_PULL_PID" 2>/dev/null; then
            kill -TERM "$ACTIVE_PULL_PID" 2>/dev/null || true
        fi
    }

    while true; do
        DOWNLOAD_CANCELLED=0

        if [ "$attempt" -eq 0 ]; then
            print_message "$YELLOW" "Running: docker model pull $model_reference"
        else
            print_message "$YELLOW" "Retry $attempt/$DOWNLOAD_MAX_RETRIES: docker model pull $model_reference"
        fi

        trap cancel_active_download INT
        if [ -n "$log" ]; then
            # tee keeps the live output the user expects while giving us a copy
            # to classify the failure from afterwards.
            : > "$log"
            docker model pull "$model_reference" > >(tee "$log") 2>&1 &
        else
            docker model pull "$model_reference" &
        fi
        ACTIVE_PULL_PID=$!
        if wait "$ACTIVE_PULL_PID"; then
            status=0
        else
            status=$?
        fi
        ACTIVE_PULL_PID=""
        trap - INT
        # tee is a separate process and may still be draining the pipe.
        sleep 0.2

        if [ "$DOWNLOAD_CANCELLED" -eq 1 ] || [ "$status" -eq 130 ] || [ "$status" -eq 143 ]; then
            print_message "$YELLOW" "Download cancelled."
            rm -f "$log" 2>/dev/null || true
            return 130
        fi

        if [ "$status" -eq 0 ]; then
            rm -f "$log" 2>/dev/null || true
            # A successful pull is no guarantee of usable metadata: some tags are
            # published with an empty config blob and land here blank.
            repair_pulled_model "$model_reference" || true
            return 0
        fi

        if [ -n "$log" ] && is_permanent_pull_failure "$log"; then
            echo
            print_message "$RED" "This is not a transient failure - retrying will not help."
            print_message "$YELLOW" "The Model Runner could not resolve or authorise against the registry."
            print_message "$YELLOW" "It does its own DNS instead of using the proxy the daemon is configured"
            print_message "$YELLOW" "with, which is why plain 'docker pull' works and this does not."
            rm -f "$log" 2>/dev/null || true
            if registry_pull "$model_reference"; then
                return 0
            fi
            return 1
        fi

        if [ "$attempt" -ge "$DOWNLOAD_MAX_RETRIES" ]; then
            rm -f "$log" 2>/dev/null || true
            return 1
        fi

        attempt=$((attempt + 1))
        print_message "$YELLOW" "Download failed. Retrying in ${DOWNLOAD_RETRY_DELAY_SECONDS}s..."
        sleep "$DOWNLOAD_RETRY_DELAY_SECONDS"
    done
}


# Function to print colored messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

SPINNER_PID=""

start_spinner() {
    local message="$1"

    stop_spinner

    if [ ! -t 1 ]; then
        print_message "$YELLOW" "$message"
        return
    fi

    (
        while true; do
            for frame in "-" "\\" "|" "/"; do
                printf "\r${YELLOW}%s${NC} %s" "$frame" "$message"
                sleep 0.12
            done
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    if [ -n "${SPINNER_PID:-}" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""

        if [ -t 1 ]; then
            printf "\r\033[K"
        fi
    fi
}

print_banner() {
    print_message "$GREEN" "╔════════════════════════════════════════════════════════════════╗"
    print_message "$GREEN" "║                 Docker Model Downloader                        ║"
    print_message "$GREEN" "╚════════════════════════════════════════════════════════════════╝"
    echo
    print_message "$YELLOW" "   Donate to support this work: $KOFI_URL"
}

# Check if docker command exists
if ! command -v docker &> /dev/null; then
    print_message "$RED" "❌ Error: Docker command not found!"
    print_message "$YELLOW" "Please install Docker Desktop first: https://www.docker.com/products/docker-desktop"
    exit 1
fi

#print_message "$GREEN" "✅ Docker command found!"

# Check if jq command exists
if ! command -v jq &> /dev/null; then
    print_message "$RED" "❌ Error: jq command not found!"
    print_message "$YELLOW" "This script uses jq to parse Docker Hub's API responses. Install it with:"
    print_message "$YELLOW" "  • macOS (Homebrew): brew install jq"
    print_message "$YELLOW" "  • Ubuntu/Debian:    sudo apt-get update && sudo apt-get install -y jq"
    exit 1
fi

#print_message "$GREEN" "✅ jq command found!"
#echo

# Detect optional GGUF tooling: prefer gguf_dump when present; Homebrew llama.cpp provides llama-gguf.
GGUF_TOOL=""
GGUF_TOOL_MESSAGE=""
GGUF_TOOL_COLOR="$GREEN"
if command -v gguf_dump >/dev/null 2>&1; then
    GGUF_TOOL="gguf_dump"
    GGUF_TOOL_MESSAGE="✅ GGUF metadata: gguf_dump"
elif command -v llama-gguf >/dev/null 2>&1; then
    GGUF_TOOL="llama-gguf"
    GGUF_TOOL_MESSAGE="✅ GGUF metadata: llama-gguf"
else
    GGUF_TOOL_MESSAGE="⚠️  GGUF metadata tools not found. Downloads still work; install llama.cpp for richer local metadata."
    GGUF_TOOL_COLOR="$YELLOW"
fi

render_startup_menu() {
    local selected="$1"
    local remaining="$2"
    local interacted="$3"

    clear
    print_banner
    echo
    echo "   Select a Docker AI model and variant, download it, then locate the GGUF blob."
    echo "   Docker stores model blobs in: ~/.docker/models/blobs/sha256/"
    echo
    print_message "$GREEN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    print_message "$GGUF_TOOL_COLOR" "$GGUF_TOOL_MESSAGE"
    echo

    if [ "$selected" -eq 1 ]; then
        echo " > (*) Download models"
        echo "   ( ) Check downloaded models"
    else
        echo "   ( ) Download models"
        echo " > (*) Check downloaded models"
    fi

    echo
    if [ "$interacted" -eq 1 ]; then
        print_message "$YELLOW" "Use ↑/↓ then Enter. [q] Quit"
    else
        print_message "$YELLOW" "Use ↑/↓ then Enter. Auto-starting downloader in ${remaining}s. [q] Quit"
    fi
}

select_startup_action() {
    local selected=1
    local deadline=$((SECONDS + 5))
    local interacted=0
    local remaining
    local key
    local rest

    while true; do
        if [ "$interacted" -eq 0 ]; then
            remaining=$((deadline - SECONDS))
            if [ "$remaining" -le 0 ]; then
                APP_ACTION="download"
                return
            fi
        else
            remaining=0
        fi

        render_startup_menu "$selected" "$remaining" "$interacted"

        if [ "$interacted" -eq 0 ]; then
            if ! IFS= read -t "$remaining" -r -s -n 1 key 2>/dev/null; then
                APP_ACTION="download"
                return
            fi
        else
            IFS= read -r -s -n 1 key 2>/dev/null
        fi

        case "$key" in
            "")
                if [ "$selected" -eq 1 ]; then
                    APP_ACTION="download"
                else
                    APP_ACTION="check"
                fi
                return
                ;;
            $'\x1b')
                if [ -t 0 ]; then
                    IFS= read -t 0.5 -r -s -n 2 rest 2>/dev/null || true
                else
                    IFS= read -r -s -n 2 rest 2>/dev/null || true
                fi
                case "$rest" in
                    '[A'|'[B')
                        interacted=1
                        if [ "$selected" -eq 1 ]; then
                            selected=2
                        else
                            selected=1
                        fi
                        ;;
                esac
                ;;
            '[')
                IFS= read -r -s -n 1 rest 2>/dev/null || true
                case "$rest" in
                    A|B)
                        interacted=1
                        if [ "$selected" -eq 1 ]; then
                            selected=2
                        else
                            selected=1
                        fi
                        ;;
                esac
                ;;
            1)
                APP_ACTION="download"
                return
                ;;
            2)
                APP_ACTION="check"
                return
                ;;
            q|Q)
                print_message "$YELLOW" "Exiting..."
                exit 0
                ;;
        esac
    done
}

APP_ACTION="download"
select_startup_action

display_downloaded_models() {
    clear
    print_banner
    echo
    print_message "$GREEN" "📁 Downloaded Docker GGUF models"
    echo

    local blobs_dir="$HOME/.docker/models/blobs/sha256"
    if [ ! -d "$blobs_dir" ]; then
        print_message "$YELLOW" "⚠️  Docker models directory not found: $blobs_dir"
        return
    fi

    start_spinner "Scanning local Docker model blobs..."

    declare -a downloaded_gguf_files=()
    declare -a incomplete_download_files=()
    local incomplete_count=0
    while IFS= read -r file; do
        case "$file" in
            *.incomplete)
                incomplete_count=$((incomplete_count + 1))
                incomplete_download_files+=("$file")
                continue
                ;;
        esac

        if [ -f "$file" ]; then
            magic=$(head -c 4 "$file" 2>/dev/null | xxd -p 2>/dev/null)
            if [ "$magic" = "47475546" ]; then
                downloaded_gguf_files+=("$file")
            fi
        fi
    done < <(find "$blobs_dir" -type f 2>/dev/null)

    stop_spinner

    if [ ${#downloaded_gguf_files[@]} -eq 0 ] && [ "$incomplete_count" -eq 0 ]; then
        print_message "$YELLOW" "No GGUF files found in $blobs_dir."
        return
    fi

    if [ ${#downloaded_gguf_files[@]} -eq 0 ]; then
        print_message "$YELLOW" "No completed GGUF files found in $blobs_dir."
        echo
    else
    IFS=$'\n' sorted_downloaded_gguf_files=($(
        for f in "${downloaded_gguf_files[@]}"; do
            echo "$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)|$f"
        done | sort -rn | cut -d'|' -f2
    ))

    if [ -n "$GGUF_TOOL" ]; then
        start_spinner "Reading GGUF metadata..."
    else
        start_spinner "Reading GGUF headers..."
    fi

    declare -a group_names=()
    declare -a record_groups=()
    declare -a record_roles=()
    declare -a record_arches=()
    declare -a record_sizes=()
    declare -a record_contexts=()
    declare -a record_quants=()
    declare -a record_tensors=()
    declare -a record_paths=()

    for gguf_file in "${sorted_downloaded_gguf_files[@]}"; do
        local file_size
        local model_name
        local arch
        local role
        local context_length
        local file_type
        local quant_version
        local quantization
        local tensor_count
        local cropped_path
        local group_exists=0
        local group_name

        file_size=$(du -h "$gguf_file" | awk '{print $1}')
        model_name=$(extract_kv_exact "$gguf_file" "general.name")
        if [ -z "$model_name" ]; then
            model_name=$(extract_kv_exact "$gguf_file" "general.basename")
        fi
        if [ -z "$model_name" ]; then
            model_name="Unknown GGUF model"
        fi

        arch=$(extract_kv_exact "$gguf_file" "general.architecture")
        if [ -z "$arch" ]; then
            arch="-"
        fi

        role=$(extract_kv_exact "$gguf_file" "general.type")
        if [ "$arch" = "clip" ]; then
            role="projector"
        elif [ -z "$role" ]; then
            role="model"
        fi

        context_length=$(extract_arch_kv "$gguf_file" "$arch" "context_length")
        if ! [[ "$context_length" =~ ^[0-9]+$ ]]; then
            context_length="-"
        fi

        file_type=$(extract_kv_exact "$gguf_file" "general.file_type")
        quant_version=$(extract_kv_exact "$gguf_file" "general.quantization_version")
        if ! [[ "$file_type" =~ ^[0-9]+$ ]]; then
            file_type=""
        fi
        if ! [[ "$quant_version" =~ ^[0-9]+$ ]]; then
            quant_version=""
        fi
        if [ -n "$file_type" ] && [ -n "$quant_version" ]; then
            quantization="type ${file_type}/v${quant_version}"
        elif [ -n "$file_type" ]; then
            quantization="type ${file_type}"
        elif [ -n "$quant_version" ]; then
            quantization="v${quant_version}"
        else
            quantization="-"
        fi

        tensor_count=$(extract_tensor_count "$gguf_file")
        if [ -z "$tensor_count" ]; then
            tensor_count="-"
        fi

        cropped_path=$(crop_middle "$gguf_file" "$PATH_DISPLAY_WIDTH")

        for group_name in "${group_names[@]}"; do
            if [ "$group_name" = "$model_name" ]; then
                group_exists=1
                break
            fi
        done
        if [ "$group_exists" -eq 0 ]; then
            group_names+=("$model_name")
        fi

        record_groups+=("$model_name")
        record_roles+=("$role")
        record_arches+=("$arch")
        record_sizes+=("$file_size")
        record_contexts+=("$context_length")
        record_quants+=("$quantization")
        record_tensors+=("$tensor_count")
        record_paths+=("$cropped_path")
    done

    stop_spinner

    print_message "$GREEN" "Found ${#sorted_downloaded_gguf_files[@]} GGUF file(s) across ${#group_names[@]} model group(s):"
    if [ "$incomplete_count" -gt 0 ]; then
        print_message "$YELLOW" "Skipped $incomplete_count incomplete download file(s)."
    fi
    echo

    for group_name in "${group_names[@]}"; do
        print_message "$GREEN" "$group_name"
        printf "  %-10s %-10s %-7s %-9s %-13s %-8s %s\n" "Role" "Arch" "Size" "Context" "Quant" "Tensors" "Path"

        local idx
        for idx in "${!record_groups[@]}"; do
            if [ "${record_groups[$idx]}" = "$group_name" ]; then
                printf "  %-10s %-10s %-7s %-9s %-13s %-8s %s\n" \
                    "$(truncate_text "${record_roles[$idx]}" 10)" \
                    "$(truncate_text "${record_arches[$idx]}" 10)" \
                    "${record_sizes[$idx]}" \
                    "$(truncate_text "${record_contexts[$idx]}" 9)" \
                    "$(truncate_text "${record_quants[$idx]}" 13)" \
                    "${record_tensors[$idx]}" \
                    "${record_paths[$idx]}"
            fi
        done
        echo
    done
    fi

    if [ "$incomplete_count" -gt 0 ]; then
        print_message "$YELLOW" "Incomplete downloads"
        printf "  %-7s %s\n" "Size" "Path"

        local incomplete_file
        for incomplete_file in "${incomplete_download_files[@]}"; do
            printf "  %-7s %s\n" \
                "$(du -h "$incomplete_file" 2>/dev/null | awk '{print $1}')" \
                "$(crop_middle "$incomplete_file" "$PATH_DISPLAY_WIDTH")"
        done
        echo

        print_message "$YELLOW" "Press [p] to purge incomplete downloads, or Enter/[q] to exit."
        printf "Enter choice: "

        local purge_choice
        if ! read -r purge_choice; then
            return
        fi

        case "$purge_choice" in
            p|P)
                print_message "$YELLOW" "Delete $incomplete_count incomplete download file(s)? [y/N]"
                printf "Confirm: "
                local confirm_purge
                if ! read -r confirm_purge; then
                    print_message "$YELLOW" "Purge cancelled."
                    return
                fi

                case "$confirm_purge" in
                    y|Y|yes|YES)
                        local purged_count=0
                        for incomplete_file in "${incomplete_download_files[@]}"; do
                            if rm -f -- "$incomplete_file"; then
                                purged_count=$((purged_count + 1))
                            fi
                        done
                        print_message "$GREEN" "Purged $purged_count incomplete download file(s)."
                        ;;
                    *)
                        print_message "$YELLOW" "Purge cancelled."
                        ;;
                esac
                ;;
        esac
    fi
}

fetch_models_from_dockerhub() {
    model_names=()
    model_stars=()
    model_pulls=()
    model_descriptions=()

    local page_size=100
    local max_attempts=3
    local skipped_incompatible_models=0

    # Docker Hub refuses anonymous listing requests once the pagination offset
    # reaches this value, answering 403 with:
    #   {"message":"pagination offset too large for anonymous requests; ..."}
    # Walking the listing once ascending and once descending keeps every request
    # below that offset, so up to 2 x ANON_OFFSET_LIMIT repositories stay
    # reachable without credentials.
    local anon_offset_limit=100
    local seen_names=" "
    local total_count=0
    local collected=0

    start_spinner "Retrieving model list from Docker Hub..."

    local ordering
    for ordering in "last_updated" "-last_updated"; do
        local page=1

        while true; do
            if [ $(( (page - 1) * page_size )) -ge "$anon_offset_limit" ]; then
                break
            fi

            local url="https://hub.docker.com/v2/repositories/ai?page_size=${page_size}&page=${page}&ordering=${ordering}"

            local response=""
            local http_code=""
            local attempt
            for attempt in $(seq 1 "$max_attempts"); do
                local body_file
                body_file=$(mktemp)
                http_code=$(curl -sSL "$url" -H 'accept: */*' -o "$body_file" -w '%{http_code}' 2>/dev/null || echo "000")
                response=$(cat "$body_file")
                rm -f "$body_file"

                if [ "$http_code" = "200" ] && [ -n "$response" ]; then
                    break
                fi
                response=""
                sleep 0.4
            done

            if [ -z "$response" ]; then
                stop_spinner
                print_message "$RED" "❌ Failed to fetch model list from Docker Hub (page $page, HTTP ${http_code:-000})."
                if [ "$http_code" = "000" ]; then
                    print_message "$YELLOW" "Check your internet connection (or proxy settings) and try again."
                else
                    print_message "$YELLOW" "Docker Hub rejected the request. Try again later (you may be rate-limited)."
                fi
                exit 1
            fi

            if ! echo "$response" | jq -e '.results and (.results|type=="array")' >/dev/null 2>&1; then
                stop_spinner
                print_message "$RED" "❌ Docker Hub returned an unexpected response (page $page)."
                print_message "$YELLOW" "Try again later (you may be rate-limited)."
                exit 1
            fi

            total_count=$(echo "$response" | jq -r '.count // 0')

            local page_count
            page_count=$(echo "$response" | jq -r '.results | length')
            if [ "$page_count" -eq 0 ]; then
                break
            fi

            while IFS='|' read -r name stars pulls description; do
                # The two ordering passes overlap when the listing is small.
                case "$seen_names" in
                    *" $name "*) continue ;;
                esac
                seen_names="${seen_names}${name} "
                collected=$((collected + 1))

                if is_incompatible_model_for_platform "$name"; then
                    skipped_incompatible_models=$((skipped_incompatible_models + 1))
                    continue
                fi

                model_names+=("$name")
                model_stars+=("$stars")
                model_pulls+=("$pulls")
                model_descriptions+=("$description")
            done < <(
                echo "$response" | jq -r '.results[] | "\(.name)|\(.star_count // 0)|\(.pull_count // 0)|\(.description // "")"'
            )

            local next_url
            next_url=$(echo "$response" | jq -r '.next')
            if [ "$next_url" = "null" ] || [ -z "$next_url" ]; then
                break
            fi

            page=$((page + 1))
        done

        # Everything is already in hand; skip the reverse pass.
        if [ "$total_count" -gt 0 ] && [ "$collected" -ge "$total_count" ]; then
            break
        fi
    done

    stop_spinner

    if [ "$total_count" -gt 0 ] && [ "$collected" -lt "$total_count" ]; then
        print_message "$YELLOW" "Showing $collected of $total_count models (Docker Hub caps anonymous listing at $((anon_offset_limit * 2))). Sign in to Docker Hub to see the rest."
    fi

    if [ "$skipped_incompatible_models" -gt 0 ]; then
        print_message "$YELLOW" "Filtered $skipped_incompatible_models vLLM model(s) on macOS."
    fi

    if [ ${#model_names[@]} -eq 0 ]; then
        print_message "$RED" "❌ No models returned from Docker Hub."
        print_message "$YELLOW" "Try again later."
        exit 1
    fi
}

# --- Hardware fit ----------------------------------------------------------
#
# What decides whether a model runs is not its parameter count but how many
# bytes of weights must be resident. On Apple Silicon the binding limit is the
# Metal wired limit - how much of unified memory the GPU is allowed to pin -
# rather than total RAM. Exceeding it does not fail outright; llama.cpp falls
# back to CPU, which is the difference between "slow" and "impossible", so it
# gets its own verdict rather than being lumped in with "won't run".
HW_CHIP=""
HW_RAM_GB=0
HW_BUDGET_GB=0
HW_BANDWIDTH=0          # GB/s; 0 means unknown, and the speed column stays "-"
HW_KIND=""

# Peak memory bandwidth per chip (GB/s). Decode streams the weights once per
# token, so this is the number that sets tokens/sec.
bandwidth_for_chip() {
    case "$1" in
        *"M1 Ultra"*) echo 800 ;; *"M1 Max"*) echo 400 ;; *"M1 Pro"*) echo 200 ;; *"M1"*) echo 68 ;;
        *"M2 Ultra"*) echo 800 ;; *"M2 Max"*) echo 400 ;; *"M2 Pro"*) echo 200 ;; *"M2"*) echo 100 ;;
        *"M3 Ultra"*) echo 800 ;; *"M3 Max"*) echo 400 ;; *"M3 Pro"*) echo 150 ;; *"M3"*) echo 100 ;;
        *"M4 Max"*)   echo 546 ;; *"M4 Pro"*) echo 273 ;; *"M4"*) echo 120 ;;
        *"M5 Max"*)   echo 546 ;; *"M5 Pro"*) echo 273 ;; *"M5"*) echo 153 ;;
        *5090*) echo 1792 ;; *4090*) echo 1008 ;; *3090*) echo 936 ;;
        *4080*) echo 717  ;; *4070*) echo 504  ;; *A100*) echo 1555 ;;
        *) echo 0 ;;
    esac
}

detect_hardware() {
    local os
    os=$(uname -s 2>/dev/null || echo unknown)

    if [ "$os" = "Darwin" ]; then
        local memb wired
        memb=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        case "$memb" in ''|*[!0-9]*) memb=0 ;; esac
        HW_RAM_GB=$(( memb / 1073741824 ))

        HW_CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
        if [ -z "$HW_CHIP" ]; then
            HW_CHIP=$(sysctl -n hw.model 2>/dev/null || echo "unknown")
        fi

        # 0 means "no override set", i.e. the system default policy, which is
        # roughly 75% of unified memory.
        wired=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
        case "$wired" in ''|*[!0-9]*) wired=0 ;; esac
        if [ "$wired" -gt 0 ]; then
            HW_BUDGET_GB=$(( wired / 1024 ))
        else
            HW_BUDGET_GB=$(( HW_RAM_GB * 3 / 4 ))
        fi

        case "$HW_CHIP" in
            *Apple*) HW_KIND="unified memory" ;;
            *)       HW_KIND="Intel Mac" ;;
        esac

    elif [ "$os" = "Linux" ]; then
        local kb vram gpuname
        kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
        case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
        HW_RAM_GB=$(( kb / 1048576 ))
        HW_CHIP=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "unknown")

        vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || true)
        case "$vram" in ''|*[!0-9]*) vram=0 ;; esac
        if [ "$vram" -gt 0 ]; then
            gpuname=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
            if [ -n "$gpuname" ]; then HW_CHIP="$gpuname"; fi
            HW_BUDGET_GB=$(( vram / 1024 ))
            HW_KIND="dedicated VRAM"
        else
            HW_BUDGET_GB=$(( HW_RAM_GB * 3 / 4 ))
            HW_KIND="CPU only"
        fi
    else
        HW_CHIP="unknown"
        HW_KIND="unknown"
    fi

    if [ "$HW_BUDGET_GB" -lt 1 ]; then HW_BUDGET_GB=1; fi
    HW_BANDWIDTH=$(bandwidth_for_chip "$HW_CHIP")
    return 0
}

# Compact size for a narrow column: "10.8GB", "180MB". format_size_gb() renders
# "10.8 GB" with a space, which is right for the variant table but too wide here.
format_size_compact() {
    local bytes="$1"
    case "$bytes" in ''|*[!0-9]*) printf '%s' "-"; return 0 ;; esac
    awk -v b="$bytes" 'BEGIN {
        if (b >= 1073741824) { g = b / 1073741824
            if (g >= 100) printf "%dGB", int(g + 0.5); else printf "%.1fGB", int(g * 10 + 0.5) / 10
        } else printf "%dMB", int(b / 1048576 + 0.5)
    }'
}

# Weights are not the only resident cost - KV cache and runtime overhead scale
# with the model - so demand ~15% headroom plus 1GB before calling it a fit.
#
# Rank: 0 comfortable, 1 tight, 2 CPU fallback, 3 won't run, 9 unknown. This is
# a pure function rather than a global side effect because every caller invokes
# it as $(...), and a subshell assignment would never reach the caller.
verdict_rank_for() {
    local bytes="$1" need_gb
    # ".." is the sentinel for a size still being fetched in the background. It
    # ranks 8 - distinct from 9, "asked and there is no answer" - so the table
    # can say "not yet" instead of implying the repo ships nothing loadable.
    case "$bytes" in '..') printf '8'; return 0 ;; esac
    case "$bytes" in ''|-|*[!0-9]*) printf '9'; return 0 ;; esac

    need_gb=$(( (bytes / 1073741824) * 115 / 100 + 1 ))
    if [ "$need_gb" -lt 1 ]; then need_gb=1; fi

    if   [ $(( need_gb * 10 )) -le $(( HW_BUDGET_GB * 6 )) ]; then printf '0'
    elif [ "$need_gb" -le "$HW_BUDGET_GB" ];                  then printf '1'
    elif [ "$need_gb" -le "$HW_RAM_GB" ];                     then printf '2'
    else                                                           printf '3'
    fi
    return 0
}

# bash printf pads %-Ns by BYTES, not characters or display cells, and these
# markers are not all the same byte length (U+2705 and U+274C are 3 bytes,
# U+1F7E1 and U+1F7E0 are 4). Letting printf pad a cell containing one shifts
# the column by a byte on half the rows - verified, it really does. So build the
# cell at a fixed display width here: one 2-cell marker, a space, then the size
# padded as pure ASCII where bytes and characters agree. Callers emit it with a
# bare %s and must not apply a field width.
FIT_CELL_W=7
verdict_for() {
    local bytes="$1" rank marker text
    rank=$(verdict_rank_for "$bytes")
    case "$rank" in
        0) marker='✅'; text=$(format_size_compact "$bytes") ;;
        1) marker='🟡'; text=$(format_size_compact "$bytes") ;;
        2) marker='🟠'; text=$(format_size_compact "$bytes") ;;
        3) marker='❌'; text=$(format_size_compact "$bytes") ;;
        8) marker='  '; text=".." ;;   # still being fetched
        *) marker='  '; text="-" ;;   # two spaces occupy the same 2 cells
    esac
    printf '%s %-*s' "$marker" "$FIT_CELL_W" "$text"
    return 0
}

# Decode is bandwidth bound, so tok/s tracks bandwidth over resident bytes. The
# efficiency factors are empirical, calibrated against qwen3:8b-q4_K_M running
# ~38 tok/s on an M4 Pro. MoE models stream only their active experts, so they
# run far faster than their total size implies, at some routing cost.
#
# Below roughly a gigabyte the model stops being bandwidth bound - sampling and
# kernel-launch overhead dominate - and the formula runs away (it claims 480
# tok/s for a 378MB model). Cap the reported figure rather than print a number
# that will not survive contact with reality. These are estimates throughout,
# and the UI says so.
TOK_S_CAP=200
estimate_tok_s() {
    local bytes="$1" active_pct="${2:-100}" eff=65 active_mb ts
    case "$bytes" in '..') printf '%s' ".."; return 0 ;; esac
    case "$bytes" in ''|-|*[!0-9]*) printf '%s' "-"; return 0 ;; esac
    case "$active_pct" in ''|*[!0-9]*) active_pct=100 ;; esac
    if [ "$HW_BANDWIDTH" -le 0 ]; then printf '%s' "-"; return 0; fi

    # Only quote a speed for models that actually run on the accelerator. A
    # model that will not load has no decode rate, and printing a fast-looking
    # number beside a "won't run" verdict reads as a recommendation. Past the
    # GPU budget the work moves to the CPU, where this bandwidth model no longer
    # describes what happens - so say nothing rather than something wrong.
    case "$(verdict_rank_for "$bytes")" in
        0|1) : ;;
        *)   printf '%s' "-"; return 0 ;;
    esac

    if [ "$active_pct" -lt 100 ]; then eff=50; fi
    active_mb=$(( (bytes / 1048576) * active_pct / 100 ))
    if [ "$active_mb" -le 0 ]; then printf '%s' "-"; return 0; fi

    ts=$(( HW_BANDWIDTH * 1024 * eff / 100 / active_mb ))
    if   [ "$ts" -le 0 ];            then printf '%s' "<1"
    elif [ "$ts" -gt "$TOK_S_CAP" ]; then printf '%s+' "$TOK_S_CAP"
    else                                  printf '%s' "$ts"
    fi
    return 0
}

# --- Parameter ranges ------------------------------------------------------
#
# Docker AI models encode their parameter size in the tag name ("20b", "120b",
# "270m", "1.7b", "1t"), so the min/max across a repo's tags gives the range of
# sizes it ships - the number that decides whether a model fits a given machine.
#
# There is no bulk endpoint for this, so it costs one tags request per model.
# Results are cached on disk because that is otherwise ~8s added to every start.
#
# Note: some repos do not encode a size in any tag (their tags are just
# "latest", "safetensors", "q8_0", ...). The registry config blob does not carry
# a parameter count either, so those are genuinely unknowable from the API and
# are shown as "-".
PARAM_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/docker_model_downloader"
PARAM_CACHE_FILE="$PARAM_CACHE_DIR/param-ranges-v3.tsv"
PARAM_CACHE_TTL=$(( 7 * 24 * 3600 ))
PARAM_FETCH_JOBS=12
PARAM_MAP=""

# Cache records are 5 tab-separated fields:
#   name <TAB> param_range <TAB> smallest_gguf_bytes <TAB> smallest_gguf_tag
#        <TAB> active_param_percent
#
# The size fields come free: the same tags response that carries the tag names
# also carries full_size per tag, so knowing what actually fits on this machine
# costs no extra requests. (v1 caches held 2 fields; the filename bump above
# retires them rather than mis-parsing them.)

# Look up one field of a name's record in the TSV held in PARAM_MAP. The
# "\n<name>\t" delimiters make this unambiguous for names that prefix one
# another (qwen3 vs qwen3-coder).
lookup_param_field() {
    local name="$1" field="$2" rest row
    case "$PARAM_MAP" in
        *$'\n'"$name"$'\t'*)
            rest="${PARAM_MAP#*$'\n'"$name"$'\t'}"
            row="${rest%%$'\n'*}"
            printf '%s' "$row" | cut -f "$field"
            ;;
        *)
            printf '%s' "-"
            ;;
    esac
    return 0
}

# --- Background size fetch -------------------------------------------------
#
# Verifying which of a repo's tags actually carry loadable GGUF weights costs
# two or three requests per repo, so filling a cold cache for the whole
# catalogue takes ~90s. Blocking the table on all of it is the wrong trade: the
# list of models is useful immediately, and the sizes are what take the time.
#
# So the fan-out runs detached. The table renders after a short head start, with
# ".." in the cells still in flight, and a progress line above the prompt tracks
# the rest. Pressing [u] folds in whatever has landed.
PARAM_WARMUP_SECS=10
PARAM_BG_PID=""
PARAM_BG_DIR=""
PARAM_BG_WORKER=""
PARAM_BG_TOTAL=0
PARAM_BG_STAMP=0
PARAM_BG_STATE=""        # "" none | running | ready | merged
PARAM_TICKS=0
PARAM_TICK_OFF=0

param_map_has() {
    case "$PARAM_MAP" in
        *$'\n'"$1"$'\t'*) return 0 ;;
        *) return 1 ;;
    esac
}

# Workers rename their output into place, so a file being visible here means it
# is complete. Counting them is the progress signal.
param_bg_done_count() {
    local n=0
    if [ -n "$PARAM_BG_DIR" ] && [ -d "$PARAM_BG_DIR" ]; then
        n=$(ls -1 "$PARAM_BG_DIR" 2>/dev/null | wc -l | tr -d ' ')
    fi
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
    return 0
}

param_bg_poll() {
    [ "$PARAM_BG_STATE" = "running" ] || return 0
    if [ -n "$PARAM_BG_PID" ] && kill -0 "$PARAM_BG_PID" 2>/dev/null; then
        return 0
    fi
    PARAM_BG_PID=""
    PARAM_BG_STATE="ready"
    return 0
}

# Fold completed records into the map and rewrite the cache. This runs once
# after the head start and again on every refresh, so it re-reads records it has
# already absorbed; keeping the first sighting of each name stops the map
# growing duplicate copies of them.
param_bg_absorb() {
    [ -n "$PARAM_BG_DIR" ] || return 0
    local merged deduped
    merged=$(cat "$PARAM_BG_DIR"/* 2>/dev/null || true)
    [ -n "$merged" ] || return 0

    deduped=$(printf '%s%s\n' "$PARAM_MAP" "$merged" | grep -v '^[[:space:]]*$' \
        | awk -F'\t' '!seen[$1]++' || true)
    [ -n "$deduped" ] || return 0
    PARAM_MAP=$'\n'"$deduped"$'\n'

    {
        printf '%s\n' "$PARAM_BG_STAMP"
        printf '%s\n' "$deduped"
    } > "$PARAM_CACHE_FILE" 2>/dev/null || true
    return 0
}

param_bg_cleanup() {
    if [ -n "${PARAM_BG_PID:-}" ]; then
        # Kill the workers before their xargs parent, or they are reparented and
        # outlive the session still holding sockets open.
        pkill -P "$PARAM_BG_PID" 2>/dev/null || true
        kill "$PARAM_BG_PID" 2>/dev/null || true
        PARAM_BG_PID=""
    fi
    if [ -n "${PARAM_BG_DIR:-}" ]; then
        rm -rf "$PARAM_BG_DIR" "${PARAM_BG_WORKER:-}" 2>/dev/null || true
        PARAM_BG_DIR=""
        PARAM_BG_WORKER=""
    fi
    return 0
}

populate_param_arrays() {
    local i
    model_params=()
    model_minbytes=()
    model_mintag=()
    model_active=()
    for (( i=0; i<total_models; i++ )); do
        if [ "$PARAM_BG_STATE" = "running" ] && ! param_map_has "${model_names[$i]}"; then
            # Still in flight. ".." is deliberately ASCII: printf pads by bytes,
            # so a one-cell ellipsis character would shift the column.
            model_params+=("..")
            model_minbytes+=("..")
            model_mintag+=("-")
            model_active+=("-")
            continue
        fi
        model_params+=("$(lookup_param_field "${model_names[$i]}" 1)")
        model_minbytes+=("$(lookup_param_field "${model_names[$i]}" 2)")
        model_mintag+=("$(lookup_param_field "${model_names[$i]}" 3)")
        model_active+=("$(lookup_param_field "${model_names[$i]}" 4)")
    done
    return 0
}

# [u]. Merging partial results is deliberate: a user who wants to see what has
# arrived so far should not have to wait for the slowest repo in the batch.
param_bg_refresh() {
    param_bg_poll
    [ -n "$PARAM_BG_DIR" ] || return 0
    param_bg_absorb
    if [ "$PARAM_BG_STATE" = "ready" ]; then
        PARAM_BG_STATE="merged"
        rm -rf "$PARAM_BG_DIR" "$PARAM_BG_WORKER" 2>/dev/null || true
        PARAM_BG_DIR=""
        PARAM_BG_WORKER=""
    fi
    populate_param_arrays
    fill_gaps_from_models_dev "$total_models" || true
    apply_filter
    return 0
}

# The progress line occupies the blank line immediately above the prompt, which
# lets it be rewritten in place with a cursor save/restore. Redrawing the whole
# table once a second to advance a bar would flicker every row.
PARAM_BAR_W=20
param_progress_body() {
    local ndone total filled i bar=""
    case "$PARAM_BG_STATE" in
        running)
            ndone=$(param_bg_done_count)
            total="$PARAM_BG_TOTAL"
            if [ "$total" -le 0 ]; then total=1; fi
            if [ "$ndone" -gt "$total" ]; then ndone="$total"; fi
            filled=$(( ndone * PARAM_BAR_W / total ))
            i=0
            while [ "$i" -lt "$PARAM_BAR_W" ]; do
                if [ "$i" -lt "$filled" ]; then bar="${bar}█"; else bar="${bar}░"; fi
                i=$(( i + 1 ))
            done
            printf "${CYAN}  Sizing models  [%s] %s/%s  ·  [u] refresh${NC}" \
                "$bar" "$ndone" "$total"
            ;;
        ready)
            printf "${GREEN}  Sizes ready  ·  press [u] to refresh the table${NC}"
            ;;
        *)
            : ;;
    esac
    return 0
}

param_progress_line() {
    param_bg_poll
    param_progress_body
    printf '\n'
    return 0
}

param_progress_tick() {
    param_bg_poll
    printf '\033[s\033[1A\r\033[2K'
    param_progress_body
    printf '\033[u'
    return 0
}

# Empty means "block on the keyboard". A one-second timeout is only used while
# there is a bar to advance, so an idle table costs nothing.
param_tick_timeout() {
    if [ "$PARAM_TICK_OFF" -eq 0 ] && [ "$PARAM_BG_STATE" = "running" ]; then
        printf '1'
    fi
    return 0
}

fetch_param_ranges() {
    model_params=()
    model_minbytes=()
    model_mintag=()
    model_active=()

    local now cache_age=0
    now=$(date +%s)

    mkdir -p "$PARAM_CACHE_DIR" 2>/dev/null || true

    # Load a non-expired cache.
    PARAM_MAP=$'\n'
    if [ -f "$PARAM_CACHE_FILE" ]; then
        local stamp
        stamp=$(head -1 "$PARAM_CACHE_FILE" 2>/dev/null || echo 0)
        case "$stamp" in
            ''|*[!0-9]*) stamp=0 ;;
        esac
        cache_age=$(( now - stamp ))
        if [ "$cache_age" -lt "$PARAM_CACHE_TTL" ]; then
            PARAM_MAP=$'\n'$(tail -n +2 "$PARAM_CACHE_FILE" 2>/dev/null || true)$'\n'
        fi
    fi

    # Only fetch what the cache is missing, so new models cost one request.
    local missing_file
    missing_file=$(mktemp)
    local i
    for (( i=0; i<total_models; i++ )); do
        local n="${model_names[$i]}"
        case "$PARAM_MAP" in
            *$'\n'"$n"$'\t'*) : ;;
            *) printf '%s\n' "$n" >> "$missing_file" ;;
        esac
    done

    local missing_count
    missing_count=$(wc -l < "$missing_file" | tr -d ' ')

    if [ "$missing_count" -gt 0 ]; then
        start_spinner "Reading parameter sizes for $missing_count model(s)..."

        local worker out_dir
        worker=$(mktemp)
        out_dir=$(mktemp -d)

        cat > "$worker" <<'WORKER'
#!/bin/bash
name="$1"
out="$2/$1"
# The table renders while this fan-out is still running, so a half-written
# record must never be visible to the merge. Write to a dotfile, which the
# merge glob skips, then rename - atomic within a directory.
tmp="$2/.$1.part"
# Every request is bounded: this runs detached, and an unbounded curl would
# outlive the session it belongs to.
tags=$(curl -fsSL --max-time 20 "https://hub.docker.com/v2/repositories/ai/${name}/tags?page_size=100" -H 'accept: */*' 2>/dev/null | jq -r '.results[] | "\(.name)\t\(.full_size // 0)"' 2>/dev/null || true)
[ -z "$tags" ] && { printf '%s\t-\t-\t-\t-\n' "$name" > "$tmp"; mv -f "$tmp" "$out"; exit 0; }

# Parameter range, parsed from the tag names.
range=$(printf '%s\n' "$tags" | awk -F'\t' '
function fmt(v,   s) {
    if (v >= 1000000) { s = sprintf("%.1f", v / 1000000); sub(/\.0$/, "", s); return s "T" }
    if (v >= 1000)    { s = sprintf("%.1f", v / 1000);    sub(/\.0$/, "", s); return s "B" }
    return sprintf("%dM", v)
}
{
    tag = tolower($1)
    if (match(tag, /^[0-9]+(\.[0-9]+)?[bmt]/)) {
        tok = substr(tag, 1, RLENGTH)
        nxt = substr(tag, RLENGTH + 1, 1)
        # Require a separator so "4bit" (a quantisation) is not read as "4B".
        if (nxt == "" || nxt == "-" || nxt == "_") {
            unit = substr(tok, length(tok), 1)
            num  = substr(tok, 1, length(tok) - 1) + 0
            v = (unit == "t") ? num * 1000000 : (unit == "b") ? num * 1000 : num
            if (!seen || v < mn) mn = v
            if (!seen || v > mx) mx = v
            seen = 1
        }
    }
}
END { print !seen ? "-" : ((mn == mx) ? fmt(mn) : fmt(mn) " - " fmt(mx)) }')

# Candidate weight files, smallest first. safetensors and mlx builds are a
# different format the GGUF runtime never loads (gpt-oss 20b-safetensors is
# 38GB against 10.8GB for 20b-q4_K_M), and mtp/draft/lora tags are auxiliary
# modules rather than servable models.
cands=$(printf '%s\n' "$tags" | awk -F'\t' '
    { tag = tolower($1); size = $2 + 0
      if (size <= 0) next
      if (tag ~ /safetensors|mlx|mmproj|mtp|draft|lora|adapter/) next
      print size "\t" $1 }' | sort -n | head -12)

# A tag name alone cannot be trusted to describe its contents: ai/gemma4:12b-q8_0
# is 611MB because it ships mtp-gemma-4-12b-it-Q8_0.gguf (a multi-token-prediction
# head) plus an mmproj projector, not the 12B weights. Reporting that as the
# model size yields a falsely optimistic "fits comfortably" verdict, which is the
# exact failure this column exists to prevent. So confirm against the manifest,
# whose layers carry an org.cncf.model.filepath annotation, and take the smallest
# tag that actually holds primary weights.
gmin="-"; gtag="-"
# A "-safetensors" repo says up front that it ships no GGUF, so skip the manifest
# probing entirely rather than spending a dozen requests to conclude the same.
case "$name" in
    *-safetensors) cands="" ;;
esac
token=""
if [ -n "$cands" ]; then
    token=$(curl -fsSL --max-time 20 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ai/${name}:pull" 2>/dev/null | jq -r '.token // empty' 2>/dev/null || true)
fi
if [ -n "$token" ] && [ -n "$cands" ]; then
    while IFS='	' read -r csize ctag; do
        [ -n "$ctag" ] || continue
        files=$(curl -fsSL --max-time 20 "https://registry-1.docker.io/v2/ai/${name}/manifests/${ctag}" \
            -H "Authorization: Bearer $token" \
            -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.cncf.model.manifest.v1+json' \
            2>/dev/null | jq -r '.layers[]? | .annotations["org.cncf.model.filepath"] // empty' 2>/dev/null || true)
        # No annotations at all means we cannot disprove it, so accept rather
        # than discard a usable model on missing metadata.
        state=$(printf '%s\n' "$files" | awk '
            { f = tolower($0); if (f == "") next; n++
              if (f ~ /\.gguf$/ && f !~ /mtp|mmproj|draft|lora|adapter/) good++ }
            END { print (n == 0) ? "unknown" : ((good > 0) ? "ok" : "aux") }')
        if [ "$state" != "aux" ]; then gmin="$csize"; gtag="$ctag"; break; fi
    done < <(printf '%s\n' "$cands")
elif [ -n "$cands" ]; then
    # Registry unreachable: fall back to the name-filtered smallest rather than
    # dropping the size entirely.
    gmin=$(printf '%s\n' "$cands" | head -1 | cut -f1)
    gtag=$(printf '%s\n' "$cands" | head -1 | cut -f2)
fi

# Mixture-of-experts models only read a fraction of their weights per token, so
# decode speed tracks the active parameters, not the file size. Docker tags spell
# this out directly - "26b-a4b" is 26B total / 4B active, "2.4t-a95b" is 2.4T/95B -
# which is both free and authoritative, so prefer it over any external source.
active="-"
if [ "$gtag" != "-" ]; then
    # The chosen tag is often a bare alias ("30B") whose sibling spells the split
    # out ("30b-a3b"), so match on the leading parameter token rather than the
    # exact tag.
    active=$(printf '%s\n' "$tags" | awk -F'\t' -v gtag="$gtag" '
    BEGIN {
        g = tolower(gtag)
        gp = match(g, /^[0-9]+(\.[0-9]+)?[bt]/) ? substr(g, 1, RLENGTH) : ""
        if (gp != "") {
            unit  = substr(gp, length(gp), 1)
            num   = substr(gp, 1, length(gp) - 1) + 0
            total = (unit == "t") ? num * 1000 : num
        }
    }
    gp == "" || total <= 0 { exit }
    substr(tolower($1), 1, length(gp)) != gp { next }
    {
        t = tolower($1)
        if (t ~ /^[0-9]+(\.[0-9]+)?[bt]-a[0-9]+(\.[0-9]+)?b/ && match(t, /-a[0-9]+(\.[0-9]+)?b/)) {
            a = substr(t, RSTART + 2, RLENGTH - 3) + 0
            p = int(a * 100 / total + 0.5)
            if (p < 1)   p = 1
            if (p > 100) p = 100
            print p
            found = 1
            exit
        }
    }
    END { if (!found) print "-" }')
    [ -n "$active" ] || active="-"
fi

printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$range" "$gmin" "$gtag" "$active" > "$tmp"
mv -f "$tmp" "$out"
WORKER
        chmod +x "$worker"

        # Detached, so the table can render before this finishes. The head start
        # is there because a warm-ish cache often completes inside it, and
        # flashing ".." for a second on a list that is about to be complete is
        # worse than simply waiting for it.
        xargs -P "$PARAM_FETCH_JOBS" -I{} "$worker" {} "$out_dir" < "$missing_file" >/dev/null 2>&1 &
        PARAM_BG_PID=$!
        PARAM_BG_DIR="$out_dir"
        PARAM_BG_WORKER="$worker"
        PARAM_BG_TOTAL="$missing_count"
        PARAM_BG_STAMP="$now"
        PARAM_BG_STATE="running"

        local waited=0
        while [ "$waited" -lt "$PARAM_WARMUP_SECS" ]; do
            if kill -0 "$PARAM_BG_PID" 2>/dev/null; then : ; else break; fi
            sleep 1
            waited=$(( waited + 1 ))
        done

        stop_spinner
        param_bg_poll
        param_bg_absorb
        if [ "$PARAM_BG_STATE" = "ready" ]; then
            # It finished inside the head start, so there is nothing to refresh.
            PARAM_BG_STATE="merged"
            rm -rf "$out_dir" "$worker" 2>/dev/null || true
            PARAM_BG_DIR=""
            PARAM_BG_WORKER=""
        fi
    fi

    rm -f "$missing_file" 2>/dev/null || true

    populate_param_arrays

    fill_gaps_from_models_dev "$total_models" || true

    return 0
}

MODELSDEV_CACHE_FILE=""
MODELSDEV_URL="https://models.dev/api.json"

# Docker Hub leaves a lot blank: 46 of 103 ai/* repos publish no description, and
# tag names do not always encode a parameter count. models.dev catalogues the same
# models and can close those gaps.
#
# This only ever writes into cells Docker left empty. A value Docker supplied is
# authoritative - it describes the artifact actually being downloaded - so it is
# never overwritten, even when models.dev disagrees.
fill_gaps_from_models_dev() {
    local total_models="$1"
    local i needed=0

    for (( i=0; i<total_models; i++ )); do
        if [ "${model_params[$i]:--}" = "-" ] || [ -z "${model_descriptions[$i]}" ]; then
            needed=1
            break
        fi
    done
    [ "$needed" -eq 1 ] || return 0

    MODELSDEV_CACHE_FILE="$PARAM_CACHE_DIR/models-dev.json"
    local now stamp=0 age=0
    now=$(date +%s)
    if [ -f "$MODELSDEV_CACHE_FILE" ]; then
        stamp=$(stat -f %m "$MODELSDEV_CACHE_FILE" 2>/dev/null || stat -c %Y "$MODELSDEV_CACHE_FILE" 2>/dev/null || echo 0)
        case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
        age=$(( now - stamp ))
    fi
    if [ ! -s "$MODELSDEV_CACHE_FILE" ] || [ "$age" -ge "$PARAM_CACHE_TTL" ]; then
        start_spinner "Filling gaps from models.dev..."
        curl -fsSL --max-time 25 "$MODELSDEV_URL" -o "$MODELSDEV_CACHE_FILE.tmp" 2>/dev/null \
            && mv -f "$MODELSDEV_CACHE_FILE.tmp" "$MODELSDEV_CACHE_FILE" 2>/dev/null || true
        rm -f "$MODELSDEV_CACHE_FILE.tmp" 2>/dev/null || true
        stop_spinner
    fi
    [ -s "$MODELSDEV_CACHE_FILE" ] || return 0

    # Flatten to "display name <TAB> description" pairs.
    local pairs
    pairs=$(jq -r '.. | objects | select(has("name")) | "\(.name)\t\(.description // "")"' \
        "$MODELSDEV_CACHE_FILE" 2>/dev/null | grep -v '^\s*$' || true)
    [ -n "$pairs" ] || return 0

    local names_file resolved
    names_file=$(mktemp)
    for (( i=0; i<total_models; i++ )); do
        printf '%s\n' "${model_names[$i]}"
    done > "$names_file"

    resolved=$(printf '%s\n' "$pairs" | awk -F'\t' '
function norm(s) { s = tolower(s); gsub(/[^a-z0-9.]+/, "-", s); gsub(/^-+|-+$/, "", s); return s }
function fmt(v,   s) {
    if (v >= 1000000) { s = sprintf("%.1f", v/1000000); sub(/\.0$/,"",s); return s "T" }
    if (v >= 1000)    { s = sprintf("%.1f", v/1000);    sub(/\.0$/,"",s); return s "B" }
    return sprintf("%dM", v)
}
function scale(tok,   n, v) { n = tok; gsub(/[^0-9.]/, "", n); v = n + 0
    if (tok ~ /[tT]/) return v * 1000000
    if (tok ~ /[mM]/) return v
    return v * 1000 }
function note(k, v) { if (!(k in mn) || v < mn[k]) mn[k] = v; if (!(k in mx) || v > mx[k]) mx[k] = v }
NR == FNR { dock[FNR] = $0; nd = FNR; next }
{
    nm = norm($1)
    for (k = 1; k <= nd; k++) {
        d = norm(dock[k])
        exact = (nm == d)
        # Family prefix: "qwen3" may answer for "qwen3-coder", but never the reverse.
        if (!exact && index(nm, d "-") != 1) continue
        # Parameter counts live in the display name. Skip MoE active counts,
        # written "A55B", so "550B A55B" reports 550B rather than 55B.
        s = $1
        while (match(s, /[0-9]+(\.[0-9]+)?[bBtT]([^a-zA-Z0-9]|$)/)) {
            tok = substr(s, RSTART, RLENGTH)
            pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : " "
            if (pre != "a" && pre != "A") note(k, scale(tok))
            s = substr(s, RSTART + RLENGTH)
        }
        if (exact) { if (!(k in dex)) { dex[k] = 1; desc[k] = $2 } }
        else if (!(k in dex) && length($2) > length(desc[k])) desc[k] = $2
    }
}
END {
    for (k = 1; k <= nd; k++) {
        # Last resort: mine "1.6T-parameter" / "2.8T parameter" out of the prose.
        if (!(k in mn)) {
            s = desc[k]
            while (match(s, /[0-9]+(\.[0-9]+)?[ ]?[BTM][- ]parameter/)) {
                note(k, scale(substr(s, RSTART, RLENGTH)))
                s = substr(s, RSTART + RLENGTH)
            }
        }
        printf "%s\t%s\t%s\n", dock[k], \
            (k in mn) ? ((mn[k] == mx[k]) ? fmt(mn[k]) : fmt(mn[k]) " - " fmt(mx[k])) : "-", \
            desc[k]
    }
}' "$names_file" - 2>/dev/null || true)
    rm -f "$names_file" 2>/dev/null || true
    [ -n "$resolved" ] || return 0

    local line mdname mdparams mddesc
    i=0
    while IFS=$'\t' read -r mdname mdparams mddesc; do
        [ "$i" -lt "$total_models" ] || break
        if [ "${model_params[$i]:--}" = "-" ] && [ -n "$mdparams" ] && [ "$mdparams" != "-" ]; then
            model_params[$i]="$mdparams"
        fi
        if [ -z "${model_descriptions[$i]}" ] && [ -n "$mddesc" ]; then
            model_descriptions[$i]="$mddesc"
        fi
        i=$(( i + 1 ))
    done <<EOF
$resolved
EOF

    return 0
}

fetch_variants_for_model() {
    local model="$1"
    local repo="ai/$model"
    local page=1
    local page_size=100
    local max_attempts=3

    variant_tags=()
    variant_params=()
    variant_quantizations=()
    variant_contexts=()
    variant_vrams=()
    variant_tool_callings=()
    variant_sizes=()

    start_spinner "Retrieving variants for ai/$model..."

    local token=""
    token=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" | jq -r '.token // empty' 2>/dev/null || true)

    while true; do
        local url="https://hub.docker.com/v2/repositories/${repo}/tags?page_size=${page_size}&page=${page}"
        local response=""
        local attempt

        for attempt in $(seq 1 "$max_attempts"); do
            if response=$(curl -fsSL "$url" -H 'accept: */*' 2>/dev/null); then
                break
            fi
            sleep 0.4
        done

        if [ -z "$response" ]; then
            break
        fi

        if ! echo "$response" | jq -e '.results and (.results|type=="array")' >/dev/null 2>&1; then
            break
        fi

        local page_count
        page_count=$(echo "$response" | jq -r '.results | length')
        if [ "$page_count" -eq 0 ]; then
            break
        fi

        while IFS='|' read -r tag full_size; do
            local params="-"
            local quantization="-"
            local context_window="-"
            local vram="-"
            local tool_calling="-"
            local formatted_size
            formatted_size=$(format_size_gb "$full_size")

            if [ -n "$token" ]; then
                local manifest=""
                local config_digest=""
                local config=""

                manifest=$(curl -fsSL "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" \
                    -H "Authorization: Bearer ${token}" \
                    -H "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.cncf.model.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
                    2>/dev/null || true)

                if [ -n "$manifest" ]; then
                    config_digest=$(printf "%s" "$manifest" | jq -r '.config.digest // empty' 2>/dev/null || true)
                fi

                if [ -n "$config_digest" ]; then
                    config=$(curl -fsSL "https://registry-1.docker.io/v2/${repo}/blobs/${config_digest}" \
                        -H "Authorization: Bearer ${token}" \
                        2>/dev/null || true)
                fi

                if [ -n "$config" ]; then
                    params=$(printf "%s" "$config" | jq -r '.config.paramSize // .config.parameters // "-"' 2>/dev/null || echo "-")
                    quantization=$(printf "%s" "$config" | jq -r '.config.quantization // "-"' 2>/dev/null || echo "-")
                    context_window=$(printf "%s" "$config" | jq -r '.config.contextWindow // .config.contextLength // .config.context // "-"' 2>/dev/null || echo "-")
                    vram=$(printf "%s" "$config" | jq -r '.config.vram // .config.vramSize // "-"' 2>/dev/null || echo "-")
                    tool_calling=$(printf "%s" "$config" | jq -r '.config.toolCalling // .config.tool_calls // "-"' 2>/dev/null || echo "-")
                fi
            fi

            variant_tags+=("$tag")
            variant_params+=("$params")
            variant_quantizations+=("$quantization")
            variant_contexts+=("$context_window")
            variant_vrams+=("$vram")
            variant_tool_callings+=("$tool_calling")
            variant_sizes+=("$formatted_size")
        done < <(
            echo "$response" | jq -r '.results[] | "\(.name)|\(.full_size // 0)"'
        )

        local next_url
        next_url=$(echo "$response" | jq -r '.next')
        if [ "$next_url" = "null" ] || [ -z "$next_url" ]; then
            break
        fi

        page=$((page + 1))
    done

    stop_spinner

    if [ ${#variant_tags[@]} -eq 0 ]; then
        variant_tags=("latest")
        variant_params=("-")
        variant_quantizations=("-")
        variant_contexts=("-")
        variant_vrams=("-")
        variant_tool_callings=("-")
        variant_sizes=("-")
    fi
}

select_variant_for_model() {
    local model="$1"

    while true; do
        clear
        print_banner
        echo
        print_message "$GREEN" "📋 Available variants for ai/$model"
        echo
        printf "%-4s %-28s %-12s %-18s %-15s %-10s %-14s %-10s\n" "#" "Variant" "Parameters" "Quantization" "Context Window" "VRAM" "Tool Calling" "Size"
        printf "%-4s %-28s %-12s %-18s %-15s %-10s %-14s %-10s\n" "----" "----------------------------" "------------" "------------------" "---------------" "----------" "--------------" "----------"

        local i
        for (( i=0; i<${#variant_tags[@]}; i++ )); do
            local display_num=$((i + 1))
            printf "%-4s %-28s %-12s %-18s %-15s %-10s %-14s %-10s\n" \
                "$display_num)" \
                "$model:${variant_tags[$i]}" \
                "${variant_params[$i]}" \
                "${variant_quantizations[$i]}" \
                "${variant_contexts[$i]}" \
                "${variant_vrams[$i]}" \
                "${variant_tool_callings[$i]}" \
                "${variant_sizes[$i]}"
        done

        echo
        print_message "$YELLOW" "Select a variant number, press Enter for 1, or [q] Quit"
        printf "Enter choice: "

        local input
        read -r input
        if [ -z "$input" ]; then
            input=1
        fi

        case "$input" in
            q|Q)
                print_message "$YELLOW" "Exiting..."
                exit 0
                ;;
        esac

        if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "${#variant_tags[@]}" ]; then
            local selected_variant_idx=$((input - 1))
            selected_variant="${variant_tags[$selected_variant_idx]}"
            selected_model_reference="ai/$model"
            if [ "$selected_variant" != "latest" ]; then
                selected_model_reference="${selected_model_reference}:${selected_variant}"
            fi
            selected_ollama_model="$model"
            if [ "$selected_variant" != "latest" ]; then
                selected_ollama_model="${model}-${selected_variant}"
            fi
            break
        fi

        print_message "$RED" "❌ Invalid selection. Please enter a number between 1 and ${#variant_tags[@]}"
        sleep 1
    done
}

if [ "$APP_ACTION" = "check" ]; then
    display_downloaded_models
    exit 0
fi

fetch_models_from_dockerhub

# Pagination settings
MODELS_PER_PAGE=20
total_models=${#model_names[@]}
current_page=1

detect_hardware

# fetch_param_ranges leaves a detached fan-out running, so it needs a teardown
# in place before it starts. The fuller traps installed further down (which also
# restore the terminal) replace these once those functions exist.
trap 'param_bg_cleanup' EXIT
trap 'param_bg_cleanup; exit 130' INT
trap 'param_bg_cleanup; exit 143' TERM

fetch_param_ranges

# Search / filter state.
#   view_idx     - indices into model_names that are currently listed
#   search_query - active filter ("" means show everything)
#   search_active- 1 while the live search bar is on screen
#   fit_only     - 1 while the list is restricted to what this machine can run
search_query=""
search_active=0
fit_only=0
view_idx=()
view_count=0

# Rebuild view_idx from search_query.
#
# The query is an unanchored, case-insensitive extended regular expression, so a
# match anywhere in the name counts ("oder" finds "qwen3-coder", "qwen.*3\.5"
# works too). While the user is mid-keystroke the query can be a syntactically
# invalid regex (a lone "[", say); rather than error out we fall back to a
# literal substring match so the list keeps updating as they type.
apply_filter() {
    view_idx=()
    local i use_regex=1 rc=0 keep

    if [ -n "$search_query" ]; then
        [[ "x" =~ $search_query ]] 2>/dev/null || rc=$?
        if [ "$rc" -gt 1 ]; then
            use_regex=0
        fi
    fi

    shopt -s nocasematch
    for (( i=0; i<total_models; i++ )); do
        keep=1

        if [ -n "$search_query" ]; then
            if [ "$use_regex" -eq 1 ]; then
                if [[ "${model_names[$i]}" =~ $search_query ]]; then :; else keep=0; fi
            else
                case "${model_names[$i]}" in
                    *"$search_query"*) : ;;
                    *) keep=0 ;;
                esac
            fi
        fi

        # "Runs here" means it fits the accelerator budget: rank 0 or 1. Rank 2
        # is a CPU fallback and rank 3 does not fit at all. Rank 9 (no size
        # known) is also excluded - listing an unmeasured model as a fit would
        # be a guess, and the whole point of this filter is not guessing.
        if [ "$keep" -eq 1 ] && [ "$fit_only" -eq 1 ]; then
            case "$(verdict_rank_for "${model_minbytes[$i]:--}")" in
                0|1) : ;;
                *)   keep=0 ;;
            esac
        fi

        if [ "$keep" -eq 1 ]; then
            view_idx+=("$i")
        fi
    done
    shopt -u nocasematch

    view_count=${#view_idx[@]}
    total_pages=$(( (view_count + MODELS_PER_PAGE - 1) / MODELS_PER_PAGE ))
    if [ "$total_pages" -lt 1 ]; then
        total_pages=1
    fi
    if [ "$current_page" -gt "$total_pages" ]; then
        current_page=$total_pages
    fi
    if [ "$current_page" -lt 1 ]; then
        current_page=1
    fi
    return 0
}

apply_filter

# Function to display models for current page
# The table now carries Fit and tok/s, which cost horizontal space, so the
# remaining columns are sized against the real terminal width rather than a
# fixed 80. Description is the elastic one: it takes whatever is left and is
# dropped entirely when there is not enough room to be worth printing. Stars
# was removed to fund this - 36 of 100 ai/* repos have zero stars and 61 have
# two or fewer, so it carried almost no signal.
LAY_COLS=80
LAY_NAME_W=22
LAY_PULLS_W=9
LAY_DESC_W=0
LAY_SEP=""
compute_layout() {
    local cols fixed
    cols=$(tput cols 2>/dev/null || echo 80)
    case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
    if [ "$cols" -lt 60 ]; then cols=60; fi
    LAY_COLS=$cols

    if [ "$cols" -ge 120 ]; then
        LAY_NAME_W=24; LAY_PULLS_W=10
    else
        LAY_NAME_W=22; LAY_PULLS_W=9
    fi

    # num(4) name params(13) fit(10) tok/s(6) pulls, each followed by a space,
    # plus one extra space before the description.
    fixed=$(( 4 + 1 + LAY_NAME_W + 1 + 13 + 1 + 10 + 1 + 6 + 1 + LAY_PULLS_W + 2 ))
    LAY_DESC_W=$(( cols - fixed ))
    if [ "$LAY_DESC_W" -lt 12 ]; then LAY_DESC_W=0; fi

    LAY_SEP=$(printf '%*s' "$cols" '' | sed 's/ /━/g')
    return 0
}

# Full-screen summary of what the fit verdicts are actually based on, so the
# numbers in the table are auditable rather than magic. Behind a keypress
# because system_profiler costs about a second and is not worth paying for on
# every redraw.
show_hardware_panel() {
    compute_layout
    clear
    print_banner
    echo
    print_message "$GREEN" "🖥  Detected hardware"
    echo
    printf "   %-24s %s\n" "Chip" "${HW_CHIP:-unknown}"
    printf "   %-24s %s GB\n" "Total memory" "$HW_RAM_GB"
    printf "   %-24s %s GB  (%s)\n" "Budget for weights" "$HW_BUDGET_GB" "$HW_KIND"
    if [ "$HW_BANDWIDTH" -gt 0 ]; then
        printf "   %-24s %s GB/s\n" "Memory bandwidth" "$HW_BANDWIDTH"
    else
        printf "   %-24s %s\n" "Memory bandwidth" "unknown (speed column shows -)"
    fi

    local gpucores
    gpucores=$(system_profiler SPDisplaysDataType 2>/dev/null \
        | awk -F': ' '/Total Number of Cores/{gsub(/^ +/, "", $2); print $2; exit}' || true)
    if [ -n "$gpucores" ]; then
        printf "   %-24s %s\n" "GPU cores" "$gpucores"
    fi

    echo
    print_message "$GREEN" "What the Fit column means"
    echo
    printf "   %s  %s\n" "✅" "fits comfortably - under 60% of the budget"
    printf "   %s  %s\n" "🟡" "fits, but with little headroom for a long context"
    printf "   %s  %s\n" "🟠" "over the accelerator budget; runs on CPU instead, slowly"
    printf "   %s  %s\n" "❌" "larger than total memory - will not run"
    printf "   %s  %s\n" " -" "no GGUF build published, so no verdict"
    printf "   %s  %s\n" " .." "size still being fetched - press [u] to fold it in"
    echo
    print_message "$YELLOW" "The size shown is the smallest GGUF build the repo ships, so it is the"
    print_message "$YELLOW" "best case; larger quantisations of the same model will need more."
    echo
    print_message "$YELLOW" "tok/s figures are ESTIMATES, not measurements. They assume decode is"
    print_message "$YELLOW" "memory-bandwidth bound and are capped at ${TOK_S_CAP}. Treat them as a rough"
    print_message "$YELLOW" "guide to whether a model will feel usable, not as a benchmark."
    echo
    print_message "$YELLOW" "A speed is shown only for models that fit the accelerator budget."
    print_message "$YELLOW" "Past it the work moves to the CPU, which this model does not describe."
    echo
    print_message "$YELLOW" "$LAY_SEP"
    print_message "$YELLOW" "Press any key to return"
    read_key >/dev/null 2>&1 || true
    return 0
}

display_page() {
    compute_layout
    clear
    print_banner
    echo

    local filter_desc=""
    if [ -n "$search_query" ] && [ "$fit_only" -eq 1 ]; then
        filter_desc="matching \"$search_query\" and runnable here"
    elif [ -n "$search_query" ]; then
        filter_desc="matching \"$search_query\""
    elif [ "$fit_only" -eq 1 ]; then
        filter_desc="that run on this machine"
    fi

    if [ -n "$filter_desc" ]; then
        print_message "$GREEN" "📋 Docker AI Models — $filter_desc: $view_count of $total_models (Page $current_page of $total_pages):"
    else
        print_message "$GREEN" "📋 Available Docker AI Models (Page $current_page of $total_pages):"
    fi
    echo

    if [ "$search_active" -eq 1 ]; then
        print_message "$CYAN" "🔎 Search: ${search_query}▌"
    fi

    local sep="$LAY_SEP"

    if [ "$view_count" -eq 0 ]; then
        echo
        if [ -n "$search_query" ]; then
            print_message "$YELLOW" "No models match \"$search_query\" — press [⌫] to widen the search."
        else
            print_message "$YELLOW" "Nothing here fits this machine's ${HW_BUDGET_GB}GB budget — press [r] to show everything."
        fi
        echo
        print_message "$YELLOW" "$sep"
        if [ "$search_active" -eq 1 ]; then
            print_message "$YELLOW" "Type to filter  [⌫] Delete  [Esc] Cancel search  [Enter] Keep filter"
        else
            print_message "$YELLOW" "Navigation: [f] Search  [r] Fits only  [h] Hardware  [c] Clear  [q] Quit"
        fi
        print_message "$YELLOW" "$sep"
        return
    fi

    local start_idx=$(( (current_page - 1) * MODELS_PER_PAGE ))
    local end_idx=$(( start_idx + MODELS_PER_PAGE ))

    if [ $end_idx -gt $view_count ]; then
        end_idx=$view_count
    fi

    # Display header. The Fit cell is pre-padded to a fixed display width by
    # verdict_for(), so it is printed with a bare %s - giving printf a field
    # width would pad by bytes and shift the column on rows whose marker is a
    # 4-byte emoji.
    local dash_name dash_pulls dash_desc
    dash_name=$(printf '%*s' "$LAY_NAME_W" '' | tr ' ' '-')
    dash_pulls=$(printf '%*s' "$LAY_PULLS_W" '' | tr ' ' '-')
    printf "\n"
    if [ "$LAY_DESC_W" -gt 0 ]; then
        dash_desc=$(printf '%*s' "$LAY_DESC_W" '' | tr ' ' '-')
        printf "%-4s %-*s %-13s %-10s %6s %*s  %s\n" \
            "#" "$LAY_NAME_W" "Model Name" "Parameters" "Fit" "tok/s" "$LAY_PULLS_W" "Pulls" "Description"
        printf "%-4s %-*s %-13s %-10s %6s %*s  %s\n" \
            "----" "$LAY_NAME_W" "$dash_name" "-------------" "----------" "------" "$LAY_PULLS_W" "$dash_pulls" "$dash_desc"
    else
        printf "%-4s %-*s %-13s %-10s %6s %*s\n" \
            "#" "$LAY_NAME_W" "Model Name" "Parameters" "Fit" "tok/s" "$LAY_PULLS_W" "Pulls"
        printf "%-4s %-*s %-13s %-10s %6s %*s\n" \
            "----" "$LAY_NAME_W" "$dash_name" "-------------" "----------" "------" "$LAY_PULLS_W" "$dash_pulls"
    fi

    # Display models. v walks the filtered view; i is the real model_names index.
    local v i
    for (( v=start_idx; v<end_idx; v++ )); do
        i=${view_idx[$v]}
        local display_num=$((v + 1))
        # Format pulls with comma separators for readability
        local formatted_pulls=$(printf "%'d" "${model_pulls[$i]}" 2>/dev/null || echo "${model_pulls[$i]}")
        local display_name fit_cell tok_cell
        display_name=$(truncate_text "${model_names[$i]}" "$LAY_NAME_W")
        fit_cell=$(verdict_for "${model_minbytes[$i]:--}")
        tok_cell=$(estimate_tok_s "${model_minbytes[$i]:--}" "${model_active[$i]:-100}")
        if [ "$LAY_DESC_W" -gt 0 ]; then
            printf "%-4s %-*s %-13s %s %6s %*s  %s\n" \
                "$display_num)" \
                "$LAY_NAME_W" "$display_name" \
                "${model_params[$i]:--}" \
                "$fit_cell" \
                "$tok_cell" \
                "$LAY_PULLS_W" "$formatted_pulls" \
                "$(truncate_text "${model_descriptions[$i]}" "$LAY_DESC_W")"
        else
            printf "%-4s %-*s %-13s %s %6s %*s\n" \
                "$display_num)" \
                "$LAY_NAME_W" "$display_name" \
                "${model_params[$i]:--}" \
                "$fit_cell" \
                "$tok_cell" \
                "$LAY_PULLS_W" "$formatted_pulls"
        fi
    done

    echo
    print_message "$YELLOW" "$sep"
    if [ "$search_active" -eq 1 ]; then
        print_message "$YELLOW" "Type to filter  [⌫] Delete  [Esc] Cancel search  [Enter] Keep filter"
    else
        local fit_label="Fits only"
        if [ "$fit_only" -eq 1 ]; then
            fit_label="Show all"
        fi
        local refresh_hint=""
        if [ -n "$PARAM_BG_DIR" ]; then
            refresh_hint="  [u] Refresh sizes"
        fi
        if [ -n "$search_query" ] || [ "$fit_only" -eq 1 ]; then
            print_message "$YELLOW" "Navigation: [←] Prev  [→] Next  [f] Search  [r] $fit_label  [h] Hardware  [c] Clear${refresh_hint}  [1-$view_count + Enter] Select  [q] Quit"
        else
            print_message "$YELLOW" "Navigation: [←] Prev  [→] Next  [f] Search  [r] $fit_label  [h] Hardware${refresh_hint}  [1-$view_count + Enter] Select  [q] Quit"
        fi
    fi
    print_message "$YELLOW" "$sep"
}

# --- Live search -----------------------------------------------------------
#
# macOS ships bash 3.2, whose `read -t` rejects sub-second timeouts, so we can't
# use a short read to tell a bare Esc from the start of an arrow-key escape
# sequence. `read -n` also resets termios itself, which defeats stty. Instead we
# hold the terminal in non-canonical mode for the whole search session and pull
# bytes with dd, which honours VMIN/VTIME (VTIME is in tenths of a second).
search_key_begin() {
    SEARCH_STTY_SAVED=$(stty -g 2>/dev/null || true)
    stty -icanon -echo min 1 time 0 2>/dev/null || true
}

search_key_end() {
    if [ -n "${SEARCH_STTY_SAVED:-}" ]; then
        stty "$SEARCH_STTY_SAVED" 2>/dev/null || true
        SEARCH_STTY_SAVED=""
    fi
}

# Non-canonical mode must always be handed back, including on Ctrl-C, or the
# user is dropped into a shell with no echo. The background size fetch is torn
# down here too, so quitting mid-fetch does not leave workers running.
trap 'search_key_end; param_bg_cleanup' EXIT
trap 'search_key_end; param_bg_cleanup; exit 130' INT
trap 'search_key_end; param_bg_cleanup; exit 143' TERM

search_key_read() {
    local key rest
    key=$(dd bs=1 count=1 2>/dev/null)

    if [ "$key" = $'\x1b' ]; then
        # Wait up to 0.1s for the rest of an escape sequence. Nothing follows a
        # bare Esc, so the read times out and we report ESC.
        stty min 0 time 1 2>/dev/null || true
        rest=$(dd bs=1 count=2 2>/dev/null)
        stty min 1 time 0 2>/dev/null || true
        case "$rest" in
            '[D') echo "LEFT" ;;
            '[C') echo "RIGHT" ;;
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            *)    echo "ESC" ;;
        esac
        return 0
    fi

    case "$key" in
        '')            echo "ENTER" ;;
        $'\x7f'|$'\b') echo "BACKSPACE" ;;
        *)             printf 'CHAR:%s\n' "$key" ;;
    esac
    return 0
}

# Live-filter the model list. Esc drops the filter and closes the search bar;
# Enter closes the bar but keeps the filter so a number can then be selected.
run_search() {
    search_active=1
    search_key_begin

    while true; do
        display_page

        local key
        key=$(search_key_read)

        case "$key" in
            ESC)
                search_query=""
                current_page=1
                apply_filter
                break
                ;;
            ENTER)
                break
                ;;
            BACKSPACE)
                search_query="${search_query%?}"
                current_page=1
                apply_filter
                ;;
            LEFT)
                if [ "$current_page" -gt 1 ]; then
                    current_page=$((current_page - 1))
                fi
                ;;
            RIGHT)
                if [ "$current_page" -lt "$total_pages" ]; then
                    current_page=$((current_page + 1))
                fi
                ;;
            UP|DOWN)
                : # ignored while searching
                ;;
            CHAR:*)
                search_query="${search_query}${key#CHAR:}"
                current_page=1
                apply_filter
                ;;
        esac
    done

    search_key_end
    search_active=0
    return 0
}

# Function to read a single keypress including arrow keys. With a timeout
# argument it reports TIMEOUT instead of blocking, which is how the progress bar
# gets a chance to advance while the user is deciding.
read_key() {
    local key started timeout="${1:-}"

    if [ -n "$timeout" ]; then
        started=$SECONDS
        if IFS= read -rsn1 -t "$timeout" key 2>/dev/null; then
            :
        else
            # bash 4 returns >128 for a expired timer and 1 for end of input,
            # but bash 3.2 - which is what macOS ships - returns 1 for both.
            # The elapsed time separates them instead: a timeout waits out its
            # full second, whereas a closed stdin comes back instantly. Getting
            # this wrong would spin the tick loop at full speed on a pipe.
            if [ $(( SECONDS - started )) -ge 1 ]; then
                echo "TIMEOUT"
            else
                echo "EOF"
            fi
            return 0
        fi
    else
        IFS= read -rsn1 key 2>/dev/null
    fi

    # Check if it's an escape sequence (arrow keys)
    if [[ $key == $'\x1b' ]]; then
        # Read the next two characters
        read -rsn2 key 2>/dev/null
        case "$key" in
            '[D') echo "LEFT" ;;      # Left arrow
            '[C') echo "RIGHT" ;;     # Right arrow
            '[A') echo "UP" ;;        # Up arrow
            '[B') echo "DOWN" ;;      # Down arrow
            *) echo "$key" ;;
        esac
    else
        echo "$key"
    fi
}

# Interactive selection loop
selected_model=""
selected_variant=""
selected_model_reference=""
selected_ollama_model=""
while true; do
    display_page

    param_progress_line
    printf "Enter choice: "

    # While sizes are still landing, wake once a second and advance the bar in
    # place rather than looping back to display_page, which would repaint every
    # row of the table a second at a time.
    first_char=""
    while true; do
        first_char=$(read_key "$(param_tick_timeout)")
        if [ "$first_char" = "EOF" ]; then
            # Nobody is at the keyboard. Stop ticking and let the usual
            # end-of-input handling below take over.
            PARAM_TICK_OFF=1
            first_char=""
            break
        fi
        if [ "$first_char" != "TIMEOUT" ]; then
            break
        fi
        PARAM_TICKS=$(( PARAM_TICKS + 1 ))
        # Belt and braces against any other source of instant timeouts.
        if [ "$PARAM_TICKS" -gt 900 ]; then
            PARAM_TICK_OFF=1
        fi
        param_progress_tick
    done

    case "$first_char" in
        # Arrow keys for navigation
        LEFT|UP)
            echo
            if [ $current_page -gt 1 ]; then
                ((current_page--))
            else
                print_message "$YELLOW" "Already on first page"
                sleep 0.5
            fi
            ;;
        RIGHT|DOWN)
            echo
            if [ $current_page -lt $total_pages ]; then
                ((current_page++))
            else
                print_message "$YELLOW" "Already on last page"
                sleep 0.5
            fi
            ;;
        # Quit
        q|Q)
            echo
            print_message "$YELLOW" "Exiting..."
            exit 0
            ;;
        # Live search
        f|F)
            run_search
            ;;
        # What this machine can run
        h|H)
            show_hardware_panel
            ;;
        # Restrict the list to models that fit this machine
        r|R)
            echo
            if [ "$fit_only" -eq 1 ]; then
                fit_only=0
            else
                fit_only=1
            fi
            current_page=1
            apply_filter
            ;;
        # Fold in sizes fetched in the background
        u|U)
            echo
            if [ -n "$PARAM_BG_DIR" ]; then
                param_bg_refresh
            fi
            ;;
        # Clear an active filter
        c|C)
            echo
            if [ -n "$search_query" ] || [ "$fit_only" -eq 1 ]; then
                search_query=""
                fit_only=0
                current_page=1
                apply_filter
            fi
            ;;
        # Number input - read the rest of the line
        [0-9])
            # Echo the first digit so user can see it
            echo -n "$first_char"
            # Read the rest of the input
            read -r rest_of_input
            input="${first_char}${rest_of_input}"

            # Validate it's a number
            if [[ "$input" =~ ^[0-9]+$ ]]; then
                # Numbers are positions in the filtered view, not absolute
                # indices, so map back through view_idx.
                if [ "$input" -ge 1 ] && [ "$input" -le "$view_count" ]; then
                    selected_model="${model_names[${view_idx[$((input - 1))]}]}"
                    break
                else
                    print_message "$RED" "❌ Invalid selection. Please enter a number between 1 and $view_count"
                    sleep 1
                fi
            else
                print_message "$RED" "❌ Invalid input. Please enter a number."
                sleep 1
            fi
            ;;
        p|P)
            echo
            if [ $current_page -gt 1 ]; then
                ((current_page--))
            else
                print_message "$YELLOW" "Already on first page"
                sleep 0.5
            fi
            ;;
        n|N)
            echo
            if [ $current_page -lt $total_pages ]; then
                ((current_page++))
            else
                print_message "$YELLOW" "Already on last page"
                sleep 0.5
            fi
            ;;
        *)
            echo
            print_message "$RED" "❌ Invalid input. Use ←→ arrows, p/n, 'f' to search, type number + Enter, or 'q' to quit"
            sleep 1
            ;;
    esac
done

echo
print_message "$GREEN" "✅ You selected model: $selected_model"
fetch_variants_for_model "$selected_model"
select_variant_for_model "$selected_model"

echo
print_message "$GREEN" "✅ You selected variant: ${selected_model}:${selected_variant}"
print_message "$YELLOW" "📥 Starting download..."
echo

# Download the model using docker. Ctrl+C cancels the active pull and returns here.
while true; do
    if pull_model_with_retries "$selected_model_reference"; then
        break
    else
        pull_status=$?
    fi

    if [ "$pull_status" -eq 130 ]; then
        echo
        print_message "$YELLOW" "Select another variant for $selected_model, or [q] Quit."
        select_variant_for_model "$selected_model"
        echo
        print_message "$GREEN" "✅ You selected variant: ${selected_model}:${selected_variant}"
        print_message "$YELLOW" "📥 Starting download..."
        echo
        continue
    fi

    echo
    print_message "$RED" "❌ Failed to download model: $selected_model_reference"
    exit 1
done

    echo
    print_message "$GREEN" "✅ Successfully downloaded model: $selected_model_reference"
    echo

    # Locate the downloaded GGUF files
    print_message "$YELLOW" "🔍 Locating GGUF files..."
    blobs_dir="$HOME/.docker/models/blobs/sha256"

    if [ -d "$blobs_dir" ]; then
        # Find GGUF files by checking for GGUF magic bytes (47 47 55 46 in hex)
        declare -a gguf_files=()

        # Get files modified in the last 5 minutes (recently downloaded)
        while IFS= read -r file; do
            # Check if file starts with GGUF magic bytes
            if [ -f "$file" ]; then
                magic=$(head -c 4 "$file" 2>/dev/null | xxd -p 2>/dev/null)
                if [ "$magic" = "47475546" ]; then
                    gguf_files+=("$file")
                fi
            fi
        done < <(find "$blobs_dir" -type f -mmin -5 2>/dev/null)

        if [ ${#gguf_files[@]} -gt 0 ]; then
            echo
            print_message "$GREEN" "📁 GGUF file(s) found: ${#gguf_files[@]} file(s)"

            declare -a matches=()
            if [ -n "$GGUF_TOOL" ]; then
                print_message "$YELLOW" "🔍 Using $GGUF_TOOL to match model metadata for '$selected_model'..."
                selected_norm=$(normalize_alnum_lower "$selected_model")
                for f in "${gguf_files[@]}"; do
                    meta=$(extract_gguf_metadata "$f")
                    if [ -n "${meta}" ]; then
                        meta_norm=$(normalize_alnum_lower "$meta")
                        if printf "%s" "$meta_norm" | grep -F -q "$selected_norm"; then
                            matches+=("$f")
                        fi
                    fi
                done
            else
                print_message "$YELLOW" "🔍 GGUF metadata tools not found; using recent GGUF files sorted by size."
            fi
            if [ ${#matches[@]} -gt 0 ]; then
                IFS=$'\n' sorted_gguf_files=($(
                    for f in "${matches[@]}"; do
                        echo "$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)|$f"
                    done | sort -rn | cut -d'|' -f2
                ))
            else
                # fallback to size sorting of all candidates
                IFS=$'\n' sorted_gguf_files=($(
                    for f in "${gguf_files[@]}"; do
                        echo "$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)|$f"
                    done | sort -rn | cut -d'|' -f2
                ))
            fi

            for gguf_file in "${sorted_gguf_files[@]}"; do
                file_size=$(du -h "$gguf_file" | cut -f1)
                echo "   • $gguf_file ($file_size)"
            done

            echo
            print_message "$GREEN" "📝 Next steps:
"

            # Decide FROM/ADAPTER files based on detected GGUF metadata
            if [ ${#sorted_gguf_files[@]} -eq 1 ]; then
                # Single GGUF file
                echo "   1. Create a Modelfile with:"
                echo "      FROM ${sorted_gguf_files[0]}"
                echo
            else
                # Detect adapters by checking general.file_type (header-only)
                declare -a is_adapter=()
                for idx in "${!sorted_gguf_files[@]}"; do
                    fpath="${sorted_gguf_files[$idx]}"
                    file_type=$(extract_kv_header "$fpath" "general.file_type")
                    # also check tags/basename for adapter hints
                    if [ -z "$file_type" ]; then
                        file_type=$(extract_kv_header "$fpath" "general.tags")
                    fi
                    if [ -z "$file_type" ]; then
                        file_type=$(extract_kv_header "$fpath" "general.basename")
                    fi
                    if [ -n "$file_type" ] && echo "$file_type" | LC_ALL=C grep -qi "adapter"; then
                        is_adapter[$idx]=1
                    else
                        is_adapter[$idx]=0
                    fi
                done

                # Print FROM for the largest (first) file
                echo "   1. Create a Modelfile with:"
                echo "      FROM ${sorted_gguf_files[0]}"

                # Print ADAPTER lines only for files that are detected as adapters
                adapter_count=0
                for (( i=1; i<${#sorted_gguf_files[@]}; i++ )); do
                    if [ "${is_adapter[$i]}" -eq 1 ]; then
                        echo "      ADAPTER ${sorted_gguf_files[$i]}"
                        adapter_count=$((adapter_count+1))
                    fi
                done

                if [ "$adapter_count" -eq 0 ]; then
                    echo
                    echo "   Note: No adapter GGUF files detected."
                fi
                echo
            fi

            echo "   2. Import to Ollama: ollama create $selected_ollama_model -f Modelfile"
            echo "   3. Run it: ollama run $selected_ollama_model"

            print_message "$YELLOW" "   ℹ️  Note: Ollama will copy the GGUF files to its own storage (~/.ollama/models)"

            echo "      After successful import, you can safely delete the Docker blobs to save space."
            echo
        else
            echo
        print_message "$YELLOW" "⚠️  No GGUF files found in recent downloads. Scanning all blobs in $blobs_dir..."

            declare -a gguf_files_all=()
            while IFS= read -r file; do
                if [ -f "$file" ]; then
                    magic=$(head -c 4 "$file" 2>/dev/null | xxd -p 2>/dev/null)
                    if [ "$magic" = "47475546" ]; then
                        gguf_files_all+=("$file")
                    fi
                fi
            done < <(find "$blobs_dir" -type f 2>/dev/null)

            if [ ${#gguf_files_all[@]} -gt 0 ]; then
                echo
                print_message "$GREEN" "📁 GGUF file(s) found: ${#gguf_files_all[@]} file(s)"

                declare -a matches_all=()
                if [ -n "$GGUF_TOOL" ]; then
                    print_message "$YELLOW" "🔍 Using $GGUF_TOOL to match model metadata for '$selected_model' (full scan)..."
                    selected_norm=$(normalize_alnum_lower "$selected_model")
                    for f in "${gguf_files_all[@]}"; do
                        meta=$(extract_gguf_metadata "$f")
                        if [ -n "${meta}" ]; then
                            meta_norm=$(normalize_alnum_lower "$meta")
                            if printf "%s" "$meta_norm" | grep -F -q "$selected_norm"; then
                                matches_all+=("$f")
                            fi
                        fi
                    done
                else
                    print_message "$YELLOW" "🔍 GGUF metadata tools not found; using all GGUF files sorted by size."
                fi
                if [ ${#matches_all[@]} -gt 0 ]; then
                    IFS=$'
' sorted_gguf_files_all=($(
                        for f in "${matches_all[@]}"; do
                            echo "$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)|$f"
                        done | sort -rn | cut -d'|' -f2
                    ))
                else
                    IFS=$'
' sorted_gguf_files_all=($(
                        for f in "${gguf_files_all[@]}"; do
                            echo "$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)|$f"
                        done | sort -rn | cut -d'|' -f2
                    ))
                fi

                for gguf_file in "${sorted_gguf_files_all[@]}"; do
                    file_size=$(du -h "$gguf_file" | cut -f1)
                    echo "   • $gguf_file ($file_size)"
                done

                echo
                print_message "$GREEN" "📝 Next steps:"

                if [ ${#gguf_files_all[@]} -eq 1 ]; then
                    echo "   1. Create a Modelfile with:"
                    echo "      FROM ${sorted_gguf_files_all[0]}"
                    echo
                else
                    declare -a is_adapter_all=()
                    for idx in "${!sorted_gguf_files_all[@]}"; do
                        fpath="${sorted_gguf_files_all[$idx]}"
                        file_type=$(extract_kv_header "$fpath" "general.file_type")
                        if [ -z "$file_type" ]; then
                            file_type=$(extract_kv_header "$fpath" "general.tags")
                        fi
                        if [ -z "$file_type" ]; then
                            file_type=$(extract_kv_header "$fpath" "general.basename")
                        fi
                        if [ -n "$file_type" ] && echo "$file_type" | LC_ALL=C grep -qi "adapter"; then
                            is_adapter_all[$idx]=1
                        else
                            is_adapter_all[$idx]=0
                        fi
                    done

                    echo "   1. Create a Modelfile with:"
                    echo "      FROM ${sorted_gguf_files_all[0]}"

                    adapter_count=0
                    for (( i=1; i<${#sorted_gguf_files_all[@]}; i++ )); do
                        if [ "${is_adapter_all[$i]}" -eq 1 ]; then
                            echo "      ADAPTER ${sorted_gguf_files_all[$i]}"
                            adapter_count=$((adapter_count+1))
                        fi
                    done

                    if [ "$adapter_count" -eq 0 ]; then
                        echo
                        echo "   Note: No adapter GGUF files detected."
                    fi
                    echo
                fi

                echo "   2. Import to Ollama: ollama create $selected_ollama_model -f Modelfile"
                echo "   3. Run it: ollama run $selected_ollama_model"

                print_message "$YELLOW" "   ℹ️  Note: Ollama will copy the GGUF files to its own storage (~/.ollama/models)"
                echo "      After successful import, you can safely delete the Docker blobs to save space."
                echo
            else
                echo
                print_message "$YELLOW" "⚠️  No GGUF files found in $blobs_dir."
                echo "   Models are stored in: $blobs_dir"
                echo "   You may need to ensure the model download completed and try again."
                echo
            fi

        fi
    else
        echo
        print_message "$YELLOW" "⚠️  Docker models directory not found: $blobs_dir"
        echo
    fi
