# PBS external-product replay — 2026-09-27

Resolved follow-up: [ciphertext-order compatibility fix](ciphertext_order_fix_20260927.md)
passes live-board encrypted smoke tests. The account below records the earlier
diagnostic stage, when the cause was still unresolved.

This host-only diagnostic extends the [KS/cache replay](ks_cache_replay_20260927.md)
into the GF64 NTT, BSK multiplication, and inverse NTT. The on-board encrypted
identity-PBS failure remains unresolved. No FPGA access, reset, flashing,
driver change, or production RTL change was performed here.

## Reference provenance

The original capture exported the input and KSK, but not the BSK. The new
TFHE-rs example `hpu_pbs_vector` reconstructs seed 42 using the exact key
generation call order from `hpu_bench`, including its CPU server-key creation.
Before using the reconstructed BSK, it requires an exact match with:

- The captured 2,049-coefficient encrypted input.
- All 5,419,008 packed KSK words, including padding.
- The captured raw CPU key-switch result and all 879 switched mask values.

Those checks pass. The BSK is **regenerated**, not read from the board in this
step. Matching the seeded input/KSK establishes a reproducible key-generation
context, but does not verify what the live FPGA's BSK reader receives.
The example never constructs `HpuDevice` and exports no secret keys.

The reference uses the normal HPU `PbsNone` LUT constructor and the standard
HPU BSK conversion/shuffle. It checks a complete BSK shuffle/unshuffle round
trip. The external-product oracle uses TFHE-rs signed decomposition and NTT
primitives, with explicit Goldilocks modular arithmetic and normalization.
For the first two steps it independently checks all 4,096 coefficients by
direct O(N²) negacyclic polynomial multiplication against the standard BSK.

The CPU reference completes all 879 blind-rotation steps, sample-extracts,
and decrypts the identity result to **1**, whereas the earlier board capture
returned **3**. The centered, mean-corrected body is **980** (12 bits).

### HPU body-rotation ordering

The HPU starts blind rotation from the unrotated LUT and defers the body
rotation to sample extraction. This is explicit in `pep_mmacc_body_ram`,
`pep_mmacc_splitc_sxt_core`, and the sample-extraction testbench. The feed
path uses `(X^a - 1)`; its read-side index offset is `2*N - a`.

The accepted reference follows that ordering: initialize from the LUT,
apply all mask-dependent external products, then apply `X^-b` and extract.
An earlier provisional reference used conventional CPU pre-rotation. Its
NTT products passed too, but those are not the accepted HPU-order vectors.
That old fixture is marked `SUPERSEDED.md`; it was not deleted.

## RTL coverage

`tb_ntt_pbs_vector` instantiates `ntt_core_gf64`, including forward transform,
BSK multiplication/accumulation, inverse transform, normalization, and final
prime-domain reduction. It uses N=2048, GLWE dimension 1, PBS level/base-log
1/23, GF64 cuts [5,6], PSI=64, radix 2, RAM/ROM latency 2, and `MULT_CORE`
multipliers (matching the deployed CLB-optimized selection).

Input coefficients are supplied in bit-reversed, row-interleaved order.
BSK words use the actual HPU shuffle, with independent per-lane/column
ready/valid counters. The scoreboard checks every output coefficient,
control marker, PID, complete key consumption, missing/extra output, unknown
data, the NTT error flag, and a 128-cycle drain. The watchdog is 20,000 cycles.

Step 0 uses the initial trivial LUT. Step 1 uses the reference accumulator
after its first update, exercising nonzero mask and body polynomials. Each
step is a separate replay: RTL step 0 is not fed directly into RTL step 1.

Accepted HPU-order results:

| Test | Result |
| --- | --- |
| Full offline CPU PBS | PASS: identity 1 → 1, all 879 steps |
| RTL external product 0 | PASS: 4,096 exact coefficients, 371 cycles |
| RTL external product 1 | PASS: 4,096 exact coefficients, 371 cycles |
| RTL product 1 with input gaps | PASS: 4,096 exact coefficients, 416 cycles |
| Deliberately wrong reference coefficient 0 | Expected mismatch at index 0; wrapper exit 1 |

The negative control is rejected, not counted as a numerical pass. All runs
completed; no replay processes were left running. Python compilation, JSON
validation, Rust formatting checks, and `git diff --check` passed.

This test does **not** instantiate the BSK loader/cache, body-correction RAM,
monomial rotation/decomposition RTL, prime-to-torus modulus switch,
accumulator, sequencer, or sample extraction. It uses a single-clock full
NTT core, not the placed three-part implementation and its inter-part links.
It is not a full RTL PBS or live-hardware pass.

## Reproduction

Build the host-only exporter from `tfhe-rs`:

```bash
timeout -k 5s 300s cargo build -p tfhe --release \
  --example hpu_pbs_vector --features hpu-v80-amr

# Output directory must not already exist. Seed/input are intentionally fixed.
timeout -k 5s 180s target/release/examples/hpu_pbs_vector \
  ../hpu_fpga/versal/diagnostic_pbs_artifacts_20260927/ks_vector_seed42 \
  /tmp/my-fresh-pbs-vector
```

Require exit zero and `PBS_SEED_MATCH`, both `PBS_PRODUCT_REFERENCE_PASS`
lines, and `PBS_CPU_PASS` before accepting a newly generated reference.
Partial output from an unsuccessful generator is not an accepted fixture.

From `hpu_fpga`, with Vivado 2026.1 on PATH:

```bash
pbs_replay_root=$(mktemp -d /tmp/hpu-pbs-check.XXXXXX)
python3 scripts/run_pbs_vector.py \
  versal/diagnostic_pbs_vector_hpu_order_20260927/step0 "$pbs_replay_root/step0"
python3 scripts/run_pbs_vector.py \
  versal/diagnostic_pbs_vector_hpu_order_20260927/step1 "$pbs_replay_root/step1"
python3 scripts/run_pbs_vector.py \
  versal/diagnostic_pbs_vector_hpu_order_20260927/step1 "$pbs_replay_root/gaps" --input-gaps

# Deliberate failure: expected wrapper exit 1 and coefficient-zero mismatch.
python3 scripts/run_pbs_vector.py \
  versal/diagnostic_pbs_vector_hpu_order_20260927/step1 "$pbs_replay_root/negative" --inject-ref-error
```

The runner requires a fresh build directory, enforces a 300-second host-only
build/simulation timeout, and requires `PBS_VECTOR_PASS` with no fatal error.
Do not run these wrappers concurrently; they share generated parameter files.
The five-minute host limit does not relax the three-minute FPGA-run limit.

Accepted fixture: `versal/diagnostic_pbs_vector_hpu_order_20260927`.
CPU/build/RTL logs are in `versal/diagnostic_pbs_replay_20260927`, alongside
the simulation source list and SHA-256 manifests. Simulation builds are in
`/tmp/hpu-pbs-replay.moJsjd/hpu_*`. The older pre-rotation `step*` builds and
`versal/diagnostic_pbs_vector_20260927` fixture are provisional, not the
accepted HPU-order results.

## Next boundary

First check the body-correction RAM using the captured raw body and 879
corrections, requiring output 980. Then compare the rotation/decomposition
and accumulator/modulus-switch paths against `acc_before.hex`, `decomp.hex`,
and `expected.hex`. Separately, the direct BSK stream can be replaced with
the real BSK loader/cache, analogous to the completed KSK integration test.
These checks distinguish the untested PBS glue logic/key delivery from the
already checked NTT arithmetic before considering a debug-image rebuild.
