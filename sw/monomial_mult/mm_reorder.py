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
    R = 2
    PSI = 8
    S = 7

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
