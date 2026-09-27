#!/usr/bin/env bash
# Use nohup setsid -f with all standard streams redirected.
set -eo pipefail
retry_repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
retry_project=${1:?PROJECT_XPR required}
retry_output=${2:?RETRY_DIR required}
retry_output=$(realpath "$retry_output")
test ! -e "$retry_output/build.pid"
printf '%s\n' "$$" > "$retry_output/build.pid"
trap 'retry_rc=$?; printf "%s\n" "$retry_rc" > "$retry_output/exit_status"; date -u > "$retry_output/finished_at"' EXIT
date -u > "$retry_output/started_at"
cd "$retry_repo"
export XILINX_PATH=${XILINX_PATH:-/home/opt/xilinx}
source ./setup.sh base
export HPU_FREQ_MHZ=350
"$XILINX_VIVADO/bin/vivado" -mode batch -nojournal \
    -log "$retry_output/vivado.log" \
    -source "$retry_repo/versal/scripts/retry_device_image.tcl" \
    -tclargs "$retry_project" "$retry_output"
