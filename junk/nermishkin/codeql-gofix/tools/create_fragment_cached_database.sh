#!/bin/sh
set -eu

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <codeql-bin> <output-root> <ya-target> [source-root]" >&2
  exit 2
fi

CODEQL_BIN=$1
OUTPUT_ROOT=$2
TARGET=$3
SOURCE_ROOT=${4:-}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
find_repo_root() {
  dir=$1
  while [ "$dir" != "/" ]; do
    if [ -e "$dir/.arcadia.root" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=$(dirname -- "$dir")
  done
  return 1
}

REPO_ROOT=$(find_repo_root "$SCRIPT_DIR")
if [ -z "$SOURCE_ROOT" ]; then
  SOURCE_ROOT=$REPO_ROOT
fi

YA_BIN=${YA_BIN:-$REPO_ROOT/ya}
YA_CACHE_DIR=${YA_CACHE_DIR:-$OUTPUT_ROOT/ya-cache}
YA_LOGS_ROOT=${YA_LOGS_ROOT:-$OUTPUT_ROOT/ya-logs}
FRAGMENT_CACHE_DIR=${FRAGMENT_CACHE_DIR:-$OUTPUT_ROOT/fragment-cache}
BOOTSTRAP_TEMPLATE_DB=${BOOTSTRAP_TEMPLATE_DB:-$OUTPUT_ROOT/bootstrap-template-db}
BOOTSTRAP_BUILD_OUT=${BOOTSTRAP_BUILD_OUT:-$OUTPUT_ROOT/bootstrap-build-output}
BOOTSTRAP_REGISTRY_DIR=${BOOTSTRAP_REGISTRY_DIR:-$OUTPUT_ROOT/bootstrap-registry}
ASSEMBLED_DB=${ASSEMBLED_DB:-$OUTPUT_ROOT/assembled-db}
WARM_BUILD_OUT=${WARM_BUILD_OUT:-$OUTPUT_ROOT/warm-build-output}
WARM_REGISTRY_DIR=${WARM_REGISTRY_DIR:-$OUTPUT_ROOT/warm-registry}
FINAL_DB=${FINAL_DB:-$OUTPUT_ROOT/final-db}
SUMMARY_TXT=${SUMMARY_TXT:-$OUTPUT_ROOT/summary.txt}
BUILD_FRAGMENT_CACHE_TOOL=${BUILD_FRAGMENT_CACHE_TOOL:-$SCRIPT_DIR/build_fragment_cache.py}
INJECT_FRAGMENT_CACHE_TOOL=${INJECT_FRAGMENT_CACHE_TOOL:-$SCRIPT_DIR/inject_fragment_cache.py}
REUSE_EXISTING_CACHE=${REUSE_EXISTING_CACHE:-true}

now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

bytes_of_path() {
  target=$1
  python3 - "$target" <<'PY'
import os
import sys
path = sys.argv[1]
if not os.path.exists(path):
    print(0)
    raise SystemExit(0)
if os.path.isfile(path):
    print(os.path.getsize(path))
    raise SystemExit(0)
size = 0
for root, dirs, files in os.walk(path):
    for name in files:
        full = os.path.join(root, name)
        try:
            size += os.path.getsize(full)
        except OSError:
            pass
print(size)
PY
}

init_db() {
  db=$1
  rm -rf "$db"
  CODEQL_EXTRACTOR_GO_EXTRACT_HTML=no "$CODEQL_BIN" database init \
    --language=go \
    --source-root="$SOURCE_ROOT" \
    --no-calculate-baseline \
    "$db" >"$OUTPUT_ROOT/$(basename "$db")-init.log" 2>&1
}

trace_build() {
  db=$1
  build_out=$2
  registry_dir=$3
  log_file=$4
  shift 4
  rm -rf "$registry_dir"
  mkdir -p "$build_out"
  CODEQL_EXTRACTOR_GO_EXTRACT_HTML=no "$CODEQL_BIN" database trace-command "$db" -- \
    env YA_CACHE_DIR="$YA_CACHE_DIR" YA_LOGS_ROOT="$YA_LOGS_ROOT" YA_CODEQL_FRAGMENT_REGISTRY_DIR="$registry_dir" \
    "$YA_BIN" make "$@" -o "$build_out" "$TARGET" >"$log_file" 2>&1
}

remove_target_outputs() {
  registry_dir=$1
  build_out=$2
  target=$3
  python3 - "$registry_dir" "$build_out" "$target" <<'PY'
import json
import os
import sys
from pathlib import Path

registry_dir = Path(sys.argv[1])
build_out = Path(sys.argv[2])
target = sys.argv[3]
for path in sorted(registry_dir.glob('*.json')):
    with path.open() as fh:
        data = json.load(fh)
    if data.get('module_path') != target:
        continue
    output_path = data.get('output', '')
    base = os.path.basename(output_path)
    if base:
        candidate = build_out / target / base
        if candidate.exists():
            candidate.unlink()
    fragment = build_out / target / 'codeql_fragment.json'
    if fragment.exists():
        fragment.unlink()
    break
PY
}

prepare_warm_build_out() {
  rm -rf "$WARM_BUILD_OUT"
  cp -R "$BOOTSTRAP_BUILD_OUT" "$WARM_BUILD_OUT"
  find "$WARM_BUILD_OUT" -type f \( -name codeql_fragment.json -o -name '*.codeql_fragment.json' \) -delete >/dev/null 2>&1 || true
  remove_target_outputs "$BOOTSTRAP_REGISTRY_DIR" "$WARM_BUILD_OUT" "$TARGET"
}

finalize_db() {
  db=$1
  log_file=$2
  "$CODEQL_BIN" database finalize "$db" >"$log_file" 2>&1
}

clone_db() {
  src=$1
  dst=$2
  rm -rf "$dst"
  cp -R "$src" "$dst"
}

assemble_from_template() {
  clone_db "$BOOTSTRAP_TEMPLATE_DB" "$FINAL_DB"
  rm -rf "$FINAL_DB/trap/go"
  mkdir -p "$FINAL_DB/trap"
  cp -R "$ASSEMBLED_DB/trap/go" "$FINAL_DB/trap/go"
}

build_fragment_cache() {
  python3 "$BUILD_FRAGMENT_CACHE_TOOL" \
    --registry-dir "$BOOTSTRAP_REGISTRY_DIR" \
    --trap-root "$BOOTSTRAP_TEMPLATE_DB/trap/go" \
    --cache-root "$FRAGMENT_CACHE_DIR" \
    --output "$OUTPUT_ROOT/fragment-cache-build.json" >"$OUTPUT_ROOT/fragment-cache-build.log" 2>&1
}

inject_fragment_cache() {
  python3 "$INJECT_FRAGMENT_CACHE_TOOL" \
    --cache-root "$FRAGMENT_CACHE_DIR" \
    --executed-registry-dir "$WARM_REGISTRY_DIR" \
    --to-trap-root "$ASSEMBLED_DB/trap/go" \
    --output "$OUTPUT_ROOT/fragment-cache-inject.json" >"$OUTPUT_ROOT/fragment-cache-inject.log" 2>&1
}

bootstrap_if_needed() {
  if [ "$REUSE_EXISTING_CACHE" = true ] && [ -f "$FRAGMENT_CACHE_DIR/index.json" ] && [ -d "$BOOTSTRAP_TEMPLATE_DB/trap/go" ] && [ -d "$BOOTSTRAP_BUILD_OUT" ] && [ -d "$BOOTSTRAP_REGISTRY_DIR" ]; then
    return
  fi

  init_db "$BOOTSTRAP_TEMPLATE_DB"
  rm -rf "$BOOTSTRAP_BUILD_OUT"
  mkdir -p "$BOOTSTRAP_BUILD_OUT"
  trace_build "$BOOTSTRAP_TEMPLATE_DB" "$BOOTSTRAP_BUILD_OUT" "$BOOTSTRAP_REGISTRY_DIR" "$OUTPUT_ROOT/bootstrap-trace.log" -r --clear --rebuild --no-yt-store
  build_fragment_cache
}

mkdir -p "$OUTPUT_ROOT" "$YA_LOGS_ROOT" "$YA_CACHE_DIR"
start_ms=$(now_ms)
bootstrap_if_needed
init_db "$ASSEMBLED_DB"
prepare_warm_build_out
trace_build "$ASSEMBLED_DB" "$WARM_BUILD_OUT" "$WARM_REGISTRY_DIR" "$OUTPUT_ROOT/warm-trace.log" -r --no-content-uids --no-yt-store
inject_fragment_cache
assemble_from_template
finalize_db "$FINAL_DB" "$OUTPUT_ROOT/finalize.log"
end_ms=$(now_ms)

ya_cache_bytes=$(bytes_of_path "$YA_CACHE_DIR")
fragment_cache_bytes=$(bytes_of_path "$FRAGMENT_CACHE_DIR")
bootstrap_registry_count=$(find "$BOOTSTRAP_REGISTRY_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
warm_registry_count=$(find "$WARM_REGISTRY_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')

{
  echo "target=$TARGET"
  echo "source_root=$SOURCE_ROOT"
  echo "final_db=$FINAL_DB"
  echo "fragment_cache_dir=$FRAGMENT_CACHE_DIR"
  echo "bootstrap_registry_dir=$BOOTSTRAP_REGISTRY_DIR"
  echo "warm_registry_dir=$WARM_REGISTRY_DIR"
  echo "bootstrap_registry_count=$bootstrap_registry_count"
  echo "warm_registry_count=$warm_registry_count"
  echo "bootstrap_template_db=$BOOTSTRAP_TEMPLATE_DB"
  echo "assembled_db=$ASSEMBLED_DB"
  echo "elapsed_ms=$((end_ms - start_ms))"
  echo "ya_cache_bytes=$ya_cache_bytes"
  echo "fragment_cache_bytes=$fragment_cache_bytes"
} | tee "$SUMMARY_TXT"

printf '%s\n' "artifacts: $OUTPUT_ROOT"
