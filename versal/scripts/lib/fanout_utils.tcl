# ==============================================================================================
# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.
# ----------------------------------------------------------------------------------------------
# Helpers for taming high-fanout nets during implementation.
# ==============================================================================================

# Apply FORCE_MAX_FANOUT to the nets driving a given pin of a cell collection.
# Nets are located by connectivity (cells -> pins -> nets) rather than by name, because
# synthesis-generated net names are not stable across runs.
#
# Arguments:
#   label      - human-readable tag used in the log messages
#   cells      - cell collection whose input pins receive the high-fanout net
#   pin_filter - braced filter selecting the loaded pins, e.g. {REF_PIN_NAME == "CE"}
#   limit      - FORCE_MAX_FANOUT value (site-pin loads per replica)
#
# Every query reports its count; a 0 anywhere means the property was NOT applied.
proc force_fanout_cells {label cells pin_filter limit} {
    if {[llength $cells] == 0} {
        puts "\[CRITICAL WARNING\] FORCE_MAX_FANOUT '$label': 0 CELLS matched. NOT applied."
        return
    }
    set pins [get_pins -quiet -of_objects $cells -filter $pin_filter]
    if {[llength $pins] == 0} {
        puts "\[CRITICAL WARNING\] FORCE_MAX_FANOUT '$label': [llength $cells] cells but 0 pins for filter {$pin_filter}. NOT applied."
        return
    }
    set nets [lsort -unique [get_nets -quiet -of_objects $pins]]
    if {[llength $nets] == 0} {
        puts "\[CRITICAL WARNING\] FORCE_MAX_FANOUT '$label': pins found but no nets. NOT applied."
        return
    }
    set_property FORCE_MAX_FANOUT $limit $nets
    puts "\[INFO\] FORCE_MAX_FANOUT '$label' = $limit applied to [llength $nets] net(s), from [llength $cells] cell(s) / [llength $pins] pin(s)"
}
