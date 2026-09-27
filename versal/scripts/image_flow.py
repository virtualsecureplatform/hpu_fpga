#!/usr/bin/env python3
"""Generate and package an image only after in-Vivado timing signoff."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import re


def run(output):
    def verify_amr_sources():
        expected = json.loads((output / 'amr_source_hashes.json').read_text())
        actual = {str(path.relative_to(output / 'amr_firmware_src')):
                  hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in (output / 'amr_firmware_src').rglob('*') if path.is_file()}
        if actual != expected:
            raise RuntimeError('AMR firmware source snapshot changed')

    verify_amr_sources()
    config = json.loads((output / 'build.json').read_text())
    vivado = Path(config['vivado_root'])
    env = {**os.environ, 'HPU_SOURCE_REVISION': config['revision'],
           'XILINX_VITIS': str(vivado.parent / 'Vitis'),
           'PATH': f"{vivado}/bin:{vivado.parent}/Vitis/bin:{vivado.parent}/Vitis/gnu/armr5/lin/gcc-arm-none-eabi/bin:" + os.environ['PATH']}
    def execute(args, cwd=output):
        subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)
    execute([vivado / 'bin/vivado', '-mode', 'batch', '-nojournal', '-log', output / 'vivado.log',
             '-source', output / 'flow/generate_timing_image.tcl', '-tclargs', config['checkpoint'], output])
    if not (output / 'image_vivado.complete').is_file():
        raise RuntimeError('Image generation did not complete')
    execute(['python3', output / 'flow/check_timing_signoff.py', output / 'signoff_image_input',
             '--verify-existing', '--checkpoint', output / 'image_input.dcp'])
    fw = output / 'firmware_src'
    execute(['python3', fw / 'scripts/check_amr_interface.py', output / 'hpu_plug.xsa'])
    execute(['python3', fw / 'scripts/build_sdt.py', '--xsa', output / 'hpu_plug.xsa',
             '--amr-source', output / 'amr_firmware_src',
             '--vitis', vivado.parent / 'Vitis', '--output', output / 'firmware_build'], cwd=fw)
    elf = output / 'firmware_build/app/amc.elf'
    verify_amr_sources()
    if not elf.is_file() or elf.stat().st_size == 0:
        raise RuntimeError('Firmware build returned without amc.elf')
    shutil.copy2(elf, output / 'amc.elf')
    bootgen = vivado / 'bin/bootgen'
    combined = output / 'top_hpu.noelf.pdi'
    for template, replacements, target, bif in [
        ('flash_template.json.j2', {'stage_1_path': output / 'top_hpu_tandem1.pdi',
                                  'stage_2_path': output / 'top_hpu_tandem2.pdi'}, combined, 'combine.bif'),
        ('pdi_template.json.j2', {'top_pdi_path': combined, 'amc_elf_path': output / 'amc.elf'},
         output / 'hpu_psi64_350mhz_amr.pdi', 'firmware.bif')]:
        text = (output / 'flow' / template).read_text()
        for key, value in replacements.items():
            text = text.replace(f'^^{key}^^', str(value))
        if '^^' in text:
            raise RuntimeError('Unexpanded Bootgen template')
        (output / bif).write_text(text)
        execute([bootgen, '-arch', 'versal', '-image', output / bif, '-w', '-o', target])
    pdi = output / 'hpu_psi64_350mhz_amr.pdi'
    inspection = subprocess.check_output([str(bootgen), '-arch', 'versal', '-read', str(pdi)], env=env, cwd=output, text=True)
    (output / 'bootgen_inspection.txt').write_text(inspection)
    if 'rpu_subsystem' not in inspection:
        raise RuntimeError('Merged PDI has no RPU subsystem')
    bundle = output / 'release.partial'
    bundle.mkdir()
    for name in ('hpu_psi64_350mhz_amr.pdi', 'image_input.dcp', 'hpu_plug.xsa', 'amc.elf',
                 'pfm_uuid_manifest.dict', 'bootgen_inspection.txt', 'build.json', 'source_hashes.json',
                 'source.patch', 'submodules.txt', 'source_snapshot.tar.gz', 'ip_status.rpt', 'vivado.log', 'cips.xci',
                 'amr_source.patch', 'amr_source_hashes.json'):
        shutil.copy2(output / name, bundle / name)
    shutil.copytree(output / 'amr_firmware_src', bundle / 'amr_firmware_src')
    shutil.copy2(output / 'firmware_build/firmware.json', bundle / 'firmware.json')
    shutil.copy2(fw / 'amr/interface.json', bundle / 'interface.json')
    # AMR publishes the PLM PL-node UID, not the legacy 128-bit UUID ROM.
    headers = re.split(r'IMAGE HEADER \(', inspection)[1:]
    pl_uids = set()
    for header in headers:
        identity = re.search(r'\bid \(0x18\) : 0x18700000\s+unique_id \(0x24\) : (0x[0-9a-fA-F]+)', header)
        if identity and int(identity[1], 16):
            pl_uids.add(int(identity[1], 16))
    if len(pl_uids) != 1:
        raise RuntimeError('Cannot establish one nonzero AMR PL-node UID from the PDI')
    release_manifest = {
        'schema_version': 1, 'management_stack': 'AMR-3.0',
        'expected_uuid': f'{next(iter(pl_uids)):032x}',
        'sha256': {name: hashlib.sha256((bundle / name).read_bytes()).hexdigest()
                   for name in ('hpu_psi64_350mhz_amr.pdi', 'hpu_plug.xsa', 'amc.elf', 'interface.json', 'firmware.json')}
    }
    (bundle / 'release_manifest.json').write_text(json.dumps(release_manifest, indent=2) + '\n')
    execute(['python3', fw / 'scripts/verify_amr_release.py', bundle / 'hpu_psi64_350mhz_amr.pdi'])
    shutil.copytree(output / 'signoff_image_input', bundle / 'signoff')
    hashes = {}
    for path in sorted(bundle.rglob('*')):
        if path.is_file():
            with path.open('rb') as stream:
                hashes[str(path.relative_to(bundle))] = hashlib.file_digest(stream, 'sha256').hexdigest()
    (bundle / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in hashes.items()))
    bundle.rename(output / 'release')
    (output / 'image.complete').touch()


if __name__ == '__main__':
    run(Path(sys.argv[1]).resolve())
