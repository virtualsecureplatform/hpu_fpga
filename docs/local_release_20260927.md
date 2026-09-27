# HPU FPGA AMR 350 MHz — local release 2026-09-27

This local release packages the IRQ-fixed AMR-3.0 PSI64 350 MHz image,
current HPU/TFHE-rs/AMR worktree sources, matching tested host executables,
configuration, original PL signoff evidence, and board regression logs.
It is not a new FPGA synthesis, public publication, or Git tag.

## Verify before use

From the unpacked release directory:

```bash
sha256sum --check --quiet SHA256SUMS
python3 verify_amr_release.py image/hpu_psi64_350mhz_amr.pdi
```

Expected logic UUID: `00000000000000000000000038624737`.
PDI SHA-256: `757dba364fb9f5c3ec8be2533228c56a9274df28a6e4f83019463b9d624f4fd1`.
The original September 26 pre-IRQ-fix PDI is deliberately NOT a deployable
artifact in this bundle. The older candidate README and build metadata are
retained under `provenance/` as historical records, not current status.
Board FPT metadata reports partition 1 active with a matching PDI size/MD5;
this is not an independent byte-for-byte flash readback.

## Host use on the existing configured machine

The supplied x86-64 Linux executables were built with Rust 1.91.1 and
`hpu-v80-amr` on this machine. CPU/system-library portability is not promised;
see `evidence/*.ldd.txt`, and rebuild from the source snapshot on other hosts.
Existing AMI/QDMA drivers, device permissions and queues are prerequisites.
Do not start a second process using the board concurrently.

```bash
export HPU_BACKEND_DIR="$PWD/host/backend"
export HPU_CONFIG=v80
export HPU_KEY_SEED=43 HPU_TEST_SEED=46 HPU_TEST_ITER=2
export HPU_VERIFY_KEY_UPLOAD=1
unset HPU_FORCE_RELOAD HPU_TEST_TRIVIAL
timeout -k 5s 600s host/bin/hpu_tests \
  hpu_test::hpu_amr_overflow_add_regression --exact --nocapture --test-threads=1
```

Keep `ciphertext_order = "RadixReversed"` for this PL image. Host code also
normalizes ZHC 0.9.1's OVF_ADD carry to a Boolean. User-supplied dynamic ZHC
graphs are not rewritten by that compatibility fix. Ordinary overflowing-add
through the high-level API uses the corrected static operation.

No programming is necessary on the already tested board. For deliberate
deployment elsewhere, extract `sources/hpu_fpga.tar.gz` and use its
`scripts/program_amr_hpu.sh` with the bundled `image/*.pdi` and explicit BDF.
The script requires confirmation and targets partition 1, preserving recovery
partition 0. Consult its source and the AMR migration documentation first;
this release command does not program, reset, or reboot any board.

## Contents and provenance

- `image/`: IRQ-fixed PDI, R5 AMC ELF, XSA and original artifact manifests.
- `sources/`: current dirty-worktree source archives for HPU FPGA, TFHE-rs,
  and AMR, inventories with per-file hashes/modes, Git base revisions/status,
  binary patches, and explicit exclusions. Initialized HPU submodule tracked
  sources are included. Source archives contain the actual modified/untracked
  sources; patches alone do not represent all untracked content.
- `host/`: rebuilt benchmark and assertion-based tests, runtime configuration,
  and TFHE-rs license. Source archives retain their own licenses.
- `provenance/`: original PL source snapshot/signoff, AMR firmware sources,
  firmware merge recipe/input, and comparison against the original snapshot.
- `evidence/`: passing post-fix tests, pre-fix comparison runs and live
  read-only board overview/FPT metadata. Baseline failure logs are intentional.
- `MANIFEST.json` and `SHA256SUMS`: machine-readable release identity and
  integrity inventory. Neither is a cryptographic signature.

Current source differs from the original image snapshot in the IRQ profile,
simulation/diagnostic code, deployment script, and documentation. The packaged
R5 binary contains the IRQ fix; PL implementation and XSA remain the signed-off
September 26 design. Full current source is provided without claiming every
file was an input to the older binary. Build manifests contain historical
absolute paths, which require adaptation when rebuilding elsewhere. The large
routed DCP and vendor tool installations are not bundled.

## Validation and limits

The corrected host code passed 55/55 single-board operation bundles across
8/16/32/64/128 bits with two randomized iterations per operation (142.85 s),
22 deterministic board overflow cases, and 27 host interpreter cases. The
rebuilt benchmark also passed the original failing input. Highest sampled
device temperature was 48 C. Multi-board/MHDMA tests and the full default
32-iteration randomized run were not performed. This is a local tested
snapshot, not certification of every operation or long-running workload.

This bundle is for local use. AMD tool/IP-generated binary redistribution
rights have not been reviewed. Downloaded AMD boot-FPT/bootfw update packages
are excluded. Do not publish this bundle without reviewing applicable licenses
and the included machine-specific build metadata.
