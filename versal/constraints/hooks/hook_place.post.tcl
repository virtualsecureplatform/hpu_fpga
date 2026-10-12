# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.

#---------------------------------------------------------------------------------------------
# NoC guard: the solution chosen by place_design must meet every bandwidth and, when a pin was
# loaded by hook_place.pre.tcl, be identical to it
#---------------------------------------------------------------------------------------------
write_noc_solution -force -file noc_placed.ncr
report_noc_qos -file noc_placed_qos.rpt

# 1. status line of report_noc_qos ("Status: OPTIMAL" expected)
set fh [open noc_placed_qos.rpt]
set qos [read $fh]
close $fh
if {![regexp {Status:\s*OPTIMAL} $qos]} {
    regexp {Status:[^\n]*} $qos status
    common::send_msg_id {NOC_PIN-2} {ERROR} "NoC solution after place_design is relaxed ($status), see noc_placed_qos.rpt"
}

# 2. every path gets what it asked for
set unmet 0
foreach p [get_noc_logical_paths] {
    foreach rw {READ WRITE} {
        set req [get_property ${rw}_BANDWIDTH $p]
        set ach [get_property ${rw}_BANDWIDTH_ACHIEVED $p]
        if {$req > 0 && $ach ne "" && $ach < $req} {
            puts "NOC_PIN> unmet ${rw} $req -> $ach on $p"
            incr unmet
        }
    }
}
if {$unmet} {
    common::send_msg_id {NOC_PIN-2} {ERROR} "$unmet NoC paths below their requested bandwidth after place_design"
}

# 3. identical to the pin
proc noc_ncr_routes {file} {
    set fh [open $file]
    set lines [split [read $fh] "\n"]
    close $fh
    set keep {}
    foreach l $lines {
        if {![regexp {AchievedBW|Latency|Lock|SolutionType|"Phase"} $l]} { lappend keep [string trim $l] }
    }
    return $keep
}
if {[file exists noc_pin_loaded.ncr]} {
    set a [noc_ncr_routes noc_pin_loaded.ncr]
    set b [noc_ncr_routes noc_placed.ncr]
    if {$a ne $b} {
        set n 0
        foreach la $a lb $b { if {$la ne $lb} { incr n } }
        common::send_msg_id {NOC_PIN-3} {ERROR} "NoC solution after place_design differs from the pin ($n lines, diff noc_pin_loaded.ncr noc_placed.ncr)"
    }
    puts "INFO> NoC solution after place_design is identical to the pin"
} else {
    puts "INFO> no NoC pin loaded, solution not compared"
}
