# Helpers shared by checkpoint repair and ordinary routing recovery.
namespace eval hpu_repair {
    variable script_dir [file dirname [file normalize [info script]]]
}
proc hpu_repair::legal {} {
    set full [report_route_status -ignore_cache -boolean_check ROUTED_FULLY]
    set errors [report_route_status -boolean_check ERRORS_IN_ROUTES]
    return [expr {$full && !$errors}]
}
proc hpu_repair::require_legal {stage} {
    report_route_status -file ${stage}_route.rpt
    if {![legal]} { error "$stage: design is not legally routed; optimization is blocked" }
}
proc hpu_repair::optimize {stage args} {
    require_legal ${stage}_before
    mark_stage $stage
    set ids {{Vivado_Tcl 4-1385} {Vivado_Tcl 4-1850}}
    foreach id $ids { set before($id) [get_msg_config -id $id -count] }
    # Inspect this command's log slice as well: Tcl-emitted messages may not
    # increment get_msg_config counters in Vivado 2026.1.
    set logfile vivado.log
    if {![file exists $logfile]} { set logfile runme.log }
    set log [open $logfile r]
    seek $log 0 end
    phys_opt_design {*}$args
    set messages [read $log]
    close $log
    set skipped [regexp -line -nocase {^(WARNING|INFO): .*?(Skipping post-route optimization|phys_opt_design is skipped)} $messages]
    set f [open ${stage}_optimization.log w]
    puts $f [list phys_opt_design {*}$args]
    puts $f $messages
    foreach id $ids {
        set after [get_msg_config -id $id -count]
        puts $f "$id: before=$before($id) after=$after"
        if {$after > $before($id)} { set skipped 1 }
    }
    close $f
    if {$skipped} { error "$stage: Vivado skipped optimization" }
}
proc hpu_repair::snapshot {stage} {
    variable script_dir
    write_checkpoint ${stage}.dcp
    report_route_status -file ${stage}_route.rpt
    set routed [legal]
    report_timing_summary -report_unconstrained -max_paths 100 -file ${stage}_timing.rpt
    set setup [get_timing_paths -quiet -delay_type max -max_paths 1]
    set hold [get_timing_paths -quiet -delay_type min -max_paths 1]
    if {[llength $setup] != 1 || [llength $hold] != 1} { error "Missing numeric timing paths" }
    set wns [get_property SLACK $setup]
    set whs [get_property SLACK $hold]
    set f [open ${stage}_numeric.json w]
    puts $f "\{\"legal\": $routed, \"wns\": $wns, \"whs\": $whs\}"
    close $f
    exec python3 [file join $script_dir repair_metrics.py] extract $stage
}
proc hpu_repair::verify_input {expected endpoint prefix} {
    variable script_dir
    report_route_status -show_all -file ${prefix}_route.rpt
    report_timing_summary -report_unconstrained -max_paths 100 -file ${prefix}_timing.rpt
    # Filter equality is literal, unlike get_nets/get_pins glob patterns.
    set net [get_nets -hierarchical -filter [format {NAME == "%s"} $expected]]
    set pin [get_pins -hierarchical -filter [format {NAME == "%s"} $endpoint]]
    if {[llength $net] != 1 || [llength $pin] != 1} { error "Expected repair net/endpoint not found uniquely" }
    set connected [get_nets -segments -of_objects $pin]
    if {[lsearch -exact [get_property NAME $connected] $expected] < 0} {
        error "Repair endpoint is connected to an unexpected net"
    }
    set bad {}
    foreach type {PARTIAL UNROUTED ANTENNAS CONFLICTS GAPS UNPLACED UNPLACED_ALL MULTI_DRIVER} {
        foreach object [report_route_status -return_nets -route_type $type] {
            lappend bad [get_property NAME $object]
        }
    }
    if {[lsort -unique $bad] ne [list $expected]} { error "Unexpected defective net set: $bad" }
    exec python3 [file join $script_dir repair_metrics.py] input ${prefix}_route.rpt $expected $endpoint
    report_property -all $net -file ${prefix}_net.rpt
    report_property -all $pin -file ${prefix}_pin.rpt
    return $net
}
proc hpu_repair::run {} {
    variable script_dir
    set expected {hpu_3parts/p3_p2_sll/in_pipe/out_data[6244]}
    set endpoint {hpu_3parts/p3_p2_sll/out_pipe/depth1.out_data_reg[6244]/D}
    set net [verify_input $expected $endpoint repair_input]
    mark_stage repair_single_net
    route_design -unroute -nets $net
    # Keep route errors recoverable through the one permitted fallback attempt.
    set failed [catch {route_design -nets $net -auto_delay} message]
    if {$failed} { puts "Targeted repair failed: $message" }
    if {$failed || ![legal]} {
        mark_stage repair_preserved_route_fallback
        route_design -preserve -directive Explore
    }
    require_legal repaired
    snapshot repaired
    mark_stage repaired_checkpoint_saved
    set best repaired
    foreach {stage options} {explore {-directive Explore} clock {-clock_opt}} {
        if {$stage eq "clock" && [exec python3 [file join $script_dir repair_metrics.py] setup_pass $best] eq "yes"} { break }
        # Always start from the retained checkpoint, never a rejected candidate.
        if {$stage ne "explore"} {
            close_design
            open_checkpoint ${best}.dcp
        }
        optimize $stage {*}$options
        snapshot $stage
        set decision [exec python3 [file join $script_dir repair_metrics.py] compare $best $stage]
        mark_stage ${stage}_${decision}
        if {$decision eq "accept"} { set best $stage }
    }
    close_design
    open_checkpoint ${best}.dcp
    require_legal selected
    file copy -force ${best}.dcp postroute_physopt.dcp
    set f [open selected_candidate.txt w]
    puts $f $best
    close $f
    mark_stage postroute_checkpoint_saved
}

