#!/usr/bin/env python3
# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.

#  This script checks the algorithm used for the reorder from reverse to natural

import os       # OS functions
import sys
import argparse # parse input argument
from math import log

# ==============================================================================
# reverse
# ==============================================================================
def reverse (v, bit_nb):
  """
  Reverse the bits inside v.
  v is composed of bit_nb bits.
  """
  k = v;
  res = 0;
  for i in range(bit_nb):
    res = (res << 1) + (k & 1)
    k = k >> 1

  return res

# ==============================================================================
# Main
# ==============================================================================
if __name__ == '__main__':
#=====================================================
# Default
#=====================================================
# smaller example  : R=2, PSI=2, S=5
# original example : R=2, PSI=8, S=7
# N4096 example    : R=2, PSI=64, S=12
    R = 2
    PSI = 2
    S = 5

#=====================================================
# Parse input arguments
#=====================================================
    parser = argparse.ArgumentParser(description = "Check mmacc sample extract.")
    parser.add_argument('-R',  dest='radix',   type=int, help="Radix. (Only value 2 has been verified)",
                               default=R)
    parser.add_argument('-P',  dest='psi',     type=int, help="PSI.",
                               default=PSI)
    parser.add_argument('-S',  dest='stage',   type=int, help="Number of NTT stages.",
                               default=S)
    parser.add_argument("-v",  dest="verbose", help="Run in verbose mode.", action="store_true",
                               default=False)


    args = parser.parse_args()

    VERBOSE = args.verbose
    R = args.radix
    PSI = args.psi
    S = args.stage

    # Deduced parameters
    N = R ** S
    STG_ITER_NB = N // (R*PSI)
    N_SZ = S
    STG_ITER_SZ = int(log(STG_ITER_NB,2))
    RPSI_SZ = int(log(R*PSI,2))

    ct_nat = []
    ct_rev = []
    for i in range(N):
      ct_nat.append(i)
      ct_rev.append(reverse(i,N_SZ))

    in_l = []
    for i in range(STG_ITER_NB):
      in_l.append(ct_rev[i*R*PSI:(i+1)*R*PSI])

    # reverse in RxPSI
    step1_l = []
    for i in range(STG_ITER_NB):
      step1_l.append([in_l[i][reverse(x,RPSI_SZ)] for x in range(R*PSI)])

    # Take each line, reverse in each line
    step2_l = []
    for i in range(R*PSI):
      for j in range(STG_ITER_NB):
        l = []
        l.append(step1_l[reverse(j,STG_ITER_SZ)][i])
        step2_l.append(l)

    # Check result
    res = [x for l in step2_l for x in l]

    for (a,b) in zip(ct_nat, res):
      if (a != b):
        print(f"ERROR> exp={a} seen={b}")

    # =============================================================================================
    # RTL model: two-stage indexed mux (should mirrors pep_mmacc_splitc_sxt_reorder.sv)
    # =============================================================================================
    # Same algorithm as the reference loop above, but laid out as I want RTL to synthesises
    #   - buf_data[r] is written one row per cycle during the write phase (r == cnt, takes STG_ITER_NB cycles to fill).
    #   - A combinational permutation layer buf_data_perm[k][m] precomputes the bit-reverse + i_outer mapping so the runtime read becomes the clean
    #     indexed form rd_data[m] = buf_data_perm[cnt][m] (a shape Vivado can
    #     map to MUXF7/MUXF8 hardened muxes).
    #   - The cnt-indexed mux is split into cnt_hi (stage 1) and cnt_lo (stage 2) with a register stage between,
    #     so each LUT level handles half the bits.
    #
    # The model emits one beat of RD_COEF_NB = R*PSI coefs per cycle for
    # STG_ITER_NB read cycles, then one final drain cycle for the pipelined
    # stage 2 output.

    RD_COEF_NB = R * PSI
    RD_COEF_W  = RPSI_SZ # =int(log(STG_ITER_NB,2))

    if VERBOSE:
      print("Input Buffer")
      print(in_l, " \n")

    # Write phase: addressed write `buf_data[cnt] <= s1_data` per cycle, matches the RTL's
    # LUTRAM-inferred write pattern.
    buf_data = [None] * STG_ITER_NB
    for cnt in range(STG_ITER_NB):
      buf_data[cnt] = list(step1_l[cnt])

    if VERBOSE:
      print("Step 1 buffer")
      print(buf_data, " \n")

    # Permutation layer (pure wiring in RTL) ------------------------------------------------------
    # for every (k, m) pair, compute the bit-reverse + i_outer mapping and
    # present buf_data_perm as a clean array that the runtime read indexes on cnt.

    # Source-address helpers: for output (beat k, lane m), return the (row, col)
    # location in buf_data holding that coef.
    # flat_p = k*RD_COEF_NB + m is the natural-order position;
    #   -> high bits pick the column
    #   -> low bits (bit-reversed) pick the row.
    def buf_col(k, m):
      flat_p = (k << RD_COEF_W) | m
      return flat_p >> STG_ITER_SZ

    def buf_row(k, m):
      flat_p = (k << RD_COEF_W) | m
      j_outer = flat_p & (STG_ITER_NB - 1)
      return reverse(j_outer, STG_ITER_SZ)

    buf_data_perm = [
      [buf_data[buf_row(k, m)][buf_col(k, m)] for m in range(RD_COEF_NB)]
      for k in range(STG_ITER_NB)
    ]

    if VERBOSE:
      print("Permutation layer")
      print(buf_data_perm, " \n")

    # Two-stage mux split parameters --------------------------------------------------------------
    HI_SZ = (STG_ITER_SZ + 1) // 2
    LO_SZ = STG_ITER_SZ // 2
    N_LO  = 1 << LO_SZ

    rtl_out_beats = []
    mux_partial_q = None
    cnt_lo_q      = None
    valid_q       = False

    for cycle in range(STG_ITER_NB + 1):
      # Stage 2: finalize the read for the cnt that stage 1 captured one cycle ago
      # (mux_partial_q / cnt_lo_q are the registered values).
      if valid_q:
        rd_data = [mux_partial_q[cnt_lo_q][m] for m in range(RD_COEF_NB)]
        rtl_out_beats.append(rd_data)

      # Stage 1: partial mux on cnt_hi; capture mux_partial + cnt_lo.
      if cycle < STG_ITER_NB:
        cnt    = cycle
        cnt_hi = cnt >> LO_SZ
        cnt_lo = cnt & (N_LO - 1)
        mux_partial = [
          [buf_data_perm[(cnt_hi << LO_SZ) | k_lo][m] for m in range(RD_COEF_NB)]
          for k_lo in range(N_LO)
        ]
        mux_partial_q = mux_partial
        cnt_lo_q      = cnt_lo
        valid_q       = True
      else:
        valid_q = False

    # Flatten the cycle-major beat stream: beat k holds natural-order coefs in [k*RD_COEF_NB .. (k+1)*RD_COEF_NB - 1],
    # so flattening is the natural output order.
    rtl_res = [x for beat in rtl_out_beats for x in beat]

    if VERBOSE:
      print("Two-stage mux split")
      print(f"RTL params: STG_ITER_NB={STG_ITER_NB} STG_ITER_SZ={STG_ITER_SZ} "
            f"RD_COEF_NB={RD_COEF_NB} HI_SZ={HI_SZ} LO_SZ={LO_SZ} N_LO={N_LO}")
      for k, beat in enumerate(rtl_out_beats):
        print(f"  cycle {k}: {beat}")

    for (a, b) in zip(ct_nat, rtl_res):
      if (a != b):
        print(f"RTL ERROR> exp={a} seen={b}")

    # =============================================================================================
    # RTL model: diagonal-skewed bank memory (mirrors current pep_mmacc_splitc_sxt_reorder.sv)
    # =============================================================================================
    # Motivation
    # ----------
    # The two-stage mux model above mirrors the old RTL: a single 3D `buf_data` transpose buffer
    # drained through a cnt_hi/cnt_lo split mux. Vivado would not infer that shape as distributed
    # RAM (Synth 8-5856) and fell back to ~131k FFs, causing timing violations. This snippet
    # reshapes `buf_data` into LUTRAM-friendly banks.
    #
    # Idea
    # ----
    # LUTRAM gives 1 write + 1 read port per bank. With the naive layout (bank = col-group g), a
    # row-write hits every bank once (fine), but a column-read targets one bank N_BANK times -
    # incompatible with the 1R/cycle budget. The diagonal skew below makes BOTH row-writes and
    # column-reads touch every bank exactly once, so 1W1R per bank is sufficient.
    #
    # Place cell (row=i, col-group=g) in bank b = (i + g) mod N_BANK (instead of bank g):
    #
    #   4x4 ex  g=0   g=1   g=2   g=3
    #   row=0    B0    B1    B2    B3
    #   row=1    B1    B2    B3    B0
    #   row=2    B2    B3    B0    B1
    #   row=3    B3    B0    B1    B2
    #
    # Properties:
    #   - Fix row i: as g sweeps 0..N_BANK-1, b sweeps 0..N_BANK-1 -> exactly 1 write per bank.
    #   - Fix col-group g: as i sweeps 0..N_BANK-1, b sweeps 0..N_BANK-1 -> exactly 1 read per bank.
    #
    # Generalisation (RD_COEF_NB vs STG_ITER_NB)
    # ------------------------------------------
    # The first version used N_BANK = STG_ITER_NB; it works when RD_COEF_NB >= STG_ITER_NB (PSI64)
    # but not when RD_COEF_NB < STG_ITER_NB (PSI16), we generalise:
    #
    #   N_BANK = min(STG_ITER_NB, RD_COEF_NB)   # independent 1W1R banks
    #   RG_H   = STG_ITER_NB / N_BANK           # row-group height   (=1 in PSI64)
    #   CG_W   = RD_COEF_NB  / N_BANK           # lanes per entry    (=1 in PSI16)
    #
    # Buffer geometry (logical STG_ITER_NB x RD_COEF_NB cell array, MOD_Q_W bits per cell):
    #   row = rg * RG_H + r_lo,   rg in [0,N_BANK),  r_lo in [0,RG_H)
    #   col = cg * CG_W + c_lo,   cg in [0,N_BANK),  c_lo in [0,CG_W)
    #
    # Diagonal skew (generalised):
    #   bank b      = (rg + cg) mod N_BANK
    #   addr in b   = rg * RG_H + r_lo       (depth = STG_ITER_NB, same in both regimes)
    #   entry width = CG_W * MOD_Q_W bits
    def run_bank_skew_model():
      # Parameters --------------------------------------------------------------------------------
      N_BANK    = min(STG_ITER_NB, RD_COEF_NB)                          # prev: N_BANK = STG_ITER_NB
      N_BANK_SZ = int(log(N_BANK, 2))                                   # prev: (not present)
      RG_H      = STG_ITER_NB // N_BANK                                 # prev: (not present, implicit 1)
      CG_W      = RD_COEF_NB  // N_BANK                                 # prev: CG_W = RD_COEF_NB // STG_ITER_NB
      RG_SZ     = STG_ITER_SZ - N_BANK_SZ  # = log2(RG_H), 0 in Case A  # prev: (not present)
      CG_SZ     = RPSI_SZ     - N_BANK_SZ  # = log2(CG_W), 0 in Case B  # prev: (not present)

      # Per-bank memory: mem[b][addr] holds a CG_W-wide slice (list of CG_W coefs).
      mem = [[None] * STG_ITER_NB for _ in range(N_BANK)]                         # prev: mem = [[None] * N_BANK for _ in range(N_BANK)]

      # Write phase: one row per cycle, write rotator + per-bank addressed write.
      for cnt in range(STG_ITER_NB):
        cnt_hi  = cnt >> RG_SZ                                                    # prev: (not present, rotator amount was full cnt)
        s1_data = step1_l[cnt]
        # Reinterpret the RD_COEF_NB-wide row as N_BANK col-groups of CG_W lanes.
        s1_cg   = [s1_data[g*CG_W:(g+1)*CG_W] for g in range(N_BANK)]
        # Write-rotator: bank b takes col-group (b - cnt_hi) mod N_BANK.
        for b in range(N_BANK):
          mem[b][cnt] = list(s1_cg[(b - cnt_hi) % N_BANK])                        # prev: mem[b][cnt] = list(s1_cg[(b - cnt) % N_BANK])

      # Read phase: STG_ITER_NB read cycles + 1 drain cycle for the bank_out pipeline register.
      out_beats  = []
      bank_out_q = None
      cnt_q      = None
      valid_q    = False

      for cycle in range(STG_ITER_NB + 1):
        # Stage 2 (post-pipe): de-skew + lane unpack.
        if valid_q:
          k_hi    = cnt_q >> RG_SZ                                                # prev: (not present)
          rd_data = [0] * RD_COEF_NB
          # Lane (m_hi, m_lo) sources from bank b = (rev(m_lo) + k_hi) mod N_BANK.
          # prev: rd_row = [bank_out_q[(i + cnt_q) % N_BANK] for i in range(N_BANK)]
          # prev: for t in range(STG_ITER_NB):
          # prev:   rev_t = reverse(t, STG_ITER_SZ)
          # prev:   for s in range(CG_W):
          # prev:     rd_data[s*STG_ITER_NB + t] = rd_row[rev_t][s]
          for m_lo in range(N_BANK):
            rg_m  = reverse(m_lo, N_BANK_SZ)
            b     = (rg_m + k_hi) % N_BANK
            lanes = bank_out_q[b]
            for m_hi in range(CG_W):
              rd_data[m_hi * N_BANK + m_lo] = lanes[m_hi]
          out_beats.append(rd_data)

        # Stage 1 (pre-pipe): per-bank independent read.
        if cycle < STG_ITER_NB:
          cnt      = cycle
          k_hi     = cnt >> RG_SZ                                                 # prev: (not present)
          k_lo     = cnt & (RG_H - 1) if RG_H > 1 else 0                          # prev: (not present)
          r_lo     = reverse(k_lo, RG_SZ)  # 0 when RG_SZ=0                       # prev: (not present)
          # prev: bank_out = [mem[b][(b - cnt) % N_BANK] for b in range(N_BANK)]
          bank_out = []
          for b in range(N_BANK):
            rg   = (b - k_hi) % N_BANK
            addr = rg * RG_H + r_lo
            bank_out.append(mem[b][addr])
          bank_out_q = bank_out
          cnt_q      = cnt
          valid_q    = True
        else:
          valid_q = False

      return [x for beat in out_beats for x in beat]

    bank_res = run_bank_skew_model()

    if VERBOSE:
      print("Bank-skew model")
      print(f"  N_BANK={STG_ITER_NB} CG_W={RD_COEF_NB // STG_ITER_NB}")
      print(f"  out: {bank_res}")

    for (a, b) in zip(ct_nat, bank_res):
      if (a != b):
        print(f"BANK ERROR> exp={a} seen={b}")

    # ==========================================================================
    # Cross-comparison: reference (res) vs RTL models (rtl_res, bank_res)
    # ==========================================================================
    if res == rtl_res:
      print(f"\nOK: reference and two-stage-mux model agree ({len(res)} elements, R={R} PSI={PSI} S={S}).")
    else:
      print("\nMISMATCH between reference and two-stage-mux model:")
      for (i, (a, b)) in enumerate(zip(res, rtl_res)):
        if a != b:
          print(f"  idx={i}: ref={a} rtl={b}")

    if res == bank_res:
      print(f"OK: reference and bank-skew model agree ({len(res)} elements, R={R} PSI={PSI} S={S}).")
    else:
      print("MISMATCH between reference and bank-skew model:")
      for (i, (a, b)) in enumerate(zip(res, bank_res)):
        if a != b:
          print(f"  idx={i}: ref={a} bank={b}")
