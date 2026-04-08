#!/bin/sh
set -eu

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <codeql-bin> <output-root> <ya-target> [source-root] [query-suite]" >&2
  exit 2
fi

CODEQL_BIN=$1
OUTPUT_ROOT=$2
TARGET=$3
SOURCE_ROOT=${4:-}
QUERY_SUITE=${5:-}

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

CODEQL_ROOT=$(CDPATH= cd -- "$(dirname -- "$CODEQL_BIN")" && pwd)
if [ -z "$QUERY_SUITE" ]; then
  if [ -f "$CODEQL_ROOT/go/ql/src/codeql-suites/go-security-extended.qls" ]; then
    QUERY_SUITE=$CODEQL_ROOT/go/ql/src/codeql-suites/go-security-extended.qls
  else
    QUERY_SUITE=go-security-extended.qls
  fi
fi

YA_BIN=${YA_BIN:-$REPO_ROOT/ya}
YA_CACHE_DIR=${YA_CACHE_DIR:-$OUTPUT_ROOT/ya-cache}
YA_LOGS_ROOT=${YA_LOGS_ROOT:-$OUTPUT_ROOT/ya-logs}
GRAPH_JSON=${GRAPH_JSON:-$OUTPUT_ROOT/target-graph.json}
FRAGMENT_CACHE_DIR=${FRAGMENT_CACHE_DIR:-$OUTPUT_ROOT/fragment-cache}
COLD_BUILD_OUT=${COLD_BUILD_OUT:-$OUTPUT_ROOT/cold-build-output}
WARM_BUILD_OUT=${WARM_BUILD_OUT:-$OUTPUT_ROOT/warm-build-output}
COLD_TEMPLATE_DB=${COLD_TEMPLATE_DB:-$OUTPUT_ROOT/cold-template-db}
WARM_ASSEMBLED_DB=${WARM_ASSEMBLED_DB:-$OUTPUT_ROOT/warm-assembled-db}
COLD_DB=${COLD_DB:-$OUTPUT_ROOT/cold-db}
WARM_DB=${WARM_DB:-$OUTPUT_ROOT/warm-db}
COLD_MANIFEST=${COLD_MANIFEST:-$OUTPUT_ROOT/cold-manifest.json}
WARM_MANIFEST=${WARM_MANIFEST:-$OUTPUT_ROOT/warm-manifest.json}
COLD_SARIF=${COLD_SARIF:-$OUTPUT_ROOT/cold-security-extended.sarif}
WARM_SARIF=${WARM_SARIF:-$OUTPUT_ROOT/warm-security-extended.sarif}
COLD_FINDINGS=${COLD_FINDINGS:-$OUTPUT_ROOT/cold-findings.json}
WARM_FINDINGS=${WARM_FINDINGS:-$OUTPUT_ROOT/warm-findings.json}
SUMMARY_TXT=${SUMMARY_TXT:-$OUTPUT_ROOT/summary.txt}
REPO_IMPORT_PREFIX=${REPO_IMPORT_PREFIX:-a.yandex-team.ru}
MANIFEST_TOOL=${MANIFEST_TOOL:-$SCRIPT_DIR/ya_codeql_fragment_manifest.py}
BUILD_FRAGMENT_CACHE_TOOL=${BUILD_FRAGMENT_CACHE_TOOL:-$SCRIPT_DIR/build_fragment_cache.py}
INJECT_FRAGMENT_CACHE_TOOL=${INJECT_FRAGMENT_CACHE_TOOL:-$SCRIPT_DIR/inject_fragment_cache.py}
EXTRA_ANALYZE_ARGS=${EXTRA_ANALYZE_ARGS:-}

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

files_of_path() {
  target=$1
  find "$target" -type f 2>/dev/null | wc -l | tr -d ' '
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
  prepare_warm_build_out "$COLD_BUILD_OUT" "$build_out" "$GRAPH_JSON"
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
    --manifest "$COLD_MANIFEST" \
    --trap-root "$COLD_TEMPLATE_DB/trap/go" \
    --cache-root "$FRAGMENT_CACHE_DIR" \
    --output "$OUTPUT_ROOT/fragment-cache-build.json" >"$OUTPUT_ROOT/fragment-cache-build.log" 2>&1
}

