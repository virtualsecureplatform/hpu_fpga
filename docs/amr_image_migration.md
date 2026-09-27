# AMR-native HPU image migration

This work targets AMD AMR 3.0 (`bb929d3`) on the existing Linux kernel.
No Zama AVED driver is required. No board programming or reboot is part of the build.

The September 15 release passed FPGA timing, but its bundled AMC 3.2.1 is
Zama's AVED-derived firmware. Its hardware GCQ and address map do not match
AMR's sGCQ. Do not deploy that release through the AMR workflow.

## New image contract

- PF0 BAR0 remains 256 MiB; the first 8 MiB maps to DDR `0x10000000` for AMR.
- HPU register blocks move to BAR0 `0x02000000..0x0205ffff`. RPU register
  addresses and PF1 QDMA-visible HPU queue addresses remain unchanged.
- The last page of the management aperture is excluded from AMR allocation.
  At BAR0 `0x7ff000`, five little-endian u32 words report magic `0x48505541`,
  ABI `1`, ucore major `3`, minor `0`, and state (0 initializing, 1 ready, 2 failed).
- `fw/arm/amr/interface.json` records the interface. Firmware uses AMR management
  sources plus the extracted HPU application, not the old `fw/arm/src/amc.c`.
- The backend requires the release's AMR logic UUID and matching HPU status
  before register traffic or QDMA queue configuration. AMR's UUID is the
  zero-extended PLM PL-node UID, not the previous UUID-ROM value.

## Build and validation

`fw/arm/scripts/build_sdt.py` now requires `--amr-source <AMR>/fw/AMC`.
It generates the R5 SDT BSP including xilloader/xilpm and links the HPU
application through the optional `HPU_APP_DIR` AMR CMake integration.
The HPU linker layout keeps application code/data at `0x40000000`, separate
from AMR's management and PDI-transfer buffers and the HPU firmware/queues.

The image launcher snapshots the pinned AMR firmware tree and records its
local patch and file hashes. Packaging checks the XSA's actual address ranges
and NoC translations, then emits `release_manifest.json` with artifact hashes
and `expected_uuid` for the backend configuration. Full timing/CDC/routing/
endpoint signoff must be repeated for the changed FPGA design.

Run `python3 fw/arm/scripts/verify_amr_release.py <release>/hpu_psi64_350mhz_amr.pdi`
before deployment. The programming helper requires this preflight and targets
boot partition 1 only. It never switches the active partition or reboots.
Partition 0 and the known-good AMD recovery image must be preserved.

## Acceptance

Development checks on September 24: native Vivado 2026.1 block-design
validation passed; the combined AMR/HPU firmware compiled with a fresh SDT BSP.
That compile used the previous XSA only as a porting check, not as a deployable
hardware/firmware pair. Release packaging must rebuild against the new XSA.
The firmware uses AMR's Debug build configuration (with warnings treated as
errors). The Linux kernel and installed AMI driver have not been changed.

Source/unit tests and compilation are not evidence of hardware operation.
Native BD validation, full implementation/signoff, and release verification
must pass before a deployment window. After an explicitly authorized deployment,
check AMI READY, sensors/FPT, image identity, DMA, and one tfhe-rs encrypted
operation against its expected decrypted result. No new image is yet board-validated.