# Report every failing endpoint, plus its opposite-delay timing, before mutation.
proc hpu_repair::failure_paths {} {
    foreach {kind opposite} {max min min max} {
        set limit 100000
        set paths [get_timing_paths -quiet -delay_type $kind -slack_lesser_than 0 -max_paths $limit -nworst 1]
        if {[llength $paths] >= $limit} { error "Failing endpoint report exceeds $limit paths" }
        set endpoints {}
        foreach path $paths { lappend endpoints [get_property ENDPOINT_PIN $path] }
        set endpoints [lsort -unique $endpoints]
        set f [open input_${kind}_endpoints.txt w]
        foreach pin $endpoints { puts $f $pin }
        close $f
        if {[llength $endpoints]} {
            set pins {}
            foreach name $endpoints {
                set pin [get_pins -hierarchical -filter [format {NAME == "%s"} $name]]
                if {[llength $pin] != 1} { error "Failing endpoint not found uniquely: $name" }
                lappend pins {*}$pin
            }
            report_timing -delay_type $kind -to $pins -max_paths $limit -nworst 1 -file input_${kind}_failing.rpt
            report_timing -delay_type $opposite -to $pins -max_paths $limit -nworst 1 -file input_${kind}_opposite.rpt
        }
    }
}

# Fresh builds use the same legality and skipped-command checks as recovery.
# Keep the original route as a candidate: optimization can worsen hold/routing.
proc hpu_repair::postroute {} {
    variable script_dir
    require_legal route_input
    snapshot route_input
    set candidates {route_input}
    if {[exec python3 [file join $script_dir repair_metrics.py] timing_pass route_input] ne "yes"} {
        optimize route_explore -directive Explore
        snapshot route_explore
        lappend candidates route_explore
        if {[exec python3 [file join $script_dir repair_metrics.py] timing_pass route_explore] ne "yes"} {
            set base route_input
            if {[exec python3 [file join $script_dir repair_metrics.py] eligible route_explore] eq "yes"} {
                set base route_explore
            }
            close_design
            open_checkpoint ${base}.dcp
            optimize route_hold -directive ExploreWithAggressiveHoldFix
            snapshot route_hold
            lappend candidates route_hold
        }
    }
    if {[catch {exec python3 [file join $script_dir repair_metrics.py] select {*}$candidates} best]} {
        set f [open selection_failure.txt w]; puts $f $best; close $f
        error $best
    }
    close_design
    open_checkpoint ${best}.dcp
    require_legal selected
    file copy -force ${best}.dcp postroute_physopt.dcp
    set f [open selected_candidate.txt w]; puts $f $best; close $f
    mark_stage selected_$best
}
proc hpu_repair::setup_repair {} {
    variable script_dir
    require_legal setup_input
    snapshot setup_input
    set candidates {setup_input}
    set best setup_input
    foreach {stage options} {setup_explore {-directive Explore} setup_clock {-clock_opt}} {
        if {[exec python3 [file join $script_dir repair_metrics.py] timing_pass $best] eq "yes"} { break }
        close_design
        open_checkpoint ${best}.dcp
        optimize $stage {*}$options
        snapshot $stage
        lappend candidates $stage
        set best [exec python3 [file join $script_dir repair_metrics.py] select {*}$candidates]
        mark_stage ${stage}_selected_$best
    }
    close_design
    open_checkpoint ${best}.dcp
    require_legal selected
    file copy -force ${best}.dcp postroute_physopt.dcp
    set f [open selected_candidate.txt w]
    puts $f $best
    close $f
    mark_stage postroute_checkpoint_saved
}
proc hpu_repair::close_timing {} {
    variable script_dir
    require_legal hold_input
    failure_paths
    snapshot hold_input
    optimize hold_fix -aggressive_hold_fix
    snapshot hold_fix
    set candidates {hold_fix}
    if {[exec python3 [file join $script_dir repair_metrics.py] timing_pass hold_fix] ne "yes"} {
        set base hold_input
        if {[exec python3 [file join $script_dir repair_metrics.py] eligible hold_fix] eq "yes"} { set base hold_fix }
        mark_stage combined_start_from_$base
        close_design
        open_checkpoint ${base}.dcp
        optimize combined -directive ExploreWithAggressiveHoldFix
        snapshot combined
        lappend candidates combined
    }
    # Unlike repair's non-regression policy, prioritize fixing hold even when
    # that costs setup slack. Full signoff still requires both to pass.
    if {[catch {exec python3 [file join $script_dir repair_metrics.py] select {*}$candidates} best]} {
        set f [open selection_failure.txt w]
        puts $f $best
        close $f
        error $best
    }
    close_design
    open_checkpoint ${best}.dcp
    require_legal selected
    file copy -force ${best}.dcp postroute_physopt.dcp
    set f [open selected_candidate.txt w]
    puts $f $best
    close $f
    mark_stage selected_$best
    mark_stage postroute_checkpoint_saved
}


