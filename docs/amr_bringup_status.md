# AMR bring-up on guadalcanal

## Current status: 2026-09-27

The AMR-native IRQ-fixed 350 MHz image is running, with AMI/AMC 3.0.0 and
UUID `00000000000000000000000038624737`. Management reports `READY`.
The encrypted-computation correctness issue is fixed: the host now uses the
radix-reversed ciphertext/KSK layout required by the deployed RTL. All four
two-bit identity inputs, eight-bit addition (including overflow), and bitwise
NOT pass on the board. This is smoke-test validation, not exhaustive coverage.
See [the fix and A/B evidence](ciphertext_order_fix_20260927.md).

Broader board regression now passes **55/55 single-board operation bundles**
with two randomized iterations per operation across 8–128-bit widths.
The two original OVF_ADD failures are [fixed](ovf_add_root_cause_20260927.md):
host-generated programs normalize ZHC 0.9.1's internal carry to a Boolean.
An additional 22 deterministic board cases test real overflow at every
standard width, and a 27-case host regression passes. No PDI/AMR changes were
needed. See the [original run](hpu_test_results_20260927.md) for comparison.

The following investigation notes describe the preceding diagnostic stages;
their outstanding next steps are superseded by the fix report.

The artifact/HBM-map/NTT-table audit passes, as does full BSK/KSK/LUT host
readback after initialization. These checks do not validate internal FPGA key
reads or numerical intermediates. See
[the PBS investigation](pbs_artifact_audit_20260927.md) for evidence,
reproduction commands, limitations, and the next diagnostic boundary.

Follow-up [exact-vector key-switch replay](ks_vector_replay_20260927.md) passes:
all 879 coefficients, corrections, and the body match TFHE-rs. A deliberate
reference error is detected. This validates the KS core in simulation for the
captured vector, not the on-board KSK DMA/cache path or the PBS pipeline.

The [KSK loader/cache integration replay](ks_cache_replay_20260927.md) also
passes with modeled AXI memory: all 5,406,720 used key words reaching the core
match, as do all CPU-reference outputs, with normal and uneven port timing.
A deliberate memory-word corruption is detected. Physical HBM/NoC and the
live KS/PBS boundary remain unverified;
no production RTL change or board operation was made in this follow-up.

The [PBS external-product follow-up](pbs_vector_replay_20260927.md) reproduces
the captured seed/input/KSK offline. A full CPU PBS returns 1; RTL matches all
4,096 coefficients in each of the first two HPU-order external products,
also with input gaps. This checks NTT/BSK multiply/INTT arithmetic, not a full
RTL PBS. Next check: body-correction RAM must produce the reference value
980, followed by the accumulator/rotation paths and BSK cache delivery.

## Historical status: 2026-09-14

The fresh clock-fix attempt completed HPU synthesis (455 warnings, no errors or
critical warnings), then failed placement at 10:13 UTC with NTCN-17. The explicit
window requires an explicit root and track as well. The corrected tuple is
X0Y1:X9Y10 / X5Y7 / track 7. The guard now checks NTCN-17 before placement and
both NTCN-16/17 afterward. The planned recovery directory is
`versal/timing_350_place_tuple_20260914`, using the preserved optimized checkpoint
without repeating synthesis. This supersedes the earlier automatic-root notes.

Hardware execution has not been validated. The September 11 finish-route
experiment failed: preserve-route left one incomplete net, and full unroute
triggered an unsupported calibrated-deskew root/window combination (NTCN-16).
There is still no signed-off, firmware-merged HPU image.

The next changes are implemented: full-SLR clock-window setup before placement,
clock DRC preflight, one shared configuration reset controller, a four-stage
PCIe reset synchronizer before software masking, and common fresh/recovery
routing guards. Whole-design unroute is removed from `finish-route`.
Signoff now binds reports to the checkpoint, checks detailed timing, and
audits the exact 56 GT endpoints against tool/IP identity and live netlist
evidence. No endpoint is accepted merely because its clock is constant.
No native endpoint exemption has been established yet.

