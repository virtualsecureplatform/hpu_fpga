# Recover implementation from a placed/physically optimized checkpoint.
# Run in a fresh output directory; keep the original project and checkpoints.
# vivado -mode batch -source recover_route.tcl -tclargs INPUT_DCP OUTPUT_DIR
if {$argc ni {2 3}} {
    error "Usage: recover_route.tcl INPUT_DCP OUTPUT_DIR"
}
set phase [expr {$argc == 3 ? [lindex $argv 2] : "recover"}]
if {$phase ni {baseline recover reroute repair close-timing setup-repair finish-route place signoff reset-signoff}} { error "Invalid phase: $phase" }
set checkpoint [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
if {![file isfile $checkpoint]} { error "Missing checkpoint: $checkpoint" }
file mkdir $output_dir
if {[file exists $output_dir/recovery.started]} {
    error "Recovery directory already used: $output_dir"
}
proc mark_stage {stage} {
    global output_dir
    set line "[clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}] $stage"
    puts $line
    set stream [open $output_dir/stages.log a]
    puts $stream $line
    close $stream
}
close [open $output_dir/recovery.started w]
cd $output_dir
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
source [file join [file dirname [info script]] repair_route.tcl]
source [file join [file dirname [info script]] clock_signoff.tcl]
if {$phase eq "place"} {
    # The input is the pre-placement optimized checkpoint from the source
    # build. Reapply its placement hook, including PMC reset rewiring and
    # pblocks, with the corrected clock helper before placement.
    set ::env(HPU_USERVARS) [file join $output_dir uservars.tcl]
    set ::env(SHELL_VER) hpu_plug
    mark_stage placement_preflight
    source [file join [file dirname [info script]] hook_place.pre.tcl]
    mark_stage place_design
    place_design -directive AggressiveExplore
    write_checkpoint placed.dcp
    hpu_clock::validate clock_validation
    mark_stage placement_phys_opt
    phys_opt_design -directive AggressiveExplore
    write_checkpoint placed_physopt.dcp
}
if {$phase in {recover reroute}} { hpu_clock::validate clock_validation }
if {$phase eq "reset-signoff"} {
    source [file join [file dirname [info script]] pcie_reset_constraints.tcl]
    hpu_reset::constrain
    write_checkpoint postroute_physopt.dcp
    mark_stage scoped_reset_constraint_checkpoint_saved
} elseif {$phase eq "signoff"} {
    # A byte-identical copy gives the existing image flow a local checkpoint
    # identity. Do not route, optimize, or change constraints in this phase.
    file copy $checkpoint postroute_physopt.dcp
    mark_stage signoff_input_preserved
} elseif {$phase eq "repair"} {
    hpu_repair::run
} elseif {$phase eq "close-timing"} {
    hpu_repair::close_timing
} elseif {$phase eq "setup-repair"} {
    hpu_repair::setup_repair
} elseif {$phase eq "finish-route"} {
    hpu_repair::finish_route
} else {
if {$phase != "reroute"} {
report_route_status -file baseline_route.rpt
report_bus_skew -file baseline_bus_skew.rpt
report_clocks -file baseline_clocks.rpt
report_clock_interaction -file baseline_clock_interaction.rpt
report_cdc -details -file baseline_cdc.rpt
report_exceptions -file baseline_exceptions.rpt
report_drc -file baseline_drc.rpt
report_ip_status -file baseline_ip_status.rpt
write_xdc -force baseline_constraints.xdc
report_timing_summary -report_unconstrained -max_paths 100 -file baseline_timing.rpt
report_methodology -file baseline_methodology.rpt
report_qor_assessment -file baseline_qor.rpt
mark_stage baseline_complete
close [open baseline.complete w]
if {$phase == "baseline"} { exit 0 }
mark_stage pre_route_phys_opt
phys_opt_design -directive AggressiveExplore
write_checkpoint pre_route_physopt.dcp
report_timing_summary -report_unconstrained -max_paths 100 -file pre_route_physopt_timing.rpt
}
# Match the project's Performance_AggressiveExplore routing effort by default.
set route_directive AggressiveExplore
if {[info exists ::env(HPU_ROUTE_DIRECTIVE)]} {
    set route_directive $::env(HPU_ROUTE_DIRECTIVE)
}
if {$route_directive ni {AggressiveExplore Explore NoTimingRelaxation}} {
    error "Unsupported routing directive: $route_directive"
}
mark_stage route_design_$route_directive
route_design -directive $route_directive
# Save before reports and subsequent optimization, which can take a long time.
write_checkpoint routed.dcp
mark_stage routed_checkpoint_saved
report_route_status -file route_status.rpt
report_timing_summary -report_unconstrained -max_paths 20 -file routed_timing.rpt
if {$phase eq "place"} {
    hpu_repair::postroute
} else {
    hpu_repair::optimize post_route_phys_opt -directive Explore
    hpu_repair::require_legal post_route_phys_opt_after
    write_checkpoint postroute_physopt.dcp
}
mark_stage postroute_checkpoint_saved
}
if {$phase ni {signoff reset-signoff}} {
report_route_status -file final_route_status.rpt
report_timing_summary -report_unconstrained -max_paths 20 -file final_timing.rpt
report_drc -file final_drc.rpt
report_bus_skew -file final_bus_skew.rpt
report_methodology -file final_methodology.rpt
}
# Persist an unsuccessful signoff without discarding the useful routed checkpoint.
source [file join [file dirname [info script]] timing_signoff.tcl]
mark_stage signoff_reports
if {[catch {hpu_signoff::run [file join $output_dir signoff] [file join $output_dir postroute_physopt.dcp]} message]} {
    set f [open signoff_failure.txt w]
    puts $f $message
    close $f
    puts "HPU signoff failed; image generation remains blocked: $message"
}
# Image generation is a separate step after reviewing routing, timing, and DRC.
mark_stage recovery_complete_review_reports_before_image_generation
close [open recovery.complete w]
exit 0
