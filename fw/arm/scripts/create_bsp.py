# Creates the AMC BSP from the XSA with the Vitis python API, run by build_bsp.sh as
#   vitis -s create_bsp.py <xsa> <os> <tick_hz> <heap> <debug>
# The BSP comes from a system device tree. The 2026.1 generator crashes on our MRMAC, so a
# patched copy of it is used through CUSTOM_SDT_REPO.
import os
import shutil
import subprocess
import sys

import vitis

sys.stdout.reconfigure(line_buffering=True)  # progress visible through build.sh's tee pipe

MRMAC_WARNING = 'dtg_warning "No GPIO Path detected...please check the design..."'


def find_sdt_repo():
    """Path of the generator repository used by sdtgen (.../system-device-tree-xlnx)."""
    out = subprocess.run(["sdtgen", "-eval", "puts [sdtgen get_dt_param -repo]"],
                         capture_output=True, text=True).stdout
    for line in reversed(out.splitlines()):
        if os.path.isfile(os.path.join(line.strip(), "device_tree", "data", "device_tree.tcl")):
            return line.strip()
    sys.exit("Error: system device tree repository not found (sdtgen get_dt_param -repo)")


def patched_sdt_repo(dst):
    """Private copy of the generator repository with the MRMAC crash fixed."""
    src = find_sdt_repo()
    print(f"sdt repo   ==> {src}")
    shutil.copytree(src, dst)
    # the install is read-only; the copy must be writable for the patch and for the next clean
    for dirpath, _, filenames in os.walk(dst):
        os.chmod(dirpath, 0o755)
        for name in filenames:
            path = os.path.join(dirpath, name)
            if not os.path.islink(path):
                os.chmod(path, 0o644)
    mrmac = os.path.join(dst, "mrmac", "data", "mrmac.tcl")
    text = open(mrmac).read()
    if MRMAC_WARNING not in text:
        sys.exit(f"Error: MRMAC generator changed, patch point not found in {mrmac}")
    # neither the old nor the new GT reset topology: skip the GT gpio properties
    text = text.replace(MRMAC_WARNING, MRMAC_WARNING + '\n                 set mode "none"', 1)
    open(mrmac, "w").write(text)
    return dst


def explain_sdt_failure(repo, xsa, outdir):
    """Vitis hides the generator error: run the generator alone to show it, then exit."""
    cmd = ["sdtgen", "-eval",
           f"sdtgen set_dt_param -repo {repo} -xsa {xsa} -dir {outdir}; generate_sdt"]
    result = subprocess.run(cmd, text=True, capture_output=True)
    print(result.stdout)
    print(result.stderr)
    sys.exit("Error: platform creation failed, see the sdtgen output above")


xsa, os_name, tick_rate_hz, heap_size, freertos_debug = sys.argv[1:6]
# the justfile passes the classic BSP name; the unified API names the OS "freertos"
if os_name.startswith("freertos"):
    os_name = "freertos"
domain_name = f"{os_name}_domain"
print(f"config xsa ==> {xsa}")
print(f"config os  ==> {os_name}")

# a fresh tree: fw/arm holds the metadata of the classic workspace, which Vitis Unified rejects
root = os.path.abspath("amc_bsp")
if os.path.isdir(root):
    shutil.rmtree(root)
workspace = os.path.join(root, "ws")
os.makedirs(workspace)

repo = patched_sdt_repo(os.path.join(root, "sdt_repo"))
os.environ["CUSTOM_SDT_REPO"] = repo  # picked up by the sdtgen run inside the Vitis server

client = vitis.create_client()
client.set_workspace(workspace)
try:
    platform = client.create_platform_component(name="amc_bsp", hw_design=xsa, os=os_name,
                                                cpu="psv_cortexr5_0", domain_name=domain_name)
except Exception as err:
    print(f"Error: {err}")
    vitis.dispose()
    explain_sdt_failure(repo, xsa, os.path.join(root, "sdt"))
domain = platform.get_domain(name=domain_name)
try:
    # stdin/stdout: the BSP defaults to the first UARTPSV instance (psv_sbsauart_0 on the V80)
    # xilfpga brings xilmailbox and xilsecure in as dependencies (set_lib refuses duplicates)
    domain.set_lib(lib_name="xilfpga")
    domain.set_config(option="os", param="freertos_tick_rate", value=tick_rate_hz)
    domain.set_config(option="os", param="freertos_total_heap_size", value=heap_size)
    domain.set_config(option="os", param="freertos_support_static_allocation", value="true")
    if freertos_debug == "1":
        domain.set_config(option="os", param="freertos_generate_runtime_stats", value="1")
        domain.set_config(option="os", param="freertos_use_trace_facility", value="true")
        domain.set_config(option="os", param="freertos_use_stats_formatting_functions",
                          value="true")
except Exception as err:
    print(f"Error: BSP configuration failed: {err}")
    print(f"OS settings: {domain.get_os()}")
    print("Valid parameters: domain.list_params('os', '<os>') in 'vitis -i'")
    vitis.dispose()
    sys.exit(1)

status = platform.build()
print(f"platform build ==> {status}")
vitis.dispose()
