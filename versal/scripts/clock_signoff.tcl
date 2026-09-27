# Processing-clock topology shared by project placement and DCP recovery.
namespace eval hpu_clock {}
proc hpu_clock::net {} {
    set pins [get_pins -hier -filter {NAME =~ */clock_primitive_inst/BUFGCE_clkout1_inst/O}]
    if {[llength $pins] != 1} { error "Expected one processing BUFG output, got $pins" }
    set net [get_nets -of_objects $pins]
    if {[llength $net] != 1} { error "Expected one processing clock net" }
    return $net
}
proc hpu_clock::full_window {} {
    set slrs [get_slrs {SLR0 SLR1 SLR2}]
    if {[llength $slrs] != 3} { error "Expected the three V80 processing SLRs" }
    # Use fabric rows only. The edge HSR rows contain I/O/NoC resources
    # and Vivado rejects them in USER_CLOCK_EXPANSION_WINDOW (12-25514).
    # Their widths also differ, so independent device X/Y extrema can
    # invent a nonexistent corner. Retain only columns common to all
    # fabric rows, including each processing SLR's complete fabric height.
    set regions [get_clock_regions -of_objects $slrs]
    set fabric_rows {}
    set slices [get_sites -of_objects $regions -filter {SITE_TYPE =~ SLICE*}]
    if {![llength $slices]} { error "Missing fabric sites" }
    foreach region [get_clock_regions -of_objects $slices] {
        if {![regexp {X([0-9]+)Y([0-9]+)$} $region -> x y]} {
            error "Unknown fabric clock region: $region"
        }
        lappend fabric_rows $y
    }
    if {![llength $fabric_rows]} { error "Missing fabric clock regions" }
    set rows [dict create]
    foreach region $regions {
        if {![regexp {X([0-9]+)Y([0-9]+)$} $region -> x y]} {
            error "Unknown clock region: $region"
        }
        if {$y ni $fabric_rows} { continue }
        dict lappend rows $y $x
    }
    if {![dict size $rows]} { error "Missing V80 clock regions" }
    set ys [lsort -integer [dict keys $rows]]
    set xs [lsort -integer -unique [dict get $rows [lindex $ys 0]]]
    for {set y [lindex $ys 0]} {$y <= [lindex $ys end]} {incr y} {
        if {![dict exists $rows $y]} { error "Missing clock-region row Y$y" }
        set common {}
        foreach x $xs {
            if {$x in [dict get $rows $y]} { lappend common $x }
        }
        set xs $common
    }
    if {![llength $xs]} { error "No full-height clock-region columns" }
    if {[llength $xs] != [lindex $xs end] - [lindex $xs 0] + 1} {
        error "Full-height clock-region columns are not contiguous"
    }
    return "CLOCKREGION_X[lindex $xs 0]Y[lindex $ys 0]:CLOCKREGION_X[lindex $xs end]Y[lindex $ys end]"
}
proc hpu_clock::configure {} {
    set clock_net [net]
    # Do not retain a forced root/track from a previous routing experiment.
    foreach {property automatic} {USER_CLOCK_ROOT {} USER_CLOCK_TRACK -1 USER_CLOCK_VTREE_TYPE {}} {
        # reset_property USER_CLOCK_ROOT is unsupported in Vivado 2026.1.
        # The integer TRACK property's native reset sentinel is -1.
        if {$property in [list_property $clock_net]} { set_property $property $automatic $clock_net }
    }
    set_property USER_CLOCK_EXPANSION_WINDOW [full_window] $clock_net
    # V80 calibrated deskew requires the complete explicit property tuple
    # (NTCN-17). This tuple matches the legal September 10 routed clock.
    set_property USER_CLOCK_ROOT X5Y7 $clock_net
    set_property USER_CLOCK_TRACK 7 $clock_net
    set_property GCLK_DESKEW CALIBRATED $clock_net
}
proc hpu_clock::preflight {directory} {
    # NTCN-17 validates the input property set. NTCN-16 additionally needs
    # a realized clock tree and is checked after placement by validate.
    file mkdir $directory
    set checks [get_drc_checks NTCN-17]
    if {[llength $checks] != 1} { error "Missing clock-property DRC" }
    report_drc -checks $checks -file $directory/clock_property_drc.rpt
    set violations [get_drc_violations NTCN-17*]
    if {[llength $violations]} { error "Clock property preflight failed: $violations" }
}
proc hpu_clock::validate {directory} {
    file mkdir $directory
    file delete -force $directory/clock_validation.json
    set clock_net [net]
    report_property -all $clock_net -file $directory/clock_properties.rpt
    set window [get_property USER_CLOCK_EXPANSION_WINDOW $clock_net]
    if {$window ne [full_window]} {
        error "Processing clock must cover complete SLRs; found $window"
    }
    if {[get_property USER_CLOCK_ROOT $clock_net] ne "X5Y7" ||
        [get_property USER_CLOCK_TRACK $clock_net] ne "7"} {
        error "Processing clock requires the complete validated root/window/track tuple"
    }
    if {[get_property GCLK_DESKEW $clock_net] ne "CALIBRATED"} {
        error "Processing clock calibrated deskew is not enabled"
    }
    set checks [get_drc_checks {NTCN-16 NTCN-17}]
    if {[llength $checks] != 2} { error "Missing calibrated-deskew DRC" }
    report_drc -checks $checks -file $directory/clock_drc.rpt
    # get_drc_violations does not support -of_objects in Vivado 2026.1.
    # Query the just-completed report by rule-name pattern instead.
    set violations [get_drc_violations {NTCN-16* NTCN-17*}]
    if {[llength $violations]} { error "Clock topology failed DRC: $violations" }
    set f [open $directory/clock_validation.json w]
    puts $f "\{\"passed\": true, \"expansion_window\": \"$window\"\}"
    close $f
}
