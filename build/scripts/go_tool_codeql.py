import hashlib
import json
import os
import shutil
import sys

CODEQL_BUILD_FLAGS = {
    '-a',
    '-asan',
    '-asmflags',
    '-buildmode',
    '-compiler',
    '-gcflags',
    '-mod',
    '-modfile',
    '-msan',
    '-overlay',
    '-p',
    '-pkgdir',
    '-tags',
    '-toolexec',
    '-trimpath',
    '-v',
    '-work',
    '-x',
}
CODEQL_BUILD_FLAGS_WITH_VALUE = {
    '-asmflags',
    '-buildmode',
    '-compiler',
    '-gcflags',
    '-mod',
    '-modfile',
    '-overlay',
    '-p',
    '-pkgdir',
    '-tags',
    '-toolexec',
}
CODEQL_ENV_SNAPSHOT = '.codeql-go-env.json'
CODEQL_ENV_PREFIXES = ('CODEQL_', 'SEMMLE_', 'LGTM_')


def _get_env_snapshot_path(args):
    return os.path.join(args.source_root, CODEQL_ENV_SNAPSHOT)


def _load_env_snapshot(args):
    path = _get_env_snapshot_path(args)
    if not os.path.isfile(path):
        return {}
    with open(path) as snapshot_file:
        data = json.load(snapshot_file)
    return {str(key): str(value) for key, value in data.items()}


def _get_runtime_env(args):
    env = os.environ.copy()
    for key, value in _load_env_snapshot(args).items():
        env.setdefault(key, value)
    return env


def _get_extractor_root(args):
    return _get_runtime_env(args).get('CODEQL_EXTRACTOR_GO_ROOT')


def _enabled(args):
    if not _get_extractor_root(args):
        return False
    return not args.is_std


def _get_tools_subdir():
    if sys.platform.startswith('linux'):
        return 'linux64'
    if sys.platform == 'darwin':
        return 'osx64'
    if sys.platform in ('win32', 'cygwin'):
        return 'win64'
    raise RuntimeError('Unsupported platform for CodeQL extractor: {}'.format(sys.platform))


def _get_extractor_path(args):
    root = _get_extractor_root(args)
    if not root:
        return None
    extractor = os.path.join(root, 'tools', _get_tools_subdir(), 'go-extractor')
    if sys.platform in ('win32', 'cygwin'):
        extractor += '.exe'
    return extractor


def _get_pattern(args):
    return args.test_import_path or args.import_path


def _get_pkg_root(args, gopath_root):
    return os.path.join(gopath_root, 'src', _get_pattern(args))


def _symlink_tree_entry(src, dst):
    if not os.path.exists(src):
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.lexists(dst):
        if os.path.islink(dst) or os.path.isfile(dst):
            os.unlink(dst)
        else:
            shutil.rmtree(dst)
    os.symlink(src, dst)


def _link_source_roots(args, gopath_root, arc_project_prefix, vendor_prefix):
    _symlink_tree_entry(args.source_root, os.path.join(gopath_root, 'src', arc_project_prefix.rstrip('/')))

    vendor_root = os.path.join(args.source_root, vendor_prefix.rstrip('/'))
    if os.path.isdir(vendor_root):
        for entry in os.listdir(vendor_root):
            _symlink_tree_entry(os.path.join(vendor_root, entry), os.path.join(gopath_root, 'src', entry))


def _get_virtual_src(gopath_root, relpath, get_import_path):
    import_path, is_std = get_import_path(os.path.dirname(relpath))
    if is_std:
        return None
    return os.path.join(gopath_root, 'src', import_path, os.path.basename(relpath))


def _get_materialized_src(args, relpath, get_import_path):
    import_path, is_std = get_import_path(os.path.dirname(relpath))
    if is_std:
        return None
    return os.path.join(args.source_root, relpath)


def _iter_generated_go_files(args):
    seen = set()
    go_files = list(args.go_srcs)
    if args.mode == 'test' and args.xtest_srcs:
        go_files.extend(args.xtest_srcs)

    for src in go_files:
        abs_src = os.path.abspath(src)
        if not abs_src.startswith(args.build_root_dir) or abs_src in seen:
            continue
        seen.add(abs_src)
        yield abs_src


def _materialize_generated_sources(args, get_import_path):
    materialized = {}
    created = []

    for abs_src in _iter_generated_go_files(args):
        rel_src = os.path.relpath(abs_src, args.build_root)
        dst = _get_materialized_src(args, rel_src, get_import_path)
        if not dst or os.path.lexists(dst):
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(abs_src, dst)
        materialized[abs_src] = dst
        created.append(dst)

    return materialized, created


def _cleanup_materialized_sources(source_root, paths):
    for path in sorted(paths, key=len, reverse=True):
        if os.path.lexists(path):
            os.unlink(path)
        parent = os.path.dirname(path)
        while parent.startswith(source_root) and parent != source_root:
            try:
                os.rmdir(parent)
            except OSError:
                break
            parent = os.path.dirname(parent)


