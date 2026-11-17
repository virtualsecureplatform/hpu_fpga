#!/usr/bin/env bash
# Full PSI64 Vivado build of the AMR variant, then AMR release packaging.
# Runs in the foreground; never programs a board. For a detached build:
#   systemd-run --user --unit=hpu-amr-build -p MemoryHigh=76G -p MemoryMax=84G \
#     --setenv=XILINX_PATH=$XILINX_PATH scripts/build_amr_psi64.sh <outdir> <AMR>/fw/AMC
#
# Environment:
#   XILINX_PATH      directory holding <version>/Vivado and <version>/Vitis (required)
#   HPU_FREQ_MHZ     350 or 400 (default 400, as upstream)
#   HPU_MAX_THREADS  Vivado threads (default 8)
#   HPU_SYNTH_JOBS   parallel out-of-context synthesis runs (default 1, for a 96 GiB host)
set -eo pipefail
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <output directory> <AMR fw/AMC source tree>" >&2
  exit 2
fi
: "${XILINX_PATH:?XILINX_PATH is required}"
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$1"
out=$(realpath "$1")
amr=$(realpath "$2")
[[ -f $amr/src/amc.c ]] || { echo "Not an AMR fw/AMC tree: $amr" >&2; exit 2; }

export HPU_FREQ_MHZ=${HPU_FREQ_MHZ:-400}
export HPU_MAX_THREADS=${HPU_MAX_THREADS:-8}
export HPU_SYNTH_JOBS=${HPU_SYNTH_JOBS:-1}
export HPU_BUILD_OUTDIR=$out
status() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" | tee -a "$out/status.log"; }
trap 'status "failed (exit $?)"' ERR

status "start: $(git -C "$repo" describe --always --dirty --abbrev=12), ${HPU_FREQ_MHZ} MHz"
# setup.sh is written for interactive use and reads unset variables.
set +e
source "$repo/setup.sh" base > "$out/setup.log" 2>&1
set -eo pipefail
[[ -x $XILINX_VIVADO/bin/vivado ]] || { echo "Vivado not found, see $out/setup.log" >&2; exit 1; }

cd "$repo/versal"
bash run_syn_hpu_3parts_psi64.sh > "$out/build.log" 2>&1
[[ -f $out/top_hpu_tandem1.pdi && -f $out/top_hpu_tandem2.pdi ]] || {
  echo "Vivado ended without device images, see $out/build.log" >&2; exit 1; }
status "vivado build complete"

python3 "$repo/scripts/build_amr_image.py" "$out" "$out/release" --amr-source "$amr" \
  --vitis "$XILINX_VITIS" ${HPU_ALLOW_TIMING_FAILURE:+--allow-timing-failure} 2>&1 | tee "$out/image.log"
status "release complete: $out/release"
