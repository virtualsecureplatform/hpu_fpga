# Timing-closed AMR image generation

## September 15 image metadata audit correction

The first image attempt passed pre-UUID signoff, then stopped at 10:13 UTC
because the constraint fingerprint included the expected UUID ROM INIT and
USR_ACCESS timestamp additions. Other signoff checks still passed; no PDI was
released. The original failed attempt and its checkpoint are preserved.

The audit now validates exactly 32 named UUID ROM INIT assignments against the
logic UUID in `pfm_uuid_manifest.dict`, using AMD's four-word bit packing. It
requires one exact INIT property declaration and one exact USR_ACCESS TIMESTAMP
setting. Only this complete metadata update is removed before comparing the
original constraint fingerprint. Missing/duplicate cells, wrong values,
unexpected targets, scopes, timing changes and other properties still fail.
The manifest is copied into and hashed with the signoff evidence.

The actual failed-run export passes this metadata validation and reduces to
the original fingerprint. A fresh signoff is required to establish the updated
source snapshot before the image retry; the managed follow-up launches the
image phase only after that signoff succeeds. No board programming is included.

The closure target is PSI64 at an actual 350 MHz processing clock, using
Vivado/Vitis 2026.1. The original placement checkpoint is preserved. Image
generation and programming are separate operations; none of these commands
programs a board.

## September 14 flow changes and restart

### September 15 routed-checkpoint validation

The first signoff run stopped in the GT evidence collector because native net
objects lacked `IS_GND`, producing an empty Tcl boolean. The collector now
checks property availability and boolean validity, and recognizes an explicit
GROUND net type; missing evidence remains unproven, not exempted.

TIMING-6/7 identify clk_pl_2 to clk_pl_0 at the new PCIe asynchronous-reset
synchronizer. The CDC report classifies this as CDC-9, four stages, ASYNC_REG,
with no exception. `pcie_reset_constraints.tcl` now applies a false path only
to the four exact `release_pipe_reg[0..3]/CLR` inputs after validating their
identity and ASYNC_REG properties. It does not group clocks or exempt D pins
or downstream reset consumers. The normal pre-placement hook applies the same
constraint for future builds.

The `reset-signoff` phase applies this scoped constraint to a new checkpoint
and reruns the full gate in `versal/timing_350_signoff_fix_20260915`. The original
routed checkpoint remains unchanged. No routing/placement optimization or
endpoint waiver is performed. Native validation completed September 15 at
03:15 UTC: zero negative setup/hold paths, no routing/DRC/methodology/critical
CDC/bus-skew failures, and both clock DRC checks pass. The only remaining
signoff failure is 56 unconstrained GT control endpoints; no image is released.

The generated CIPS `bd_0/ip/ip_1/ip_cpm5.xdc:13` explicitly sets case analysis
to zero on `CH?_?XUSRCLK`, and the fresh implementation log confirms loading
that file at the CPM hierarchy. This is timing-model case analysis, not a
physical ground tie or proof that the PCIe quads are inactive. The existing
ground-only audit correctly does not exempt these endpoints.

The managed `gt-inspect` phase captures all 56 control pins and their eight
RXUSRCLK pins after `update_timing`, including native properties, leaf drivers,
driver primitive types, clocks, detailed `check_timing`, and exported checkpoint
constraints. It preserves and hashes the generated vendor XDC alongside the
normal input provenance. It does not apply constraints, route, write a DCP,
or grant signoff. Its output is intended to establish the evidence needed
before considering an exact vendor-IP endpoint policy.

The inspection completed successfully at 05:36 UTC. All 64 pins have the
expected unique CPM5 leaf driver and no associated fabric clock. The checkpoint
export retains the scoped AMD user-clock case analysis. `LOGIC_VALUE` remains
unavailable even after `update_timing` and is not used as proof.

