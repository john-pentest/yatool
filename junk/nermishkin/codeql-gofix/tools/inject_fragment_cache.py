#!/usr/bin/env python3
import argparse
import json
import shutil
from pathlib import Path


def load_json(path: Path) -> dict:
    with path.open() as fh:
        return json.load(fh)


def build_lookup(nodes: list[dict], key: str) -> dict[str, dict]:
    lookup = {}
    for node in nodes:
        value = node.get(key)
        if value:
            lookup[value] = node
    return lookup


def copy_rel(src_root: Path, dst_root: Path, rel_path: str, copied: list[str]) -> None:
    src = src_root / rel_path
    if not src.exists():
        return
    dst = dst_root / rel_path
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    copied.append(rel_path)


def target_needs_fragment(node: dict) -> bool:
    if not node.get("complete_source_fragment"):
        return True
    if not node.get("package_traps_found"):
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Inject cached CodeQL fragment bundles into an unfinalized trap tree.")
    parser.add_argument("--cache-root", required=True)
    parser.add_argument("--target-manifest", required=True)
    parser.add_argument("--to-trap-root", required=True)
    parser.add_argument("--output", default="-")
    args = parser.parse_args()

    cache_root = Path(args.cache_root)
    cache_index = load_json(cache_root / "index.json")
    target_manifest = load_json(Path(args.target_manifest))
    dst_root = Path(args.to_trap_root)
    src_root = cache_root / "trap" / "go"

    by_uid = build_lookup(cache_index.get("nodes", []), "uid")
    by_self_uid = build_lookup(cache_index.get("nodes", []), "self_uid")
    by_module_dir = build_lookup(cache_index.get("nodes", []), "module_dir")

    copied: list[str] = []
    matched_nodes = []

    for rel_path in cache_index.get("compilation_traps", []):
        copy_rel(src_root, dst_root, rel_path, copied)
    for rel_path in cache_index.get("residual_traps", []):
        copy_rel(src_root, dst_root, rel_path, copied)

    target_nodes = target_manifest.get("nodes", [])
    inject_all = len(target_nodes) == 0
    iterable = target_nodes if target_nodes else cache_index.get("nodes", [])
    for node in iterable:
        if not inject_all and not target_needs_fragment(node):
            continue
        if inject_all:
            cached = node
            matched_nodes.append({"module_dir": node.get("module_dir"), "matched_by": "all", "value": node.get("uid")})
        else:
            cached = None
            for key, lookup in (("uid", by_uid), ("self_uid", by_self_uid), ("module_dir", by_module_dir)):
                value = node.get(key)
                if value and value in lookup:
                    cached = lookup[value]
                    matched_nodes.append({"module_dir": node.get("module_dir"), "matched_by": key, "value": value})
                    break
            if not cached:
                continue
        for rel_path in cached.get("package_traps", []):
            copy_rel(src_root, dst_root, rel_path, copied)
        for rel_path in cached.get("source_traps", []):
            copy_rel(src_root, dst_root, rel_path, copied)

    result = {
        "cache_root": str(cache_root),
        "matched_node_count": len(matched_nodes),
        "copied_count": len(copied),
        "matched_nodes": matched_nodes,
    }
    payload = json.dumps(result, indent=2, sort_keys=True)
    if args.output == "-":
        print(payload)
    else:
        Path(args.output).write_text(payload + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
