#!/usr/bin/env python3
"""Checkpoint recovery in a memory-limited user systemd service."""
import argparse
import hashlib
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import shlex
import subprocess
import sys
import tarfile
import time

REPO = Path(__file__).resolve().parent.parent
GIB = 1024**3


def sha256(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def available_memory():
    for line in Path('/proc/meminfo').read_text().splitlines():
        if line.startswith('MemAvailable:'):
            return int(line.split()[1]) * 1024
    raise RuntimeError('MemAvailable is missing')


def source_files(repo):
    """Include initialized submodule contents, not just gitlink revisions."""
    names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=repo).decode().split('\0')
    for name in sorted(set(names) - {''}):
        path = repo / name
        if path.is_file():
            yield name, path
        elif path.is_dir() and (path / '.git').exists():
            for child, filename in source_files(path):
                yield str(Path(name) / child), filename


def verify_sources(output, config):
    manifest = output / 'source_hashes.json'
    if not manifest.exists():
        # Older workers/tests did not carry source manifests.
        if config.get('source_guard'):
            raise RuntimeError('Missing source manifest')
        return
    expected = json.loads(manifest.read_text())
    actual = {name: sha256(path) for name, path in source_files(Path(config['repo']))}
    changed = sorted(name for name in expected.keys() | actual.keys() if expected.get(name) != actual.get(name))
    if changed:
        raise RuntimeError('Source drift detected: ' + ', '.join(changed[:20]))


def verify_inputs(output, config):
    for name, identity in config.get('inputs', {}).items():
        path = Path(identity['path']) if name == 'checkpoint' else output / name
        if not path.is_file() or sha256(path) != identity['sha256']:
            raise RuntimeError(f'Build input changed: {name}')


def finalize(output):
    status_file = output / 'status.json'
    status = json.loads(status_file.read_text()) if status_file.exists() else {}
    result = os.environ.get('SERVICE_RESULT', 'unknown')
    status['service_result'] = result
    if result != 'success' or status.get('state') != 'complete':
        status.update(state='failed', exit_code=1,
                      error=status.get('error', f'Systemd service ended: {result}'))
    status['finished_at'] = time.time()
    status_file.write_text(json.dumps(status, indent=2) + '\n')


