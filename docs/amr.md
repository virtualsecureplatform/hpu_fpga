# HPU on AMD AMR (branch `amr2026`)

Upstream `main` targets Zama's AVED fork: its firmware and host driver replace AMD's
board management. This branch runs the same HPU on an Alveo V80 that keeps the stock
**AMD AMR 3.0** management stack (`ami` driver and AMC firmware, revision `bb929d3`)
and the upstream Xilinx QDMA driver. No Zama kernel driver is needed.

The branch is `main` plus the smallest set of changes that AMR needs, so that the
FPGA design keeps upstream's timing closure flow (Vivado 2026.1, pinned NoC solution,
400 MHz). The earlier `amr` branch (350 MHz, based on the August 2026 `main`) holds the
bring-up history, its signoff tooling and the investigation notes.

## What differs from `main`

| Area | Change |
| --- | --- |
| PCIe address map (`versal/scripts/bd/bd_main.tcl`, `bd_noc_wrapper.tcl`) | PF0 BAR0 `0x0..0x7fffff` maps to DDR `0x10000000` (AMR sGCQ and payload). HPU and MHDMA registers move to BAR0 `0x02000000..0x0205ffff`. |
| NoC pin (`versal/constraints/noc/top_hpu_psi64.ncr`) | The pinned NoC solution carries the PCIe remaps; only those seven entries are changed to the AMR map. Routing and QoS are upstream's. |
| Firmware (`fw/arm/amr/`) | AMR's AMC firmware is built with the HPU application linked in. `hpu_app.c` is generated from `src/amc.c`; `ucore.c`, `mhdma_driver.c`, `stream_isc.c` and `ucore_lat.c` are used unchanged. |
| Build knobs | `HPU_FREQ_MHZ` (350 or 400), `HPU_MAX_THREADS`, `HPU_SYNTH_JOBS`, `HPU_BUILD_OUTDIR`, `HPU_STOP_AFTER_ROUTE`. Defaults are upstream's. |
| Packaging | `scripts/build_amr_image.py` merges the PL image and the firmware into one PDI and writes a release manifest. |
| Host | `scripts/setup_amr_host.sh` (QDMA on PF1), `scripts/program_amr_hpu.sh` (flash partition 1). |

The RTL, the clock and reset structure, the constraints and the implementation hooks
are upstream's. The PL design therefore differs from the AVED one only in the NoC
address remaps of the PCIe management port.

## Image contract

`fw/arm/amr/interface.json` is the reference; `scripts/test_amr_interface.py` checks it
against the firmware sources.

- The host reaches HPU shared memory (`0x38000000`: IOp queue, ack queue, firmware
  tables, trace) through QDMA on PF1, not through BAR0.
- The last page of the AMR management window is excluded from AMR allocation. At BAR0
  `0x7ff000` five little-endian `u32` report: magic `0x48505541`, ABI `1`, ucore major,
  ucore minor, state (0 starting, 1 ready, 2 failed).
- Queue layout and IOp/DOp encoding are upstream's HIS 3.1 (`UCORE_VERSION` 3.1). The
  ack queue tail is at `0x38210040`.
- AMR reports the PLM PL-node unique id as logic UUID. The release manifest records it
  as `expected_uuid`.

## Build

Requirements: Vivado and Vitis 2026.1, `just`, an AMR 3.0.0 checkout with the HPU hook
applied, about 80 GiB of free memory.

```bash
git submodule update --init
git -C <AMR> checkout bb929d3
git -C <AMR> apply <hpu_fpga>/fw/arm/amr/amr-3.0.0-hpu.patch

export XILINX_PATH=/path/to/xilinx          # holds 2026.1/Vivado and 2026.1/Vitis
scripts/build_amr_psi64.sh versal/output_amr_psi64 <AMR>/fw/AMC
```

The script runs upstream's `run_syn_hpu_3parts_psi64.sh` (more than ten hours) and then
`scripts/build_amr_image.py`. The result is `versal/output_amr_psi64/release/`:
`hpu_psi64_400mhz_amr.pdi`, `amc.elf`, `hpu_plug.xsa`, `release_manifest.json`.
Packaging refuses a build that misses timing unless `HPU_ALLOW_TIMING_FAILURE=1`.

To package an existing Vivado output, or to rebuild only the firmware:

```bash
scripts/build_amr_image.py versal/output_amr_psi64 <release dir> --amr-source <AMR>/fw/AMC
```

After an upstream change of `fw/arm/src/amc.c`, regenerate the application and review
the diff:

```bash
fw/arm/amr/extract_hpu_app.py
python3 scripts/test_amr_interface.py
```

## Deploy

```bash
python3 fw/arm/scripts/verify_amr_release.py <release>/hpu_psi64_400mhz_amr.pdi
sudo scripts/program_amr_hpu.sh <release>/hpu_psi64_400mhz_amr.pdi [BB:DD.F]
```

`program_amr_hpu.sh` asks for confirmation, writes flash partition 1 only and verifies
it. It does not select the partition or reboot; partition 0 stays as the recovery
image. After booting partition 1, run `scripts/setup_amr_host.sh` again if PCIe
re-enumeration removed the QDMA queues.

## Host software

The backend must speak HIS 3.1 and the AMR control path:

- tfhe-rs with the `hpu-v80-amr` feature (`ffi/v80/amr.rs`) on a tfhe-rs revision that
  matches this firmware (zama-ai/tfhe-rs `main` of November 2026 or later).
- In the V80 configuration: `[fpga.ffi.V80Amr]` with `expected_uuid` from the release
  manifest. This PL uses the natural ciphertext order; the `RadixReversed`
  compatibility mode was only for images built from the old `amr` branch.

## Validation status

See the commit message of the branch head and the build directory's `status.log` for
what has been run. Block-design validation, the interface tests and a firmware compile
do not show that an image works on the board; only a tfhe-rs run against the
programmed image does.
