# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.

source $::env(PROJECT_DIR)/versal/scripts/clock_signoff.tcl
hpu_clock::validate clock_validation

report_timing_summary -rpx route_pre_timing_summary.rpx -max_paths 1000 -file route_pre_timing_summary.rpt

# Preserve the input constraints and Vivado's clock uncertainty model.
phys_opt_design -directive AggressiveExplore
write_checkpoint -force pre_route_physopt_1.dcp
phys_opt_design -directive AggressiveExplore
write_checkpoint -force pre_route_physopt_2.dcp

report_timing_summary -rpx route_pre_timing_summary.rpx -max_paths 1000 -file physopt2_timing_summary.rpt
