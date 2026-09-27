"""Run with Vitis Python: generate the R5 FreeRTOS BSP for the supplied XSA."""
import os
import re
from pathlib import Path
import vitis

workspace = Path(os.environ['HPU_BSP_WORKSPACE']).resolve()
xsa = Path(os.environ['HPU_FW_XSA']).resolve()
client = vitis.create_client()
try:
    client.set_workspace(str(workspace))
    platform = client.create_platform_component(
        name='amc_bsp', hw_design=str(xsa), os='freertos',
        cpu='psv_cortexr5_0', domain_name='amc_r5', no_boot_bsp=True)
    domain = platform.get_domain(name='amc_r5')
    for key, value in [('freertos_tick_rate', '10000'),
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
    for key, value in [('configTICK_RATE_HZ', '10000'),
                       ('configTOTAL_HEAP_SIZE', '131072'),
                       ('configSUPPORT_STATIC_ALLOCATION', '1')]:
        match = re.search(r'^\s*#define\s+' + key + r'\s+(.+)$', config, re.M)
        if not match or not re.search(r'\b' + value + r'\b', match[1]):
            raise RuntimeError(f'Unexpected generated FreeRTOS setting: {key}')
    (workspace / 'bsp.complete').touch()
finally:
    vitis.dispose()
