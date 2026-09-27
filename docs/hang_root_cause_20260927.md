# Original completion hang: firmware interrupt mapping

2026-09-27 follow-up: the separate encrypted-result correctness issue is now
[fixed and smoke-tested on the board](ciphertext_order_fix_20260927.md).
It was a host/RTL ciphertext-order mismatch, separate from this interrupt fix.

The original AMR HPU firmware used interrupt IDs five higher than the
Versal CIPS interrupt wiring requires. This prevents the R5 completion
handlers from servicing the actual HPU interrupts. The existing fix is in
`fw/arm/amr/hpu_profile.h`; no additional firmware or driver change was
made during this audit.

| Handler | Original absolute GIC ID | Correct absolute GIC ID |
| --- | ---: | ---: |
| Debug | 122 | 117 |
| ISC acknowledgement | 123 | 118 |
| MHDMA notification | 125 | 120 |
| MHDMA read completion | 126 | 121 |

## Evidence

The original release's archived `firmware_src/amr/hpu_profile.h` uses the
BSP `XPAR_FPGAx_INTERRUPT_ID` definitions. Its generated
`xparameters_ps.h` contains the ZynqMP-style mapping, rather than the
Versal mapping needed by this design. The interrupt wrapper adds 32 to
the low twelve bits of an encoded SPI identifier.

The shell block-design script wires GCQ to `pl_ps_irq0`, and its generated
device tree describes that GCQ interrupt as SPI 84 (absolute GIC 116).
HPU interrupts occupy the subsequent CIPS interrupt inputs. The corrected
profile explicitly encodes the Versal IDs, retaining edge triggering for
ISC acknowledgement.

This difference exists in the compiled firmware, not only in source.
Disassembling `hpu_amr_run` in the original and IRQ-fixed release ELFs
shows the argument to `iOSAL_Interrupt_Setup` at address `0x4005e9a8`
changing from `0x105b` to `0x1056`: absolute ISC IDs 123 and 118.
The other three handlers likewise change by five. Saved disassemblies:

- `versal/diagnostic_hang_audit_20260927/original_disassembly.txt`
- `versal/diagnostic_hang_audit_20260927/fixed_disassembly.txt`

In `fw/arm/amr/hpu_app.c`, `vInterruptHandler_isc_ack` drains the ISC
acknowledgements and posts the teardown command. The MHDMA worker waits
on its mailbox, performs teardown, and publishes the host acknowledgement
queue head. Missing the interrupt therefore leaves the host waiting for
completion. This is not evidence that Linux itself is stuck computing.
The incorrect MHDMA interrupt IDs also prevent the corresponding DMA
completion handlers from running.

The IRQ-fixed image uses the original `top_hpu.noelf.pdi` and updated R5
firmware; its release manifest retains the original XSA hash. This fix
does not require switching to AVED or changing the Linux kernel.

## Fresh verification and remaining issue

On 2026-09-27, the current board completed a seeded, two-bit identity-PBS
operation in **40.582923 ms**, under a 180-second timeout. Immediate and
final key/LUT upload readbacks passed. The command exited successfully;
the saved output is `versal/diagnostic_hang_audit_20260927/identity.log`.
FPGA hwmon temperature was 40 C and PCB temperature 32 C before and after.
No reset, reflash, or driver change was performed for this check.

The decrypted answer was **3 for input 1**, so this is a completion check,
not a correctness pass. The separate PBS numerical issue remains open;
see `pbs_vector_replay_20260927.md` for the reference/RTL investigation.
Do not conflate that issue with the original missing-completion hang.

Limitations: this audit did not reinstall the known-bad firmware for a
new live A/B test, nor independently read back the running R5 ELF. The
binary/source mapping defect and its completion-path consequence are
established; the fresh test verifies that the current board completes.
It does not exclude unrelated causes of future hangs or prove all
workloads correct.
