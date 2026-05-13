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

    # Write phase: buf_data filled row-by-row from step1_l (each row is a full
    # R*PSI vector stored at index cnt during cycle cnt of the write phase).
    buf_data = [list(step1_l[r]) for r in range(STG_ITER_NB)]

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

    # ==========================================================================
    # Cross-comparison: reference (res) vs RTL model (rtl_res)
    # ==========================================================================
    if res == rtl_res:
      print(f"\nOK: reference and RTL model agree ({len(res)} elements, R={R} PSI={PSI} S={S}).")
    else:
      print("\nMISMATCH between reference and RTL model:")
      for (i, (a, b)) in enumerate(zip(res, rtl_res)):
        if a != b:
          print(f"  idx={i}: ref={a} rtl={b}")
