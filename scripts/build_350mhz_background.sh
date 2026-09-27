#!/usr/bin/env bash
# Launch with nohup setsid -f and redirected stdin/stdout/stderr in a fresh
# output directory, so the build survives cleanup of the launching shell group.
set -eo pipefail
build_repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_output=${1:?Usage: build_350mhz_background.sh OUTPUT_DIRECTORY}
build_output=$(realpath "$build_output")
if [[ -e "$build_output/build.pid" || -e "$build_output/top_hpu" ]]; then
    echo "Refusing to reuse an existing build directory: $build_output" >&2
    exit 1
fi
printf '%s\n' "$$" > "$build_output/build.pid"
trap 'build_rc=$?; printf "%s\n" "$build_rc" > "$build_output/exit_status"; date -u > "$build_output/finished_at"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
date -u > "$build_output/started_at"
cd "$build_repo"
export XILINX_PATH=${XILINX_PATH:-/home/opt/xilinx}
source ./setup.sh base
export PATH="/home/kmatsuoka/.cargo/bin:$XILINX_VIVADO/bin:$PATH"
export HPU_FREQ_MHZ=350
export HPU_BUILD_OUTDIR="$build_output"
cd versal
build_rc=0
bash run_syn_hpu_3parts_psi64.sh || build_rc=$?
if (( build_rc != 0 )); then
    exit "$build_rc"
fi
# A successful launcher alone is insufficient: require its resulting image.
if [[ ! -s "$build_output/top_hpu.pdi" ]]; then
    echo "Build returned without producing $build_output/top_hpu.pdi" >&2
    exit 1
fi
