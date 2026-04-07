#!/bin/sh
set -eu

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <codeql-bin> <database> <output-csv> [query-file] [extra query run args ...]" >&2
  exit 2
fi

CODEQL_BIN="$1"
DATABASE="$2"
OUTPUT_CSV="$3"
shift 3

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
QUERY_FILE=${1:-$SCRIPT_DIR/queries/enriched_callgraph.ql}
if [ "$#" -gt 0 ]; then
  shift
fi
QUERY_DIR=$(dirname -- "$QUERY_FILE")
TMP_BQRS=$(mktemp /tmp/codeql-callgraph.XXXXXX.bqrs)
trap 'rm -f "$TMP_BQRS"' EXIT
mkdir -p "$(dirname -- "$OUTPUT_CSV")"

"$CODEQL_BIN" query run "$QUERY_FILE"   --database "$DATABASE"   --search-path "$QUERY_DIR"   --output "$TMP_BQRS"   "$@"
"$CODEQL_BIN" bqrs decode "$TMP_BQRS" --format=csv > "$OUTPUT_CSV"

echo "Generated callgraph CSV at $OUTPUT_CSV"