def worker(output):
    config = json.loads((output / 'build.json').read_text())
    status = {'state': 'waiting_for_memory', 'started_at': time.time()}
    child = None
    lock = None

    def save():
        temp = output / 'status.json.tmp'
        temp.write_text(json.dumps(status, indent=2) + '\n')
        temp.replace(output / 'status.json')

    def interrupted(signum, frame):
        raise InterruptedError(f'Signal {signum}')

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        lock = open(f'/var/tmp/hpu-timing-{os.getuid()}.lock', 'a')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        save()
        ready = 0
        while ready < 3:
            free = available_memory()
            required = config.get('start_memory_gib', 64) * GIB
            ready = ready + 1 if free >= required else 0
            status.update(available_bytes=free, memory_ready_samples=ready, required_available_bytes=required)
            save()
            time.sleep(10)
        env = {**os.environ, 'PROJECT_DIR': config['repo'], 'HPU_FREQ_MHZ': '350',
               'HPU_BUILD_STEP': config.get('build_step', 'new'),
               'HPU_ROUTE_DIRECTIVE': config.get('route_directive', 'AggressiveExplore'),
               'PATH': config.get('path', os.environ['PATH']),
               'XILINX_VIVADO': config['vivado_root'],
               'XILINXD_LICENSE_FILE': config.get('license_file', os.environ.get('XILINXD_LICENSE_FILE', '2100@eddystone.sato.lab'))}
        if (output / 'cips.xci').is_file():
            env['HPU_CIPS_XCI'] = str(output / 'cips.xci')
        elif config['phase'] == 'build':
            env.pop('HPU_CIPS_XCI', None)
        if config.get('source_guard'):
            verify_sources(output, config)
            verify_inputs(output, config)
        command = [str(Path(config['vivado_root']) / 'bin/vivado'), '-mode', 'batch',
                   '-nojournal', '-log', str(output / 'vivado.log'),
                   '-source', str(output / 'flow/recover_route.tcl'),
                   '-tclargs', config['checkpoint'], str(output), config['phase']]
        if config['phase'] == 'build':
            command = ['/bin/bash', str(output / 'flow/build_timing_fresh.sh'), str(output)]
        if config['phase'] == 'replay':
            command[command.index('-source') + 1] = str(output / 'flow/replay_route_crash.tcl')
        if config['phase'] == 'gt-inspect':
            command[command.index('-source') + 1] = str(output / 'flow/inspect_gt_endpoints.tcl')
        if config['phase'] == 'image':
            command = [sys.executable, str(output / 'flow/image_flow.py'), str(output)]
        status.update(state='running', command=command)
        save()
        with (output / 'launcher.log').open('a') as log:
            child = subprocess.Popen(command, cwd=output, env=env, stdout=log,
                                     stderr=subprocess.STDOUT, start_new_session=True)
            low_since = None
            checked_sources = time.monotonic()
            while child.poll() is None:
                free = available_memory()
                low_since = (low_since if low_since is not None else time.monotonic()) if free < 8 * GIB else None
                status.update(available_bytes=free, pid=child.pid, updated_at=time.time())
                cgroup = Path('/sys/fs/cgroup') / Path('/proc/self/cgroup').read_text().strip().split('::', 1)[1].lstrip('/')
                for metric in ('memory.peak', 'memory.current'):
                    if (cgroup / metric).is_file():
                        status[metric] = int((cgroup / metric).read_text())
                save()
                if low_since is not None and time.monotonic() - low_since >= 30:
                    raise RuntimeError('Available memory below 8 GiB for 30 seconds')
                if config.get('source_guard') and time.monotonic() - checked_sources >= 60:
                    verify_sources(output, config)
                    checked_sources = time.monotonic()
                time.sleep(10)
        status['vivado_exit_code'] = child.returncode
        if child.returncode:
            raise RuntimeError(f'Vivado exited with status {child.returncode}')
        marker = {'gt-inspect': 'gt_inspect.complete', 'baseline': 'baseline.complete', 'recover': 'recovery.complete', 'reroute': 'recovery.complete', 'repair': 'recovery.complete', 'close-timing': 'recovery.complete', 'setup-repair': 'recovery.complete', 'finish-route': 'recovery.complete', 'place': 'recovery.complete', 'signoff': 'recovery.complete', 'reset-signoff': 'recovery.complete', 'replay': 'replay.complete', 'image': 'image.complete', 'build': 'fresh.complete'}[config['phase']]
        if not (output / marker).is_file():
            raise RuntimeError(f'Vivado returned without {marker}')
        if config.get('source_guard'):
            verify_sources(output, config)
        status.update(state='complete', exit_code=0)
        if config['phase'] == 'build':
            signoff = output / 'top_hpu/prj.runs/impl_1/signoff'
            status['signoff'] = 'passed' if (signoff / 'signoff.json').is_file() else 'failed'
            status['clock_validation'] = str(output / 'top_hpu/prj.runs/impl_1/clock_validation')
            status['constraint_audit'] = str(signoff / 'constraint_audit.json')
        if config['phase'] in ('recover', 'reroute', 'repair', 'close-timing', 'setup-repair', 'finish-route', 'place', 'signoff', 'reset-signoff'):
            status['signoff'] = 'passed' if (output / 'signoff/signoff.json').is_file() else 'failed'
    except BaseException as error:
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        if config.get('phase') == 'image':
            # A final source-guard failure must not leave a published release.
            # Keep the diagnostic bundle recoverable rather than deleting it.
            release = output / 'release'
            if release.is_dir():
                rejected = output / f'release.rejected.{time.time_ns()}'
                release.rename(rejected)
                status['rejected_release'] = str(rejected)
            (output / 'image.complete').unlink(missing_ok=True)
        status.update(state='failed', error=str(error), exit_code=1)
    finally:
        status['finished_at'] = time.time()
        save()
        if lock is not None:
            lock.close()
    return status['exit_code']