inject_fragment_cache() {
  python3 "$INJECT_FRAGMENT_CACHE_TOOL" \
    --cache-root "$FRAGMENT_CACHE_DIR" \
    --target-manifest "$WARM_MANIFEST" \
    --to-trap-root "$WARM_ASSEMBLED_DB/trap/go" \
    --output "$OUTPUT_ROOT/fragment-cache-inject.json" >"$OUTPUT_ROOT/fragment-cache-inject.log" 2>&1
}

analyze_db() {
  db=$1
  sarif=$2
  findings=$3
  log_file=$4
  rm -f "$sarif" "$findings"
  "$CODEQL_BIN" database analyze \
    "$db" \
    "$QUERY_SUITE" \
    --format=sarifv2.1.0 \
    --output="$sarif" \
    $EXTRA_ANALYZE_ARGS >"$log_file" 2>&1
  python3 - "$sarif" "$findings" <<'PY'
import json
import sys
from pathlib import Path

sarif_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
data = json.loads(sarif_path.read_text())
rows = []
for run in data.get("runs", []):
    for result in run.get("results", []):
        message = result.get("message", {}).get("text", "")
        rule_id = result.get("ruleId", "")
        kind = result.get("kind", "")
        level = result.get("level", "")
        if result.get("locations"):
            for loc in result["locations"]:
                physical = loc.get("physicalLocation", {})
                artifact = physical.get("artifactLocation", {}).get("uri", "")
                region = physical.get("region", {})
                rows.append({
                    "ruleId": rule_id,
                    "kind": kind,
                    "level": level,
                    "message": message,
                    "artifact": artifact,
                    "startLine": region.get("startLine", 0),
                    "startColumn": region.get("startColumn", 0),
                    "endLine": region.get("endLine", 0),
                    "endColumn": region.get("endColumn", 0),
                })
        else:
            rows.append({
                "ruleId": rule_id,
                "kind": kind,
                "level": level,
                "message": message,
                "artifact": "",
                "startLine": 0,
                "startColumn": 0,
                "endLine": 0,
                "endColumn": 0,
            })
rows.sort(key=lambda row: (
    row["ruleId"],
    row["artifact"],
    row["startLine"],
    row["startColumn"],
    row["endLine"],
    row["endColumn"],
    row["message"],
    row["kind"],
    row["level"],
))
out_path.write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n")
PY
}

print_ya_log_summary() {
  label=$1
  out=$OUTPUT_ROOT/$label-ya-summary.txt
  latest_log=$(find "$YA_LOGS_ROOT" -type f -name '*.log' 2>/dev/null | sort | tail -n 1 || true)
  {
    echo "label=$label"
    echo "target=$TARGET"
    echo "latest_log=${latest_log:-missing}"
    if [ -n "${latest_log:-}" ] && [ -f "$latest_log" ]; then
      grep -E 'Run tasks|statistics_cache_hit|critical_path - ' "$latest_log" || true
    fi
  } > "$out"
}

write_summary() {
  {
    echo "target=$TARGET"
    echo "source_root=$SOURCE_ROOT"
    echo "query_suite=$QUERY_SUITE"
    echo "cold_status=$cold_status"
    echo "warm_status=$warm_status"
    echo "analysis_status=$analysis_status"
    echo "cold_db_ms=$cold_ms"
    echo "warm_db_ms=$warm_ms"
    echo "ya_cache_bytes=$ya_cache_bytes"
    echo "ya_cache_files=$ya_cache_files"
    echo "fragment_cache_bytes=$fragment_cache_bytes"
    echo "fragment_cache_files=$fragment_cache_files"
    echo "total_cache_bytes=$total_cache_bytes"
    echo "total_cache_files=$total_cache_files"
    echo "cold_findings_count=$cold_findings_count"
    echo "warm_findings_count=$warm_findings_count"
    echo "findings_equal=$findings_equal"
    echo "cold_db=$COLD_DB"
    echo "warm_db=$WARM_DB"
    echo "cold_template_db=$COLD_TEMPLATE_DB"
    echo "warm_assembled_db=$WARM_ASSEMBLED_DB"
    echo "fragment_cache_dir=$FRAGMENT_CACHE_DIR"
    echo "graph_json=$GRAPH_JSON"
    echo "cold_manifest=$COLD_MANIFEST"
    echo "warm_manifest=$WARM_MANIFEST"
    echo "cold_sarif=$COLD_SARIF"
    echo "warm_sarif=$WARM_SARIF"
    echo "cold_findings=$COLD_FINDINGS"
    echo "warm_findings=$WARM_FINDINGS"
    echo "ya_cache_dir=$YA_CACHE_DIR"
  } | tee "$SUMMARY_TXT"
}