The endpoint audit now supports the exact `vendor_case_disabled_cpm5_gt_controls`
classification. It requires the existing exact 56-name constant-clock report,
GTYP_QUAD primitives, signal nets, the 64 exact CPM5 driver identities and zero
associated clocks, the pinned Vivado/IP configuration, and a SHA-256 fingerprint
of every executable line of the reviewed checkpoint constraint export. Only
blank lines and full-line comments are excluded from that fingerprint; scope,
ordering and overrides are preserved. A changed constraint requires a new
review, even if unrelated to the GT. No design constraint is added or removed.
This is a project-specific audit based on the generated vendor constraints and
native connectivity, not a blanket AMD waiver or a claim that PCIe is inactive.
The signoff record hashes the new driver and constraint evidence as well.

83 tests pass, including rejection of changed drivers, primitives, clocks,
missing/duplicate evidence and constraint overrides. Full native signoff is
being rerun in `versal/timing_350_vendor_signoff_20260915`; image generation
remains gated on that run's success.

The routing-only replay completed September 14 at 21:35 UTC without reproducing
the segfault. Router timing was WNS 0.000, TNS 0.000, WHS 0.002, THS 0.000 ns;
these rounded numbers are not full signoff. `routed.dcp` is preserved in
`versal/timing_350_route_replay_20260914`.

The new `signoff` phase loads that checkpoint, creates a byte-identical local
`postroute_physopt.dcp` copy, and runs the full existing gate without placement,
routing, optimization, or constraint edits. The validation directory is
`versal/timing_350_signoff_20260915`. Image generation remains blocked unless
the checkpoint-bound timing/route/CDC/DRC/methodology/endpoint checks all pass.

### Routing crash reproduction

The placement recovery crashed at 14:23 UTC in routing Phase 12 leaf-clock
optimization, with SIGSEGV in `FlopGraphPathEndVisitor::visitPathEnd` and
`XilinxSearch::visitUnconstrainedPathEnds`. This is not a completed route.
The saved `pre_route_physopt.dcp` is the input for the first controlled replay.

The `replay` phase checks Vivado 2026.1 build 6511674, uses eight threads,
repeats the final pre-route timing report, and calls exactly
`route_design -directive AggressiveExplore`. It neither changes constraints
nor invokes placement/phys_opt/signoff. Checkpoint and original build/crash/log
artifacts are hashed in the new manifest. A successful route saves `routed.dcp`
and `replay.complete`, which is NOT a timing/image signoff marker. A failure
retains the raw `vivado_exit_code` and native crash logs.

The first replay output is `versal/timing_350_route_replay_20260914` with the
original PATH/license and 76/84 GiB limits, 72 GiB start threshold. Reopening a
DCP may not restore the prior process's in-memory state; failure to reproduce
would warrant a separate full-sequence replay, not a claim that the crash is fixed.

### Placement retry after NTCN-17

The fresh clock-fix build completed synthesis but failed placement at 10:13 UTC:
V80 does not allow an explicit calibrated clock window with automatic root/track.
The current helper supplies the complete tuple: window X0Y1:X9Y10, root X5Y7,
track 7, with no forced VTREE type. NTCN-17 runs before placement; NTCN-16 and
NTCN-17 both run after placement and at signoff. This supersedes the automatic
root/track approach described in the historical notes below.

Native validation passed on a small out-of-context fixture with a register
fixed in each SLR: the incomplete tuple failed NTCN-17 before placement, the
complete tuple passed preflight and placement, and both NTCN-16/17 passed
after placement. Evidence: `versal/output_validation_20260914/clock_tuple_verified.log`
and its matching directory. All 68 regression tests passed. This is validation
of the clock configuration, not full HPU timing closure.

The `place` recovery phase reuses the preserved `top_hpu_opt.dcp`, reapplies the
placement hook (PMC reset rewiring, pblocks, and corrected clock constraints),
and runs placement, physical optimization, routing and gated signoff. It writes
to a new directory and retains the original checkpoint unchanged. Recovery
image verification checks the recovery source manifest and the original source
build's input hashes, rather than requiring that the obsolete fresh-flow scripts
remain current.

