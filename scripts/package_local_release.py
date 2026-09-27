#!/usr/bin/env python3
"""Package the validated September 27 AMR image and current dirty source trees.

Local packaging only: no Git mutations, downloads, publishing, or board writes.
Existing destinations are rejected. Source selection is Git-tracked files plus
nonignored untracked files, with build artifacts explicitly excluded below.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
from datetime import datetime, timezone


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def snapshot(repo, target, name):
    files, states, excluded, missing = {}, {}, [], []

    def visit(root, prefix='', nested=False):
        states[prefix or '.'] = {
            'head': run('git', 'rev-parse', 'HEAD', cwd=root).decode().strip(),
            'status': run('git', 'status', '--short', cwd=root).decode(),
        }
        tracked = {}
        for entry in run('git', 'ls-files', '--stage', '-z', cwd=root).split(b'\0'):
            if not entry:
                continue
            meta, raw_name = entry.split(b'\t', 1)
            mode, _, stage = meta.decode().split()
            if stage != '0':
                raise ValueError(f'Unmerged source: {root}/{os.fsdecode(raw_name)}')
            tracked[os.fsdecode(raw_name)] = mode
        untracked = [os.fsdecode(p) for p in run(
            'git', 'ls-files', '--others', '--exclude-standard', '-z', cwd=root
        ).split(b'\0') if p]
        for rel in sorted(set(tracked) | set(untracked)):
            path = root / rel
            arc = prefix + rel
            if tracked.get(rel) == '160000':
                if not (path / '.git').exists():
                    raise ValueError(f'Uninitialized submodule: {path}')
                visit(path, arc + '/', True)
                continue
            # Retain all tracked content, including tracked binary assets.
            if rel not in tracked and (
                nested or rel.startswith('build_ami/')
                or rel.startswith('clockInfo.')
            ):
                excluded.append(arc)
                continue
            if not path.exists() and not path.is_symlink():
                missing.append(arc)
                continue
            if not path.is_file() and not path.is_symlink():
                raise ValueError(f'Unexpected source entry: {path}')
            files[arc] = path

    visit(repo)
    hashes = {}
    archive = target / f'{name}.tar.gz'
    with tarfile.open(archive, 'w:gz', compresslevel=3) as tar:
        for arc, path in sorted(files.items()):
            entry = {'mode': oct(path.lstat().st_mode & 0o777)}
            if path.is_symlink():
                entry['symlink'] = os.readlink(path)
            else:
                entry['sha256'] = digest(path)
            hashes[arc] = entry
            tar.add(path, arcname=f'{name}/{arc}', recursive=False)
    # Verify every captured byte against the inventory, independently of source.
    with tarfile.open(archive, 'r:gz') as tar:
        for member in tar:
            rel = member.name[len(name) + 1:]
            entry = hashes[rel]
            if member.issym():
                assert member.linkname == entry['symlink']
            else:
                with tar.extractfile(member) as stream:
                    assert hashlib.file_digest(stream, 'sha256').hexdigest() == entry['sha256']
    write_json(target / f'{name}.inventory.json', hashes)
    write_json(target / f'{name}.git.json', states)
    write_json(target / f'{name}.exclusions.json', {'untracked_build_files': excluded, 'deleted': missing})
    (target / f'{name}.patch').write_bytes(run('git', 'diff', 'HEAD', '--binary', cwd=repo))
    return {'head': states['.']['head'], 'files': len(files), 'archive': archive.name}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    hpu = Path(__file__).resolve().parents[1]
    workspace = hpu.parent
    out = args.output.resolve()
    if out.exists() or Path(str(out) + '.tar.gz').exists():
        raise ValueError('Release destination already exists; choose a new name')
    image = hpu / 'versal/timing_350_amr_irqfix_20260927/release'
    old = hpu / 'versal/timing_350_amr_image_20260926/release'
    verify = hpu / 'fw/arm/scripts/verify_amr_release.py'
    preflight = run('python3', str(verify), str(image / 'hpu_psi64_350mhz_amr.pdi'))
    assert json.loads((old / 'signoff/signoff.json').read_text())['passed']
    out.mkdir(parents=True)
    for subdir in ('sources', 'host/bin', 'evidence', 'provenance'):
        (out / subdir).mkdir(parents=True)
    print(f'Packaging {out}', flush=True)
    shutil.copytree(image, out / 'image')
    # Keep the obsolete candidate description only as historical provenance.
    (out / 'image/README.md').rename(out / 'provenance/irqfix_candidate_README.md')
    shutil.copytree(old / 'signoff', out / 'provenance/pl_signoff')
    for name in ('source_snapshot.tar.gz', 'source_hashes.json', 'source.patch',
                 'amr_source_hashes.json', 'amr_source.patch', 'submodules.txt',
                 'build.json', 'bootgen_inspection.txt'):
        shutil.copy2(old / name, out / 'provenance' / name)
    shutil.copytree(old / 'amr_firmware_src', out / 'provenance/amr_firmware_src')
    shutil.copy2(image.parent / 'firmware.bif', out / 'provenance/firmware.bif')
    shutil.copy2(old.parent / 'top_hpu.noelf.pdi', out / 'provenance/top_hpu.noelf.pdi')
    old_hashes = json.loads((old / 'source_hashes.json').read_text())
    changes = {name: {'build_sha256': value,
                      'current_sha256': digest(hpu / name) if (hpu / name).is_file() else None}
               for name, value in old_hashes.items()
               if not (hpu / name).is_file() or digest(hpu / name) != value}
    write_json(out / 'provenance/changes_since_original_image_snapshot.json', changes)
    repos = {}
    for name in ('hpu_fpga', 'tfhe-rs', 'amr'):
        print(f'Snapshotting {name}', flush=True)
        repos[name] = snapshot(workspace / name, out / 'sources', name)
    tfhe = workspace / 'tfhe-rs'
    for source, dest in (
        ('target/release/examples/hpu_bench', 'hpu_bench'),
        ('target/release/deps/hpu-35b7a96778d0706d', 'hpu_tests'),
    ):
        shutil.copy2(tfhe / source, out / 'host/bin' / dest)
        (out / 'evidence' / f'{dest}.ldd.txt').write_bytes(run('ldd', str(tfhe / source)))
    shutil.copytree(tfhe / 'backends/tfhe-hpu-backend/config_store', out / 'host/backend/config_store')
    shutil.copy2(tfhe / 'LICENSE', out / 'host/LICENSE')
    for name in ('tests_ovf_fix_20260927', 'tests_ct_order_20260927', 'diagnostic_ct_order_fix_20260927'):
        shutil.copytree(hpu / 'versal' / name, out / 'evidence' / name)
    (out / 'evidence/image_preflight.json').write_bytes(preflight)
    for args, dest in (
        (['ami_tool', 'overview'], 'board_overview.txt'),
        (['ami_tool', 'cfgmem_info', '-d', '02:00.0', '-t', 'primary'], 'board_partitions.txt'),
    ):
        (out / 'evidence' / dest).write_bytes(run('timeout', '-k', '5s', '30s', *args))
    # FPT metadata is corroborating evidence, not a byte-for-byte flash readback.
    md5 = hashlib.md5((image / 'hpu_psi64_350mhz_amr.pdi').read_bytes()).hexdigest()
    assert md5 in (out / 'evidence/board_partitions.txt').read_text()
    assert '55 passed; 0 failed' in (out / 'evidence/tests_ovf_fix_20260927/all_widths.log').read_text()
    assert '3 passed; 0 failed' in (out / 'evidence/tests_ovf_fix_20260927/targeted.log').read_text()
    for script in ('verify_amr_release.py', 'check_amr_interface.py'):
        shutil.copy2(verify.parent / script, out / script)
    shutil.copy2(hpu / 'docs/local_release_20260927.md', out / 'README.md')
    manifest = {
        'schema_version': 1, 'name': out.name,
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'publication': 'local-only; redistribution rights not assessed',
        'image': json.loads(preflight), 'source_snapshots': repos,
        'ciphertext_order': 'RadixReversed',
        'host_fixes': ['ciphertext/KSK ordering', 'OVF_ADD carry normalization'],
        'validation': {'single_board_bundles_passed': 55, 'iterations_per_operation': 2,
                       'targeted_board_cases': 22, 'host_overflow_cases': 27},
        'provenance_note': 'Current worktree snapshots are not a new PL synthesis. '
                           'Original PL snapshot/signoff retained; IRQ-fixed ELF/PDI packaged.',
        'omitted': ['Git object databases', 'ignored build products', 'original 1.6GB routed DCP',
                    'Vivado/Vitis installations', 'AMD downloaded boot-FPT/bootfw packages'],
    }
    write_json(out / 'MANIFEST.json', manifest)
    files = sorted(p for p in out.rglob('*') if p.is_file())
    (out / 'SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.relative_to(out)}\n' for p in files))
    run('sha256sum', '--check', '--quiet', 'SHA256SUMS', cwd=out)
    run('python3', str(out / verify.name), str(out / 'image/hpu_psi64_350mhz_amr.pdi'))
    archive = Path(str(out) + '.tar.gz')
    print('Creating complete release archive', flush=True)
    with tarfile.open(archive, 'w:gz', compresslevel=3) as tar:
        tar.add(out, arcname=out.name)
    Path(str(archive) + '.sha256').write_text(f'{digest(archive)}  {archive.name}\n')
    print(json.dumps({'directory': str(out), 'archive': str(archive),
                      'sha256': digest(archive), 'bytes': archive.stat().st_size}, indent=2), flush=True)


if __name__ == '__main__':
    main()
