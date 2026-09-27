#!/usr/bin/env python3
"""Build/run the exact KS fixture using Xsim (host only, no FPGA access)."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("vector", type=Path)
p.add_argument("build", type=Path, help="fresh simulation root")
p.add_argument("--seconds", type=int, default=180)
p.add_argument("--inject-ref-error", action="store_true", help="negative control: must fail at coefficient zero")
p.add_argument("--cached", action="store_true", help="replay through real KSK loader/cache and manager")
p.add_argument("--axi-stagger", action="store_true", help="vary the modeled memory response latency per port")
p.add_argument("--inject-mem-error", action="store_true", help="negative control: corrupt first modeled HBM word")
a = p.parse_args()
repo = Path(__file__).resolve().parents[1]
vector, build = a.vector.resolve(), a.build.resolve()
if not vector.is_dir() or build.exists():
    p.error("vector must exist and build must be fresh")
if a.seconds <= 0:
    p.error("seconds must be positive")
if (a.axi_stagger or a.inject_mem_error) and not a.cached:
    p.error("AXI options require --cached")
gen = repo / "hw/module/pep_key_switch/simu/tb_pep_key_switch_vector/gen"
(gen / "rtl").mkdir(parents=True, exist_ok=True)
(gen / "info").mkdir(exist_ok=True)
env = dict(os.environ, PROJECT_DIR=str(repo), PROJECT_SIMU_TOOL="xsim",
           PYTHONPATH=str(repo / "edalize"))

def run(args):
    subprocess.run([str(x) for x in args], cwd=repo, env=env, check=True)

run([sys.executable, "hw/module/param/scripts/gen_param_tfhe_definition_pkg.py", "-f",
     "-N", 2048, "-g", 1, "-K", 879, "-q", "2**64", "-W", 64, "-l", 1, "-b", 23,
     "-L", 8, "-B", 2, "-r", "2**21", "-V", 21, "-d", 1,
     "-o", gen / "rtl/param_tfhe_definition_pkg.sv"])
run([sys.executable, "hw/module/pe_pbs/module/pep_common/scripts/gen_pep_batch_definition_pkg.py",
     "-f", "-c", 12, "-H", 27, "-o", gen / "rtl/pep_batch_definition_pkg.sv"])
run([sys.executable, "hw/module/pep_key_switch/module/pep_ks_common/scripts/gen_pep_ks_common_definition_pkg.py",
     "-f", "-lbx", 3, "-lby", 64, "-lbz", 3, "-o", gen / "rtl/pep_ks_common_definition_pkg.sv"])
run([sys.executable, "hw/scripts/create_module/create_file_list.py", "-o", gen / "info/file_list.json",
     "-p", gen / "rtl", "-R", "param_tfhe_definition_pkg.sv", "simu", 0, 1,
     "-R", "pep_batch_definition_pkg.sv", "simu", 0, 1,
     "-R", "pep_ks_common_definition_pkg.sv", "simu", 0, 1,
     "-F", "param_tfhe_definition_pkg.sv", "APPLICATION", "APPLI_simu",
     "-F", "pep_batch_definition_pkg.sv", "PEP_BATCH", "PEP_BATCH_bpbs12_tpbs27",
     "-F", "pep_ks_common_definition_pkg.sv", "KSLB", "KSLB_x3y64z3"])
# timeout covers the full subprocess tree, not just the launcher.
run(["timeout", "-k", "5s", f"{a.seconds}s", sys.executable, "hw/scripts/edalize/run_edalize.py",
     "-m", "tb_pep_key_switch_vector", "-t", "xsim", "-d", build, "-s", 42,
     "-F", "APPLICATION", "APPLI_simu", "-F", "PEP_BATCH", "PEP_BATCH_bpbs12_tpbs27",
     "-F", "KSLB", "KSLB_x3y64z3", "-P", "VECTOR_DIR", "str", vector,
     "-F", "KSK_CUT", "KSK_CUT_16", "-F", "KSK_SLOT", "KSK_SLOT_8",
     "-F", "AXI_DATA_W", "AXI_DATA_W_256", "-F", "TOP_PC", "TOP_PC_pem2_glwe1_bsk16_ksk16",
     "-F", "TOP_PCMAX", "TOP_PCMAX_pem2_glwe1_bsk16_ksk16",
     "-P", "INJECT_REF_ERROR", "int", int(a.inject_ref_error),
     "-P", "USE_KSK_PIPE", "int", int(a.cached),
     "-P", "AXI_STAGGER", "int", int(a.axi_stagger),
     "-P", "INJECT_MEM_ERROR", "int", int(a.inject_mem_error)])
# Some simulators report success even after $fatal; require the positive verdict.
log = build / "xsim/tb_pep_key_switch_vector/xsim.log"
text = log.read_text()
if "KS_VECTOR_PASS:" not in text or "Fatal:" in text or "FAILURE" in text:
    raise SystemExit("KS replay did not pass; inspect xsim.log")
if a.cached and "KSK_PIPE_PASS:" not in text:
    raise SystemExit("KSK pipeline replay did not pass")
