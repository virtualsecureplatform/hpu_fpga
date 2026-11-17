# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.

set cdir [pwd]
puts "current directory: $cdir"
source ${cdir}/../../uservars.tcl
puts "current PSI is: $::ntt_psi"

#################################################################################################
# Stop opt_design from undoing the fanout work this design already asks for
#################################################################################################
# hook_opt.post.tcl runs `opt_design -merge_equivalent_drivers`, which merges logically equivalent drivers
# Exactly what fanout replication and per-generate-instance control pipes produce.
# In this design that switch REVERSES committed work rather than merely skipping it.
#
# The remedy is EQUIVALENT_DRIVER_OPT KEEP on the affected drivers, NOT dropping the flag:
# global merge is what holds control sets and area down.

# please note that signals are explicitely named here for simplicity
set keep_repl_cells [get_cells -quiet -hier -regexp -filter {
       NAME =~ ".*/ntt_core_gf64_ntw_core_(rd|wr)/s0_iter_reg\[.*"
    || NAME =~ ".*/ntt_core_gf64_ntw_core_(rd|wr)/s1_pos_reg\[.*"
    || NAME =~ ".*/ntt_core_gf64_ntw_rot/s1_rot_part2_factor_reg\[.*"
    || NAME =~ ".*/pep_mmacc_infifo/data_sample.*"
    || NAME =~ ".*pep_mmacc_splitc_sxt_rot/x0_gram_sxt_rd_data_avail.*"
    || NAME =~ ".*pep_mmacc_splitc_sxt_join/join_fifo/gen_depth_gt_2.no_depth_is_power_of_2_gen.wp_lsb.*"
    || NAME =~ ".*/regfile/gen_seq_loop\[.*\].gen_word_loop\[.*\].regf_ram_unit/s1_rd_en_sr_reg\[.*"
    || NAME =~ ".*/regfile/gen_seq_loop\[.*\].gen_word_loop\[.*\].regf_ram_unit/s1_rd_pe_id_1h_sr_reg\[.*"
    || NAME =~ ".*/regfile/gen_seq_loop\[.*\].gen_word_loop\[.*\].regf_ram_unit/s1_rd_side_sr_reg\[.*"
    || NAME =~ ".*/pe_alu/p2_seq_id_reg\[.*"
}]

puts "INFO> EQUIVALENT_DRIVER_OPT KEEP: protecting [llength $keep_repl_cells] cells from opt_design -merge_equivalent_drivers"

if {[llength $keep_repl_cells] > 0} {
    set_property EQUIVALENT_DRIVER_OPT KEEP $keep_repl_cells
} else {
    puts "CRITICAL WARNING> EQUIVALENT_DRIVER_OPT matched 0 cells."
}

#################################################################################################
# Clocks and pblock floorplan
#################################################################################################
# Rename the clock gated clock to something sensible
create_generated_clock -name prc_clk [get_pins -of_objects [get_clocks clkout1_primitive]]

# Fail early if a rebuild retained a stale clock-wizard configuration.
if {[info exists ::env(HPU_FREQ_MHZ)]} {
    set actual_hpu_mhz [expr {1000.0 / [get_property PERIOD [get_clocks prc_clk]]}]
    puts "HPU processing clock actual: $actual_hpu_mhz MHz"
    if {abs($actual_hpu_mhz - $::env(HPU_FREQ_MHZ)) > 0.05} {
        error "Actual HPU clock does not match HPU_FREQ_MHZ"
    }
}

#cfg clock and prc clocks are asynchronous
set_clock_groups -name async_cfg_prc -asynchronous -group {cfg_clk} -group [get_clocks  -regexp {.*prc_.*clk.*}]
set_clock_groups -name async_mhdma_cfg -asynchronous -group [get_clocks mhdma_cfg_clk] -group [get_clocks cfg_clk]

# PBLOCK
create_pblock pblock_pl
resize_pblock pblock_pl -add SLR0
resize_pblock pblock_pl -add SLR1
resize_pblock pblock_pl -add SLR2

create_pblock pblock_SLR0
resize_pblock pblock_SLR0 -add SLR0
create_pblock pblock_SLR1
resize_pblock pblock_SLR1 -add SLR1
create_pblock pblock_SLR2
resize_pblock pblock_SLR2 -add SLR2