Clock-window correction: native Vivado inspection identifies Y0/Y11 as HSR
rows, excluded from legal clock expansion windows. The helper now derives
fabric rows from SLICE sites and returns `CLOCKREGION_X0Y1:CLOCKREGION_X9Y10`.
The old window already covered the fabric height; the previous NTCN-16
failure involved a forced unsupported root/window combination. The fresh
flow leaves root/track selection to placement. The native DRC query was also
corrected to use `get_drc_violations NTCN-16*`.
Automatic root/tree settings use empty strings and automatic track uses -1;
these native reset values replace the unsupported `reset_property` call.
`versal/timing_350_fresh_retry_20260914` was deliberately stopped while waiting
for memory, before synthesis, to make this correction; its Signal 15 is not a
license or synthesis failure. The next build uses
`versal/timing_350_fresh_clockfix_20260914`.

The user restarted `2100@eddystone.sato.lab` (`10.0.0.209`). The September 14
07:27 UTC retry confirmed FlexNet and `xilinxd` UP with licenses available;
Vivado 2026.1 now starts successfully. Native XSim reset simulation and native
clock/reset block-design validation pass. All 60 regression tests pass.
Both native DMA simulations also report `SUCCEED !`: `tb_mhdma_master`
(all 19 scenarios) and `tb_multi_hpu_dma`, with AXI_DATA_W_256, GLWE_K=2,
PEM_PC=2. Logs are preserved in `versal/output_timing_cdc_sim_20260914`.
Checkpoint clock/GT inspection and fresh synthesis/signoff remain separate
from these simulation results; no new image is accepted yet.

The guarded fresh-build attempt `versal/timing_350_fresh_20260914` completed
source/configuration generation, then failed before synthesis with Vivado
status 42. Its authoritative `status.json` records `state: failed` and
`service_result: exit-code`. The 76/84 GiB limits were verified. The source
snapshot, launcher log and generated configuration are preserved. No follow-up
image job was launched.

Host inspection: kernel `6.8.0-139-generic`, 24 logical CPUs, about 90 GiB
available RAM out of 93 GiB, and no swap. PF0 remains bound to `ami`, but
AMI/AMC 3.0.0 reports `INIT_ERROR`. PF1 has no bound driver; `modinfo qdma-pf`
finds no module for the current kernel, and there are no QDMA device nodes.
Kernel logs are not readable by this user, so AMR's initialization failure
has not been diagnosed. No driver installation, board loading, or reboot was
performed.

## Earlier work (historical notes)

The following entries describe the September 8–11 state, not current readiness.

Image-generation work is tracked in [timing_image_flow.md](timing_image_flow.md).
The completed baseline fails timing (setup WNS -0.326 ns, hold WHS -3.473 ns).
A fresh guarded PSI64/350 MHz build is in
`versal/timing_350_fresh_retry_20260908`; check `status.json` for its current
state. The firmware has been ported to the Vitis 2026.1 Python/SDT workflow and
an application ELF has linked with a verified R5 `_boot` entry point. A routed,
signed-off and firmware-merged image is still required before board execution.

## Existing work

- V80 management PF `0000:02:00.0`, serial `XFL1A4U1GPFD`, is READY
  with AMI/AMC 3.0.0. Reported UUID: `00000000000000000000000059b68233`.
- User PF `0000:02:00.1` is bound to QDMA 2025.2.0.0 with `qmax=100`.
  Verified after host installation at approximately 15:27 UTC: queue 1
  (`/dev/qdma02001-MM-1`, H2C) and queue 2 (`/dev/qdma02001-MM-2`, C2H)
  both report `online` and are accessible to the normal user.
- The adjacent `tfhe-rs` checkout already contains the `hpu-v80-amr` feature
  and `V80Amr` configuration. Its AMR ring-buffer tests pass.
- Both `hpu_hlapi` and `hpu_bench` release examples build successfully with
  `hpu-v80-amr`; binaries are in `tfhe-rs/target/release/examples`.
- The upstream QDMA PF module builds against kernel `6.8.0-138-generic`.
  Its userspace tools also build with libaio development files supplied.
- No PDI was found in `versal`. The latest 350 MHz build was terminated
  during physical optimization. Its `exit_status` file says 0, but the
  launcher log shows signal 15; it must not be treated as a successful build.

The saved placement checkpoint is:

