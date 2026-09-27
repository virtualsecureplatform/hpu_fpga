# OVF_ADD flag failure: missing ZHC carry normalization

## Fix follow-up

The standard OVF_ADD generation path is now fixed in TFHE-rs's backend.
`interface/overflow_add.rs` wraps the ZHC builder and applies `IsSome` to
the final carry before emitting the Boolean output; `interface/node.rs`
selects this builder for `Iop::OvfAdd` using the existing compiler pipeline.
No Cargo dependency/cache patch, ciphertext-order change, or PDI change is
required. The high-level API uses this same static opcode. Arbitrary dynamic
ZHC programs supplied by callers are outside this compatibility workaround.

The host-only regression passes 27 cases across 8/16/32/64/128 bits. The board
regression passes 22 deterministic cases at those widths, including both
original operands and 128-bit MAX+1/MAX+MAX. Both formerly failing randomized
bundles also pass (key seed 43, test seed 46, two iterations per operation).
The targeted board run finished in 17.39 seconds, 3 tests passed, none failed.
Logs are under `versal/tests_ovf_fix_20260927/`.

The full same-seed single-board rerun now passes **55/55 bundles** across
8/16/32/64/128 bits, with two iterations per operation, in 142.85 seconds.
This is the identical width/seed/iteration selection that previously passed
53 and failed 2. Multi-board/MHDMA tests were excluded; this is not exhaustive
coverage or the default 32-iteration run. The highest sampled device
temperature was 48 C, and it was 45 C immediately afterward (PCB 34 C).
All board runs used the approved 600-second limit with five-second kill grace;
none timed out. The benchmark executable was also rebuilt successfully.
The rebuilt benchmark reproducer now returns `[8f1e86af, 1]` for
`c4f023a2 + ca2e630d` (32-bit encrypted inputs, seed 43, two iterations).

Validated executable SHA-256 values:

- HPU integration test: `64e508713285ab3c0e00f461b0b456ad334194bc9573cecfdecd12646e5e98f7`
- `hpu_bench`: `01a712f60640ca79c50ac68df53158dcd1b9f8adda5db8b1037b8012a4e2669e`

The following sections preserve the diagnosis made before the fix.

## Conclusion

This is a semantic bug in the installed `zhc_builder` 0.9.1, not another
CPU/FPGA ciphertext-order mismatch. The generic overflowing-add builder
returns the Kogge-Stone propagate/generate carry representation directly as
a Boolean. A true carry is encoded as 2 internally, but the API requires 1.

No production source, dependency, firmware, or RTL was modified in this
diagnostic. The current RadixReversed host configuration remains necessary.

## Exact source path

TFHE-rs `backends/tfhe-hpu-backend/src/interface/node.rs:1070` routes recognized
standard IOps through `zhc::pipeline::compat::Iop::get_translation_table`.
Consequently selecting the older `Llt`/`Ilp` configuration does not bypass ZHC
for OVF_ADD. `zhc_pipeline` 0.9.1 recognizes OVF_ADD and builds `overflow_add`.

In the installed `zhc_builder-0.9.1/src/iops/add.rs`:

- `iop_overflow_add` (line 163) calls `iop_add_raw` and directly joins its carry
  into the flag output, without normalization.
- `iop_add_raw` (line 182) selects Kogge-Stone for widths 17 through 255.
- `iop_add_kogge_stone_raw` returns `cin_pg_kogge_entry.fresh` (line 756);
  the comment explicitly identifies the carry as being in bit 1.
- The explicit `iop_add_kogge_stone` wrapper (line 684), in contrast, applies
  `Lut1Def::IsSome` to the raw carry before returning its flag.

Installed source provenance: Cargo.lock pins ZHC 0.9.1; the builder crate's
`.cargo_vcs_info.json` identifies commit
`e3014a2d8150b81a9ccca111b256ac3f8bd0662f`. This diagnosis is about the installed
crate, not a claim that public main currently has identical code.

## Evidence

1. Original encrypted u32/u64 tests fail with a correct sum and flag 2.
2. The u32 failing operands also produce flag 2 with trivial ciphertexts on
   the board (zero masks), independently of encrypted-mask reordering.
3. A host-only ZHC IR interpreter reproduces both exact failures without
   touching the FPGA, keys, driver, or ciphertext serialization.
4. In that interpreter, calling the explicit normalized Kogge wrapper gives
   flag 1 for the same operands and the same correct sum.
5. `u128::MAX + 1` exposes the same defect at 128 bits. Earlier randomized
   u128 OVF_ADD cases both had no overflow, so their passing result did not
   exercise this case. Eight-/sixteen-bit overflowing controls and a u32
   non-overflowing control pass.

The diagnostic asserts exact sums and expected flags for both paths.
Its `DIAG_PASS` means the defect and normalized control were reproduced,
not that production OVF_ADD is fixed.

Artifacts: `versal/diagnostic_ovf_add_20260927/` contains `repro.rs`,
`host_interpreter.log`, and `trivial_u32.log`.

Reproduce the host-only diagnostic from the workspace root with the existing
dependency artifacts (no Cargo cache edits):

```bash
rustc +1.91.1 --edition 2021 \
  hpu_fpga/versal/diagnostic_ovf_add_20260927/repro.rs \
  --extern zhc=tfhe-rs/target/release/deps/libzhc-31253afd83b636d0.rlib \
  -L dependency=tfhe-rs/target/release/deps \
  -o hpu_fpga/versal/diagnostic_ovf_add_20260927/repro
timeout -k 5s 60s hpu_fpga/versal/diagnostic_ovf_add_20260927/repro
```

## Recommended fix

Normalize the raw carry at the generic overflowing-add Boolean-output
boundary, using the existing IsSome lookup, or route this operation through
the already normalized wrapper. Preserve PG encoding within the carry tree.
Do not simply accept 2 as a correct Boolean in the test or host decoder.
Add deterministic overflowing/non-overflowing cases at 8, 16, 32, 64, and
128 bits, then rerun the board suite. This is a host-generated instruction
program change; it does not require an FPGA rebuild or AMR change.
