# ==============================================================================================
# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.
# ----------------------------------------------------------------------------------------------
# Description  : Timing constraints for hierarchical synthesis
# ----------------------------------------------------------------------------------------------
#
# This file contains:
#   Module specific constraints, to be kept when doing hierarchical synthesis.
# ==============================================================================================

# forcing usage of BRAM for NTT network RAM
set_property RAM_STYLE BLOCK [get_cells -hierarchical -regexp " .*ntt_ntw_ram/ram_1R1W/ram_1R1W_core/a_reg.*"]


# These nets, without max fanouts are among the worst negative-slack paths
set_property max_fanout 64 [get_cells -hier -regexp -filter { \
       NAME =~ ".*/ntt_core_gf64_ntw_core_(rd|wr)/s0_iter_reg\[.*\]" \
    || NAME =~ ".*/ntt_core_gf64_ntw_core_(rd|wr)/s1_pos_reg\[.*\]" \
    || NAME =~ ".*/ntt_core_gf64_ntw_rot/s1_rot_part2_factor_reg\[.*\]" \
}]
