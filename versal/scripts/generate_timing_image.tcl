if {$argc != 2} { error "Usage: generate_timing_image.tcl CHECKPOINT OUTPUT_DIR" }
set checkpoint [file normalize [lindex $argv 0]]
set output [file normalize [lindex $argv 1]]
cd $output
set_param general.maxThreads 8
open_checkpoint $checkpoint
set_property IP_REPO_PATHS [file join $::env(PROJECT_DIR) versal iprepo] [current_project]
set ::env(HPU_SYNTHESIS_VDS) [file join $output synthesis.vds]
set ::env(HPU_USERVARS) [file join $output uservars.tcl]
set ::env(HPU_ROUTED_CHECKPOINT) $checkpoint
set ::env(HPU_IMAGE_METADATA_DIR) $output
set ::env(HPU_SIGNOFF_SCRIPT) [file join $output flow timing_signoff.tcl]
report_ip_status -file image_ip_status.rpt
# Hook runs the gate both before and after changing the UUID ROM.
source [file join $output flow hook_write_device_image.pre.tcl]
write_device_image -force top_hpu.pdi
foreach path {top_hpu_tandem1.pdi top_hpu_tandem2.pdi image_input.dcp} {
    if {![file isfile $path] || [file size $path] == 0} { error "Missing image artifact: $path" }
}
close [open image_vivado.complete w]
exit 0
