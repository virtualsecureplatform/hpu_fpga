# Export the NoC solution of a routed checkpoint as the pinned solution.
# Usage: vivado -mode batch -source write_noc.tcl -tclargs <routed.dcp> <out.ncr>
set dcp [lindex $::argv 0]
set out [lindex $::argv 1]

open_checkpoint $dcp
write_noc_solution -force -file $out
puts "INFO> NoC solution written to $out"