def _write_overlay(args, gopath_root, materialized_sources, get_import_path):
    replace = {}
    go_files = list(args.go_srcs)
    if args.mode == 'test' and args.xtest_srcs:
        go_files.extend(args.xtest_srcs)

    for src in go_files:
        abs_src = os.path.abspath(src)
        if abs_src in materialized_sources:
            continue
        if abs_src.startswith(args.build_root_dir):
            rel_src = os.path.relpath(abs_src, args.build_root)
            virtual_src = _get_virtual_src(gopath_root, rel_src, get_import_path)
        else:
            virtual_src = os.path.join(_get_pkg_root(args, gopath_root), os.path.basename(src))
        if not virtual_src:
            continue
        if os.path.abspath(virtual_src) == abs_src:
            continue
        replace[virtual_src] = abs_src

    for abs_src in _iter_generated_go_files(args):
        if abs_src in materialized_sources:
            continue
        rel_src = os.path.relpath(abs_src, args.build_root)
        virtual_src = _get_virtual_src(gopath_root, rel_src, get_import_path)
        if not virtual_src or os.path.abspath(virtual_src) == abs_src:
            continue
        replace.setdefault(virtual_src, abs_src)

    if not replace:
        return None

    overlay_dir = os.path.join(args.output_root, '.codeql')
    os.makedirs(overlay_dir, exist_ok=True)
    digest = hashlib.md5(args.output.encode('utf-8')).hexdigest()
    overlay_path = os.path.join(overlay_dir, '{}.overlay.json'.format(digest))
    with open(overlay_path, 'w') as overlay_file:
        json.dump({'Replace': replace}, overlay_file, indent=2, sort_keys=True)
    return overlay_path


def _link_peer_archives(args, gopath_root, pkg_suffix, get_import_path):
    pkg_root = os.path.join(gopath_root, 'pkg', pkg_suffix)
    peers = list(args.peers or [])
    peers.extend(args.non_local_peers or [])

    for peer in peers:
        src = os.path.join(args.build_root, peer)
        if not os.path.isfile(src):
            continue
        import_path, _ = get_import_path(os.path.dirname(peer))
        dst = os.path.join(pkg_root, import_path + '.a')
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.lexists(dst):
            os.unlink(dst)
        os.symlink(src, dst)


def _prepare_gopath(args, get_import_path, arc_project_prefix, vendor_prefix):
    overlay_root = os.path.join(args.output_root, '.codeql')
    os.makedirs(overlay_root, exist_ok=True)
    digest = hashlib.md5(args.output.encode('utf-8')).hexdigest()
    gopath_root = os.path.join(overlay_root, 'gopath-{}'.format(digest))
    os.makedirs(os.path.join(gopath_root, 'src'), exist_ok=True)
    _link_source_roots(args, gopath_root, arc_project_prefix, vendor_prefix)

    goarch = '386' if args.targ_arch == 'x86' else ('arm' if args.targ_arch in ('armv6', 'armv7') else args.targ_arch)
    pkg_suffix = '{}_{}'.format(args.targ_os, goarch)
    _link_peer_archives(args, gopath_root, pkg_suffix, get_import_path)
    return gopath_root


def _filter_build_flags(flags):
    filtered = []
    i = 0
    while i < len(flags):
        flag = flags[i]
        if flag.startswith('-') and '=' in flag:
            flag_name = flag.split('=', 1)[0]
            if flag_name in CODEQL_BUILD_FLAGS:
                filtered.append(flag)
        elif flag in CODEQL_BUILD_FLAGS:
            filtered.append(flag)
            if flag in CODEQL_BUILD_FLAGS_WITH_VALUE and i + 1 < len(flags):
                filtered.append(flags[i + 1])
                i += 1
        i += 1
    return filtered


def _get_env(args, gopath_root):
    env = _get_runtime_env(args)
    env['PATH'] = os.path.join(args.toolchain_root, 'bin') + os.pathsep + env.get('PATH', '')
    env['GOROOT'] = args.toolchain_root
    env['GOPATH'] = gopath_root
    env['GO111MODULE'] = 'off'
    env['GOOS'] = args.targ_os
    if args.targ_arch == 'x86':
        env['GOARCH'] = '386'
    elif args.targ_arch in ('armv6', 'armv7'):
        env['GOARCH'] = 'arm'
        env['GOARM'] = '6' if args.targ_arch == 'armv6' else '7'
    else:
        env['GOARCH'] = args.targ_arch
    return env


def maybe_run(args, call, get_import_path, arc_project_prefix, vendor_prefix):
    if not _enabled(args):
        return
    extractor = _get_extractor_path(args)
    if not extractor:
        return
    if not os.path.isfile(extractor):
        raise RuntimeError('CodeQL extractor not found: {}'.format(extractor))

    gopath_root = _prepare_gopath(args, get_import_path, arc_project_prefix, vendor_prefix)
    materialized_sources, created_sources = _materialize_generated_sources(args, get_import_path)
    try:
        overlay = _write_overlay(args, gopath_root, materialized_sources, get_import_path)
        cmd = [extractor, '--mimic', 'go', 'test' if args.mode == 'test' else 'build']
        cmd.extend(_filter_build_flags(args.compile_flags or []))
        if overlay:
            cmd.extend(['-overlay', overlay])
        cmd.append(_get_pattern(args))
        env = _get_env(args, gopath_root)
        call(cmd, args.source_root, env=env)
    finally:
        _cleanup_materialized_sources(args.source_root, created_sources)
