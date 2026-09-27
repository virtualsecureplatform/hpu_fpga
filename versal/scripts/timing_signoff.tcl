# Shared pre-image gate. Never waive checks or edit clock constraints here.
namespace eval hpu_signoff {
    variable script_dir [file dirname [file normalize [info script]]]
}
proc hpu_signoff::run {directory checkpoint} {
    variable script_dir
    file mkdir $directory
    file delete -force [file join $directory signoff.json]
    report_timing_summary -report_unconstrained -max_paths 100 -file $directory/timing.rpt
    check_timing -verbose -file $directory/check_timing.rpt
    report_route_status -file $directory/route.rpt
    report_bus_skew -file $directory/bus_skew.rpt
    report_drc -file $directory/drc.rpt
    report_methodology -file $directory/methodology.rpt
    report_cdc -details -file $directory/cdc.rpt
    report_clocks -file $directory/clocks.rpt
    report_exceptions -file $directory/exceptions.rpt
    source [file join $script_dir clock_signoff.tcl]
    source [file join $script_dir constraint_audit.tcl]
    hpu_clock::validate $directory
    hpu_audit::collect $directory
    # Numeric slack queries catch violations that round to -0.000 in reports.
    set setup [llength [get_timing_paths -quiet -delay_type max -slack_lesser_than 0 -max_paths 1]]
    set hold [llength [get_timing_paths -quiet -delay_type min -slack_lesser_than 0 -max_paths 1]]
    set prc [get_clocks -quiet prc_clk]
    set free [get_clocks -quiet prc_free_clk]
    if {[llength $prc] != 1 || [llength $free] != 1} { error "Missing HPU clocks" }
    set mhz [expr {1000.0 / [get_property PERIOD $prc]}]
    set free_mhz [expr {1000.0 / [get_property PERIOD $free]}]
    # Evaluate report text with a strict parser. Unsupported formats fail closed.
    set checks [open $directory/checks.json w]
    puts $checks "\{\"setup_paths\": $setup, \"hold_paths\": $hold, \"processing_mhz\": $mhz, \"free_running_mhz\": $free_mhz\}"
    close $checks
    puts [exec python3 [file join $script_dir check_timing_signoff.py] $directory --checkpoint $checkpoint --record-checkpoint]
}
