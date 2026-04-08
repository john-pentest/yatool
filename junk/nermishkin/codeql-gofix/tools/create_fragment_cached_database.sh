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
GRAPH_JSON=${GRAPH_JSON:-$OUTPUT_ROOT/target-graph.json}
FRAGMENT_CACHE_DIR=${FRAGMENT_CACHE_DIR:-$OUTPUT_ROOT/fragment-cache}
BOOTSTRAP_TEMPLATE_DB=${BOOTSTRAP_TEMPLATE_DB:-$OUTPUT_ROOT/bootstrap-template-db}
BOOTSTRAP_BUILD_OUT=${BOOTSTRAP_BUILD_OUT:-$OUTPUT_ROOT/bootstrap-build-output}
BOOTSTRAP_MANIFEST=${BOOTSTRAP_MANIFEST:-$OUTPUT_ROOT/bootstrap-manifest.json}
ASSEMBLED_DB=${ASSEMBLED_DB:-$OUTPUT_ROOT/assembled-db}
WARM_BUILD_OUT=${WARM_BUILD_OUT:-$OUTPUT_ROOT/warm-build-output}
WARM_MANIFEST=${WARM_MANIFEST:-$OUTPUT_ROOT/warm-manifest.json}
FINAL_DB=${FINAL_DB:-$OUTPUT_ROOT/final-db}
SUMMARY_TXT=${SUMMARY_TXT:-$OUTPUT_ROOT/summary.txt}
REPO_IMPORT_PREFIX=${REPO_IMPORT_PREFIX:-a.yandex-team.ru}
MANIFEST_TOOL=${MANIFEST_TOOL:-$SCRIPT_DIR/ya_codeql_fragment_manifest.py}
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

trace_clean() {
  db=$1
  build_out=$2
  log_file=$3
  rm -rf "$build_out"
  mkdir -p "$build_out"
  CODEQL_EXTRACTOR_GO_EXTRACT_HTML=no "$CODEQL_BIN" database trace-command "$db" -- \
    env YA_CACHE_DIR="$YA_CACHE_DIR" YA_LOGS_ROOT="$YA_LOGS_ROOT" \
    "$YA_BIN" make -r --clear --rebuild --no-yt-store -o "$build_out" "$TARGET" >"$log_file" 2>&1
}

prepare_warm_build_out() {
  src_build_out=$1
  dst_build_out=$2
  graph_json=$3
  rm -rf "$dst_build_out"
  cp -R "$src_build_out" "$dst_build_out"
  python3 - "$graph_json" "$dst_build_out" <<'PY'
import json
import shutil
import sys
from pathlib import Path

graph_json = Path(sys.argv[1])
build_out = Path(sys.argv[2])
with graph_json.open() as fh:
    graph = json.load(fh)

by_uid = {node.get("uid"): node for node in graph.get("graph", [])}
for uid in graph.get("result", []):
    node = by_uid.get(uid)
    if not node:
        continue
    for output in node.get("outputs") or []:
        if not output.startswith("$(BUILD_ROOT)/"):
            continue
        rel = output.replace("$(BUILD_ROOT)/", "", 1)
        path = build_out / rel
        if path.is_dir():
            shutil.rmtree(path, ignore_errors=True)
        elif path.exists():
            path.unlink()
PY
}

trace_nocu() {
  db=$1
  build_out=$2
  log_file=$3
  prepare_warm_build_out "$BOOTSTRAP_BUILD_OUT" "$build_out" "$GRAPH_JSON"
  CODEQL_EXTRACTOR_GO_EXTRACT_HTML=no "$CODEQL_BIN" database trace-command "$db" -- \
    env YA_CACHE_DIR="$YA_CACHE_DIR" YA_LOGS_ROOT="$YA_LOGS_ROOT" \
    "$YA_BIN" make -r --no-content-uids --no-yt-store -o "$build_out" "$TARGET" >"$log_file" 2>&1
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
  template_db=$1
  assembled_trap_db=$2
  final_db=$3
  clone_db "$template_db" "$final_db"
  rm -rf "$final_db/trap/go"
  mkdir -p "$final_db/trap"
  cp -R "$assembled_trap_db/trap/go" "$final_db/trap/go"
}

