# Only the asynchronous clear inputs of the tested four-stage reset
# synchronizer are exempt from inter-clock recovery/removal timing.
# The stage-to-stage D paths and all synchronized reset consumers stay timed.
namespace eval hpu_reset {}
proc hpu_reset::constrain {} {
    set base hpu_plug_wrapper/hpu_plug_i/shell_wrapper/clock_reset/pcie_mgmt_pdi_reset/reset_sync/inst
    set clears {}
    foreach i {0 1 2 3} {
        set name [format {%s/release_pipe_reg[%d]} $base $i]
        set cells [get_cells -hier -filter [format {NAME == "%s"} $name]]
        if {[llength $cells] != 1} { error "Missing exact reset synchronizer stage: $name" }
        set async [get_property ASYNC_REG $cells]
        if {![string is boolean -strict $async] || !$async} {error "Reset stage is not ASYNC_REG: $name"}
        set pin [get_pins -of_objects $cells -filter {REF_PIN_NAME == CLR && DIRECTION == IN}]
        if {[llength $pin] != 1} {error "Missing asynchronous clear on reset stage: $name"}
        lappend clears {*}$pin
    }
    set_false_path -to $clears
    puts "HPU reset exception: asynchronous CLR pins only: $clears"
}
