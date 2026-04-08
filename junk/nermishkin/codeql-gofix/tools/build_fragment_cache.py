#!/usr/bin/env python3
import argparse
import json
import shutil
from pathlib import Path


def load_manifest(path: Path) -> dict:
    with path.open() as fh:
        return json.load(fh)


def copy_rel(src_root: Path, dst_root: Path, rel_path: str) -> None:
    src = src_root / rel_path
    if not src.exists():
        return
    dst = dst_root / rel_path
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def main() -> int:
    parser = argparse.ArgumentParser(description="Materialize a node-level CodeQL fragment cache from a full TRAP tree.")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--trap-root", required=True)
    parser.add_argument("--cache-root", required=True)
    parser.add_argument("--output", default="-")
    args = parser.parse_args()

    manifest = load_manifest(Path(args.manifest))
    trap_root = Path(args.trap_root)
    cache_root = Path(args.cache_root)
    cache_trap_root = cache_root / "trap" / "go"
    cache_trap_root.mkdir(parents=True, exist_ok=True)

    index_nodes = []
    copied = []
    compilation_traps = []
    claimed = set()
    for node in manifest.get("nodes", []):
        if not node.get("complete_source_fragment"):
            continue
        node_copy = {
            "uid": node.get("uid"),
            "self_uid": node.get("self_uid"),
            "module_dir": node.get("module_dir"),
            "package_traps": list(node.get("package_traps_found", [])),
            "source_traps": [entry["trap"] for entry in node.get("source_traps", []) if entry.get("present")],
        }
        if not node_copy["package_traps"] and not node_copy["source_traps"]:
            continue
        index_nodes.append(node_copy)
        for rel_path in node_copy["package_traps"] + node_copy["source_traps"]:
            copy_rel(trap_root, cache_trap_root, rel_path)
            copied.append(rel_path)
            claimed.add(rel_path)

    comp_root = trap_root / "compilations"
    if comp_root.exists():
        for path in sorted(comp_root.rglob("*.trap.gz")):
            rel_path = path.relative_to(trap_root).as_posix()
            copy_rel(trap_root, cache_trap_root, rel_path)
            compilation_traps.append(rel_path)
            copied.append(rel_path)
            claimed.add(rel_path)

    residual_traps = []
    for path in sorted(trap_root.rglob("*.trap.gz")):
        rel_path = path.relative_to(trap_root).as_posix()
        if rel_path in claimed:
            continue
        copy_rel(trap_root, cache_trap_root, rel_path)
        residual_traps.append(rel_path)
        copied.append(rel_path)

    index = {
        "source_root": manifest.get("source_root"),
        "repo_import_prefix": manifest.get("repo_import_prefix"),
        "node_count": len(index_nodes),
        "compilation_traps": compilation_traps,
        "residual_traps": residual_traps,
        "nodes": index_nodes,
    }
    (cache_root / "index.json").write_text(json.dumps(index, indent=2, sort_keys=True) + "\n")

    result = {
        "cache_root": str(cache_root),
        "node_count": len(index_nodes),
        "copied_count": len(copied),
    }
    payload = json.dumps(result, indent=2, sort_keys=True)
    if args.output == "-":
        print(payload)
    else:
        Path(args.output).write_text(payload + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