build_graph() {
  "$YA_BIN" make -r --no-yt-store --dump-json-graph --dump-graph-to-file "$GRAPH_JSON" "$TARGET" >"$OUTPUT_ROOT/graph.log" 2>&1
}

build_manifest() {
  graph_json=$1
  trap_root=$2
  output=$3
  python3 "$MANIFEST_TOOL" \
    --graph-json "$graph_json" \
    --source-root "$SOURCE_ROOT" \
    --trap-root "$trap_root" \
    --repo-import-prefix "$REPO_IMPORT_PREFIX" \
    --output "$output" >"$output.log" 2>&1
}

build_fragment_cache() {
  python3 "$BUILD_FRAGMENT_CACHE_TOOL" \
    --manifest "$BOOTSTRAP_MANIFEST" \
    --trap-root "$BOOTSTRAP_TEMPLATE_DB/trap/go" \
    --cache-root "$FRAGMENT_CACHE_DIR" \
    --output "$OUTPUT_ROOT/fragment-cache-build.json" >"$OUTPUT_ROOT/fragment-cache-build.log" 2>&1
}

inject_fragment_cache() {
  python3 "$INJECT_FRAGMENT_CACHE_TOOL" \
    --cache-root "$FRAGMENT_CACHE_DIR" \
    --target-manifest "$WARM_MANIFEST" \
    --to-trap-root "$ASSEMBLED_DB/trap/go" \
    --output "$OUTPUT_ROOT/fragment-cache-inject.json" >"$OUTPUT_ROOT/fragment-cache-inject.log" 2>&1
}

bootstrap_if_needed() {
  if [ "$REUSE_EXISTING_CACHE" = true ] && [ -f "$FRAGMENT_CACHE_DIR/index.json" ] && [ -d "$BOOTSTRAP_TEMPLATE_DB/trap/go" ] && [ -d "$BOOTSTRAP_BUILD_OUT" ]; then
    return
  fi

  init_db "$BOOTSTRAP_TEMPLATE_DB"
  trace_clean "$BOOTSTRAP_TEMPLATE_DB" "$BOOTSTRAP_BUILD_OUT" "$OUTPUT_ROOT/bootstrap-trace.log"
  build_manifest "$GRAPH_JSON" "$BOOTSTRAP_TEMPLATE_DB/trap/go" "$BOOTSTRAP_MANIFEST"
  build_fragment_cache
}

mkdir -p "$OUTPUT_ROOT" "$YA_LOGS_ROOT"
mkdir -p "$YA_CACHE_DIR"

build_graph
start_ms=$(now_ms)
bootstrap_if_needed
init_db "$ASSEMBLED_DB"
trace_nocu "$ASSEMBLED_DB" "$WARM_BUILD_OUT" "$OUTPUT_ROOT/warm-trace.log"
build_manifest "$GRAPH_JSON" "$ASSEMBLED_DB/trap/go" "$WARM_MANIFEST"
inject_fragment_cache
assemble_from_template "$BOOTSTRAP_TEMPLATE_DB" "$ASSEMBLED_DB" "$FINAL_DB"
finalize_db "$FINAL_DB" "$OUTPUT_ROOT/finalize.log"
end_ms=$(now_ms)

{
  echo "target=$TARGET"
  echo "source_root=$SOURCE_ROOT"
  echo "final_db=$FINAL_DB"
  echo "graph_json=$GRAPH_JSON"
  echo "fragment_cache_dir=$FRAGMENT_CACHE_DIR"
  echo "bootstrap_template_db=$BOOTSTRAP_TEMPLATE_DB"
  echo "assembled_db=$ASSEMBLED_DB"
  echo "elapsed_ms=$((end_ms - start_ms))"
  echo "ya_cache_bytes=$(bytes_of_path "$YA_CACHE_DIR")"
  echo "fragment_cache_bytes=$(bytes_of_path "$FRAGMENT_CACHE_DIR")"
} | tee "$SUMMARY_TXT"

echo "artifacts: $OUTPUT_ROOT"