rm -rf "$OUTPUT_ROOT"
mkdir -p "$OUTPUT_ROOT" "$YA_LOGS_ROOT"
rm -rf "$YA_CACHE_DIR" "$FRAGMENT_CACHE_DIR"
mkdir -p "$YA_CACHE_DIR" "$FRAGMENT_CACHE_DIR"

cold_status=failed
warm_status=skipped
analysis_status=skipped
cold_ms=0
warm_ms=0
ya_cache_bytes=0
ya_cache_files=0
fragment_cache_bytes=0
fragment_cache_files=0
total_cache_bytes=0
total_cache_files=0
cold_findings_count=0
warm_findings_count=0
findings_equal=unknown

build_graph

cold_start=$(now_ms)
init_db "$COLD_TEMPLATE_DB"
trace_clean "$COLD_TEMPLATE_DB" "$COLD_BUILD_OUT" "$OUTPUT_ROOT/cold-trace.log"
build_manifest "$GRAPH_JSON" "$COLD_TEMPLATE_DB/trap/go" "$COLD_MANIFEST"
build_fragment_cache
clone_db "$COLD_TEMPLATE_DB" "$COLD_DB"
finalize_db "$COLD_DB" "$OUTPUT_ROOT/cold-finalize.log"
cold_end=$(now_ms)
cold_status=ok
print_ya_log_summary cold
cold_ms=$((cold_end - cold_start))

warm_start=$(now_ms)
init_db "$WARM_ASSEMBLED_DB"
trace_nocu "$WARM_ASSEMBLED_DB" "$WARM_BUILD_OUT" "$OUTPUT_ROOT/warm-trace.log"
build_manifest "$GRAPH_JSON" "$WARM_ASSEMBLED_DB/trap/go" "$WARM_MANIFEST"
inject_fragment_cache
assemble_from_template "$COLD_TEMPLATE_DB" "$WARM_ASSEMBLED_DB" "$WARM_DB"
finalize_db "$WARM_DB" "$OUTPUT_ROOT/warm-finalize.log"
warm_end=$(now_ms)
warm_status=ok
print_ya_log_summary warm
warm_ms=$((warm_end - warm_start))

ya_cache_bytes=$(bytes_of_path "$YA_CACHE_DIR")
ya_cache_files=$(files_of_path "$YA_CACHE_DIR")
fragment_cache_bytes=$(bytes_of_path "$FRAGMENT_CACHE_DIR")
fragment_cache_files=$(files_of_path "$FRAGMENT_CACHE_DIR")
total_cache_bytes=$((ya_cache_bytes + fragment_cache_bytes))
total_cache_files=$((ya_cache_files + fragment_cache_files))

analyze_db "$COLD_DB" "$COLD_SARIF" "$COLD_FINDINGS" "$OUTPUT_ROOT/cold-analyze.log"
analyze_db "$WARM_DB" "$WARM_SARIF" "$WARM_FINDINGS" "$OUTPUT_ROOT/warm-analyze.log"
analysis_status=ok

if cmp -s "$COLD_FINDINGS" "$WARM_FINDINGS"; then
  findings_equal=yes
else
  findings_equal=no
fi

cold_findings_count=$(python3 - "$COLD_FINDINGS" <<'PY'
import json
import sys
print(len(json.load(open(sys.argv[1]))))
PY
)
warm_findings_count=$(python3 - "$WARM_FINDINGS" <<'PY'
import json
import sys
print(len(json.load(open(sys.argv[1]))))
PY
)

write_summary

if [ "$findings_equal" != yes ]; then
  echo "normalized findings differ; inspect $COLD_FINDINGS and $WARM_FINDINGS" >&2
  exit 1
fi

echo "artifacts: $OUTPUT_ROOT"