def launch(args):
    output = args.output.resolve()
    if args.phase != 'build' and args.source_build is None:
        raise ValueError('--source-build is required except for a fresh build')
    source = args.source_build.resolve() if args.source_build else REPO
    checkpoint = (args.checkpoint or source / 'top_hpu/prj.runs/impl_1/top_hpu_placed.dcp').resolve()
    if args.phase == 'place' and checkpoint != source / 'top_hpu/prj.runs/impl_1/top_hpu_opt.dcp':
        raise ValueError('Placement resume requires the source build top_hpu_opt.dcp')
    inputs = {} if args.phase == 'build' else {'checkpoint': checkpoint, 'synthesis.vds': source / 'top_hpu/prj.runs/synth_1/top_hpu.vds',
              'uservars.tcl': source / 'top_hpu/uservars.tcl', 'hpu_plug.xsa': source / 'hpu_plug.xsa',
              'ip_status.rpt': source / 'ip_status_before_synthesis.rpt',
              'cips.xci': source / 'top_hpu/prj.srcs/sources_1/bd/hpu_plug/ip/hpu_plug_cips_0/hpu_plug_cips_0.xci'}
    for path in inputs.values():
        if not path.is_file():
            raise FileNotFoundError(path)
    if args.phase == 'replay':
        if args.checkpoint is None or checkpoint.name != 'pre_route_physopt.dcp':
            raise ValueError('Replay requires the preserved pre_route_physopt.dcp')
        for name, filename in {'original_build.json': 'build.json',
                               'original_crash.log': 'hs_err_pid187981.log',
                               'original_vivado.log': 'vivado.log',
                               'original_recover_route.tcl': 'flow/recover_route.tcl'}.items():
            inputs[name] = checkpoint.parent / filename
            if not inputs[name].is_file():
                raise FileNotFoundError(inputs[name])
    if args.phase == 'image':
        provenance_dir = source if checkpoint.parent == source / 'top_hpu/prj.runs/impl_1' else checkpoint.parent
        verify_sources(provenance_dir, json.loads((provenance_dir / 'build.json').read_text()))
        sys.path.insert(0, str(REPO / 'versal/scripts'))
        from check_timing_signoff import verify_signed
        signoff = checkpoint.parent / 'signoff'
        verify_signed(signoff, checkpoint)
        if sha256(signoff / 'cips.xci') != sha256(inputs['cips.xci']):
            raise ValueError('CIPS configuration does not match the signed checkpoint')
        if checkpoint.parent != source / 'top_hpu/prj.runs/impl_1':
            # Recovery checkpoints must retain the original fresh-build lineage.
            provenance = json.loads((checkpoint.parent / 'build.json').read_text())['inputs']
            for name, path in inputs.items():
                if name != 'checkpoint' and sha256(path) != provenance[name]['sha256']:
                    raise ValueError(f'Source build does not match recovery checkpoint: {name}')
    active = subprocess.check_output(['systemctl', '--user', 'list-units', 'hpu-timing-*.service', '--state=active,activating', '--no-legend', '--plain'], text=True)
    if active.strip():
        raise RuntimeError(f'Another HPU timing job is active:\n{active}')
    output.mkdir(parents=True, exist_ok=False)
    (output / 'flow').mkdir()
    for name in ('recover_route.tcl', 'repair_route.tcl', 'repair_metrics.py', 'timing_signoff.tcl', 'check_timing_signoff.py', 'complete_signoff_checks.py', 'generate_timing_image.tcl', 'image_flow.py', 'clock_signoff.tcl', 'pcie_reset_constraints.tcl', 'constraint_audit.tcl', 'constraint_audit.py', 'inactive_gt_policy.json'):
        path = REPO / 'versal/scripts' / name
        if path.exists():
            shutil.copy2(path, output / 'flow' / name)
    shutil.copy2(REPO / 'versal/constraints/hooks/hook_write_device_image.pre.tcl', output / 'flow')
    shutil.copy2(REPO / 'versal/constraints/hooks/hook_place.pre.tcl', output / 'flow')
    if args.phase == 'replay':
        shutil.copy2(REPO / 'versal/scripts/replay_route_crash.tcl', output / 'flow')
    if args.phase == 'gt-inspect':
        shutil.copy2(REPO / 'versal/scripts/inspect_gt_endpoints.tcl', output / 'flow')
        vendor_xdc = source / 'top_hpu/prj.gen/sources_1/bd/hpu_plug/ip/hpu_plug_cips_0/bd_0/ip/ip_1/ip_cpm5.xdc'
        if not vendor_xdc.is_file():
            raise FileNotFoundError(vendor_xdc)
        inputs['vendor_ip_cpm5.xdc'] = vendor_xdc
    shutil.copy2(REPO / 'scripts/build_timing_fresh.sh', output / 'flow')
    if args.phase == 'image':
        shutil.copytree(REPO / 'fw/arm', output / 'firmware_src', ignore=shutil.ignore_patterns('build', 'amc_bsp', '.Xil', '.git'))
        amr = Path(os.environ.get('HPU_AMR_SOURCE', str(REPO.parent / 'amr'))).resolve()
        revision = subprocess.check_output(['git', '-C', str(amr), 'rev-parse', 'HEAD'], text=True).strip()
        if revision != 'bb929d3ea60e67f952c59fde8514383f8648d60a':
            raise ValueError('Image generation requires the pinned AMR 3.0 release bb929d3')
        shutil.copytree(amr / 'fw/AMC', output / 'amr_firmware_src',
                        ignore=shutil.ignore_patterns('build', 'amc_bsp', '.Xil', '.git'))
        (output / 'amr_source.patch').write_bytes(subprocess.check_output(
            ['git', '-C', str(amr), 'diff', 'HEAD', '--binary', '--', 'fw/AMC']))
        (output / 'amr_source_hashes.json').write_text(json.dumps({
            str(p.relative_to(output / 'amr_firmware_src')): sha256(p)
            for p in sorted((output / 'amr_firmware_src').rglob('*')) if p.is_file()
        }, indent=2) + '\n')
        for name in ('flash_template.json.j2', 'pdi_template.json.j2'):
            shutil.copy2(REPO / 'versal/scripts/fpt/template' / name, output / 'flow')
    manifest = {}
    for name, path in inputs.items():
        manifest[name] = {'path': str(path), 'sha256': sha256(path)}
        if name != 'checkpoint':
            shutil.copy2(path, output / name)
    sources = {}
    with tarfile.open(output / 'source_snapshot.tar.gz', 'w:gz') as archive:
        for name, path in source_files(REPO):
            sources[name] = sha256(path)
            archive.add(path, arcname=name, recursive=False)
    (output / 'source_hashes.json').write_text(json.dumps(sources, indent=2) + '\n')
    (output / 'source.patch').write_bytes(subprocess.check_output(['git', 'diff', 'HEAD', '--binary'], cwd=REPO))
    (output / 'submodules.txt').write_bytes(subprocess.check_output(['git', 'submodule', 'status', '--recursive'], cwd=REPO))
    config = {'repo': str(REPO), 'checkpoint': str(checkpoint), 'phase': args.phase,
              'path': os.environ['PATH'],
              'vivado_root': '/home/opt/xilinx/2026.1/Vivado',
              'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO).decode().strip(),
              'inputs': manifest,
              'source_guard': True,
              'license_file': os.environ.get('XILINXD_LICENSE_FILE', '2100@eddystone.sato.lab'),
              'route_directive': getattr(args, 'route_directive', 'AggressiveExplore'),
              'start_memory_gib': getattr(args, 'start_memory_gib', 64),
              'memory_high_gib': getattr(args, 'memory_high_gib', 56),
              'memory_max_gib': getattr(args, 'memory_max_gib', 64)}
    (output / 'build.json').write_text(json.dumps(config, indent=2) + '\n')
    shutil.copy2(__file__, output / 'worker.py')
    unit = f'hpu-timing-{time.time_ns()}'
    command = ['systemd-run', '--user', '--unit', unit,
               '-p', f"MemoryHigh={config['memory_high_gib']}G", '-p', f"MemoryMax={config['memory_max_gib']}G", '-p', 'MemorySwapMax=0',
               '-p', 'KillMode=control-group', '-p', 'TimeoutStopSec=30',
               '-p', 'OOMPolicy=stop',
               '-p', 'ExecStopPost=' + shlex.join([sys.executable, str(output / 'worker.py'), '--finalize', str(output)]),
               '-p', f'StandardOutput=append:{output}/service.log',
               '-p', f'StandardError=append:{output}/service.log',
               sys.executable, str(output / 'worker.py'), '--worker', str(output)]
    subprocess.run(command, check=True)
    (output / 'systemd_unit').write_text(unit + '\n')
    print(json.dumps({'output': str(output), 'unit': unit}, indent=2))


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--finalize':
        finalize(Path(sys.argv[2]))
        sys.exit(0)
    if len(sys.argv) == 3 and sys.argv[1] == '--worker':
        sys.exit(worker(Path(sys.argv[2])))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--source-build', type=Path)
    parser.add_argument('--checkpoint', type=Path)
    parser.add_argument('--phase', choices=['baseline', 'recover', 'reroute', 'repair', 'close-timing', 'setup-repair', 'finish-route', 'place', 'signoff', 'reset-signoff', 'gt-inspect', 'replay', 'image', 'build'], default='recover')
    parser.add_argument('--route-directive', choices=['AggressiveExplore', 'Explore', 'NoTimingRelaxation'], default='AggressiveExplore')
    parser.add_argument('--memory-high-gib', type=int, default=56)
    parser.add_argument('--memory-max-gib', type=int, default=64)
    parser.add_argument('--start-memory-gib', type=int, default=64)
    args = parser.parse_args()
    if not 0 < args.memory_high_gib <= args.memory_max_gib or args.start_memory_gib <= 0:
        parser.error('Memory limits must be positive, with high <= max')
    launch(args)
