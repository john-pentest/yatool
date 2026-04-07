#!/bin/sh
set -eu

if [ "$#" -lt 4 ]; then
  echo "usage: $0 <codeql-bin> <database> <query-or-suite> <output-sarif> [extra analyze args ...]" >&2
  exit 2
fi

CODEQL_BIN="$1"
DATABASE="$2"
QUERY_OR_SUITE="$3"
OUTPUT_SARIF="$4"
shift 4

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$(dirname -- "$OUTPUT_SARIF")"

"$CODEQL_BIN" database analyze   "$DATABASE"   "$QUERY_OR_SUITE"   --format=sarifv2.1.0   --output="$OUTPUT_SARIF"   "$@"


echo "Generated SARIF at $OUTPUT_SARIF"
