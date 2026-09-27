# Lightweight native device/property preflight; no existing DCP is modified.
if {$argc != 1} { error "Usage: test_clock_window_native.tcl OUTPUT" }
set root [file dirname [file dirname [file normalize [info script]]]]
set output [file normalize [lindex $argv 0]]
file mkdir $output
cd $output
create_project -in_memory -part xcv80-lsva4737-2MHP-e-S
set_param general.maxThreads 8
read_verilog $root/scripts/clock_tuple_fixture.v
synth_design -mode out_of_context -top clock_tuple_fixture -part xcv80-lsva4737-2MHP-e-S
create_clock -period 2.857142857 [get_ports clk]
foreach i {0 1 2} {
    set sites [get_sites -of_objects [get_clock_regions -of_objects [get_slrs SLR$i]] -filter {SITE_TYPE =~ SLICE*}]
    if {![llength $sites]} {error "No fabric site in SLR$i"}
    set_property LOC [lindex $sites 0] [get_cells r$i]
}
source $root/versal/scripts/clock_signoff.tcl
set window [hpu_clock::full_window]
report_property -all [get_clock_regions X0Y0] -file $output/region_y0.rpt
report_property -all [get_clock_regions X0Y1] -file $output/region_y1.rpt
report_property -all [get_clock_regions X0Y11] -file $output/region_y11.rpt
if {$window ne "CLOCKREGION_X0Y1:CLOCKREGION_X9Y10"} {
    error "Unexpected native V80 window: $window"
}
foreach y {1 10} {
    foreach x {0 9} {
        if {[llength [get_clock_regions -quiet X${x}Y${y}]] != 1} {
            error "Missing window corner X${x}Y${y}"
        }
    }
}
# Only substitute the production hierarchy selector for this tiny fixture.
proc hpu_clock::net {} { return [get_nets -of_objects [get_pins bufg/O]] }
set_property USER_CLOCK_ROOT X3Y7 [hpu_clock::net]
set_property USER_CLOCK_TRACK 7 [hpu_clock::net]
hpu_clock::configure
if {[get_property USER_CLOCK_ROOT [hpu_clock::net]] ne "X5Y7" ||
    [get_property USER_CLOCK_TRACK [hpu_clock::net]] ne "7"} {
    error "Explicit root/track not applied"
}
if {[get_property USER_CLOCK_EXPANSION_WINDOW [hpu_clock::net]] ne $window} {
    error "Vivado did not retain the fabric window"
}
# Reproduce the failed build's incomplete tuple before placement.
set_property USER_CLOCK_ROOT {} [hpu_clock::net]
set_property USER_CLOCK_TRACK -1 [hpu_clock::net]
if {![catch {hpu_clock::preflight $output/invalid_preflight} preflight_message] ||
    ![string match "Clock property preflight failed:*" $preflight_message]} {
    error "Incomplete property set not rejected by NTCN-17: $preflight_message"
}
hpu_clock::configure
hpu_clock::preflight $output/preflight
# NTCN-16 also examines the realized clock tree, so test it after placement.
place_design -directive Quick
hpu_clock::validate $output/valid
puts "NATIVE_CLOCK_WINDOW_PASSED $window X5Y7 track 7; incomplete tuple correctly rejected"
exit 0
