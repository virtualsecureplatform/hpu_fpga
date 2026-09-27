# PBS correctness investigation — 2026-09-27

Resolved follow-up: [ciphertext-order compatibility fix](ciphertext_order_fix_20260927.md)
passes live-board encrypted smoke tests. The unresolved findings below are
historical and describe the investigation before that fix.

Follow-up: [exact-vector KS replay](ks_vector_replay_20260927.md) now passes
against the CPU reference for the failing board input. This does not validate
the live FPGA's internal KS output or key-cache path.
The [KSK loader/cache follow-up](ks_cache_replay_20260927.md) also passes
against modeled AXI memory, including uneven response timing and detection
of deliberate memory corruption. The live-hardware limitation still applies.

Encrypted identity PBS is still incorrect. The artifact audit and final host-side
memory readback passed; neither establishes that the FPGA reads or computes with
the correct key coefficients internally. No image was programmed or reset during
this investigation. Recovery partition 0 was not modified.

## Image and artifact audit

Board `02:00.0` reports AMI/AMC 3.0.0, `READY`, UUID
`00000000000000000000000038624737`. The release under examination is
`versal/timing_350_amr_irqfix_20260927/release`. Its manifest hashes match all
five release files. This is an on-disk integrity check, not a flash readback.

The PL/XSA originates from `versal/timing_350_amr_image_20260926`, using the
synthesis project `versal/timing_350_amr_native_20260924/top_hpu/prj.xpr`.
The IRQ-fix release changed the AMC firmware, not this PL/XSA.

Run the read-only audit from `hpu_fpga` with Python 3.11 or later:

```bash
python3 scripts/audit_pbs_artifacts.py \
  --release versal/timing_350_amr_irqfix_20260927/release \
  --image-dir versal/timing_350_amr_image_20260926 \
  --project versal/timing_350_amr_native_20260924/top_hpu/prj.xpr \
  --tfhe-rs ../tfhe-rs
```

Results:

- All 36 accelerator HBM mappings agree with the host configuration: 16 BSK,
  16 KSK, two ciphertext, one LUT, and one trace port. Both CPM host routes cover
  the same physical HBM blocks as the corresponding accelerator routes. No
  accelerator address remap was found. Data ports are 256-bit; trace is 128-bit.
- All 356 selected hardware sources match their archived hashes. The current
  versions of these sources also match the archive.
- Live architecture registers and selected source packages agree on N=2048,
  GLWE dimension 1, LWE dimension 879, PBS base-log/level 23/1, KS base-log/level
  2/8, KS width 21, and mean compensation. NTT is GF64/PSI64, cuts [5,6];
  KS parallelism is x3/y64/z3. Live PBS batch/total capacity is 12/27.
- All 30 forward/inverse/normalized-inverse phi tables match independently
  calculated modular powers: 24,552 entries, zero mismatches. The N=2048 root
  `10974926054405199669` agrees with TFHE-rs.
- The absent `R2_PSI64` phi-ROM directory is not a demonstrated defect:
  this configuration selects the generated register tables, since 16 iterations
  is below the ROM-selection threshold of 128.

The script emits JSON and exits nonzero on a detected mismatch. It audits this
specific parameter variant; it does not validate all possible HPU configurations.
Live registers and the ROM-selection condition were inspected separately.

Saved report: `versal/diagnostic_pbs_artifacts_20260927/artifact_report.json`.

## Stronger initialization check and board reproduction

`HPU_VERIFY_KEY_UPLOAD=1` now performs a second full readback of all BSK/KSK cuts
and LUT bodies after firmware, trace, and MHDMA initialization. The existing
immediate readbacks alone could miss a later upload overwriting an earlier bank.
The extra check is opt-in and does not log key material.

The release benchmark compiled successfully. From `tfhe-rs`, reproduce with:

```bash
timeout -k 5s 180s env \
  HPU_BACKEND_DIR="$PWD/backends/tfhe-hpu-backend" \
  HPU_CONFIG=v80 RUST_LOG=info HPU_VERIFY_KEY_UPLOAD=1 \
  ./target/release/examples/hpu_bench \
  --integer-w 2 --iop 'IOP[16]' --user-proto '[1]<N>::<N><0>' \
  --src 1 --seed 42 --iter 1
```

