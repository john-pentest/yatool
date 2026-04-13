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
CREATE_DB_SCRIPT=${CREATE_DB_SCRIPT:-$SCRIPT_DIR/create_fragment_cached_database.sh}

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

WORK_ROOT=$OUTPUT_ROOT/work
COLD_DB=$OUTPUT_ROOT/cold-db
WARM_DB=$OUTPUT_ROOT/warm-db
COLD_SARIF=$OUTPUT_ROOT/cold.sarif
WARM_SARIF=$OUTPUT_ROOT/warm.sarif
COLD_FINDINGS=$OUTPUT_ROOT/cold-findings.json
WARM_FINDINGS=$OUTPUT_ROOT/warm-findings.json
SUMMARY_TXT=$OUTPUT_ROOT/summary.txt

mkdir -p "$OUTPUT_ROOT"
rm -rf "$WORK_ROOT" "$COLD_DB" "$WARM_DB"

start_ms=$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)
REUSE_EXISTING_CACHE=false sh "$CREATE_DB_SCRIPT" "$CODEQL_BIN" "$WORK_ROOT" "$TARGET" "$SOURCE_ROOT" >/tmp/bench-cold.log 2>&1
end_ms=$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)
COLD_MS=$((end_ms - start_ms))
cp -R "$WORK_ROOT/final-db" "$COLD_DB"

start_ms=$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)
REUSE_EXISTING_CACHE=true sh "$CREATE_DB_SCRIPT" "$CODEQL_BIN" "$WORK_ROOT" "$TARGET" "$SOURCE_ROOT" >/tmp/bench-warm.log 2>&1
end_ms=$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)
WARM_MS=$((end_ms - start_ms))
cp -R "$WORK_ROOT/final-db" "$WARM_DB"

"$CODEQL_BIN" database analyze "$COLD_DB" "$QUERY_SUITE" --format=sarifv2.1.0 --output="$COLD_SARIF" >/tmp/bench-analyze-cold.log 2>&1
"$CODEQL_BIN" database analyze "$WARM_DB" "$QUERY_SUITE" --format=sarifv2.1.0 --output="$WARM_SARIF" >/tmp/bench-analyze-warm.log 2>&1

python3 - "$COLD_SARIF" "$COLD_FINDINGS" <<'PY'
import json, sys
sarif = json.load(open(sys.argv[1]))
rows = []
for run in sarif.get('runs', []):
    for result in run.get('results', []):
        rows.append({
            'ruleId': result.get('ruleId', ''),
            'message': result.get('message', {}).get('text', ''),
            'locations': result.get('locations', []),
        })
rows.sort(key=lambda r: (r['ruleId'], r['message'], json.dumps(r['locations'], sort_keys=True)))
json.dump(rows, open(sys.argv[2], 'w'), indent=2, sort_keys=True)
PY
python3 - "$WARM_SARIF" "$WARM_FINDINGS" <<'PY'
import json, sys
sarif = json.load(open(sys.argv[1]))
rows = []
for run in sarif.get('runs', []):
    for result in run.get('results', []):
        rows.append({
            'ruleId': result.get('ruleId', ''),
            'message': result.get('message', {}).get('text', ''),
            'locations': result.get('locations', []),
        })
rows.sort(key=lambda r: (r['ruleId'], r['message'], json.dumps(r['locations'], sort_keys=True)))
json.dump(rows, open(sys.argv[2], 'w'), indent=2, sort_keys=True)
PY

FINDINGS_EQUAL=$(python3 - "$COLD_FINDINGS" "$WARM_FINDINGS" <<'PY'
import json, sys
print('yes' if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 'no')
PY
)
YA_CACHE_BYTES=$(python3 - "$WORK_ROOT/ya-cache" <<'PY'
import os, sys
size = 0
for root, dirs, files in os.walk(sys.argv[1]):
    for name in files:
        try:
            size += os.path.getsize(os.path.join(root, name))
        except OSError:
            pass
print(size)
PY
)
FRAGMENT_CACHE_BYTES=$(python3 - "$WORK_ROOT/fragment-cache" <<'PY'
import os, sys
size = 0
for root, dirs, files in os.walk(sys.argv[1]):
    for name in files:
        try:
            size += os.path.getsize(os.path.join(root, name))
        except OSError:
            pass
print(size)
PY
)

{
  echo "target=$TARGET"
  echo "source_root=$SOURCE_ROOT"
  echo "query_suite=$QUERY_SUITE"
  echo "cold_db_ms=$COLD_MS"
  echo "warm_db_ms=$WARM_MS"
  echo "ya_cache_bytes=$YA_CACHE_BYTES"
  echo "fragment_cache_bytes=$FRAGMENT_CACHE_BYTES"
  echo "findings_equal=$FINDINGS_EQUAL"
  echo "cold_db=$COLD_DB"
  echo "warm_db=$WARM_DB"
} | tee "$SUMMARY_TXT"
