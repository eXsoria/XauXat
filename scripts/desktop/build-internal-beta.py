#!/usr/bin/env python3
"""Build the fork's native core/JNI in an ephemeral CI checkout, never a user profile."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / '.desktop-beta-build'
MULTI = ROOT / 'apps/multiplatform'
SYSTEM = platform.system()
WINDOWS = SYSTEM == 'Windows'
MAC = SYSTEM == 'Darwin'
ARCH = 'aarch64' if platform.machine().lower() in ('arm64', 'aarch64') else 'x86_64'
OS = 'windows' if WINDOWS else 'mac' if MAC else 'linux'
EXT = 'dll' if WINDOWS else 'dylib' if MAC else 'so'
LIBS = MULTI / f'common/src/commonMain/cpp/desktop/libs/{OS}-{ARCH}'
LINK = MULTI / ('build/links/' + ('macos' if MAC else OS) + ('-arm64' if ARCH == 'aarch64' else '-x64'))
OPENSSL_VERSION = '3.5.9'
OPENSSL_HASH = '603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a'
VLC_HASHES = {
    'linux-x86_64': '594fc3a603167a977cc0de519e1d5f785037df0db60c57518f88e46606d5bb98',
    'mac-aarch64': 'ee537e339b4b40546dc9374db4a2e74eeb46d4b76fb7f23b201e7beb144decb8',
    'mac-x86_64': 'a4a782b8d2f5475ae7a7dda84a2ba4989d415cd4c0a7d19c68e75a90920a0d6b',
    'windows-x86_64': '09993fc4e6bf8239cf847f943ae593dd62ba9abbe5f2f18c42bfca1bc9e94443',
}


def run(*args, cwd=ROOT, capture=False, env=None):
    print('+', ' '.join(str(a) for a in args), flush=True)
    return subprocess.run([str(a) for a in args], cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None, env=env).stdout


def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def download(url, sha):
    path = WORK / url.rsplit('/', 1)[1]
    if not path.exists() or digest(path) != sha:
        with urllib.request.urlopen(url, timeout=120) as response, path.open('wb') as f:
            shutil.copyfileobj(response, f)
    if digest(path) != sha:
        raise RuntimeError(f'Checksum mismatch: {path.name}')
    return path


def inside(path, parent):
    if not path.resolve().is_relative_to(parent.resolve()) or path.resolve() == parent.resolve():
        raise RuntimeError(f'Path outside the dedicated build directory: {path}')


def extract(archive, target):
    inside(target, WORK)
    target.mkdir(parents=True, exist_ok=True)
    if archive.suffix == '.zip':
        with zipfile.ZipFile(archive) as z:
            for info in z.infolist():
                inside(target / info.filename, target)
                # VLC ZIPs contain ordinary files/directories; refuse symlinks.
                if (info.external_attr >> 16) & 0o170000 == 0o120000:
                    raise RuntimeError('Unexpected ZIP symlink')
            z.extractall(target)
            if not WINDOWS:
                for info in z.infolist():
                    if info.external_attr >> 16 & 0o111:
                        (target / info.filename).chmod(0o755)
    else:
        with tarfile.open(archive) as t:
            t.extractall(target, filter='data')


def build_openssl():
    prefix = WORK / 'openssl'
    target = 'mingw64' if WINDOWS else ('darwin64-arm64-cc' if ARCH == 'aarch64' else 'darwin64-x86_64-cc') if MAC else 'linux-x86_64'
    inputs = {
        'source_sha256': OPENSSL_HASH, 'target': target,
        'compiler': run('gcc' if WINDOWS else 'cc', '--version', capture=True).splitlines()[0],
        'prefix': prefix.as_posix(), 'options': ['shared', 'no-tests', '--libdir=lib'],
        'sdk': os.environ.get('SDKROOT') if MAC else None,
        'deployment': os.environ.get('MACOSX_DEPLOYMENT_TARGET') if MAC else None,
    }
    manifest = prefix / 'XAUXAT-OPENSSL-BUILD.json'
    if manifest.is_file():
        try:
            cached = json.loads(manifest.read_text(encoding='utf-8'))
            files = {p.relative_to(prefix).as_posix(): p for p in prefix.rglob('*') if p.is_file() and p != manifest}
            if cached['inputs'] == inputs and files.keys() == cached['files'].keys() and all(digest(p) == cached['files'][name] for name, p in files.items()):
                print('Verified cached OpenSSL build inputs and every installed file digest.', flush=True)
                return prefix
        except (ValueError, KeyError, OSError):
            pass
    if prefix.exists():
        # Only a checked build-cache directory in this ephemeral checkout is removed.
        inside(prefix, WORK)
        shutil.rmtree(prefix)
    source = WORK / 'openssl-source' / f'openssl-{OPENSSL_VERSION}'
    archive = download(f'https://github.com/openssl/openssl/releases/download/openssl-{OPENSSL_VERSION}/openssl-{OPENSSL_VERSION}.tar.gz', OPENSSL_HASH)
    if not source.exists():
        extract(archive, source.parent)
    run('perl', 'Configure', target, 'shared', 'no-tests', '--libdir=lib', f'--prefix={prefix.as_posix()}', cwd=source)
    run('make', '-j2', cwd=source)
    run('make', 'install_sw', cwd=source)
    copy_file(source / 'LICENSE.txt', prefix / 'LICENSE.txt')
    files = {p.relative_to(prefix).as_posix(): digest(p) for p in prefix.rglob('*') if p.is_file()}
    manifest.write_text(json.dumps({'inputs': inputs, 'files': files}, indent=2) + '\n', encoding='utf-8')
    return prefix


def copy_file(source, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, dest)
    dest.chmod(0o755)


def configure_mac_sdk():
    # GHC's bindist can retain absolute CLT SDK paths. The runner's CLT SDK may
    # be newer than its selected Xcode/linker (e.g. SDK 27 versus Xcode 26).
    # Retarget only this ephemeral compiler's text configuration, restoring it later.
    xcodes = []
    for app in Path('/Applications').glob('Xcode_26*.app'):
        match = re.fullmatch(r'Xcode_(26(?:\.\d+)+)\.app', app.name)
        if match:
            xcodes.append((tuple(map(int, match[1].split('.'))), app))
    if xcodes:
        os.environ['DEVELOPER_DIR'] = str(max(xcodes)[1] / 'Contents/Developer')
    sdk = run('xcrun', '--sdk', 'macosx', '--show-sdk-path', capture=True).strip()
    if not Path(sdk).is_dir():
        raise RuntimeError(f'Missing selected macOS SDK: {sdk}')
    os.environ['SDKROOT'] = sdk
    os.environ['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
    libdir = Path(run('ghc', '--print-libdir', capture=True).strip())
    package_db = Path(run('ghc', '--print-global-package-db', capture=True).strip())
    originals = {}
    for path in [libdir / 'settings', *package_db.glob('*.conf')]:
        original = path.read_bytes()
        updated = re.sub(rb'/Library/Developer/CommandLineTools/SDKs/MacOSX[^/\s"\\]*\.sdk', sdk.encode(), original)
        if updated != original:
            originals[path] = original
            path.write_bytes(updated)
            print(f'Retargeted GHC SDK reference: {path.name}', flush=True)
    if originals:
        run('ghc-pkg', 'recache', '--global')
    return originals


def mac_dependencies(entry, ghc_libdir):
    """Relocate the full non-system dylib closure, without retaining runner paths."""
    search = {}
    for base in (ghc_libdir, WORK / 'openssl'):
        for p in base.rglob('*.dylib'):
            search[p.name] = p
    queue, processed = [entry], set()
    while queue:
        src = queue.pop()
        if src.name in processed:
            continue
        processed.add(src.name)
        dest = LIBS / src.name
        if src.resolve() != dest.resolve():
            copy_file(src, dest)
        source_commands = run('otool', '-l', src, capture=True)
        source_rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', source_commands)
        deps = [line.strip().split(' (', 1)[0] for line in run('otool', '-L', src, capture=True).splitlines()[1:]]
        for dep in deps:
            if dep.startswith(('/usr/lib/', '/System/Library/')) or Path(dep).name == src.name:
                continue
            name = Path(dep).name
            candidate = Path(dep.replace('@loader_path', str(src.parent)))
            if dep.startswith('@rpath/'):
                # Hackage libraries are in Cabal's store, separate from GHC's runtime.
                for rpath in source_rpaths:
                    resolved = Path(rpath.replace('@loader_path', str(src.parent))) / dep.removeprefix('@rpath/')
                    if resolved.is_file():
                        candidate = resolved
                        break
            if not candidate.is_file():
                candidate = search.get(name)
            if candidate is None or not candidate.is_file():
                raise RuntimeError(f'Cannot resolve {dep} required by {src}')
            run('install_name_tool', '-change', dep, f'@rpath/{name}', dest)
            queue.append(candidate)
        run('install_name_tool', '-id', f'@rpath/{dest.name}', dest)
        commands = run('otool', '-l', dest, capture=True)
        rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands)
        for rpath in rpaths:
            if not rpath.startswith('@'):
                run('install_name_tool', '-delete_rpath', rpath, dest)
        if '@loader_path' not in rpaths:
            run('install_name_tool', '-add_rpath', '@loader_path', dest)
        run('codesign', '--force', '--sign', '-', dest)


def linux_dependencies(entry):
    queue, processed = [entry], set()
    system = re.compile(r'^(ld-linux|lib(c|m|dl|pthread|rt|resolv|util)\.so)')
    while queue:
        src = queue.pop()
        if src.name in processed:
            continue
        processed.add(src.name)
        dest = LIBS / src.name
        if src.resolve() != dest.resolve():
            copy_file(src, dest)
        result = run('ldd', src, capture=True)
        if 'not found' in result:
            raise RuntimeError(f'Unresolved runtime dependency: {result}')
        for name, path in re.findall(r'\s+(\S+) => (/\S+)', result):
            if not system.match(name):
                queue.append(Path(path))
        run('patchelf', '--set-rpath', '$ORIGIN', dest)


def build_core(openssl):
    ghc = run('ghc', '--numeric-version', capture=True).strip()
    if ghc != '9.6.3':
        raise RuntimeError(f'This build requires GHC 9.6.3, got {ghc}')
    ghc_libdir = Path(run('ghc', '--print-libdir', capture=True).strip())
    path = lambda p: str(p).replace('\\', '/')
    config = f'''ignore-project: False
package *
  extra-include-dirs: {path(openssl / 'include')}
  extra-lib-dirs: {path(openssl / 'lib')}
package direct-sqlcipher
  flags: +openssl
'''
    args = ['cabal', 'build', 'lib:simplex-chat', '-j2', '--constraint=simplexmq +client_library', '--constraint=simplex-chat +client_library']
    if WINDOWS:
        # Installed OpenSSL import library is lib/libcrypto.dll.a; its runtime DLL is in bin.
        config += f'package simplex-chat\n  ghc-options: -shared -threaded -optl-L{path(openssl / "lib")} -optl-lcrypto -o libsimplex.dll libsimplex.dll.def\n'
    elif MAC:
        args += [f'--ghc-options=-optl-Wl,-rpath,@loader_path -optl-Wl,-install_name,@rpath/libsimplex.dylib -optl-Wl,-L{ghc_libdir}/{ARCH}-osx-ghc-{ghc} -optl-lHSrts_thr-ghc{ghc} -optl-lffi']
    else:
        args += ['--ghc-options=-optl-Wl,-rpath,$ORIGIN -optl-Wl,-soname,libsimplex.so -flink-rts -threaded']
    project = ROOT / 'cabal.project.xauxat-desktop' if WINDOWS else None
    local = ROOT / ('cabal.project.xauxat-desktop.local' if WINDOWS else 'cabal.project.local')
    if local.exists() or (project is not None and project.exists()):
        raise RuntimeError('Refusing to overwrite an existing cabal.project.local')
    if project is not None:
        patch = ROOT / 'scripts/desktop/patch-windows-remote-peer.py'
        original = (ROOT / 'cabal.project').read_text(encoding='utf-8')
        pin = '    tag: efaad8e73436d60f5052f07dda6b71151ad5039b\n'
        if original.count(pin) != 1:
            raise RuntimeError('Expected the reviewed MQ revision in cabal.project')
        hook = f'    post-checkout-command: "{path(sys.executable)}" "{path(patch)}" {digest(patch)}\n'
        project.write_text(original.replace(pin, pin + hook), encoding='utf-8')
        args += [f'--project-file={project.name}']
    local.write_text(config, encoding='utf-8')
    settings = ghc_libdir / 'settings'
    original = settings.read_bytes() if WINDOWS else None
    env = dict(os.environ)
    env['LD_LIBRARY_PATH'] = str(openssl / 'lib') + os.pathsep + env.get('LD_LIBRARY_PATH', '')
    env['PKG_CONFIG_PATH'] = str(openssl / 'lib/pkgconfig') + os.pathsep + env.get('PKG_CONFIG_PATH', '')
    try:
        if WINDOWS:
            # GHC 9.6.3 upstream DLL export workaround, ephemeral runner only; always restore.
            settings.write_bytes(original.replace(b'ld.lld.exe', b'xauxat-use-system-linker.exe'))
        run(*args, env=env)
    finally:
        if original is not None:
            settings.write_bytes(original)
        local.unlink()
        if project is not None:
            project.unlink()
    LIBS.mkdir(parents=True, exist_ok=True)
    if WINDOWS:
        copy_file(ROOT / 'libsimplex.dll', LIBS / 'libsimplex.dll')
        copy_file(openssl / 'bin/libcrypto-3-x64.dll', LIBS / 'libcrypto-3-x64.dll')
    else:
        candidates = list((ROOT / 'dist-newstyle/build').glob(f'*/ghc-{ghc}/simplex-chat-*/build/libHSsimplex-chat-*-inplace-ghc{ghc}.{EXT}'))
        if len(candidates) != 1:
            raise RuntimeError(f'Expected one fork-native core, got {candidates}')
        core = LIBS / f'libsimplex.{EXT}'
        copy_file(candidates[0], core)
        if MAC:
            mac_dependencies(core, ghc_libdir)
        else:
            os.environ['LD_LIBRARY_PATH'] = env['LD_LIBRARY_PATH']
            linux_dependencies(core)


def cached_core(openssl):
    source = hashlib.sha256()
    source.update(run('git', 'rev-parse', 'HEAD:src', capture=True).strip().encode())
    for name in ('cabal.project', 'simplex-chat.cabal', 'libsimplex.dll.def', 'scripts/desktop/build-internal-beta.py', 'scripts/desktop/patch-windows-remote-peer.py'):
        source.update(name.encode())
        source.update((ROOT / name).read_bytes())
    inputs = {
        'source_sha256': source.hexdigest(), 'target': f'{OS}-{ARCH}',
        'ghc': run('ghc', '--numeric-version', capture=True).strip(),
        'cabal': run('cabal', '--numeric-version', capture=True).strip(),
        'compiler': run('gcc' if WINDOWS else 'cc', '--version', capture=True).splitlines()[0],
        'openssl_sha256': OPENSSL_HASH, 'sdk': os.environ.get('SDKROOT') if MAC else None,
        'deployment': os.environ.get('MACOSX_DEPLOYMENT_TARGET') if MAC else None,
    }
    cache = WORK / 'core'
    manifest = cache / 'BUILD.json'
    if manifest.is_file():
        try:
            saved = json.loads(manifest.read_text(encoding='utf-8'))
            files = saved['files']
            valid = saved['inputs'] == inputs and f'libsimplex.{EXT}' in files
            valid = valid and all(Path(n).name == n and (cache / n).is_file() and digest(cache / n) == sha for n, sha in files.items())
            if valid:
                LIBS.mkdir(parents=True, exist_ok=True)
                for name in files:
                    copy_file(cache / name, LIBS / name)
                print('Verified native core source/toolchain inputs and every cached runtime file.', flush=True)
                return saved
        except (ValueError, KeyError, OSError):
            pass
    build_core(openssl)
    if cache.exists():
        inside(cache, WORK)
        shutil.rmtree(cache)
    cache.mkdir()
    files = {}
    for path in LIBS.iterdir():
        if path.is_file():
            copy_file(path, cache / path.name)
            files[path.name] = digest(path)
    saved = {'inputs': inputs, 'files': files, 'producer_commit': run('git', 'rev-parse', 'HEAD', capture=True).strip()}
    manifest.write_text(json.dumps(saved, indent=2) + '\n', encoding='utf-8')
    return saved


def prepare_vlc():
    key = f'{OS}-{ARCH}'
    name = f'vlc-{"macos" if MAC else "win" if WINDOWS else "linux"}-{ARCH}.{"appimage" if OS == "linux" else "zip"}'
    archive = download(f'https://github.com/simplex-chat/vlc/releases/download/v3.0.23-2/{name}', VLC_HASHES[key])
    target = WORK / 'vlc'
    target.mkdir(exist_ok=True)
    dest = LIBS / 'vlc'
    dest.mkdir(exist_ok=True)
    if not MAC and not WINDOWS:
        archive.chmod(0o755)
        run(archive, '--appimage-extract', cwd=target)
        shutil.copytree(target / 'squashfs-root/usr/lib', dest, dirs_exist_ok=True, symlinks=True)
    else:
        extract(archive, target)
        if WINDOWS:
            root = next(target.glob('vlc-*'))
            for dll in root.glob('*.dll'):
                copy_file(dll, dest / dll.name)
        else:
            root = target / 'VLC.app/Contents/MacOS'
            for dylib in (root / 'lib').glob('*'):
                if dylib.is_file():
                    copy_file(dylib, dest / dylib.name)
            # Retain the upstream relative VLC layout for plugins.
        shutil.copytree(root / 'plugins', dest / 'vlc/plugins', dirs_exist_ok=True)
        if MAC:
            for lib in dest.rglob('*.dylib'):
                rpath = '@loader_path' if lib.parent == dest else '@loader_path/../../'
                commands = run('otool', '-l', lib, capture=True)
                if f'path {rpath} (offset' not in commands:
                    run('install_name_tool', '-add_rpath', rpath, lib)
                run('codesign', '--force', '--sign', '-', lib)
    license_file = download('https://github.com/simplex-chat/vlc/releases/download/v3.0.23-2/COPYING', '8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643')
    copy_file(license_file, dest / 'COPYING')


def build_jni(core_origin):
    build = WORK / 'jni'
    args = ['cmake', '-S', MULTI / 'common/src/commonMain/cpp/desktop', '-B', build, '-DCMAKE_BUILD_TYPE=Release']
    if WINDOWS:
        args += ['-G', 'MinGW Makefiles']
    run(*args)
    run('cmake', '--build', build, '--parallel', '2')
    copy_file(build / f'libapp-lib.{EXT}', LIBS / f'libapp-lib.{EXT}')
    if MAC:
        run('codesign', '--force', '--sign', '-', LIBS / 'libapp-lib.dylib')
    LINK.parent.mkdir(parents=True, exist_ok=True)
    if LINK.exists():
        raise RuntimeError(f'Expected a fresh resource directory: {LINK}')
    shutil.copytree(LIBS, LINK, symlinks=False)
    common = LINK.parent / 'common'
    common.mkdir(exist_ok=True)
    copy_file(ROOT / 'LICENSE', common / 'LICENSE-XauXat-AGPL.txt')
    copy_file(WORK / 'openssl/LICENSE.txt', common / 'LICENSE-OpenSSL-Apache.txt')
    provenance = {
        'commit': run('git', 'rev-parse', 'HEAD', capture=True).strip(),
        'core': 'built from this repository source; not an upstream app binary',
        'native_core_build_commit': core_origin['producer_commit'],
        'native_core_source_sha256': core_origin['inputs']['source_sha256'],
        'simplexmq_commit': 'efaad8e73436d60f5052f07dda6b71151ad5039b',
        'windows_rcp_adjustment_sha256': digest(ROOT / 'scripts/desktop/patch-windows-remote-peer.py') if WINDOWS else None,
        'ghc': '9.6.3', 'openssl': OPENSSL_VERSION, 'openssl_source_sha256': OPENSSL_HASH,
        'vlc': 'v3.0.23-2', 'vlc_archive_sha256': VLC_HASHES[f'{OS}-{ARCH}'],
        'target': f'{OS}-{ARCH}', 'distribution': 'internal beta; unsigned/ad-hoc macOS; not notarized',
        'macos_sdk': Path(os.environ['SDKROOT']).name if MAC else None,
        'macos_deployment_target': os.environ.get('MACOSX_DEPLOYMENT_TARGET') if MAC else None,
        'native_files': {p.name: digest(p) for p in LIBS.iterdir() if p.is_file()},
    }
    (common / 'BUILD-PROVENANCE.json').write_text(json.dumps(provenance, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        raise SystemExit('Run only in an ephemeral GitHub Actions checkout, not on a user workstation.')
    inside(WORK, ROOT)
    WORK.mkdir(exist_ok=True)
    compiler_originals = configure_mac_sdk() if MAC else {}
    try:
        core_origin = cached_core(build_openssl())
        prepare_vlc()
        build_jni(core_origin)
    finally:
        for path, original in compiler_originals.items():
            path.write_bytes(original)
        if compiler_originals:
            run('ghc-pkg', 'recache', '--global')
