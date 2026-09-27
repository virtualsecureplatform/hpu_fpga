#!/usr/bin/env python3
"""Host-only exact two-product MMACC replay with four zero-rotation padding steps."""
import argparse
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("vector", type=Path)
p.add_argument("build", type=Path)
p.add_argument("--inject-ref-error", action="store_true")
a = p.parse_args()
repo = Path(__file__).resolve().parents[1]
vector, build = a.vector.resolve(), a.build.resolve()
if not vector.is_dir() or build.exists():
    p.error("vector must exist and build must be fresh")
env = dict(os.environ, PROJECT_DIR=str(repo), PROJECT_SIMU_TOOL="xsim", PYTHONPATH=str(repo / "edalize"))
subprocess.run([
    "timeout", "-k", "5s", "300s", "bash",
    "hw/module/pep_mono_mult_acc/simu/tb_pep_mono_mult_acc/scripts/run.sh",
    "-R", "2", "-S", "11", "-P", "64", "-g", "1", "-W", "64", "-q", "2**64",
    "-c", "12", "-H", "27", "-G", "3", "-K", "6", "-X", "3", "--",
    "-d", str(build), "-s", "42", "-F", "PEP_MSPLIT", "PEP_MSPLIT_main2_subs2",
    "-P", "SLR_LATENCY", "int", "4", "-P", "URAM_LATENCY", "int", "4",
    "-P", "INST_THROUGHPUT", "int", "1023",
    "-P", "SAMPLE_THROUGHPUT_NB", "int", "1", "-P", "SAMPLE_RANDOM_NB", "int", "0",
    "-P", "VECTOR_DIR", "str", str(vector),
    "-P", "VECTOR_INJECT_ERROR", "int", str(int(a.inject_ref_error)),
], cwd=repo, env=env, check=True)
log = (build / "xsim/tb_pep_mono_mult_acc/xsim.log").read_text()
if "MMACC_VECTOR_PASS:" not in log or "SUCCEED !" not in log or "Fatal:" in log or "FAILURE" in log:
    raise SystemExit("MMACC replay did not pass; inspect xsim.log")
