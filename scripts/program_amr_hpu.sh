#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script as root: sudo $0 <firmware-merged.pdi> [device]" >&2
  exit 1
fi
if [[ $# -lt 1 || $# -gt 2 || ! -f $1 ]]; then
  echo "Usage: sudo $0 <firmware-merged.pdi> [BB:DD.F]" >&2
  exit 2
fi

pdi=$(readlink -f "$1")
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Reject the old, timing-closed but AVED-derived image before any board write.
python3 "${script_dir}/../fw/arm/scripts/verify_amr_release.py" "$pdi"
device=${2:-}
if [[ -z ${device} ]]; then
  mapfile -t devices < <(lspci -Dnnd 10ee:50b4 | awk '{print $1}' | sed 's/^0000://')
  if [[ ${#devices[@]} -ne 1 ]]; then
    echo "Specify a device; discovered ${#devices[@]} V80 management PFs." >&2
    exit 1
  fi
  device=${devices[0]}
fi

ami_tool overview
echo "Programming recovery-safe OSPI partition 1 on ${device} with ${pdi}"
read -r -p "Type YES to program partition 1 (partition 0 stays intact): " confirmation || {
  echo "Programming cancelled; no flash write requested." >&2
  exit 1
}
if [[ ${confirmation} != YES ]]; then
  echo "Programming cancelled; no flash write requested." >&2
  exit 1
fi

# AMI 3.0 returns success even when its own confirmation prompt aborts. The
# script's explicit confirmation above lets us skip that prompt. -q prevents
# cfgmem_program from immediately selecting partition 1 and hot-resetting.
ami_tool cfgmem_program -d "${device}" -t primary -i "${pdi}" -p 1 -y -q

fpt_info=$(ami_tool cfgmem_info -d "${device}" -t primary)
printf '%s\n' "$fpt_info"
read -r programmed_size programmed_md5 < <(
  printf '%s\n' "$fpt_info" | awk -F '|' '
    $1 ~ /^[[:space:]]*1[[:space:]]*$/ {
      gsub(/[[:space:]]/, "", $5)
      gsub(/[[:space:]]/, "", $6)
      print $5, $6
    }'
)
expected_size=$(printf '0x%08x' "$(stat -c %s "$pdi")")
expected_md5=$(md5sum "$pdi")
expected_md5=${expected_md5%% *}
if [[ ${programmed_size:-} != "$expected_size" || ${programmed_md5:-} != "$expected_md5" ]]; then
  echo "Partition 1 verification failed: expected ${expected_size} ${expected_md5}; got ${programmed_size:-missing} ${programmed_md5:-missing}. Do not boot partition 1." >&2
  exit 1
fi
echo "Programming complete. Reboot into partition 1 using the machine's AMR boot-selection procedure."
echo "Partition 0 was not modified and remains the recovery image."
