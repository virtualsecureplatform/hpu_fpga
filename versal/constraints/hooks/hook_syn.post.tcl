# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.

if {[get_property TOP [current_fileset]] eq "top_hpu"} {
    foreach pattern {*mhdma_bridge/*hpu_ids_cdc* *line_sel_cdc_reg* *timeout_duration_cdc_reg* *bpip_config_cdc_reg*} {
        set sync_cells [get_cells -hier -quiet -filter "NAME =~ $pattern"]
        if {[llength $sync_cells] == 0} { error "Synchronizer missing after synthesis: $pattern" }
        if {[llength [filter $sync_cells {REF_NAME =~ SRL*}]] != 0} {
            error "Synchronizer incorrectly mapped into SRLs: $pattern"
        }
        set async_cells [filter $sync_cells {ASYNC_REG == TRUE}]
        if {[llength $async_cells] == 0} { error "Synchronizer lost ASYNC_REG: $pattern" }
        puts "CDC verified: $pattern, [llength $async_cells] ASYNC_REG cells, no SRLs"
    }
}
