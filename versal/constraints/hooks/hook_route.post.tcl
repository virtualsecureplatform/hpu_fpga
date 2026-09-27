# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.

# Preserve and compare candidates; successful commands do not imply legality.
proc mark_stage {stage} {
    puts "HPU stage: $stage"
    set f [open stages.log a]
    puts $f "[clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}] $stage"
    close $f
}
source $::env(PROJECT_DIR)/versal/scripts/repair_route.tcl
set source_build [file dirname [file dirname [file dirname [pwd]]]]
set ::env(HPU_CIPS_XCI) $source_build/top_hpu/prj.srcs/sources_1/bd/hpu_plug/ip/hpu_plug_cips_0/hpu_plug_cips_0.xci
hpu_repair::postroute
report_timing_summary -report_unconstrained -max_paths 100 -file final_timing.rpt
report_route_status -file final_route.rpt
report_bus_skew -file final_bus_skew.rpt
source $::env(PROJECT_DIR)/versal/scripts/timing_signoff.tcl
if {[catch {hpu_signoff::run [file join [pwd] signoff] [file join [pwd] postroute_physopt.dcp]} message]} {
    set f [open signoff_failure.txt w]; puts $f $message; close $f
    puts "HPU signoff failed; image generation remains blocked: $message"
}
