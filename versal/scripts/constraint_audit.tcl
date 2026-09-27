# Capture proof from the currently opened netlist on every signoff invocation.
namespace eval hpu_audit { variable script_dir [file dirname [file normalize [info script]]] }
proc hpu_audit::ground {pin} {
    if {[llength $pin] != 1} { return [list {} 0] }
    set nets [get_nets -segments -of_objects $pin]
    if {![llength $nets]} { return [list {} 0] }
    set grounded 0
    foreach net $nets {
        # IS_GND is absent on native Vivado 2026.1 net objects. Missing or
        # malformed values are unknown evidence, never true and never an
        # exception that aborts all remaining signoff reports.
        set properties [list_property $net]
        if {"TYPE" in $properties && [get_property TYPE $net] eq "GROUND"} {
            set grounded 1
        }
        if {"IS_GND" in $properties} {
            set value [get_property IS_GND $net]
            if {[string is boolean -strict $value] && $value} { set grounded 1 }
        }
    }
    return [list [lindex $nets 0] $grounded]
}
proc hpu_audit::collect {directory} {
    variable script_dir
    set f [open $directory/gt_endpoint_evidence.tsv w]
    set prefix hpu_plug_wrapper/hpu_plug_i/shell_wrapper/cips/inst/cpm_0/inst
    set drivers_file [open $directory/gt_cpm_drivers.tsv w]
    foreach quad {2 3} {
        set cell_name $prefix/gt_quad_inst$quad/inst/quad_inst
        set cell [get_cells -quiet $cell_name]
        set primitive missing
        if {[llength $cell] == 1} {
            set primitive [get_property REF_NAME $cell]
            report_property -all $cell -file $directory/gt_quad${quad}_properties.rpt
        }
        foreach channel {0 1 2 3} {
            set clock_name $cell_name/CH${channel}_RXUSRCLK
            foreach suffix {RXUSRCLK PHYESMADAPTSAVE RXDLYALIGNREQ RXMLDCHAINDONE RXMLDCHAINREQ RXPHALIGNREQ RXPHSETINITREQ RXPHSHIFT180} {
                set name $cell_name/CH${channel}_$suffix
                set pin [get_pins -quiet $name]
                if {[llength $pin] != 1} {error "Missing exact GT pin $name"}
                set nets [get_nets -segments -of_objects $pin]
                set drivers [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == OUT}]
                set driver_type unknown
                if {[llength $drivers] == 1} {
                    set driver_type [get_property REF_NAME [get_cells -of_objects $drivers]]
                }
                puts $drivers_file [join [list $name $drivers $driver_type [llength [get_clocks -quiet -of_objects $pin]]] "\t"]
            }
            lassign [ground [get_pins -quiet $clock_name]] clock_net clock_gnd
            foreach control {PHYESMADAPTSAVE RXDLYALIGNREQ RXMLDCHAINDONE RXMLDCHAINREQ RXPHALIGNREQ RXPHSETINITREQ RXPHSHIFT180} {
                set pin_name $cell_name/CH${channel}_$control
                lassign [ground [get_pins -quiet $pin_name]] data_net data_gnd
                puts $f [join [list $pin_name $primitive $data_net $data_gnd $clock_net $clock_gnd] "\t"]
            }
        }
    }
    close $f
    close $drivers_file
    write_xdc -force $directory/gt_checkpoint_constraints.xdc
    if {[file isfile [file join [pwd] pfm_uuid_manifest.dict]]} {
        file copy -force [file join [pwd] pfm_uuid_manifest.dict] $directory/pfm_uuid_manifest.dict
    }
    set f [open $directory/gt_evidence_metadata.json w]
    puts $f "\{\"tool_version\": \"[version -short]\"\}"
    close $f
    if {[info exists ::env(HPU_CIPS_XCI)]} {
        set xci $::env(HPU_CIPS_XCI)
    } else {
        set xci [get_files -quiet -all *hpu_plug_cips_0.xci]
    }
    if {[llength $xci] != 1 || ![file isfile $xci]} { error "Missing matching CIPS configuration" }
    file copy -force $xci $directory/cips.xci
    file copy -force [file join $script_dir inactive_gt_policy.json] $directory/inactive_gt_policy.json
}