```
versal/output_psi64_350mhz_licensed_hC65yl/top_hpu/prj.runs/impl_1/top_hpu_placed.dcp
```

`versal/scripts/recover_route.tcl` can resume routing into a fresh directory.
The earlier run reported about 54 GB peak memory; account for other jobs
before starting it. Review final timing, routing and DRC before generating
an image, then build and merge the HPU firmware using the Versal flow.

## Host installation completed

The following commands have been run successfully. For future reinstallations,
from `hpu_fpga`:

```bash
sudo apt-get install libaio-dev
bash ./scripts/setup_amr_host.sh
```

Run setup as your normal user: it copies the build files to `/var/tmp` before
requesting sudo, avoiding NFS root-access restrictions on the checkout.
The setup script preserves AMI on PF0, installs QDMA on PF1, and verifies
that queues 1 (H2C) and 2 (C2H) are online. Re-run after loading an image
if PCIe re-enumeration removed the queues. This session cannot run sudo
without interactive authentication.

## End-to-end validation after image activation

After generating, reviewing, programming and activating a firmware-merged
HPU image, set `expected_uuid` in the backend's V80 AMR configuration to
the generated image UUID. From `tfhe-rs`:

```bash
cargo test -p tfhe-hpu-backend --features hw-v80-amr --lib ffi::v80::amr::tests
cargo build -p tfhe --release --features hpu-v80-amr --example hpu_hlapi --example hpu_bench -j 2
source setup_hpu.sh --config v80
./target/release/examples/hpu_hlapi
```

The example decrypts its results and checks them against clear arithmetic.
AMR mode expects the HPU image to be active already; it does not program
the FPGA automatically.


## 2026-09-10: report parsing and routing strategy correction

The September 9 reroute completed at 16:24 UTC, including the long DFX DRC.
Both `timing_350_reroute_20260909/routed.dcp` and `postroute_physopt.dcp` exist.
Final setup WNS/TNS were -0.276 ns/-7832.863 ns (78,366 failing endpoints);
hold and pulse-width checks passed. All 2,886,115 routable nets were routed
with zero routing errors. This is not a timing-closed implementation.

The extraction failure was caused by the trailing colon in Vivado 2026.1's
route summary table. The parser now accepts that delimiter and continues to
reject missing counts and incomplete routing. Real signoff reports extract
zero DRC/methodology errors and bus-skew violations, but three critical CDC
findings. Two are reset-source fanout into `usr_1_psr` and
`mhdma_freerun_psr` in the shared configuration clock domain; the third is
combinational logic before the PCIe reset-status GPIO synchronizer. These
remain unwaived. Constant-clock unconstrained endpoints also need auditing.
The corrected signoff gate rejects the saved implementation for negative WNS.

The restart helper had used `route_design -directive Explore`, although the
original project used `AggressiveExplore`. The latter had reached intermediate
WNS/TNS -0.125 ns/-102.784 ns before cancellation; these were not final results.
Worst paths in the completed Explore run have 0–1 logic levels and more than
90% routing delay, including SLR crossings and distributed control signals.
The next experiment restores the original routing effort before changing RTL.
`--route-directive` is now explicit in the launch manifest, with
`AggressiveExplore` as the default. Frequency and timing constraints are unchanged.

Active experiment: `versal/timing_350_aggressive_20260910`, unit
`hpu-timing-1789001917659409496.service`. It starts from the same
`pre_route_physopt_2.dcp`, uses 8 threads, MemoryHigh=76 GiB/MemoryMax=84 GiB,
requires 72 GiB available before launch, and retains the 8 GiB low-memory guard.
Image follow-up `hpu-image-followup-aggressive-20260910.service` now refuses
recovery results without a passing signoff marker, avoiding another expensive
image attempt when implementation signoff has already failed. No board loading.

Validation: 14 regression tests pass, including a real-format route-table
fixture that rejects incomplete routing and a follow-up test that verifies no
image launch after failed recovery signoff. Extraction against the saved real
reports passed; timing acceptance correctly failed. Python compilation, Tcl
completeness, and git diff whitespace checks passed.


## 2026-09-10: bounded single-net repair implementation

