# Validate the actual revised address map before a costly full implementation.
if {$argc != 1} { error "Usage: test_amr_bd_native.tcl OUTPUT" }
set root [file dirname [file dirname [file normalize [info script]]]]
set ::env(PROJECT_DIR) $root
set ::env(HPU_FREQ_MHZ) 350
set output [file normalize [lindex $argv 0]]
create_project amr_map $output -part xcv80-lsva4737-2MHP-e-S
set_param general.maxThreads 8
set_property ip_repo_paths $root/versal/iprepo [current_project]
update_ip_catalog
set ntt_psi 64
create_bd_design hpu_plug
source $root/versal/scripts/bd/bd_hpu_plug.tcl
assign_bd_address
validate_bd_design
save_bd_design
write_bd_tcl $output/hpu_plug.tcl
puts "AMR_NATIVE_BD_VALIDATION_PASSED"
exit 0
