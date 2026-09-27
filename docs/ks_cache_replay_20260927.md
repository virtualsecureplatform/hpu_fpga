# Exact KSK loader/cache replay — 2026-09-27

The captured failing board vector also passes through the real KSK loader,
cache, manager, and key-switch core in RTL simulation. This narrows the search;
it does **not** resolve or reproduce the on-board encrypted PBS failure.
No FPGA operation, reset, flash write, or production RTL change was made in
this step.

Follow-up: [the first two PBS external products](pbs_vector_replay_20260927.md)
now pass exact RTL/CPU comparison, and the full offline CPU PBS returns 1.
The on-board result remains unresolved.

## Test and evidence

The extended `tb_pep_key_switch_vector` uses the same seed-42 input, uploaded
key layout, and TFHE-rs reference as [the direct KS replay](ks_vector_replay_20260927.md).
Its new `ks_vector_cached_source` instantiates `ksk_if` and `ksk_manager` and
connects their real slot notifications, batch commands, and cache-release
signals to `pep_key_switch`.

Configuration matches the deployed KSK path: 16 AXI ports of 256 bits,
16 cuts, eight cache slots, x3/y64/z3, and four-cycle manager RAM latency.
The latency is `hpu_common_param_pkg::URAM_LATENCY`, passed by
`hpu_3parts_1in3_core` through `pe_pbs_with_ksk`.

Each AXI memory port models the host's four-u64 stripe, as defined by
`HpuLweKeyswitchKey::get_pc_offset_from_index`. The synthetic base addresses
use the host configuration's HBM banks 0–7 and 16–23, with an additional
aligned nonzero allocation offset. They are not a capture of the live
allocation addresses. Bursts are checked for known values, range,
alignment, length, size, INCR type, and 4-KiB boundaries. Each port supports
one outstanding burst and holds responses while backpressured.

The scoreboard checks every used packed key word **at the core input**, not
just the modeled memory. It also checks all 879 output coefficients, all
879 corrections, the body, pointers, duplicate/late outputs, complete
command/key consumption, and core/manager error flags. Processing 294 block
columns exercises repeated reuse of the eight cache slots.

| Run | Result |
| --- | --- |
| Normal memory responses | PASS: 5,406,720 used key words; all CPU-reference outputs; 86,128 cycles |
| Uneven responses across 16 ports | PASS: same key/output checks; 192,828 cycles |
| First memory word bit-flipped | Expected failure at `x=0 y=0 word=0`; wrapper exit 1 |
| Direct-stream regression after extension | PASS: all CPU-reference outputs; 29,153 cycles |

The memory negative control reads `74261f9081bb9f0e` where the captured word
is `74261f9081bb9f0f`. It fails before numerical output, demonstrating that
the core-input checker observes corruption through the cache path.

Normal and staggered simulations took about 84 and 137 seconds respectively
(excluding compilation). Reported Xsim process peak memory was approximately
1.6 GiB, with simulator-kernel peaks below 1.1 GiB.

### Final-column padding

The first integration attempt exposed a testbench assumption, not a proven
RTL defect: it compared the two unused columns after the final body column.
`ksk_if_axi4_read` deliberately omits them (`r0_x_cnt_max`), while
`pep_ks_out_process` discards outputs whose column is at least `LWE_K+1`.
The cache may therefore supply stale values on those unused lanes.

The corrected checker compares all 880 meaningful columns and checks the
transfer count, but not the payload, of the 12,288 unused words. All
5,419,008 transfers must still drain. The initial attempt also used a
three-cycle manager RAM default; all accepted cached results use the
deployed four-cycle setting.

## Reproduction

From `hpu_fpga`, with Vivado 2026.1 on PATH:

```bash
ks_cache_root=$(mktemp -d /tmp/hpu-ks-cache-replay.XXXXXX)
python3 scripts/run_ks_vector.py \
  versal/diagnostic_pbs_artifacts_20260927/ks_vector_seed42 \
  "$ks_cache_root/normal" --cached

# Host-only latency stress; this does not access the FPGA.
python3 scripts/run_ks_vector.py \
  versal/diagnostic_pbs_artifacts_20260927/ks_vector_seed42 \
  "$ks_cache_root/stagger" --cached --axi-stagger --seconds 300

# Deliberate failure: expected exit 1 and first-key-word mismatch.
python3 scripts/run_ks_vector.py \
  versal/diagnostic_pbs_artifacts_20260927/ks_vector_seed42 \
  "$ks_cache_root/negative" --cached --inject-mem-error
```

Build roots must be fresh. Do not run wrappers concurrently: they share the
generated parameter-package directory. The wrapper bounds the build and
simulation subprocess tree and requires both `KS_VECTOR_PASS` and
`KSK_PIPE_PASS`; simulator exit zero alone is not success. The RTL watchdog
also limits execution to 200,000 cycles.

The stagger mode independently delays address acceptance, first responses,
and subsequent beats on each port. It is deterministic, not an exhaustive
AXI timing verification suite.

Logs are preserved in `versal/diagnostic_ks_cache_20260927`: normal, staggered,
memory-negative, and direct-regression launcher and Xsim logs, plus the
rejected initial padding-check log. `simulation_sources.sha256` records the
91 final compiled SystemVerilog files; `harness.sha256` and `fixture.sha256` record the runner,
file list, relevant deployed-configuration sources, and input/reference
files. The simulation builds are under `/tmp/hpu-ks-cache.4KMEHt`.

Python compilation, file-list JSON validation, and `git diff --check` passed.
The CLI rejects AXI options without `--cached` and nonpositive timeouts with
exit 2. All replay processes completed; none were left running.

## Interpretation and next step

For this one ciphertext/key, the functional KS arithmetic, KSK ordering,
address generation, and cache-slot reuse agree with the CPU reference under
the tested memory responses. This does not validate physical HBM/NoC/PCIe,
clock-domain crossings outside these modules, implementation timing, the
live FPGA's internal key/data stream, reset after an interrupted run,
multi-ciphertext scheduling, or blind rotation/PBS/NTT/sample extraction.

Next, extend the exact-vector comparison into the PBS stage: use the checked
KS result, the same uploaded BSK and LUT, and a CPU reference, starting at
the first blind-rotation/external-product boundary. If that agrees too,
capturing the live KS/PBS boundary with a separately reviewed debug image
would distinguish an implementation/interface issue from a functional RTL
issue. The present evidence does not justify a speculative arithmetic fix
or a reflash.