```bash
python3 scripts/run_timing_build.py versal/timing_350_place_tuple_20260914 \
  --phase place --source-build versal/timing_350_fresh_clockfix_20260914 \
  --checkpoint versal/timing_350_fresh_clockfix_20260914/top_hpu/prj.runs/impl_1/top_hpu_opt.dcp \
  --memory-high-gib 76 --memory-max-gib 84 --start-memory-gib 72
```

### Earlier clock-window work

Native device inspection corrected the initial whole-device bounding-box
assumption. V80 rows Y0 and Y11 are special HSR regions and cannot be included
in `USER_CLOCK_EXPANSION_WINDOW` (Vivado 12-25514). The helper now identifies
fabric rows using SLICE sites and intersects their columns, producing
`CLOCKREGION_X0Y1:CLOCKREGION_X9Y10`. Thus the older window was already
full fabric height; the September 11 failure concerned its forced X3Y7 root,
not omitted fabric rows. Root and track remain automatic before placement.
The native probe also exposed an unsupported `get_drc_violations -of_objects`
call; the guard now queries `NTCN-16*` from the just-completed report.
Clock properties use their native reset values (empty root/tree, track -1),
because `reset_property USER_CLOCK_ROOT` is unsupported. The small native
test in `scripts/test_clock_window_native.tcl` checks the window assignment,
clearing a forced root/track, and rejection of an unplaced clock without
writing a passing signoff marker. It is not a placed/routed signoff test.
This native test passed with Vivado 2026.1; evidence is in
`versal/output_validation_20260914/clock_window_final.log` and
`versal/output_validation_20260914/clock_window_final/`. The NTCN-16 error
in that fixture is intentional and confirms rejection of the unplaced net.
See AMD's [window property documentation](https://docs.amd.com/r/en-US/ug912-vivado-properties/USER_CLOCK_EXPANSION_WINDOW)
and [calibrated deskew guidance](https://docs.amd.com/r/en-US/ug1388-acap-system-integration-validation-methodology/Calibrated-Deskew).

Fresh synthesis is required for the shared HPU/MHDMA configuration reset and
PCIe reset synchronizer. The processing BUFG receives a complete-SLR expansion
window before placement; the placer selects the root and track. A native
NTCN-16 check rejects incompatible topology before routing. The license server
was restored September 14 at 07:27 UTC; native clock topology signoff remains
required during the fresh implementation.

Fresh routing now retains the initial checkpoint and compares at most two
optimization candidates (Explore, then ExploreWithAggressiveHoldFix if needed).
Every optimization requires legal input routing and detects skipped execution.
Only legally routed candidates passing hold/pulse checks can be selected;
setup and all other signoff checks must pass before image generation.
`finish-route` performs one preserve-route attempt, with no full-unroute fallback.

Signoff requires `check_timing.rpt`, checkpoint identity, clock validation, and
current GT evidence. For the exact 56 known GT controls, an exemption requires
the pinned CIPS configuration and tool version, a GTYP_QUAD input tied to ground,
and its RXUSRCLK tied to ground in the current netlist. Unknown or active pins
remain failures. `constraint_audit.json` distinguishes raw, justified, and
unresolved counts. No real-netlist exemption is claimed before native inspection.
Continuation rechecks both the checkpoint hash and all accepted report hashes.

The launcher includes submodule contents in its source snapshot, checks for
source drift before/during/after execution, and preserves an explicitly supplied
license setting in the service manifest. Do not edit build sources while a
managed job is running. Synthesis jobs are serialized with an eight-thread cap.
For a fresh build, `--source-build` is now optional and no old XSA is copied.
With licensing restored, from the repository root use a new output directory:

```bash
python3 scripts/run_timing_build.py versal/timing_350_fresh_clockfix_20260914 \
  --phase build --memory-high-gib 76 --memory-max-gib 84 --start-memory-gib 72
python3 scripts/finish_timing_image.py \
  versal/timing_350_fresh_clockfix_20260914 versal/timing_350_image_20260914
```

The second command waits for completion and refuses image launch without
matching, passing signoff. It does not program the board. If a different license
server/file is supplied, export `XILINXD_LICENSE_FILE` before launching.

Focused validation without a Vivado simulation license (the portable compiler
was extracted into the ignored validation directory, not installed systemwide):

```bash
HPU_IVERILOG="$PWD/versal/output_validation_20260914/tools/iverilog/usr/bin/iverilog" \
HPU_IVERILOG_LIB="$PWD/versal/output_validation_20260914/tools/iverilog/usr/lib/x86_64-linux-gnu/ivl" \
python3 -m unittest discover -s scripts -p 'test_*.py'
```

Result: 66 tests pass, including an executed reset simulation and six additional
clock-region regression cases. After licensing
was restored, native XSim reset simulation, Vivado reset BD validation, and
both `tb_mhdma_master` (19 scenarios) and `tb_multi_hpu_dma` simulations passed.
DMA logs are under `versal/output_timing_cdc_sim_20260914`; the reset BD log is
`versal/output_validation_20260914/reset_bd.log`.

## September 8 build history

The 2026-09-08 baseline (`versal/timing_350_baseline_20260908`) completed with
WNS -0.326 ns, TNS -29.493 ns, WHS -3.473 ns and THS -2899.303 ns. It does
not meet timing. Its CDC report found 496 unsafe HPU-ID SRL crossings, and
methodology TIMING-51 identified configuration clocks from parallel MMCMs.

The source now preserves the HPU-ID synchronizer flip-flops and feeds both
100 MHz configuration interfaces from the same clock source, including the
matching reset-controller lock input. These changes require fresh synthesis:

```bash
python3 scripts/run_timing_build.py versal/output_timing_350_fresh \
  --source-build versal/output_psi64_350mhz_licensed_hC65yl --phase build
```

The active attempt is `versal/timing_350_fresh_retry_20260908`; consult its
`status.json` for live state. The first fresh attempt stopped before Vivado
because the service PATH lacked `just`; the launcher now preserves PATH.
The subsequent attempt stopped during synthesis at 17:27 UTC when available
RAM stayed below 8 GiB for 30 seconds. Its logs and synthesis working directory
are preserved under `attempts/failed_20260908_172743`. A synthesis-only restart
uses `build_step: "syn"` in the worker configuration; it reopens the existing
project and retains completed shell/IP outputs. The retry requires 72 GiB
available RAM before starting, covering its 64 GiB limit plus the 8 GiB reserve.
Memory limits remain unchanged. The launcher regression suite passes 12 tests.
`fresh.complete` means routing completed, not timing acceptance. Use the fresh
directory as `--source-build` for subsequent image generation so its XSA and
synthesis metadata match the new checkpoint.

The user service `hpu-image-followup-retry-20260908` waits for this fresh build and
then launches gated image generation in `versal/timing_350_image_20260908`.
It stops if the build fails. Its log is `image_followup.log` in the fresh build
directory. Image generation stops at any failed signoff check and never
programs the board. For another managed build, the same continuation is:

```bash
python3 scripts/finish_timing_image.py BUILD_DIRECTORY NEW_IMAGE_DIRECTORY
```

Before top-level synthesis, the service was paused to add synchronizers for
MHDMA lane selection, timeout configuration and BPIP configuration. The HPU-ID
false path now targets only stage zero, preserving timing between stages.
`source_amendment.json` records this update; the earlier source snapshot is
retained with the `before_cdc_` prefix. Configuration must remain stable during
active work; these synchronizers do not implement atomic live reconfiguration.

## Recover implementation for an unchanged netlist

From the repository root, choose a new output directory:

```bash
python3 scripts/run_timing_build.py versal/output_timing_350_recovery \
  --source-build versal/output_psi64_350mhz_licensed_hC65yl
```

Use `--phase baseline` for analysis without implementation. The source build
supplies its matching XSA, synthesis log and user variables. `--checkpoint`
can select a different placed checkpoint; do not mix a checkpoint with an
unrelated source build.

The launcher snapshots sources and input hashes, starts a user systemd service,
and permits only one managed HPU job at a time. Other Vivado jobs are left alone.
It requires 64 GiB available memory for 30 seconds before starting; the service
has a 56 GiB soft limit and a 64 GiB hard limit. A sustained drop below 8 GiB
available memory stops only this job. Completed stage checkpoints survive.

Inspect `status.json`, `stages.log` and `launcher.log` in the output directory.
The unit name is recorded in `systemd_unit`; inspect its authoritative service
status and memory counters with `systemctl --user show UNIT`. A killed process
must not be treated as successful merely because an older status file exists.

Recovery saves pre-route, routed and post-route checkpoints, preserving clock
uncertainty. `recovery.complete` means the implementation commands completed;
it does **not** mean timing passed. `signoff/signoff.json` is written only when
the acceptance checks pass. `signoff_failure.txt` records a rejected result.

## Signoff and image generation

The shared gate rejects negative setup/hold/pulse-width slack, failing endpoint
counts, incomplete routing, bus-skew violations, unresolved critical DRC,
methodology or CDC findings, missing timing constraints, and missing reports.
Unknown report formats fail closed. Numeric timing-path queries additionally
catch setup/hold violations rounded to zero in text reports.

Once the recovered design has passed signoff and its constraints/CDC findings
have been reviewed:

```bash
python3 scripts/run_timing_build.py versal/output_timing_350_image \
  --source-build versal/output_psi64_350mhz_licensed_hC65yl \
  --checkpoint versal/output_timing_350_recovery/postroute_physopt.dcp \
  --phase image
```

Image generation reruns the gate before and after updating the UUID ROM. The
exact final design is saved as `image_input.dcp`, and its hash is recorded with
signoff. The generated tandem images are combined, the matching R5 firmware is
built and merged, and Bootgen inspects the result before publication.

Successful output is `release/hpu_psi64_350mhz_amr.pdi` with the input checkpoint,
XSA, firmware, UUID metadata, source snapshot, reports and `SHA256SUMS`. A failed
packaging step leaves no `release` directory and no `image.complete` marker.

## Validation

```bash
python3 scripts/test_timing_flow.py
```

Tool invocations and report parsers must also be checked against the actual
Vivado reports. Passing these software regressions alone does not establish
hardware timing closure or correct operation on a board.

## Vitis 2026.1 firmware

The image flow uses `fw/arm/scripts/build_sdt.py` because XSCT is disabled in
Vitis 2026.1. It creates the R5 FreeRTOS BSP through Vitis Python, preserves the
10 kHz tick, 128 KiB RTOS heap and static allocation settings, then builds AMC
against SDT headers and startup libraries. It verifies the ELF architecture
and that its entry point equals `_boot`. The V80 profile maps SDT peripheral
names and encoded interrupt IDs; the OSAL interrupt argument is 16 bits to
preserve the encoding. No board has been programmed by this flow.

The clean build in `versal/output_timing_firmware_verified_20260908` completed
against the original diagnostic XSA. Its ELF entry is `0x3c`, matching `_boot`.
The final image flow rebuilds firmware against the fresh build's XSA.
Both the MHDMA master and full MHDMA XSim regressions passed with the added
synchronizers (`versal/output_timing_cdc_sim_20260908/xsim/`, each test's
`xsim.log`). The timing-gate and launcher regression suite passes 11 tests.


## Bounded repair of the aggressive-route checkpoint

`--phase repair` reopens the September 10 aggressive `routed.dcp` and verifies
that the only defective net is `hpu_3parts/p3_p2_sll/in_pipe/out_data[6244]`
with destination `hpu_3parts/p3_p2_sll/out_pipe/depth1.out_data_reg[6244]/D`.
Unexpected nets or endpoints stop the job before mutation. Exact property
filters preserve literal bus indices.

The flow unroutes only that net and uses `route_design -nets ... -auto_delay`.
If needed it makes one `route_design -preserve -directive Explore` fallback.
It saves `repaired.dcp` only after whole-design routing legality is established.
It then runs post-route Explore, followed by a separate clock optimization
attempt only if the retained candidate still fails setup. Every candidate has
its own checkpoint, route/timing reports, and numeric slack metrics. Candidates
with routing errors, hold/pulse-width failures, or worse WNS/TNS are rejected;
clock optimization starts from the retained candidate. `selected_candidate.txt`
identifies the checkpoint copied to `postroute_physopt.dcp` for final signoff.

Ordinary recovery also checks routing legality before and after optimization.
Skipped optimization is a failed stage. Completed recovery jobs expose a
separate `signoff` field in `status.json`; completion alone does not authorize
image generation. Existing CDC/unconstrained-endpoint gates remain unchanged.
The bounded experiment retains 350 MHz, eight threads, 76/84 GiB limits,
72 GiB startup availability, and the existing 8 GiB low-memory guard.


## Bounded setup/hold closure

`--phase close-timing` starts from the saved repair-run `explore.dcp`.
It verifies routing and 350 MHz clocks, records every failing setup/hold
endpoint and its opposite-delay timing, and preserves an input checkpoint.
The first candidate uses `phys_opt_design -aggressive_hold_fix`.
If all timing does not pass, one further candidate uses
`phys_opt_design -directive ExploreWithAggressiveHoldFix`; it starts from the
first result only if routing, hold, and pulse-width checks pass, otherwise
from the input checkpoint. No clock-only pass or full reroute is performed.

This phase has its own selection policy: candidates must pass routing, hold,
and pulse-width checks, then the highest numeric WNS wins, followed by TNS;
ties retain the earlier candidate. Setup regression during hold repair is
allowed, but never authorizes an image. With no eligible candidate the job
fails without creating a selected image-input checkpoint. Otherwise it saves
`postroute_physopt.dcp`, records the selected candidate, and runs full signoff.
The original repair-phase non-regression policy is unchanged.

Use eight threads and `--memory-high-gib 76 --memory-max-gib 84
--start-memory-gib 72`; the 8 GiB sustained low-memory guard remains enabled.
The output directory for the first run is `versal/timing_350_hold_20260910`.


## Complete routing after hold optimization

`--phase finish-route` starts from `timing_350_hold_20260910/combined.dcp`.
It checks both 350 MHz clocks and exactly one defective net,
`hpu_3parts/p2_p1_sll/in_pipe/out_data[5862]_hold_fix_1`, terminating at
`hpu_3parts/p2_p1_sll/out_pipe/depth1.out_data_reg[5862]/D`. Input diagnostics
include all failing setup/hold endpoints and their opposite-delay timing.

The first attempt is `route_design -preserve -directive AggressiveExplore
-tns_cleanup`. Save `preserved.dcp` before evaluating legality and timing.
If either fails, reopen the preserved candidate when legally routed, otherwise
reopen the input snapshot; run `route_design -unroute` followed by
`route_design -directive AggressiveExplore -tns_cleanup` exactly once.
Save `full_route.dcp` and compare candidates using the close-timing policy:
legal routing, passing hold/pulse-width, then highest numeric WNS and TNS.
A tool-command error aborts the job; successful tool exit never substitutes
for the report checks. No further standalone physical optimization is run.

No eligible candidate means a failed experiment with diagnostic checkpoints
preserved and no selected image-input checkpoint. Otherwise the selected
checkpoint is copied to `postroute_physopt.dcp` (the existing downstream
interface name) and full signoff runs once. Timing and CDC/unconstrained-path
acceptance remain mandatory for image generation. All existing source
checkpoints remain unchanged. Use the same eight threads, 76/84 GiB limits,
72 GiB startup threshold and 8 GiB low-memory guard as the prior attempt.