# Finalize the known hold-insertion defect without discarding clock routing.
proc hpu_repair::finish_route {} {
    variable script_dir
    set expected {hpu_3parts/p2_p1_sll/in_pipe/out_data[5862]_hold_fix_1}
    set endpoint {hpu_3parts/p2_p1_sll/out_pipe/depth1.out_data_reg[5862]/D}
    verify_input $expected $endpoint finish_input
    failure_paths
    snapshot finish_input
    mark_stage route_preserve_AggressiveExplore_tns_cleanup
    route_design -preserve -directive AggressiveExplore -tns_cleanup
    snapshot preserved
    mark_stage preserved_checkpoint_saved
    set candidates {preserved}
    # Full rerouting is a separate phase from a validated placement checkpoint.
    # Unrouting this post-route checkpoint can invalidate its deskew topology.
    if {[catch {exec python3 [file join $script_dir repair_metrics.py] select {*}$candidates} best]} {
        set f [open selection_failure.txt w]
        puts $f $best
        close $f
        error $best
    }
    close_design
    open_checkpoint ${best}.dcp
    require_legal selected
    file copy -force ${best}.dcp postroute_physopt.dcp
    set f [open selected_candidate.txt w]
    puts $f $best
    close $f
    mark_stage selected_$best
    mark_stage postroute_checkpoint_saved
}
