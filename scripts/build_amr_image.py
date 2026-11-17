#!/usr/bin/env python3
"""Package a finished Vivado build as an AMR release. Never touches a board.

Takes the output directory of versal/run_syn_hpu_3parts_psi64.sh, builds the
AMR management firmware with the HPU application against the build's XSA and
merges both into one PDI for AMR's cfgmem_program.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
FW = ROOT / 'fw/arm'
TEMPLATES = ROOT / 'versal/scripts/fpt/template'
sys.path.insert(0, str(FW / 'scripts'))
from check_amr_interface import validate_xsa
from verify_amr_release import verify


def timing(report):
    """(WNS, WHS, frequency in MHz of prc_clk) from a routed report_timing_summary."""
    text = report.read_text()
    table = re.search(r'WNS\(ns\)\s+TNS\(ns\).*?\n\s*-[- ]+\n\s*(\S+)\s+\S+\s+\d+\s+\d+\s+(\S+)', text)
    clock = re.search(r'^\s*prc_clk\s+\{[^}]*\}\s+([\d.]+)\s+[\d.]+\s*$', text, re.M)
    if not table or not clock:
        raise RuntimeError(f'Cannot read the timing summary of {report}')
    return float(table[1]), float(table[2]), 1000.0 / float(clock[1])


def routed_timing_report(build):
    # Vivado names the report after the last implementation step that ran.
    run = build / 'top_hpu/prj.runs/impl_1'
    for name in ('top_hpu_timing_summary_postroute_physopted.rpt', 'top_hpu_timing_summary_routed.rpt'):
        if (run / name).is_file():
            return run / name
    raise RuntimeError(f'No routed timing summary in {run}')


def pl_node_uid(inspection):
    """AMR reports the PLM PL-node unique id as logic UUID, not the UUID ROM."""
    uids = set()
    for header in re.split(r'IMAGE HEADER \(', inspection)[1:]:
        identity = re.search(r'\bid \(0x18\) : 0x18700000\s+unique_id \(0x24\) : (0x[0-9a-fA-F]+)', header)
        if identity and int(identity[1], 16):
            uids.add(int(identity[1], 16))
    if len(uids) != 1:
        raise RuntimeError('Cannot establish one nonzero AMR PL-node UID from the PDI')
    return f'{uids.pop():032x}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path, help='Vivado build output, e.g. versal/output_psi64')
    parser.add_argument('release', type=Path, help='release directory to create')
    parser.add_argument('--amr-source', type=Path, required=True,
                        help='AMR 3.0.0 fw/AMC tree with fw/arm/amr/amr-3.0.0-hpu.patch applied')
    parser.add_argument('--vitis', type=Path, default=os.environ.get('XILINX_VITIS'),
                        help='Vitis installation (default: $XILINX_VITIS)')
    parser.add_argument('--allow-timing-failure', action='store_true',
                        help='package an image that misses timing (for experiments only)')
    args = parser.parse_args()
    if not args.vitis:
        parser.error('--vitis or XILINX_VITIS is required')
    build, release, vitis = args.build.resolve(), args.release.resolve(), Path(args.vitis).resolve()

    report = routed_timing_report(build)
    wns, whs, frequency = timing(report)
    print(f'{report.name}: WNS {wns} ns, WHS {whs} ns, prc_clk {frequency:.1f} MHz')
    timing_met = wns >= 0 and whs >= 0
    if not timing_met and not args.allow_timing_failure:
        sys.exit('Timing is not met; refusing to package this build')

    xsa = build / 'hpu_plug.xsa'
    interface = json.loads((FW / 'amr/interface.json').read_text())
    validate_xsa(xsa, interface)

    release.mkdir(parents=True)
    work = release / 'work'
    subprocess.run([sys.executable, FW / 'scripts/build_sdt.py', '--xsa', xsa, '--vitis', vitis,
                    '--amr-source', args.amr_source.resolve(), '--output', work / 'firmware'], check=True)
    shutil.copy2(work / 'firmware/app/amc.elf', release / 'amc.elf')
    shutil.copy2(work / 'firmware/firmware.json', release / 'firmware.json')
    shutil.copy2(xsa, release / 'hpu_plug.xsa')
    shutil.copy2(FW / 'amr/interface.json', release / 'interface.json')
    shutil.copy2(report, release / report.name)

    bootgen = vitis / 'bin/bootgen'
    pdi = release / f'hpu_psi64_{round(frequency)}mhz_amr.pdi'
    combined = work / 'top_hpu.noelf.pdi'
    for template, values, target in [
            ('flash_template.json.j2', {'stage_1_path': build / 'top_hpu_tandem1.pdi',
                                        'stage_2_path': build / 'top_hpu_tandem2.pdi'}, combined),
            ('pdi_template.json.j2', {'top_pdi_path': combined, 'amc_elf_path': release / 'amc.elf'}, pdi)]:
        text = (TEMPLATES / template).read_text()
        for key, value in values.items():
            text = text.replace(f'^^{key}^^', str(value))
        if '^^' in text:
            raise RuntimeError(f'Unexpanded Bootgen template {template}')
        bif = work / (target.name + '.bif')
        bif.write_text(text)
        subprocess.run([bootgen, '-arch', 'versal', '-image', bif, '-w', '-o', target], cwd=work, check=True)
    inspection = subprocess.check_output([bootgen, '-arch', 'versal', '-read', pdi], cwd=work, text=True)
    (release / 'bootgen_inspection.txt').write_text(inspection)
    if 'rpu_subsystem' not in inspection:
        raise RuntimeError('Merged PDI has no RPU subsystem')

    revision = subprocess.check_output(['git', 'describe', '--always', '--dirty', '--abbrev=12'], cwd=ROOT, text=True).strip()
    sha256 = lambda name: hashlib.sha256((release / name).read_bytes()).hexdigest()
    manifest = {
        'schema_version': 1, 'management_stack': 'AMR-3.0', 'pdi': pdi.name,
        'expected_uuid': pl_node_uid(inspection), 'hpu_fpga_revision': revision,
        'frequency_mhz': round(frequency), 'wns_ns': wns, 'whs_ns': whs, 'timing_met': timing_met,
        'sha256': {name: sha256(name) for name in (pdi.name, 'hpu_plug.xsa', 'amc.elf', 'interface.json', 'firmware.json')},
    }
    (release / 'release_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    verify(pdi)
    shutil.rmtree(work)
    print(json.dumps(manifest, indent=2))
    print(f'Release ready: {pdi}\nSet expected_uuid = "{manifest["expected_uuid"]}" in the tfhe-rs V80Amr configuration.')


if __name__ == '__main__':
    main()
