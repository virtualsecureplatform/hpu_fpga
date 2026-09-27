# HPU board regression — 2026-09-27

Follow-up: the overflow-flag fix now passes the same-seed **55/55** bundle run
and 22 deterministic board boundary cases. See
[fix details and validation](ovf_add_root_cause_20260927.md). The results below
are retained as the pre-fix baseline.

The TFHE-rs `hpu` integration tests were rebuilt with `hpu-v80-amr` and run
sequentially on the current AMR image with `ciphertext_order = "RadixReversed"`.
No RTL, driver, firmware, or ordering code was changed during this test run.

## Results

| Run | Key / test seed | Iterations per operation | Result | Duration |
| --- | --- | ---: | --- | ---: |
| AMR encrypted ADD regression (2/4/8 bits, copy and trivial controls) | 42 / 45 | Dedicated test | 1 passed | 14.43 s |
| All 11 single-board u8 bundles | 42 / 45 | 2 | 11 passed | 17.94 s |
| All 55 single-board bundles, u8/u16/u32/u64/u128 | 43 / 46 | 2 | 53 passed, 2 failed | 142.57 s |
| Isolated u32/u64 overflow-arithmetic reproduction | 43 / 46 | 2 | Both failures reproduced | 15.82 s |

These are assertion-based tests using real encrypted inputs. Multi-HPU and
MHDMA bundles were excluded. The separate key-loopback test was not run;
`HPU_VERIFY_KEY_UPLOAD=1` enabled immediate/final key-memory readback checks.
The normal randomized iteration count is 32; this bounded run used 2.

## Remaining failure

`OVF_ADD` returns the correct wrapped sum but a noncanonical overflow flag:

| Width | Inputs (hex) | Sum (hex, correct) | Flag actual / expected |
| --- | --- | --- | --- |
| 32 | c4f023a2 + ca2e630d | 8f1e86af | 2 / 1 |
| 64 | 9e65caf984ff237b + 7fe9a0a99b34437a | 1e4f6ba3203366f5 | 2 / 1 |

Both failures recur in a fresh process containing only those two bundles.
The OVF_SUB and OVF_MUL cases within those bundles pass. Root cause of this
remaining overflow-flag problem was subsequently established in the
[ZHC carry-normalization diagnosis](ovf_add_root_cause_20260927.md).
At the time of this baseline, the production fix had not yet been applied.
Do not interpret the
earlier successful ordering-fix smoke tests as full-suite certification.

## Safety and artifacts

Initial device/PCB temperature: 40/32 C. Highest sampled device temperature:
47 C; highest sampled PCB temperature: 34 C. During isolated reproduction,
the sampled device temperature was 43 C. These are discrete samples, not
a continuous peak measurement. No timeout occurred, reset or flash was used.
Initial runs had a 180-second limit; later runs used the user's approved
600-second limit with a five-second kill grace period.

Logs: `versal/tests_ct_order_20260927/` (build, test list, and four runs).
Test executable SHA-256:
`18d5f256ae85d545876bce5e3c73b3e17f05911d17a4abdcc6f9891a7847cecf`.
Configuration SHA-256:
`ddeda5fc2f9a08542e36216594a85f8109fe3bb7b543be396b45f65bbeb5efa1`.

Reproduce from `tfhe-rs` after building the test executable:

```bash
cargo test -p tfhe --release --features hpu-v80-amr --test hpu --no-run
env -u HPU_TEST_TRIVIAL -u HPU_FORCE_RELOAD \
  HPU_BACKEND_DIR="$PWD/backends/tfhe-hpu-backend" HPU_CONFIG=v80 \
  HPU_KEY_SEED=43 HPU_TEST_SEED=46 HPU_TEST_ITER=2 \
  HPU_VERIFY_KEY_UPLOAD=1 RUST_LOG=info \
  timeout -k 5s 600s ./target/release/deps/hpu-35b7a96778d0706d \
  hpu_test::hpu_test_ovf_alu_u32 hpu_test::hpu_test_ovf_alu_u64 \
  --exact --nocapture --test-threads=1
```

The executable hash suffix may change with a different build configuration.
Expected current exit status for the reproduction is 101 (test failure).
