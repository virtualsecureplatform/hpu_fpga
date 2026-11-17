#!/usr/bin/env python3
"""Build AMC with the Vitis 2026.1 Python/SDT workflow; never program hardware."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import struct
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--xsa', type=Path, required=True)
parser.add_argument('--vitis', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--amr-source', type=Path, required=True,
                    help='AMR 3.0 fw/AMC source tree (including HPU integration hooks)')
args = parser.parse_args()
version = (args.amr_source / 'src/common/include/amc_version.h').read_text()
if not re.search(r'#define\s+GIT_TAG\s+"3\.0\.0"', version):
    raise RuntimeError('HPU integration requires the AMR 3.0.0 firmware baseline')
root = Path(__file__).resolve().parent.parent
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
sdk = args.vitis.resolve()
workspace = output / 'bsp_workspace'
env = {**os.environ, 'HPU_FW_XSA': str(args.xsa.resolve()),
       'HPU_BSP_WORKSPACE': str(workspace),
       'PATH': f"{sdk / 'bin'}:{sdk / 'gnu/armr5/lin/gcc-arm-none-eabi/bin'}:" + os.environ['PATH']}
subprocess.run([sdk / 'bin/vitis', '-s', root / 'scripts/create_bsp_sdt.py'], env=env, check=True)
if not (workspace / 'bsp.complete').is_file():
    raise RuntimeError('Vitis returned without a completed BSP')
cmake = sdk / 'tps/lnx64/cmake-4.0.1/bin/cmake'
bsp = workspace / 'amc_bsp/psv_cortexr5_0/amc_r5/bsp'
subprocess.run([cmake, '-S', args.amr_source.resolve(), '-B', output / 'app',
                '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', '-DPROFILE=v80', '-DCMAKE_BUILD_TYPE=Debug',
                '-DAMC_COPY_DIAG=OFF', f'-DHPU_APP_DIR={root}', f'-DBSP_ROOT={bsp}',
                '-DAMC_SOURCE_REVISION=bb929d3ea60e67f952c59fde8514383f8648d60a',
                f'-DBSP_SPECS={sdk}/data/embeddedsw/scripts/specs/arm/Xilinx.spec'], env=env, check=True)
subprocess.run([cmake, '--build', output / 'app', '-j', '4'], env=env, check=True)
if not (output / 'app/amc.elf').is_file():
    raise RuntimeError('Application build returned without amc.elf')
elf = output / 'app/amc.elf'
data = elf.read_bytes()
if data[:7] != b'\x7fELF\x01\x01\x01' or struct.unpack_from('<H', data, 18)[0] != 40:
    raise RuntimeError('Firmware is not an ARM little-endian ELF32')
entry = struct.unpack_from('<I', data, 24)[0]
phoff = struct.unpack_from('<I', data, 28)[0]
phsize, phcount = struct.unpack_from('<HH', data, 42)
for index in range(phcount):
    kind, _, _, address, _, size, _, _ = struct.unpack_from('<8I', data, phoff + index * phsize)
    if kind == 1 and not any(start <= address and address + size <= end
                             for start, end in [(0, 0x10000), (0x40000000, 0x7e800000)]):
        raise RuntimeError(f'ELF load segment overlaps reserved memory: {address:#x}+{size:#x}')
nm = sdk / 'gnu/armr5/lin/gcc-arm-none-eabi/bin/armr5-none-eabi-nm'
symbols = subprocess.check_output([nm, '--defined-only', elf], text=True)
boots = [int(line.split()[0], 16) for line in symbols.splitlines()
         if len(line.split()) == 3 and line.split()[2] == '_boot']
if boots != [entry]:
    raise RuntimeError('ELF entry point does not match the R5 _boot symbol')
(output / 'firmware.json').write_text(json.dumps({
    'elf_sha256': hashlib.sha256(data).hexdigest(), 'entry_point': hex(entry),
    'xsa_sha256': hashlib.sha256(args.xsa.read_bytes()).hexdigest(),
    'vitis': str(sdk), 'management_stack': 'AMR-3.0',
    'interface': json.loads((root / 'amr/interface.json').read_text())}, indent=2) + '\n')
(output / 'firmware.complete').touch()
