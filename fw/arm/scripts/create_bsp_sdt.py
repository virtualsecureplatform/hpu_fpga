"""Run with Vitis Python: generate the R5 FreeRTOS BSP for the supplied XSA."""
import os
import re
import shutil
import subprocess
from pathlib import Path
import vitis

MRMAC_WARNING = 'dtg_warning "No GPIO Path detected...please check the design..."'


def patched_sdt_repo(destination):
    """Private copy of the device-tree generator with the MRMAC crash fixed.

    Same fix as create_bsp.py: the 2026.1 generator crashes on this design's MRMAC,
    whose GT reset topology is neither the old nor the new one it knows.
    """
    out = subprocess.run(['sdtgen', '-eval', 'puts [sdtgen get_dt_param -repo]'],
                         capture_output=True, text=True, check=True).stdout
    source = next((Path(line.strip()) for line in reversed(out.splitlines())
                   if (Path(line.strip()) / 'device_tree/data/device_tree.tcl').is_file()), None)
    if source is None:
        raise RuntimeError('System device tree repository not found (sdtgen get_dt_param -repo)')
    shutil.copytree(source, destination)
    # The installation is read-only; the copy must be writable to patch and to delete.
    for path in [destination, *destination.rglob('*')]:
        if not path.is_symlink():
            path.chmod(0o755 if path.is_dir() else 0o644)
    mrmac = destination / 'mrmac/data/mrmac.tcl'
    text = mrmac.read_text()
    if text.count(MRMAC_WARNING) != 1:
        raise RuntimeError(f'MRMAC generator changed, patch point not found in {mrmac}')
    mrmac.write_text(text.replace(MRMAC_WARNING, MRMAC_WARNING + '\n                 set mode "none"'))
    return destination


workspace = Path(os.environ['HPU_BSP_WORKSPACE']).resolve()
xsa = Path(os.environ['HPU_FW_XSA']).resolve()
workspace.mkdir(parents=True)
# Picked up by the sdtgen run inside the Vitis server.
os.environ['CUSTOM_SDT_REPO'] = str(patched_sdt_repo(workspace.parent / 'sdt_repo'))
client = vitis.create_client()
try:
    client.set_workspace(str(workspace))
    platform = client.create_platform_component(
        name='amc_bsp', hw_design=str(xsa), os='freertos',
        cpu='psv_cortexr5_0', domain_name='amc_r5', no_boot_bsp=True)
    domain = platform.get_domain(name='amc_r5')
    for key, value in [('freertos_tick_rate', '1000'),
                       ('freertos_total_heap_size', '131072'),
                       ('freertos_support_static_allocation', 'true')]:
        domain.set_config(option='os', param=key, value=value)
    for name in ('xilfpga', 'xilmailbox', 'xilloader', 'xilpm'):
        # xilfpga can add xilmailbox transitively; adding it twice is an error.
        if name not in {lib['name'] for lib in domain.get_libs()}:
            domain.set_lib(lib_name=name)
    platform.build()
    bsp = workspace / 'amc_bsp/psv_cortexr5_0/amc_r5/bsp'
    for name in ('libxil.a', 'libfreertos.a', 'libxilfpga.a', 'libxilmailbox.a', 'libxilloader.a', 'libxilpm.a'):
        if not (bsp / 'lib' / name).is_file():
            raise RuntimeError(f'BSP build did not produce {name}')
    config = (bsp / 'include/FreeRTOSConfig.h').read_text()
    for key, value in [('configTICK_RATE_HZ', '1000'),
                       ('configTOTAL_HEAP_SIZE', '131072'),
                       ('configSUPPORT_STATIC_ALLOCATION', '1')]:
        match = re.search(r'^\s*#define\s+' + key + r'\s+(.+)$', config, re.M)
        if not match or not re.search(r'\b' + value + r'\b', match[1]):
            raise RuntimeError(f'Unexpected generated FreeRTOS setting: {key}')
    (workspace / 'bsp.complete').touch()
finally:
    vitis.dispose()