create_pblock pblock_SLL2BOT
create_pblock pblock_SLL1TOP
create_pblock pblock_SLL1BOT
create_pblock pblock_SLL0TOP
create_pblock pblock_CLKROOT

# The location of the SLLs are within 75 slices from the SLR border
# according to: Vivado Design Suite Properties Reference Guide (UG912, 2025-05-29, section USER_SLL_REG)

if [expr $::ntt_psi < 32] {
    resize_pblock pblock_SLL2BOT -add SLICE_X48Y620:SLICE_X379Y694
    resize_pblock pblock_SLL1TOP -add SLICE_X48Y619:SLICE_X379Y545
    resize_pblock pblock_SLL1BOT -add SLICE_X48Y332:SLICE_X379Y406
    resize_pblock pblock_SLL0TOP -add SLICE_X48Y331:SLICE_X379Y257
} elseif [expr $::ntt_psi < 64] {
    # However, limiting the registers to the slices containing UBUMPS increases congestion too much
    # for PSI=32. Relaxing to constraint the clock region.
    resize_pblock pblock_SLL2BOT -add CLOCKREGION_X1Y8:CLOCKREGION_X9Y8
    resize_pblock pblock_SLL1TOP -add CLOCKREGION_X1Y7:CLOCKREGION_X9Y7
    resize_pblock pblock_SLL1BOT -add CLOCKREGION_X1Y5:CLOCKREGION_X9Y5
    # The clock region on SLL0 is very small and does't catch all SLLs
    resize_pblock pblock_SLL0TOP -add SLICE_X48Y331:SLICE_X379Y257
} else {
    # Congestion is over the roof on PSI=64, so don't restrict. Placement will be bad initially, but
    # we'll gain time in routing.
    resize_pblock pblock_SLL2BOT -add SLR2
    resize_pblock pblock_SLL1TOP -add SLR1
    resize_pblock pblock_SLL1BOT -add SLR1
    resize_pblock pblock_SLL0TOP -add SLR0
}

# Constraining the clock root
resize_pblock pblock_CLKROOT -add CLOCKREGION_X6Y0

# parent
set_property PARENT pblock_SLR2 [get_pblocks {pblock_SLL2BOT}]
set_property PARENT pblock_SLR1 [get_pblocks {pblock_SLL1TOP pblock_SLL1BOT}]
set_property PARENT pblock_SLR0 [get_pblocks {pblock_SLL0TOP pblock_CLKROOT}]
set_property PARENT pblock_pl [get_pblocks pblock_SLR0] [get_pblocks pblock_SLR1] [get_pblocks pblock_SLR2]

set_property IS_SOFT TRUE [get_pblocks pblock*]

#################################################################################################
#                                            IMPORTANT:
#################################################################################################
# The following loose constraints are only possible because the design gates the clock before
# changing the reset. The time between disabling the clock, changing the reset and enabling the
# clock again is given in *fpga_clock_reset*. Please make sure that the design is configured to
# margins equal or greater than the ones defined here.
#################################################################################################

# Constrain the reset path, with loose constraints
set rst_setup_hold_margin 3
set ce_delay_margin       4

# Set a multicycle path on the main reset
set rst_pin [get_pins -hier -regexp {hpu_3parts/prc._clk_rst/rst_ff.*/C}]
set_multicycle_path $rst_setup_hold_margin -setup -from $rst_pin
set_multicycle_path [expr 2*$rst_setup_hold_margin-1] -hold -from $rst_pin

# We need also a max delay on the clock gate input pin. Cannot be a multicycle path this time
# because the path is not timed. The design is made to absorb a controllable amount of latency on
# that path, but we still need a constraint.
set clk_period [get_property PERIOD [get_clocks prc_clk]]
set_max_delay [expr $clk_period*$ce_delay_margin] -from [get_pins hpu_3parts/prc3_clk_rst/clk_en_reg/C] \
                                                  -to   [get_pins -hier -regexp -filter \
                                                        {NAME =~ .*/clock_primitive_inst/BUFGCE.*/CE}]
