#!/usr/bin/env bash
set -euo pipefail

# Install and configure the upstream 2025.2 QDMA PF driver for the V80 user PF.
# AMR continues to own management PF 0 (10ee:50b4); only PF 1 (10ee:50b5)
# is handed to QDMA.

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "${script_dir}/.." && pwd)
qdma_dir="${repo_dir}/third_party/dma_ip_drivers/QDMA/linux-kernel"

if [[ ! -d ${qdma_dir} ]]; then
  echo "Missing QDMA submodule. Run: git submodule update --init --recursive" >&2
  exit 1
fi

# NFS root squashing can deny root access to the user's checkout, including
# writes performed by make. Stage as the invoking user on local disk first.
if [[ ${EUID} -ne 0 ]]; then
  stage_dir=$(mktemp -d /var/tmp/hpu-amr-host.XXXXXXXX)
  mkdir -p "${stage_dir}/scripts" "${stage_dir}/third_party/dma_ip_drivers/QDMA"
  cp "${BASH_SOURCE[0]}" "${stage_dir}/scripts/setup_amr_host.sh"
  cp -R "${qdma_dir}" "${stage_dir}/third_party/dma_ip_drivers/QDMA/linux-kernel"
  echo "Staged host setup on local disk: ${stage_dir}"
  echo "Requesting sudo to build, install and configure QDMA."
  echo "Staging files are retained for troubleshooting."
  cd "${stage_dir}"
  exec sudo -- /bin/bash "${stage_dir}/scripts/setup_amr_host.sh"
fi

if [[ ! -d /lib/modules/$(uname -r)/build ]]; then
  echo "Missing kernel headers for $(uname -r). Install linux-headers-$(uname -r)." >&2
  exit 1
fi
if [[ ! -f /usr/include/libaio.h ]]; then
  echo "Missing libaio headers. Install libaio-dev before building QDMA tools." >&2
  exit 1
fi

make -C "${qdma_dir}/driver" clean
make -C "${qdma_dir}/driver" mod_pf modulesymfile=Module.symvers TANDEM_BOOT_SUPPORTED=1 -j"$(nproc)"
make -C "${qdma_dir}/apps" clean
# The upstream app targets clean shared objects, so build them serially.
make -C "${qdma_dir}/apps" apps -j1
install -D -m 0644 "${qdma_dir}/bin/qdma-pf.ko" "/lib/modules/$(uname -r)/extra/qdma-pf.ko"
install -m 0755 "${qdma_dir}/bin/dma-ctl" /usr/local/sbin/dma-ctl
install -m 0755 "${qdma_dir}/bin/dma-to-device" /usr/local/sbin/dma-to-device
install -m 0755 "${qdma_dir}/bin/dma-from-device" /usr/local/sbin/dma-from-device
depmod -a
modprobe qdma-pf

mapfile -t user_pfs < <(lspci -Dnnd 10ee:50b5 | awk '{print $1}')
if [[ ${#user_pfs[@]} -eq 0 ]]; then
  echo "No V80 user PF (10ee:50b5) was found." >&2
  exit 1
fi

for bdf in "${user_pfs[@]}"; do
  sysfs="/sys/bus/pci/devices/${bdf}"
  if [[ -L ${sysfs}/driver ]]; then
    current=$(basename "$(readlink -f "${sysfs}/driver")")
    if [[ ${current} != qdma-pf && ${current} != qdma_pf ]]; then
      echo "${bdf}" > "${sysfs}/driver/unbind"
    fi
  fi
done

# The upstream driver intentionally has no static V80 ID.
if ! grep -q '^10ee 50b5' /sys/bus/pci/drivers/qdma-pf/new_id 2>/dev/null; then
  echo '10ee 50b5' > /sys/bus/pci/drivers/qdma-pf/new_id || true
fi

for bdf in "${user_pfs[@]}"; do
  sysfs="/sys/bus/pci/devices/${bdf}"
  if [[ ! -L ${sysfs}/driver ]]; then
    echo "${bdf}" > /sys/bus/pci/drivers/qdma-pf/bind
  fi
  if [[ $(<"${sysfs}/qdma/qmax") != 100 ]]; then
    echo 100 > "${sysfs}/qdma/qmax"
  fi

  short=${bdf#0000:}
  bus=${short%%:*}
  qdev="qdma${bus}001"
  # q add creates the character device before the queue is started. Query
  # state so reruns also recover queues left configured by an earlier failure.
  for idx in 1 2 3 4; do
    direction=h2c
    (( idx % 2 )) || direction=c2h  # tfhe-rs lanes: odd h2c, even c2h
    if [[ ! -e /dev/${qdev}-MM-${idx} ]]; then
      dma-ctl "${qdev}" q add idx "${idx}" mode mm dir "${direction}"
    fi
    queue_state=$(dma-ctl "${qdev}" q list "${idx}" 1)
    if ! grep -Eq "${direction^^} online[[:space:]]*$" <<< "${queue_state}"; then
      dma-ctl "${qdev}" q start idx "${idx}" dir "${direction}"
    fi
    queue_state=$(dma-ctl "${qdev}" q list "${idx}" 1)
    if ! grep -Eq "${direction^^} online[[:space:]]*$" <<< "${queue_state}"; then
      echo "${qdev} queue ${idx} (${direction}) did not come online: ${queue_state}" >&2
      exit 1
    fi
  done
done

# Development-machine permissions. Replace with a dedicated group/udev rule on
# shared systems.
chmod a+rw /dev/ami* /dev/qdma*-MM-[1-4]

echo "AMR management PF preserved; QDMA user queues are ready."
ami_tool overview
dma-ctl dev list
