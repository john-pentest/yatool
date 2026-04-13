#!/bin/sh
set -eu

if [ "$#" -lt 4 ]; then
  echo "usage: $0 <codeql-bin> <output-root> <ya-target> <source-file> [source-root]" >&2
  exit 2
fi

CODEQL_BIN=$1
OUTPUT_ROOT=$2
TARGET=$3
SOURCE_FILE=$4
SOURCE_ROOT=${5:-}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CREATE_DB_SCRIPT=${CREATE_DB_SCRIPT:-$SCRIPT_DIR/create_fragment_cached_database.sh}
INJECT_FRAGMENT_CACHE_TOOL=${INJECT_FRAGMENT_CACHE_TOOL:-$SCRIPT_DIR/inject_fragment_cache.py}
BUILD_FRAGMENT_CACHE_TOOL=${BUILD_FRAGMENT_CACHE_TOOL:-$SCRIPT_DIR/build_fragment_cache.py}

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
ABS_SOURCE_FILE=$SOURCE_ROOT/$SOURCE_FILE

WORK_ROOT=$OUTPUT_ROOT/work
BASELINE_ROOT=$OUTPUT_ROOT/baseline
MUTATED_ROOT=$OUTPUT_ROOT/mutated
BACKUP_FILE=$OUTPUT_ROOT/source.backup
SUMMARY_TXT=$OUTPUT_ROOT/summary.txt

mkdir -p "$OUTPUT_ROOT"
cp "$ABS_SOURCE_FILE" "$BACKUP_FILE"
restore_source() {
  if [ -f "$BACKUP_FILE" ]; then
    cp "$BACKUP_FILE" "$ABS_SOURCE_FILE"
  fi
}
trap restore_source EXIT INT TERM HUP

sh "$CREATE_DB_SCRIPT" "$CODEQL_BIN" "$BASELINE_ROOT" "$TARGET" "$SOURCE_ROOT" >/tmp/verify-fragment-baseline.log 2>&1

python3 - "$ABS_SOURCE_FILE" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
marker = "// codeql fragment cache probe\n"
if marker not in text:
    idx = text.index("func main()") if "func main()" in text else len(text)
    text = text[:idx] + marker + text[idx:]
    p.write_text(text)
PY

YA_CACHE_DIR=$BASELINE_ROOT/ya-cache \
YA_LOGS_ROOT=$BASELINE_ROOT/ya-logs \
FRAGMENT_CACHE_DIR=$BASELINE_ROOT/fragment-cache \
BOOTSTRAP_TEMPLATE_DB=$BASELINE_ROOT/bootstrap-template-db \
BOOTSTRAP_BUILD_OUT=$BASELINE_ROOT/bootstrap-build-output \
BOOTSTRAP_REGISTRY_DIR=$BASELINE_ROOT/bootstrap-registry \
REUSE_EXISTING_CACHE=true \
sh "$CREATE_DB_SCRIPT" "$CODEQL_BIN" "$MUTATED_ROOT" "$TARGET" "$SOURCE_ROOT" >/tmp/verify-fragment-mutated.log 2>&1

restore_source
rm -f "$BACKUP_FILE"
trap - EXIT INT TERM HUP

WARM_REGISTRY_COUNT=$(find "$MUTATED_ROOT/warm-registry" -type f 2>/dev/null | wc -l | tr -d ' ')
INJECT_JSON=$MUTATED_ROOT/fragment-cache-inject.json
MATCHED_NODE_COUNT=$(python3 - "$INJECT_JSON" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
print(data.get('matched_node_count', 0))
PY
)
APP_INJECTED=$(python3 - "$INJECT_JSON" "$TARGET" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
target = sys.argv[2]
print('yes' if any(node.get('module_path') == target for node in data.get('matched_nodes', [])) else 'no')
PY
)
LATEST_LOG=$(find "$BASELINE_ROOT/ya-logs" -type f | sort | tail -n 1)
WARM_LOG=$(find "$BASELINE_ROOT/ya-logs" -type f | sort | tail -n 1)
RESTORE_GO_QTY=$(python3 - "$WARM_LOG" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'"restore\[GO\]":\{"sum":[^,]+,"qty":(\d+)', text)
print(m.group(1) if m else '0')
PY
)
NOT_CACHED_QTY=$(python3 - "$WARM_LOG" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'Run tasks \d+: \d+ cached tasks .*?, (\d+) not cached', text)
print(m.group(1) if m else '0')
PY
)

{
  echo "target=$TARGET"
  echo "source_file=$SOURCE_FILE"
  echo "baseline_root=$BASELINE_ROOT"
  echo "mutated_root=$MUTATED_ROOT"
  echo "warm_registry_count=$WARM_REGISTRY_COUNT"
  echo "inject_matched_node_count=$MATCHED_NODE_COUNT"
  echo "app_injected_from_cache=$APP_INJECTED"
  echo "restore_go_qty=$RESTORE_GO_QTY"
  echo "not_cached_qty=$NOT_CACHED_QTY"
} | tee "$SUMMARY_TXT"
