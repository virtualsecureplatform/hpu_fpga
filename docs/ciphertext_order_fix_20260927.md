# PBS correctness fix — ciphertext-format compatibility

The running AMR-native 350 MHz image is working with TFHE-rs after correcting
the host-side ciphertext/KSK format. No AMR driver, firmware, PL rebuild,
reflash, or board reset was needed for this fix.

## Cause and fix

The deployed RTL (`hpu_fpga` base `6c8b3fa`) stores ciphertext masks in
radix-reversed order within each polynomial. Its sample-extraction testbench
explicitly checks that order. The new exact accumulator replay independently
confirmed it: output lane 1 contains natural coefficient 1024, not coefficient
1, for N=2048.

TFHE-rs commit `b72e6ff1180db39ca32da50bf1e56d6ac07b8cb2` (July 21, 2026,
`feat(hpu): ct_fmt update`) removed host-side ciphertext and KSK input-axis
permutation, expecting newer RTL to perform the conversion internally.
Combining that host format with this image caused incorrect decryption.

TFHE-rs now carries an explicit `HpuCiphertextOrder` in its HPU parameters.
The `[fpga]` configuration chooses the deployed ABI:

```toml
ciphertext_order = "RadixReversed"
```

The current `config_store/v80/hpu_config.toml` selects this mode. The default
remains `Natural` for newer images. The choice is independent of AMR/AVED.
Both upload/download of ciphertext masks and conversion/unconversion of the
KSK input dimension use the same permutation. Ciphertext bodies and BSK
layout are unchanged. Reinitialize and reupload keys when changing modes;
HPU-formatted buffers cannot be shared between modes.

CPU TFHE keys are unaffected. HPU parameter/entity serialization now includes
the order field; old binary-serialized HPU objects should be regenerated.
Older JSON/TOML parameters without this field retain the natural-order default.

## Board evidence

All runs were bounded by `timeout -k 5s 180s`, with full immediate and final
BSK/KSK/LUT readback verification. No concurrent board tests were run.

| Test | Result |
| --- | --- |
| Seed 42, encrypted identity input 1, **Natural** control | Incorrect 3, reproducing the original failure |
| Same binary/seed/input, **RadixReversed** | Correct 1, 40.282 ms |
| Seed 43, identity inputs 0, 1, 2, 3, two iterations each | All correct, about 40 ms/operation |
| Seed 43, eight-bit ADD 255 + 1, two iterations | Correct wraparound result 0, 44.927 ms/operation |
| Seed 44, eight-bit ADD 7 + 9, two iterations | Correct 16, 46.736 ms/operation |
| Seed 44, eight-bit BW_NOT 7, two iterations | Correct 248, 40.100 ms/operation |

FPGA temperature remained 40 C and PCB temperature 32 C at the recorded
checks. Logs are under `versal/diagnostic_ct_order_fix_20260927`.
Benchmark exit status alone is not a correctness assertion; the decrypted
`Behavior` lines above were checked against expected values. This is a
bounded regression, not certification of every operation or long-running load.

Host-only tests in `tfhe/tests/hpu_ciphertext_order.rs` check exact mask/KSK
layouts and round trips in both modes, per-polynomial boundaries, unchanged
bodies, padding, natural defaults, and invalid-order rejection.
All three regression tests pass. The final rebuilt benchmark also returns 1
for seed 42 / encrypted identity input 1 (40.650 ms), with verified key uploads.

Final benchmark SHA-256:
`8afaff75ee65029081778d75d3b5465da27b33ac2b25648b0ed24927c5315987`.
V80 configuration SHA-256:
`ddeda5fc2f9a08542e36216594a85f8109fe3bb7b543be396b45f65bbeb5efa1`.

## Diagnostic coverage added

- Body correction: raw captured body plus 879 corrections gives 980, including
  gapped inputs, output backpressure, and PID reuse. A wrong reference fails.
- BSK loader/cache: 879 slices / 7,200,768 words pass with normal and uneven
  AXI timing. The first two slices use real seeded key data; subsequent slices
  use repeated, loop-tagged data to detect stale slots. Memory is modeled,
  not physical HBM. The consumer follows the PP's one-cycle column skew;
  independent per-lane backpressure is not supported. Corruption is detected.
- Split GF64 NTT: the deployed 6/10/6 head/middle/tail stage partition with
  two-cycle modeled links matches all 4,096 step-1 coefficients, including
  input gaps and prime-to-torus conversion. This is not a physical SLR test.
- MMACC: exact rotation/feed and sample-extraction values pass for the first
  two captured products, padded with four zero rotations (LWE_K=6). The
  arithmetic oracle supplies NTT results; this is not a complete RTL PBS.
  The existing MMACC testbench preload had scalar write enables/addresses
  assigned to packed lane arrays; replication now initializes every lane.
  That was a **testbench bug**, not the board's root cause.

These explain why earlier local arithmetic tests passed: they checked kernels
with consistently arranged inputs, not the CPU/FPGA ciphertext-format boundary.

Host-only replay commands, from `hpu_fpga` with Vivado on PATH (fresh output
directories required; run sequentially because generators share files):

```bash
python3 scripts/run_pbs_glue_vector.py --mode body \
  versal/diagnostic_pbs_artifacts_20260927/ks_vector_seed42 /tmp/my-body-replay
python3 scripts/run_pbs_glue_vector.py --mode bsk --axi-stagger \
  versal/diagnostic_pbs_vector_hpu_order_20260927 /tmp/my-bsk-replay
python3 scripts/run_pbs_vector.py --split-core --input-gaps \
  versal/diagnostic_pbs_vector_hpu_order_20260927/step1 /tmp/my-split-replay
python3 scripts/run_mmacc_vector.py \
  versal/diagnostic_pbs_vector_hpu_order_20260927 /tmp/my-mmacc-replay
```

Each runner requires a positive verdict and rejects simulator fatal errors.
Use `--inject-ref-error` with a fresh directory for an expected-failure
negative control. Accepted logs are saved in the diagnostic directory's `rtl/`.
