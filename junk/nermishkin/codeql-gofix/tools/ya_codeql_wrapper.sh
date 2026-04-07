#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <ya-target>" >&2
  exit 2
fi

TARGET="$1"
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
YA_BIN=${YA_BIN:-$REPO_ROOT/ya}
OUTDIR=$(mktemp -d /tmp/ya-codeql-out.XXXXXX)

cleanup() {
  rm -rf "$OUTDIR"
}
trap cleanup EXIT

cd "$REPO_ROOT"
"$YA_BIN" make -r --clear --rebuild -o "$OUTDIR" "$TARGET"
