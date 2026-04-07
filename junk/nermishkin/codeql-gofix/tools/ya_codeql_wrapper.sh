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
export REPO_ROOT
YA_BIN=${YA_BIN:-$REPO_ROOT/ya}
ENV_SNAPSHOT="$REPO_ROOT/.codeql-go-env.json"
OUTDIR=$(mktemp -d /tmp/ya-codeql-out.XXXXXX)
COPIED_LIST=$(mktemp /tmp/codeql-go-copied.XXXXXX)

python3 - <<'PY2'
import json
import os
from pathlib import Path
repo_root = Path(os.environ['REPO_ROOT'])
snapshot = {k: v for k, v in os.environ.items() if k.startswith(("CODEQL_", "SEMMLE_", "LGTM_"))}
(repo_root / '.codeql-go-env.json').write_text(json.dumps(snapshot))
PY2

cd "$REPO_ROOT"
"$YA_BIN" make -r --replace-result --add-result=.go   --no-output-for=.cgo1.go   --no-output-for=.res.go   --no-output-for=_cgo_gotypes.go   --no-output-for=_cgo_import.go   "$TARGET" >/tmp/codeql-precodegen.log 2>&1 || true

find "$TARGET" -type l -name '*.go' | while read -r path; do
  real=$(readlink -f "$path")
  rm "$path"
  cp "$real" "$path"
  printf '%s\n' "$path" >> "$COPIED_LIST"
done

cleanup() {
  rm -f "$ENV_SNAPSHOT"
  if [ -f "$COPIED_LIST" ]; then
    while IFS= read -r path; do
      rm -f "$path"
    done < "$COPIED_LIST"
    rm -f "$COPIED_LIST"
  fi
  rm -rf "$OUTDIR"
}
trap cleanup EXIT

"$YA_BIN" make -r --clear --rebuild -o "$OUTDIR" "$TARGET"
