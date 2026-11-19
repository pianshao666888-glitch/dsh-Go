#!/usr/bin/env python3
"""Prepare private OHOS composition inputs from the two existing npm locks.

No hardlink clone or lifecycle scripts. Partial failures are kept for diagnosis.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess

# dsh-purge is not on npm; it ships as a GitHub release tarball.
PURGE_SPEC = ('https://github.com/kingcharleslzy-ai/dsh-purge/releases/download/'
              'v1.7.20/dsh-purge-community-1.7.20.tgz')
SEED_LIANGSHEN_VERSION = '0.4.16'
SEED_DSH_VERSION = '0.2.2-rc.1'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def prefix_files(prefix):
    rows = []
    paths = [prefix / 'package.json', prefix / 'package-lock.json']
    paths.extend(sorted((prefix / 'node_modules').rglob('*')))
    for path in paths:
        relative = path.relative_to(prefix).as_posix()
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            continue
        if stat.S_ISLNK(info.st_mode):
            if '/.bin/' not in '/' + relative and relative != 'node_modules/@deepseek-ai':
                raise ValueError(f'Unexpected installed symlink: {relative}')
            continue  # development-only links are never payload inputs
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError(f'Prepared input is non-regular or shared by hardlink: {relative}')
        if path.name == '.package-lock.json':
            continue  # npm installation cache is not part of a runtime
        data = path.read_bytes()
        rows.append({'path': relative, 'size': len(data), 'sha256': digest(data)})
    return sorted(rows, key=lambda row: row['path'])


def verify_inputs(receipt_path, config, dsh, process):
    receipt = json.loads(receipt_path.read_text())
    if receipt.get('schema') != 1 or receipt.get('installation') != config['installation']:
        raise ValueError('Input installation recipe differs from composition.json')
    if receipt.get('nodeVersion') != config['nodeVersion']:
        raise ValueError('Input preparation used a different Node version')
    for name, prefix in [('dsh', dsh), ('process', process)]:
        actual = prefix_files(prefix)
        if receipt['files'][name] != actual:
            raise ValueError(f'Prepared {name} input bytes/file set changed after its recipe ran')
    return digest(encoded(receipt))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['ohos'], required=True)
    parser.add_argument('--node', type=Path, required=True)
    parser.add_argument('--npm', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--seed-profile', action='store_true',
                        help='also build ~/.dsh/profiles/web with bundled plugins (dsh-purge + liangshen)')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    config = json.loads(Path(__file__).with_name('composition.json').read_text())
    output = args.out.absolute()
    if output.exists() or output.is_relative_to(repo):
        raise ValueError('Use a new input directory outside the repository')
    output.mkdir(parents=True)
    environment = os.environ.copy()
    environment['PATH'] = str(args.node.resolve().parent) + os.pathsep + environment.get('PATH', '')
    commands = []

    def run(name, command, directory):
        result = subprocess.run(command, cwd=directory, env=environment, capture_output=True, text=True)
        (output / (name + '.stdout')).write_text(result.stdout)
        (output / (name + '.stderr')).write_text(result.stderr)
        commands.append({'argv': list(map(str, command)), 'cwd': str(directory), 'exitCode': result.returncode})
        (output / 'commands.json').write_bytes(encoded(commands))
        if result.returncode:
            raise ValueError(f'{name} failed; original stdout/stderr preserved')
        return result.stdout.strip()

    if run('node-version', [str(args.node), '--version'], output) != 'v' + config['nodeVersion']:
        raise ValueError('Node version differs from the fixed composition recipe')
    if run('npm-version', [str(args.npm), '--version'], output) != config['installation']['npmVersion']:
        raise ValueError('npm version differs from the fixed composition recipe')
    for name, source in [('dsh', repo / 'runtime/locks/dsh-0.2.2-rc.1'),
                         ('process', repo / 'runtime/ohos/process')]:
        prefix = output / name
        prefix.mkdir()
        for filename in ('package.json', 'package-lock.json'):
            shutil.copyfile(source / filename, prefix / filename)
        command = [str(args.npm), *config['installation']['arguments'], '--cache', str(args.cache)]
        if args.offline:
            command.append('--offline')
        run(name + '-npm-ci', command, prefix)
    run('ohos-patches', ['python3', '-I', '-B', str(repo / 'runtime/lib/rtbuild.py'), 'patch-dsh',
        '--prefix', str(output / 'dsh'), '--dsh-version', config['dshVersion'], '--target', 'ohos',
        '--out', str(output / 'patch-results.json'), '--target-report', str(output / 'target-report.json')], repo)
    helper = output / 'dsh/node_modules/@dsh-go/ohos-native'
    helper.mkdir(parents=True)
    for filename in ('index.cjs', 'package.json'):
        shutil.copyfile(repo / 'runtime/ohos/native/hap-loader' / filename, helper / filename)
    shutil.copyfile(repo / 'LICENSE', helper / 'LICENSE')
    # Bundled plugin profile. The guest's DSH_HOME is an app-owned directory created
    # at first start, not part of this runtime image, so the profile ships here as a
    # seed the app copies in. Both plugins are plain JavaScript, so the install done on
    # this host is valid on the phone.
    if args.seed_profile:
        seed = output / 'seed' / 'profile'
        seed.mkdir(parents=True)
        (seed / 'package.json').write_text(json.dumps({
            'name': 'dsh-profile-web',
            'private': True,
            'dependencies': {
                'dsh-purge-community': PURGE_SPEC,
                # 梁神：极简 persona + 工具收拢成 run_code，省 context。
                # 0.4.16 是最后一代声明 >=0.2.2-rc.1 的版本，0.4.19 起要 rc.3。
                '@linxin666/dsh-liangshen': SEED_LIANGSHEN_VERSION,
            },
            'dsh': {'profile': {'bundles': [
                '@deepseek-ai/dsh-base',
                '@deepseek-ai/dsh-web-app',
                'dsh-purge-community',
                '@linxin666/dsh-liangshen',
            ]}},
        }, indent=2) + '\n')
        # 引擎会拒绝 peer 范围不满足的插件；把要用的版本显式豁免掉。
        (seed / 'compatibility.json').write_text(json.dumps({
            '@linxin666/dsh-liangshen@' + SEED_LIANGSHEN_VERSION: [SEED_DSH_VERSION],
            'dsh-purge-community@1.7.20': [SEED_DSH_VERSION],
        }, indent=2) + '\n')
        (seed / 'pnpm-workspace.yaml').write_text(
            'packages:\n  - .\n\nnodeLinker: hoisted\nautoInstallPeers: false\n')
        # config['installation']['arguments'] starts with `ci`, which refuses a
        # directory without a package-lock.json. The seed profile is composed
        # here, so it uses `install` with the same flags minus the lockfile-only ones.
        # --omit=peer is essential: both plugins peer-depend on the whole
        # @deepseek-ai tree, which the runtime image already ships. Without it the
        # seed pulls 336 packages / 788 MB; with it the seed is ~9 MB.
        seed_args = [a for a in config['installation']['arguments']
                     if a not in ('ci', '--install-links=true', '--include=dev')]
        run('seed-install', [str(args.npm), 'install', *seed_args, '--omit=peer',
                             '--cache', str(args.cache)], seed)
        # Repair dsh-purge against the runtime it now targets: its own patch table still
        # points at modules the engine moved, so #35/#91 silently stay "not applicable".
        fixer = repo / 'runtime' / 'presets' / 'purge-fix.py'
        purge_dir = seed / 'node_modules' / 'dsh-purge-community'
        if fixer.is_file() and purge_dir.is_dir():
            run('seed-repair', ['python3', '-I', '-B', str(fixer), '--plugin', str(purge_dir)], seed)
        receipt_seed = {str(p.relative_to(seed)): True for p in seed.rglob('*') if p.is_file()}
        (output / 'seed' / 'profile.json').write_text(json.dumps(
            {'files': len(receipt_seed), 'purgeSpec': PURGE_SPEC}, indent=2) + '\n')
        print(json.dumps({'seedProfile': len(receipt_seed)}))

    receipt = {'schema': 1, 'nodeVersion': config['nodeVersion'], 'installation': config['installation'],
               'files': {name: prefix_files(output / name) for name in ('dsh', 'process')}}
    (output / 'prepared-inputs.json').write_bytes(encoded(receipt))
    print(json.dumps({'status': 'PREPARED', 'receiptSha256': digest(encoded(receipt)),
                      'dshFiles': len(receipt['files']['dsh']), 'processFiles': len(receipt['files']['process'])}))


if __name__ == '__main__':
    main()
