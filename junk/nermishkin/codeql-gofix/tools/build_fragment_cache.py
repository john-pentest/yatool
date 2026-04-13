#!/usr/bin/env python3
import argparse
import json
import shutil
from pathlib import Path


def copy_rel(src_root: Path, dst_root: Path, rel_path: str) -> bool:
    src = src_root / rel_path
    if not src.exists():
        return False
    dst = dst_root / rel_path
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return True


def load_manifests(registry_dir: Path) -> list[dict]:
    manifests = []
    if not registry_dir.exists():
        return manifests
    for path in sorted(registry_dir.glob('*.json')):
        with path.open() as fh:
            manifests.append(json.load(fh))
    return manifests


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Materialize a CodeQL fragment cache from ya-emitted node manifests.')
    parser.add_argument('--registry-dir', required=True)
    parser.add_argument('--trap-root', required=True)
    parser.add_argument('--cache-root', required=True)
    parser.add_argument('--output', default='-')
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    registry_dir = Path(args.registry_dir)
    trap_root = Path(args.trap_root)
    cache_root = Path(args.cache_root)
    cache_trap_root = cache_root / 'trap' / 'go'
    cache_trap_root.mkdir(parents=True, exist_ok=True)

    manifests = load_manifests(registry_dir)
    nodes = []
    copied = []

    for manifest in manifests:
        traps = []
        for rel_path in manifest.get('traps', []):
            if copy_rel(trap_root, cache_trap_root, rel_path):
                traps.append(rel_path)
                copied.append(rel_path)
        nodes.append(
            {
                'module_path': manifest.get('module_path'),
                'import_path': manifest.get('import_path'),
                'pattern': manifest.get('pattern'),
                'mode': manifest.get('mode'),
                'output': manifest.get('output'),
                'traps': traps,
            }
        )

    index = {
        'registry_dir': str(registry_dir),
        'trap_root': str(trap_root),
        'node_count': len(nodes),
        'nodes': nodes,
    }
    (cache_root / 'index.json').write_text(json.dumps(index, indent=2, sort_keys=True) + '\n')

    result = {
        'cache_root': str(cache_root),
        'node_count': len(nodes),
        'copied_count': len(copied),
    }
    payload = json.dumps(result, indent=2, sort_keys=True)
    if args.output == '-':
        print(payload)
    else:
        Path(args.output).write_text(payload + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