The aggressive run completed at 06:20 UTC with WNS/TNS -0.034/-43.090 ns
and 3,018 failing setup endpoints. Its post-route optimization was **skipped**,
not ineffective: Vivado reported an illegal route on SLR-crossing data bit
6244. One missing destination connection and one antenna account for the two
critical routing DRC findings. The route command's successful exit did not
establish complete routing.

Implemented `--phase repair` with exact-net/endpoint validation, one targeted
repair and at most one preserve-route fallback, legal-route checks around
optimization, checkpointed Explore/clock-opt candidates, and non-regression
selection. The recovery status now records signoff separately. Native message
counts and a per-command log slice detect optimization being skipped.
No RTL, clock period, timing exception, CDC waiver, or board state is changed.
The three critical CDC findings and 56 unconstrained endpoints remain gated.

Validation: 23 Python/Tcl regression tests pass. They cover literal bus names,
unexpected defects, successful and exhausted fallback, skipped optimization,
negative numeric slack hidden by report rounding, and rejecting illegal or
regressing candidates. The known saved route report passes repair-input
validation. Python compilation and Tcl completeness checks pass.

Native Vivado 2026.1 smoke test also passed: a real emitted skip warning is
caught even when its native message count stays zero. Repair launched in
`versal/timing_350_repair_20260910` under
`hpu-timing-1789041248892299646.service`, with the 76/84 GiB limits verified.
`hpu-image-followup-repair-20260910.service` waits for passing signoff.
Real checkpoint repair and timing results remain pending.


## 2026-09-10: hold-aware closure phase

The single-net repair completed with zero routing and critical/error DRC
findings. Its Explore candidate reached setup WNS/TNS -0.002/-0.092 ns
(87 endpoints), but had 99 hold failures, WHS -0.021 ns and THS -1.040 ns.
Plain Explore did not request hold fixing. The saved Explore checkpoint is
the input to a new `--phase close-timing` experiment.

The phase runs aggressive hold fixing, followed by at most one combined
ExploreWithAggressiveHoldFix pass, with explicit eligibility-based checkpoint
selection. It permits a setup tradeoff to repair hold; full signoff remains
strict. It does not edit RTL, clock constraints, CDC exceptions, or board state.
Three critical CDC findings and 56 unconstrained endpoints remain unresolved.

Validation: 31 tests pass across timing, repair, and new closure suites.
Tests cover early exit, second-pass input selection, illegal routes, skipped
optimization, ineligible candidates, numeric slack precision, stable ranking,
and the existing image follow-up gate. Python compilation, Tcl completeness,
and launcher CLI validation passed. Real hold-repair results are pending.

Launched in `versal/timing_350_hold_20260910` under
`hpu-timing-1789055459708538119.service`; MemoryHigh=76 GiB and
MemoryMax=84 GiB verified. Image follow-up is
`hpu-image-followup-hold-20260910.service`, conditional on full signoff.


## 2026-09-10: finish routing on the combined hold-fix candidate

The hold experiment stopped at 17:41 UTC without an eligible candidate.
Combined optimization reached zero reported setup violations before hold
fixing. Hold fixing inserted 43 buffers and left two setup violations
(-0.514/-0.447 ns), 54 hold violations (WHS -0.016 ns), and a partial route
on `p2_p1_sll/in_pipe/out_data[5862]_hold_fix_1`. Both setup paths include
inserted hold buffers; they are distinct from the incomplete net.

Implemented `--phase finish-route`: preserve-route AggressiveExplore with
TNS cleanup, followed only if needed by one full unroute/reroute fallback.
Candidate legality/hold/pulse checks, skipped-stage guards in prior phases,
and full image signoff remain enforced. No RTL, clock exceptions, CDC
waivers, synthesis, or board programming changes.

Validation: 37 tests pass across the timing, repair, closure, and final-route
suites. New tests cover early success, legal/illegal fallback starting points,
the two-routing-attempt limit, unexpected input defects, and retaining the
better eligible checkpoint. The saved combined route report matches the
expected repair input. Python compilation, Tcl completeness, and whitespace
checks pass. Real routing results remain pending.

Launched in `versal/timing_350_finish_route_20260910` under
`hpu-timing-1789080796339423273.service`; 76/84 GiB limits verified.
`hpu-image-followup-finish-route-20260910.service` waits for full signoff.
