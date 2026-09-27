#!/usr/bin/env bash
set -eo pipefail
timing_output=$(realpath "${1:?OUTPUT_DIRECTORY required}")
cd "${PROJECT_DIR:?PROJECT_DIR required}"
export XILINX_PATH=/home/opt/xilinx
source ./setup.sh base
export HPU_FREQ_MHZ=350 HPU_MAX_THREADS=8 HPU_STOP_AFTER_ROUTE=1
export HPU_BUILD_OUTDIR="$timing_output"
export PATH="$XILINX_VIVADO/bin:$PATH"
cd versal
bash run_syn_hpu_3parts_psi64.sh
test -s "$timing_output/top_hpu/prj.runs/impl_1/top_hpu_routed.dcp"
test -f "$timing_output/top_hpu/prj.runs/impl_1/.route_design.end.rst"
touch "$timing_output/fresh.complete"
