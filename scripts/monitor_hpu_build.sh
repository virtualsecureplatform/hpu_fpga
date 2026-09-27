#!/usr/bin/env bash
# Detached, read-only build checks every 30 minutes; exits when the build ends.
set -eo pipefail
monitor_dir=$(realpath "${1:?BUILD_DIRECTORY required}")
monitor_pid=$(<"$monitor_dir/build.pid")
[[ "$monitor_pid" =~ ^[0-9]+$ ]] || exit 1
cd "$monitor_dir"
while :; do
    date -u '+%Y-%m-%d %H:%M:%S UTC'
    ps -eo pid,pgid,etime,time,stat,rss,comm | awk -v group="$monitor_pid" 'NR == 1 || $2 == group'
    free -h
    if [[ -f top_hpu/prj.runs/impl_1/runme.log ]]; then
        monitor_log=top_hpu/prj.runs/impl_1/runme.log
    else
        monitor_log=launcher.log
    fi
    stat -c 'Last log update: %y (%s bytes)' "$monitor_log"
    rg '(^Phase [0-9]|Timing Summary|^ERROR:|^HPU processing clock|Design_Linking|write_device_image completed)' "$monitor_log" | tail -12 || true
    tail -5 "$monitor_log"
    if [[ -f ip_status_before_synthesis.rpt ]]; then
        rg 'hpu_plug_mrmac_0_core_0 ' ip_status_before_synthesis.rpt || true
    fi
    find . -maxdepth 4 -type f \( -name '*.pdi' -o -name '*routed.dcp' \) -printf '%TY-%Tm-%Td %TH:%TM %s %p\n'
    if [[ -f exit_status ]]; then
        printf 'Build exit status: '
        cat exit_status
        cat finished_at
        break
    fi
    if ! kill -0 "$monitor_pid" 2>/dev/null; then
        printf 'Build launcher disappeared without an exit-status file; inspect worker processes above.\n'
        break
    fi
    printf '\n'
    sleep 1800
done
