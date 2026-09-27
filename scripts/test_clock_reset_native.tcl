# Native module-reference/clock/reset BD validation, without building the HPU.
if {$argc != 1} { error "Usage: test_clock_reset_native.tcl OUTPUT" }
set root [file dirname [file dirname [file normalize [info script]]]]
set ::env(PROJECT_DIR) $root
set output [file normalize [lindex $argv 0]]
create_project reset_native $output -part xcv80-lsva4737-2MHP-e-S
set_param general.maxThreads 8
source $root/versal/scripts/bd/bd_lib.tcl
source $root/versal/scripts/bd/bd_clock_reset.tcl
namespace eval _nsp_hpu {
    variable USER_0_FREQ 350; variable USER_1_FREQ 100
    variable MHDMA_FREERUN_FREQ 100; variable MRMAC_APB3_FREQ 200; variable MHDMA_FREQ 390.625
}
create_bd_design reset_test
create_hier_cell_clock_reset / clock_reset
foreach interface [get_bd_intf_pins /clock_reset/*] { make_bd_intf_pins_external $interface }
foreach pin [get_bd_pins /clock_reset/*] { make_bd_pins_external $pin }
foreach {port frequency} {clk_pl_0 100000000 clk_freerun_0 33333333 clk_pcie_0 250000000} {
    set_property CONFIG.FREQ_HZ $frequency [get_bd_ports $port]
}
assign_bd_address
validate_bd_design
save_bd_design
puts "NATIVE_RESET_BD_VALIDATION_PASSED"
exit 0
