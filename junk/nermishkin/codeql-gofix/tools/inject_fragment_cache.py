#!/usr/bin/env python3
import argparse
import json
import shutil
from pathlib import Path


def load_json(path: Path) -> dict:
    with path.open() as fh:
        return json.load(fh)


def load_manifests(registry_dir: Path) -> list[dict]:
    manifests = []
    if not registry_dir.exists():
        return manifests
    for path in sorted(registry_dir.glob('*.json')):
        with path.open() as fh:
            manifests.append(json.load(fh))
    return manifests


def copy_rel(src_root: Path, dst_root: Path, rel_path: str, copied: list[str]) -> None:
    src = src_root / rel_path
    if not src.exists():
        return
    dst = dst_root / rel_path
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    copied.append(rel_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Inject cached CodeQL fragments using ya-emitted node manifests only.')
    parser.add_argument('--cache-root', required=True)
    parser.add_argument('--executed-registry-dir', required=True)
    parser.add_argument('--to-trap-root', required=True)
    parser.add_argument('--output', default='-')
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    cache_root = Path(args.cache_root)
    cache_index = load_json(cache_root / 'index.json')
    executed_manifests = load_manifests(Path(args.executed_registry_dir))
    dst_root = Path(args.to_trap_root)
    src_root = cache_root / 'trap' / 'go'

    executed_module_paths = {m.get('module_path') for m in executed_manifests if m.get('module_path')}
    executed_import_paths = {m.get('import_path') for m in executed_manifests if m.get('import_path')}

    copied: list[str] = []
    matched_nodes = []

    for node in cache_index.get('nodes', []):
        if node.get('module_path') in executed_module_paths:
            continue
        if node.get('import_path') in executed_import_paths:
            continue
        matched_nodes.append(
            {
                'module_path': node.get('module_path'),
                'import_path': node.get('import_path'),
                'matched_by': 'cache-minus-executed',
            }
        )
        for rel_path in node.get('traps', []):
            copy_rel(src_root, dst_root, rel_path, copied)

    result = {
        'cache_root': str(cache_root),
        'executed_registry_dir': args.executed_registry_dir,
        'matched_node_count': len(matched_nodes),
        'copied_count': len(copied),
        'matched_nodes': matched_nodes,
    }
    payload = json.dumps(result, indent=2, sort_keys=True)
    if args.output == '-':
        print(payload)
    else:
        Path(args.output).write_text(payload + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
