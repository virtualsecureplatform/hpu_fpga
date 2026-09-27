# Routing-only crash reproduction. Never alter the checkpoint constraints.
if {$argc != 3 || [lindex $argv 2] ne "replay"} {
    error "Usage: replay_route_crash.tcl CHECKPOINT OUTPUT replay"
}
set checkpoint [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
cd $output_dir
if {[file exists replay.started]} { error "Replay directory already used" }
close [open replay.started w]
proc mark_stage {stage} {
    set line "[clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}] $stage"
    puts $line
    set f [open stages.log a]; puts $f $line; close $f
}
set tool_version [version]
if {![string match {*2026.1*6511674*} $tool_version]} {
    error "Replay requires the original Vivado 2026.1 build 6511674: $tool_version"
}
set f [open tool_version.txt w]; puts $f $tool_version; close $f
set_param general.maxThreads 8
mark_stage open_checkpoint
open_checkpoint $checkpoint
set_property IP_REPO_PATHS [file join $::env(PROJECT_DIR) versal iprepo] [current_project]
foreach name {prc_clk prc_free_clk} {
    set clocks [get_clocks -quiet $name]
    if {[llength $clocks] != 1} { error "Expected one $name clock" }
    set freq [expr {1000.0 / [get_property PERIOD $clocks]}]
    if {abs($freq - 350.0) > 0.05} { error "$name has incorrect frequency: $freq" }
}
# This report was the last operation between saving the original input DCP
# and routing. No placement, phys_opt, unroute, clock edits or waivers here.
mark_stage pre_route_timing_report
report_timing_summary -report_unconstrained -max_paths 100 -file pre_route_physopt_timing.rpt
mark_stage route_design_AggressiveExplore
route_design -directive AggressiveExplore
mark_stage route_returned_without_crash
write_checkpoint routed.dcp
mark_stage routed_checkpoint_saved
close [open replay.complete w]
exit 0
