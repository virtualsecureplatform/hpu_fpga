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

# Use Ultra RAM
set_property ram_style ultra [get_cells -hier -regexp -filter {NAME =~ .*/pep_mmacc_infifo/gen_psi_loop\[.*\].gen_r_loop\[.*\].gen_fifo.fifo_data/ram/ram_1R1W/ram_1R1W_core/a_reg.*}]
set_property cascade_height 8 [get_cells -hier -regexp -filter {NAME =~ .*/pep_mmacc_infifo/gen_psi_loop\[.*\].gen_r_loop\[.*\].gen_fifo.fifo_data/ram/ram_1R1W/ram_1R1W_core/a_reg.*}]

# pep_mmacc_infifo/buf_data_reg has a high-fanout CE enable that Vivado infers from the FIFO feedback.
# EXTRACT_ENABLE no tells Vivado not to route the enable to the FDRE CE pin and to fold it back into a feedback mux on D, so each bit's driver can be replicated independently.
# Then we apply max_fanout 64 on the upstream data_sample selector.
# With these two constraints, design WNS improves slightly and TNS drops ~42%, failing endpoints drop ~28%, and net resource usage is neutral (FFs slightly down, LUTs +0.5%, slices unchanged).
set_property max_fanout 64 [get_nets -hier -regexp -filter { NAME =~ .*/pep_mmacc_infifo/data_sample.* }]
set_property EXTRACT_ENABLE no [get_cells -hier -regexp -filter {NAME =~ .*/pep_mmacc_infifo/gen_psi_loop\[.*\].gen_r_loop\[.*\].gen_fifo.fifo_data/buf_data_reg.*}]

# These two nets, without max fanouts are among the worst negative-slack paths
set_property max_fanout 32 [get_nets -hier -regexp -filter {NAME =~ .*/pep_mmacc_splitc_sxt_rot/x0_gram_sxt_rd_data_avail.*}]
set_property max_fanout 32 [get_cells -hier -regexp -filter {NAME =~ ".*/pep_mmacc_splitc_sxt_join/join_fifo/gen_depth_gt_2.no_depth_is_power_of_2_gen.wp_lsb_reg\[.*\]"}]
