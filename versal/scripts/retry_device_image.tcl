# Retry only the failed image step; retain synthesis, placement and routing.
if {$argc != 2} { error "Usage: retry_device_image.tcl PROJECT_XPR RETRY_DIR" }
set project_file [file normalize [lindex $argv 0]]
set retry_dir [file normalize [lindex $argv 1]]
file mkdir $retry_dir
open_project $project_file
set impl [get_runs impl_1]
set repo_root [file normalize [file join [file dirname [info script]] ../..]]
set ::env(PROJECT_DIR) $repo_root
# Use the maintained hook, not a stale imported copy from the original build.
set_property STEPS.WRITE_DEVICE_IMAGE.TCL.PRE \
    $repo_root/versal/constraints/hooks/hook_write_device_image.pre.tcl $impl
set run_dir [get_property DIRECTORY $impl]
set checkpoint $run_dir/top_hpu_routed.dcp
if {![file isfile $checkpoint]} { error "Missing routed checkpoint: $checkpoint" }
if {[file exists $retry_dir/top_hpu_routed.dcp]} { error "Retry directory already used" }
file copy $checkpoint $retry_dir/top_hpu_routed.dcp
foreach name {runme.log top_hpu.tcl top_hpu.vdi} {
    if {[file exists $run_dir/$name]} { file copy $run_dir/$name $retry_dir/$name }
}
report_ip_status -file $retry_dir/ip_status.rpt
reset_run impl_1 -from_step write_device_image
# Some Vivado versions retain the old overall failure marker on a partial
# reset, causing wait_on_runs to return before the new worker completes.
if {[file exists $run_dir/.vivado.error.rst]} {
    file rename $run_dir/.vivado.error.rst $retry_dir/previous_vivado.error.rst
}
launch_runs impl_1 -next_step -jobs 1
wait_on_runs impl_1
set status [get_property STATUS $impl]
puts "Image retry status: $status"
if {![file exists $run_dir/.write_device_image.end.rst]} {
    error "Image generation did not complete: $status"
}
set images [glob -nocomplain $run_dir/*.pdi]
if {![llength $images]} { error "No PDI generated" }
foreach file $images { file copy $file $retry_dir/[file tail $file] }
puts "Image generation complete. Images copied to $retry_dir"
exit
