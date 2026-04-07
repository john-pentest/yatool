#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <input-csv-dir> <output-svg-dir>" >&2
  exit 2
fi

INPUT_DIR="$1"
OUTPUT_DIR="$2"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

mkdir -p "$OUTPUT_DIR"

for csv in "$INPUT_DIR"/*.csv; do
  [ -e "$csv" ] || continue
  name=$(basename "$csv" .csv)
  python3 "$SCRIPT_DIR/render_callgraph_svg.py" "$csv" "$OUTPUT_DIR/$name.svg"
done

echo "Generated callgraphs in $OUTPUT_DIR"
