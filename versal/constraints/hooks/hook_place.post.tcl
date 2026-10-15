# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.

#---------------------------------------------------------------------------------------------
# NoC guard: the solution must be identical to the pinned ncr
#---------------------------------------------------------------------------------------------
package require md5

write_noc_solution -force -file noc_placed.ncr
report_noc_qos -file noc_placed_qos.rpt

if {![file exists noc_pin_loaded.ncr]} {
    puts "INFO> no NoC pin loaded, solution not compared, see noc_placed_qos.rpt"
} elseif {[md5::md5 -hex -file noc_placed.ncr] ne [md5::md5 -hex -file $::noc_pin]} {
    common::send_msg_id {NOC_PIN-3} {ERROR} "NoC solution after place_design differs from the pin, diff $::noc_pin noc_placed.ncr"
} else {
    puts "INFO> NoC solution after place_design is identical to the pin $::noc_pin"
}
