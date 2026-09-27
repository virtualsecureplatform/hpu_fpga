# Read-only native evidence capture. Does not constrain, route, or save a DCP.
if {$argc != 3 || [lindex $argv 2] ne "gt-inspect"} {
    error "Usage: inspect_gt_endpoints.tcl CHECKPOINT OUTPUT gt-inspect"
}
set checkpoint [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
cd $output_dir
if {[file exists gt_inspect.started]} {error "Inspection directory already used"}
close [open gt_inspect.started w]
set_param general.maxThreads 8
set f [open tool_version.txt w]; puts $f [version]; close $f
puts "GT_INSPECT open_checkpoint"
open_checkpoint $checkpoint
puts "GT_INSPECT update_timing"
update_timing
set prefix hpu_plug_wrapper/hpu_plug_i/shell_wrapper/cips/inst/cpm_0/inst
set f [open gt_native_evidence.txt w]
foreach quad {2 3} {
    foreach channel {0 1 2 3} {
        foreach control {RXUSRCLK PHYESMADAPTSAVE RXDLYALIGNREQ RXMLDCHAINDONE RXMLDCHAINREQ RXPHALIGNREQ RXPHSETINITREQ RXPHSHIFT180} {
            set name $prefix/gt_quad_inst$quad/inst/quad_inst/CH${channel}_$control
            set pin [get_pins -quiet $name]
            if {[llength $pin] != 1} {error "Missing or ambiguous endpoint $name"}
            puts $f "PIN $name"
            puts $f [report_property -all -return_string $pin]
            puts $f "CLOCKS [get_clocks -quiet -of_objects $pin]"
            set nets [get_nets -segments -of_objects $pin]
            set drivers [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == OUT}]
            puts $f "DRIVERS $drivers"
            foreach driver $drivers {
                puts $f [report_property -all -return_string $driver]
                set cell [get_cells -of_objects $driver]
                puts $f "DRIVER_PRIMITIVE [get_property REF_NAME $cell]"
            }
            flush $f
        }
    }
}
close $f
puts "GT_INSPECT check_timing"
check_timing -verbose -file check_timing.rpt
# Export existing constraints only, to correlate native case values with XDC.
write_xdc -force checkpoint_constraints.xdc
close [open gt_inspect.complete w]
puts "GT_INSPECT complete"
exit 0
