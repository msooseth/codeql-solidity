#!/usr/bin/env bash
#
# Download the first N parquet shards of a Sourcify export dataset.
#
# Instead of guessing range numbers, this reads the real bucket listing
# (https://export.sourcify.dev/?prefix=v2/<dataset>/), so it only ever requests
# files that exist, in numeric order, and stops at whatever is available.
#
# Datasets (see the listing for the full set):
#   compiled_contracts_sources : compilation_id -> source_hash, path  (~26 shards)
#   sources                    : source_hash -> content
#   code                       : creation/runtime bytecode
#
# Usage:
#   ./download_parquet.sh                       # first 100 of compiled_contracts_sources
#   ./download_parquet.sh sources 100           # first 100 sources shards
#   DATASET=sources COUNT=100 ./download_parquet.sh
#   OUTDIR=somewhere ./download_parquet.sh sources 50

set -euo pipefail

HOST="https://export.sourcify.dev"
DATASET="${1:-${DATASET:-compiled_contracts_sources}}"
COUNT="${2:-${COUNT:-100}}"
OUTDIR="${OUTDIR:-$DATASET}"
PREFIX="v2/${DATASET}/"

mkdir -p "$OUTDIR"

# --- 1. Page through the bucket listing to collect every key for the dataset.
echo "Listing $HOST/$PREFIX ..."
keys=()
marker=""
while :; do
    resp=$(curl -sf "${HOST}/?prefix=${PREFIX}&max-keys=1000${marker:+&marker=${marker}}")
    page_keys=$(printf '%s' "$resp" | grep -oP '(?<=<Key>)[^<]+(?=</Key>)' | grep '\.parquet$' || true)
    if [[ -n "$page_keys" ]]; then
        while IFS= read -r k; do keys+=("$k"); done <<< "$page_keys"
    fi
    if [[ "$(printf '%s' "$resp" | grep -oP '(?<=<IsTruncated>)[^<]+')" == "true" ]]; then
        # Prefer NextMarker; fall back to the last key on this page.
        marker=$(printf '%s' "$resp" | grep -oP '(?<=<NextMarker>)[^<]+' | tail -1)
        [[ -z "$marker" ]] && marker=$(printf '%s' "$page_keys" | tail -1)
    else
        break
    fi
done

if [[ ${#keys[@]} -eq 0 ]]; then
    echo "No parquet files found under $PREFIX" >&2
    exit 1
fi

# --- 2. Sort by the numeric start range (key looks like <dataset>_<start>_<end>.parquet).
mapfile -t sorted < <(
    for k in "${keys[@]}"; do
        base=${k##*/}                       # strip path
        start=${base#${DATASET}_}           # drop "<dataset>_"
        start=${start%%_*}                  # keep first number
        printf '%s\t%s\n' "$start" "$k"
    done | sort -n -k1,1 | cut -f2-
)

avail=${#sorted[@]}
want=$COUNT
(( want > avail )) && want=$avail
echo "Found $avail shard(s); downloading first $want into $OUTDIR/"

# --- 3. Download.
ok=0; fail=0; skip=0
for ((i = 0; i < want; i++)); do
    key="${sorted[$i]}"
    file="${key##*/}"
    url="${HOST}/${key}"
    out="${OUTDIR}/${file}"

    if [[ -s "$out" ]]; then
        echo "[$((i + 1))/$want] skip (exists): $file"
        skip=$((skip + 1))
        continue
    fi

    echo "[$((i + 1))/$want] $url"
    if curl -L -f -C - --retry 5 --retry-delay 2 -o "${out}.part" "$url"; then
        mv "${out}.part" "$out"
        ok=$((ok + 1))
    else
        echo "  FAILED: $file" >&2
        rm -f "${out}.part"
        fail=$((fail + 1))
    fi
done

echo "Done: $ok downloaded, $skip already present, $fail failed."