Custom instruction `config_store/custom_iop/integer_w_2/cust_16_v0.asm` is:

```text
LD R0 TS[0].0
PBS_F R0 R0 PbsNone
ST TD[0].0 R0
```

Encrypted input 1 returned 3, despite both immediate and final memory checks
passing. Reported operation latency was 41.61857 ms. The benchmark exits zero
even for this wrong output; its exit status is not a correctness assertion.
The instruction/acknowledgment counters were both 157 after this run.

The `--trivial` control returned 1 for input 1 in 40.570744 ms, also with both
memory checks passing. A trivial ciphertext has a zero mask and does not
exercise the same nonzero key-dependent arithmetic as an encrypted ciphertext.
Passing it is not enough to establish PBS correctness. Both PBS error registers
(`status_1in3::error` and `status_3in3::error`) read zero afterward.

The encrypted and trivial logs are saved as `identity_final_verify.log` and
`identity_trivial_final_verify.log` under
`versal/diagnostic_pbs_artifacts_20260927/`.

Board runs use the user's three-minute timeout. Host-only RTL simulations have
separate wall-clock bounds and do not execute on or heat the FPGA.

## RTL test coverage and next discriminator

The standalone `tb_pep_key_switch` test disables numerical output comparison
(`sink_result.set_do_ref(0)`). Its progress cannot be reported as an arithmetic
pass; that run was stopped.

The `tb_pep_ks_mult_outp` bench does compare multiply-node results, accumulated
results, modulus-switched coefficients, mean-compensation corrections, and body
subtraction against arithmetic references. It does not cover key DMA/cache
ordering, decomposition, the complete PBS pipeline, or the implemented netlist.
Its generated total PBS capacity is 32, unlike the board's 27; arithmetic widths
and KS parallelism match.

This run compiled and started, but was intentionally stopped after about
7.5 minutes (exit 143), before its ten-minute bound. Simulator RSS had risen to
about 36 GiB and there was no completion verdict. The log showed `Out_pbs # 0`
and `In_batch # 0`, with neither a numerical mismatch nor `SUCCEED`. This is
**inconclusive**, not an arithmetic pass or proof of a hardware stall. Its
log is `versal/diagnostic_pbs_artifacts_20260927/ks_arithmetic.log`; the build
directory is `/tmp/hpu-pbs-audit.WEWoeQ/ks_arithmetic`.

Invocation from `hpu_fpga` (host-only simulation):

```bash
timeout -k 10s 600s env PROJECT_DIR="$PWD" PROJECT_SIMU_TOOL=xsim \
  PYTHONPATH="$PWD/edalize" \
  bash hw/module/pep_key_switch/simu/tb_pep_ks_mult_outp/scripts/run.sh \
  -g 1 -R 2 -S 11 -q '2**64' -W 64 -r '2**21' -V 21 \
  -c 12 -K 879 -L 8 -B 2 -X 3 -Y 64 -Z 3 -d 1 \
  -- -d /tmp/hpu-pbs-audit.WEWoeQ/ks_arithmetic -s 42 \
  -P PROC_BATCH_NB int 2 -P BATCH_IN_PARALLEL int 1
```

Use a fresh build directory for another run. `BATCH_IN_PARALLEL` is declared by
this bench but unused in its stimulus control, so setting it does not establish
single-batch serialization. A focused exact-vector bench needs explicit input
and output bounds, scoreboard-drain checks, and a cycle watchdog.

The remaining high-value discriminator is an exact-vector comparison at the
key-switch output/PBS input boundary, followed by blind rotation if KS agrees.
Use the same input ciphertext and keys as the seeded failing case. Compare
coefficients, body, and mean-compensation data, not just decrypted final output.
Start with simulation/capture support; do not infer intermediate values from
the current scheduling-only hardware trace or reflash a speculative fix.

No root cause has yet been proven. These checks reduce the likelihood of an
artifact/configuration mismatch or a host-visible initialization overwrite.
They do not rule out FPGA-side key addressing/cache behavior, a data-ordering
mismatch, or arithmetic/integration errors.

## Validation of diagnostic changes

The release `hpu_bench` build, Rust formatting checks, Python compilation, and
Git whitespace checks passed. A read-only fault-injection check mocked an
incorrect `amc.elf` digest and confirmed that the audit reports that mismatch
and returns nonzero; no release artifact was modified.
