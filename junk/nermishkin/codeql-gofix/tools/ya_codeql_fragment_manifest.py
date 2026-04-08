#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def rel_trap_path(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def source_trap_rel(source_root: Path, src_file: str) -> str:
    src_path = Path(src_file)
    if not src_path.is_absolute():
        src_path = source_root / src_path
    return src_path.as_posix().lstrip("/") + ".trap.gz"


def package_trap_candidates(node: dict, repo_import_prefix: str | None) -> list[str]:
    target_props = node.get("target_properties") or {}
    module_dir = target_props.get("module_dir")
    if not module_dir:
        return []

    candidates = [module_dir + ".trap.gz"]
    if repo_import_prefix:
        candidates.insert(0, repo_import_prefix.rstrip("/") + "/" + module_dir + ".trap.gz")
    return candidates


def build_manifest(graph: dict, source_root: Path, trap_root: Path, repo_import_prefix: str | None) -> dict:
    trap_files = {rel_trap_path(path, trap_root): path for path in trap_root.rglob("*.trap.gz")}

    manifest_nodes = []
    for node in graph.get("graph", []):
        kv = node.get("kv") or {}
        target_props = node.get("target_properties") or {}
        if kv.get("p") != "GO":
            continue
        if target_props.get("module_lang") != "go":
            continue

        src_inputs = []
        for item in node.get("inputs") or []:
            if item.startswith("$(SOURCE_ROOT)/") and item.endswith(".go"):
                src_inputs.append(item.replace("$(SOURCE_ROOT)/", "", 1))

        source_traps = []
        for rel_src in sorted(src_inputs):
            rel_trap = source_trap_rel(source_root, rel_src)
            source_traps.append(
                {
                    "source": rel_src,
                    "trap": rel_trap,
                    "present": rel_trap in trap_files,
                }
            )

        pkg_candidates = package_trap_candidates(node, repo_import_prefix)
        pkg_matches = [candidate for candidate in pkg_candidates if candidate in trap_files]

        manifest_nodes.append(
            {
                "uid": node.get("uid"),
                "self_uid": node.get("self_uid"),
                "kind": kv.get("p"),
                "module_dir": target_props.get("module_dir"),
                "module_type": target_props.get("module_type"),
                "outputs": node.get("outputs") or [],
                "source_inputs": sorted(src_inputs),
                "source_traps": source_traps,
                "package_trap_candidates": pkg_candidates,
                "package_traps_found": pkg_matches,
                "complete_source_fragment": bool(source_traps) and all(item["present"] for item in source_traps),
            }
        )

    return {
        "source_root": str(source_root),
        "trap_root": str(trap_root),
        "repo_import_prefix": repo_import_prefix,
        "node_count": len(graph.get("graph", [])),
        "go_node_count": len(manifest_nodes),
        "nodes": manifest_nodes,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a manifest that maps ya GO graph nodes to CodeQL Go TRAP fragments."
    )
    parser.add_argument("--graph-json", required=True)
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--trap-root", required=True)
    parser.add_argument("--repo-import-prefix", default=None)
    parser.add_argument("--output", default="-")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    with open(args.graph_json) as fh:
        graph = json.load(fh)

    manifest = build_manifest(
        graph=graph,
        source_root=Path(args.source_root),
        trap_root=Path(args.trap_root),
        repo_import_prefix=args.repo_import_prefix,
    )

    output = json.dumps(manifest, indent=2, sort_keys=True)
    if args.output == "-":
        print(output)
    else:
        Path(args.output).write_text(output + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
