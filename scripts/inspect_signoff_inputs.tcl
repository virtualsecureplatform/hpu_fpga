# Read-only checkpoint inspection; output goes only into a new diagnostic dir.
if {$argc != 2} { error "Usage: inspect_signoff_inputs.tcl CHECKPOINT OUTPUT" }
set output [file normalize [lindex $argv 1]]
file mkdir $output
set_param general.maxThreads 8
open_checkpoint [lindex $argv 0]
set f [open $output/device_regions.txt w]
foreach slr [get_slrs] {
    puts $f "$slr: [get_clock_regions -of_objects $slr]"
}
close $f
set net [get_nets -of_objects [get_pins -hier -filter {NAME =~ */clock_primitive_inst/BUFGCE_clkout1_inst/O}]]
report_property -all $net -file $output/clock_properties.rpt
set f [open $output/gt_controls.txt w]
foreach pin [get_pins -hier -filter {REF_PIN_NAME =~ *PHYESMADAPTSAVE || REF_PIN_NAME =~ *RXDLYALIGNREQ || REF_PIN_NAME =~ *RXMLDCHAINDONE || REF_PIN_NAME =~ *RXMLDCHAINREQ || REF_PIN_NAME =~ *RXPHALIGNREQ || REF_PIN_NAME =~ *RXPHSETINITREQ || REF_PIN_NAME =~ *RXPHSHIFT180}] {
    puts $f "PIN $pin"
    puts $f [report_property -all -return_string $pin]
    foreach n [get_nets -segments -of_objects $pin] {
        puts $f [report_property -all -return_string $n]
        puts $f "DRIVERS [get_pins -of_objects $n -filter {DIRECTION == OUT}]"
    }
}
close $f
exit 0
