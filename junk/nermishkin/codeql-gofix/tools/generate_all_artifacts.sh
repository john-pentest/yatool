#!/bin/sh
set -eu

if [ "$#" -ne 6 ]; then
  echo "usage: $0 <codeql-bin> <database> <query-or-suite> <callgraph-csv-output> <sarif-output> <svg-output-dir>" >&2
  exit 2
fi

CODEQL_BIN="$1"
DATABASE="$2"
QUERY_OR_SUITE="$3"
CALLGRAPH_CSV_OUTPUT="$4"
SARIF_OUTPUT="$5"
SVG_OUTPUT_DIR="$6"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$(dirname -- "$CALLGRAPH_CSV_OUTPUT")" "$SVG_OUTPUT_DIR"

"$SCRIPT_DIR/generate_sarif.sh" "$CODEQL_BIN" "$DATABASE" "$QUERY_OR_SUITE" "$SARIF_OUTPUT"
"$SCRIPT_DIR/generate_callgraph_csv.sh" "$CODEQL_BIN" "$DATABASE" "$CALLGRAPH_CSV_OUTPUT"
python3 "$SCRIPT_DIR/render_callgraph_svg.py" "$CALLGRAPH_CSV_OUTPUT" "$SVG_OUTPUT_DIR/$(basename "$CALLGRAPH_CSV_OUTPUT" .csv).svg"

echo "Generated artifacts:"
echo "  SARIF: $SARIF_OUTPUT"
echo "  Callgraph CSV: $CALLGRAPH_CSV_OUTPUT"
echo "  SVG dir: $SVG_OUTPUT_DIR"
