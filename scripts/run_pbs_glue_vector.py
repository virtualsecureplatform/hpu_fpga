#!/usr/bin/env python3
"""Bounded host-only checks of PBS body correction and BSK delivery."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("vector", type=Path)
p.add_argument("--mode", choices=["body", "bsk"], required=True)
p.add_argument("build", type=Path, help="fresh simulation root")
p.add_argument("--seconds", type=int, default=300)
p.add_argument("--inject-ref-error", action="store_true")
p.add_argument("--axi-stagger", action="store_true")
a = p.parse_args()
repo = Path(__file__).resolve().parents[1]
vector, build = a.vector.resolve(), a.build.resolve()
if not vector.is_dir() or build.exists() or a.seconds <= 0:
    p.error("vector must exist, build must be fresh, and timeout must be positive")
bench = repo / "hw/module/number_theoretic_transform/module/ntt_core_gf64/simu/tb_ntt_pbs_vector"
module = "tb_body_vector" if a.mode == "body" else "tb_bsk_vector"
gen = bench / "gen"
(gen / "rtl").mkdir(parents=True, exist_ok=True)
(gen / "info").mkdir(exist_ok=True)
env = dict(os.environ, PROJECT_DIR=str(repo), PROJECT_SIMU_TOOL="xsim", PYTHONPATH=str(repo / "edalize"))

def run(args):
    subprocess.run([str(x) for x in args], cwd=repo, env=env, check=True)

run([sys.executable, "hw/module/param/scripts/gen_param_tfhe_definition_pkg.py", "-f",
     "-N", 2048, "-g", 1, "-K", 879, "-q", "2**64", "-W", 64, "-l", 1, "-b", 23,
     "-L", 8, "-B", 2, "-r", "2**21", "-V", 21, "-d", 1,
     "-o", gen / "rtl/param_tfhe_definition_pkg.sv"])
run([sys.executable, "hw/module/pe_pbs/module/pep_common/scripts/gen_pep_batch_definition_pkg.py",
     "-f", "-c", 12, "-H", 27, "-o", gen / "rtl/pep_batch_definition_pkg.sv"])
run([sys.executable, "hw/scripts/create_module/create_file_list.py", "-o", gen / "info/file_list.json",
     "-p", gen / "rtl", "-R", "param_tfhe_definition_pkg.sv", "simu", 0, 1,
     "-R", "pep_batch_definition_pkg.sv", "simu", 0, 1,
     "-F", "param_tfhe_definition_pkg.sv", "APPLICATION", "APPLI_simu",
     "-F", "pep_batch_definition_pkg.sv", "PEP_BATCH", "PEP_BATCH_bpbs12_tpbs27"])
run(["timeout", "-k", "5s", f"{a.seconds}s", sys.executable, "hw/scripts/edalize/run_edalize.py",
     "-m", module, "-t", "xsim", "-d", build, "-s", 42,
     "-F", "APPLICATION", "APPLI_simu", "-F", "PEP_BATCH", "PEP_BATCH_bpbs12_tpbs27",
     "-F", "NTT_CORE_R", "NTT_CORE_R_2", "-F", "NTT_CORE_PSI", "NTT_CORE_PSI_64",
     "-F", "NTT_CORE_RDX_CUT", "NTT_CORE_RDX_CUT_n5c6", "-F", "NTT_MOD", "NTT_MOD_goldilocks",
     "-F", "NTT_CORE_ARCH", "NTT_CORE_ARCH_gf64",
     "-P", "VECTOR_DIR", "str", vector,
     "-P", "INJECT_REF_ERROR", "int", int(a.inject_ref_error),
     "-P", "AXI_STAGGER", "int", int(a.axi_stagger),
     "-F", "BSK_CUT", "BSK_CUT_16", "-F", "BSK_SLOT", "BSK_SLOT_8",
     "-F", "AXI_DATA_W", "AXI_DATA_W_256",
     "-F", "TOP_PC", "TOP_PC_pem2_glwe1_bsk16_ksk16",
     "-F", "TOP_PCMAX", "TOP_PCMAX_pem2_glwe1_bsk16_ksk16"])
log = (build / f"xsim/{module}/xsim.log").read_text()
if f"{a.mode.upper()}_VECTOR_PASS:" not in log or "Fatal:" in log or "FAILURE" in log:
    raise SystemExit("PBS replay did not pass; inspect xsim.log")
