#!/bin/sh
set -eu

EXTRACT_VENDOR_DIRS=false
if [ "${1:-}" = "--extract-vendor-dirs" ]; then
  EXTRACT_VENDOR_DIRS=true
  shift
fi

if [ "$#" -lt 3 ]; then
  echo "usage: $0 [--extract-vendor-dirs] <codeql-bin> <database-dir> <ya-target> [extra database create args ...]" >&2
  exit 2
fi

CODEQL_BIN="$1"
DATABASE_DIR="$2"
TARGET="$3"
shift 3

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
find_repo_root() {
  dir="$1"
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
WRAPPER="$SCRIPT_DIR/ya_codeql_wrapper.sh"

if [ "$EXTRACT_VENDOR_DIRS" = true ]; then
  export CODEQL_EXTRACTOR_GO_OPTION_EXTRACT_VENDOR_DIRS=true
fi

: "${CODEQL_EXTRACTOR_GO_EXTRACT_HTML:=no}"
export CODEQL_EXTRACTOR_GO_EXTRACT_HTML

"$CODEQL_BIN" database create "$DATABASE_DIR"   --language=go   --source-root="$REPO_ROOT"   --no-calculate-baseline   --command "$WRAPPER $TARGET"   "$@"
