# Exact key-switch replay — 2026-09-27

The key-switch RTL core passes an exact replay of the ciphertext and key from a
failing encrypted identity-PBS board run. This is a simulation result, **not**
a capture of the board's internal key-switch output. The on-board PBS failure
is still unresolved.

Follow-up: [the KSK loader/cache replay](ks_cache_replay_20260927.md) now also
checks the real `ksk_if`/`ksk_manager` path in simulation. The evidence below
describes the original direct-stream test.

## Evidence

- Board capture: seed 42, encrypted input 1, identity PBS output 3, operation
  latency 44.237544 ms. All immediate and final BSK/KSK/LUT readbacks passed.
- CPU reference: TFHE-rs `keyswitch_lwe_ciphertext_with_scalar_change`, using
  the actual compressed server key supplied to `init_device` and the exact
  ciphertext subsequently sent to the HPU. No new random key or ciphertext is
  generated for the reference.
- RTL replay: all 879 output coefficients, all 879 mean-compensation
  corrections, and the 21-bit body agree with the CPU reference. Completion
  at 29,153 simulated cycles; the initial replay took about 27 seconds.
- Negative control: changing expected coefficient zero by one bit causes
  `KS coefficient mismatch index=0`, and the wrapper returns exit status 1.
  Expected `cd3`, actual `cd2` in that deliberately corrupted comparison.
- The new bench uses fixed arrays, checks unknown/missing references,
  duplicate outputs, pointers, complete key consumption, and a pipeline-drain
  interval. It has a 200,000-cycle watchdog. Unlike the old random bench, it
  does not accumulate unbounded stimulus/scoreboard queues.

`tb_pep_key_switch_vector` instantiates the real `pep_key_switch`, covering
input decomposition, BLWE RAM, multiplication, accumulation, modulus switch,
per-coefficient correction, body subtraction, and result formatting. It uses
the board's KS dimensions, x3/y64/z3 parallelism, and batch/total capacity 12/27.
The generated package also selects PBS base-log/level 23/1, although the PBS
engine itself is not instantiated.

The KSK stream is supplied directly to the core in HPU linear key order. This
bypasses PCIe/QDMA, HBM/NoC, `ksk_if`, and `ksk_manager`; those paths remain
unverified by this test. Blind rotation, NTT arithmetic, sample extraction,
implemented-netlist behavior, and timing are also outside its coverage.

## Reproduction

Saved fixture directory:
`versal/diagnostic_pbs_artifacts_20260927/ks_vector_seed42`.
It contains the encrypted input, evaluation-key data, CPU intermediate output,
expected RTL outputs, and parameters. No secret key is exported. Use these
diagnostic fixtures locally; they are not included in source control.

Capture, positive replay, negative replay, and build logs are saved beside it
as `ks_vector_capture.log`, `ks_vector_positive.log`, `ks_vector_negative.log`,
and `ks_vector_build.log`. Fixture and source SHA-256 lists are saved there as
`ks_vector_sha256.txt` and `ks_vector_source_sha256.txt`. The final simulation
build is `/tmp/hpu-ks-vector.fkqUyi/canonical`.

From `hpu_fpga`, with Vivado 2026.1 available in PATH:

```bash
ks_replay_root=$(mktemp -d /tmp/hpu-ks-replay.XXXXXX)
python3 scripts/run_ks_vector.py \
  versal/diagnostic_pbs_artifacts_20260927/ks_vector_seed42 \
  "$ks_replay_root/positive"

# Deliberate failure: expected exit status 1, coefficient-zero mismatch.
python3 scripts/run_ks_vector.py \
  versal/diagnostic_pbs_artifacts_20260927/ks_vector_seed42 \
  "$ks_replay_root/negative" --inject-ref-error
```

The build directory must be fresh. The wrapper defaults to a 180-second
host-only build/simulation limit and requires a `KS_VECTOR_PASS` marker; a
simulator exit status of zero alone is insufficient. Do not run two wrappers
concurrently because they share the generated parameter-package directory.

To capture a new fixture, rebuild `hpu_bench` with `hpu-v80-amr`, then use the
same bounded identity-PBS command documented in
[the artifact audit](pbs_artifact_audit_20260927.md), with an additional
`HPU_KS_VECTOR_DIR` environment variable naming a **nonexistent** directory
whose parent exists. Use one input, one block, and one node. The exporter
rejects a second input rather than silently overwriting the first one.
This capture step accesses the FPGA; ordinary replay does not.

## Interpretation and next step

The replay makes a KS-core numerical or decomposition error for this vector
less likely. It does not establish that the live FPGA sees the same key/data
stream, and it does not clear the subsequent PBS engine.

The follow-up [KSK loader/cache replay](ks_cache_replay_20260927.md) checks the
same uploaded KSK layout through `ksk_if`/`ksk_manager` against this fixture.
The next boundary is blind rotation/PBS, or the live KS boundary captured
using a separately reviewed debug image. No speculative arithmetic fix or
reflash is justified by these simulation results alone.

The board remained `READY`. The only hardware operation in this step was the
bounded capture run; no reset, driver change, firmware change, or flash write
was performed.
