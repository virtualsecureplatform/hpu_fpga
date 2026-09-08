# ==============================================================================================
# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.
# ----------------------------------------------------------------------------------------------
# Contains procedure to generate block designs that handle MRMAC wrapper.
# Part of it is derived from the example design and adapted to our needs.
#
# We needed an MRMAC MAC + PCS driving GTM for QSFPs + GT wizard.
#
# ==============================================================================================

###############################################################################
# The majority of this code has been generated using example design.
# some parts have been modified to fit our needs and naming convention.
###############################################################################

# Versal Transceivers Wizard.
namespace eval _nsp_hpu {
  variable GTWIZ_CONFIG [list \
    CONFIG.GT_TYPE {GTM} \
    CONFIG.NO_OF_QUADS {1} \
    CONFIG.NO_OF_INTERFACE {4} \
    CONFIG.QUAD0_NO_PROT {4} \
    CONFIG.ENABLE_REG_INTERFACE {true} \
    CONFIG.REG_CONF_INTF {AXI_LITE} \
    CONFIG.INTF0_PRESET {GTM-NRZ_Ethernet_25G_40W} \
    CONFIG.INTF1_PRESET {GTM-NRZ_Ethernet_25G_40W} \
    CONFIG.INTF2_PRESET {GTM-NRZ_Ethernet_25G_40W} \
    CONFIG.INTF3_PRESET {GTM-NRZ_Ethernet_25G_40W} \
    CONFIG.INTF0_NO_OF_LANES {1} \
    CONFIG.INTF1_NO_OF_LANES {1} \
    CONFIG.INTF2_NO_OF_LANES {1} \
    CONFIG.INTF3_NO_OF_LANES {1} \
    CONFIG.INTF0_GT_SETTINGS {LR0_SETTINGS {RX_REFCLK_FREQUENCY 322.265625 TX_REFCLK_FREQUENCY 322.265625}} \
    CONFIG.INTF1_GT_SETTINGS {LR0_SETTINGS {RX_REFCLK_FREQUENCY 322.265625 TX_REFCLK_FREQUENCY 322.265625}} \
    CONFIG.INTF2_GT_SETTINGS {LR0_SETTINGS {RX_REFCLK_FREQUENCY 322.265625 TX_REFCLK_FREQUENCY 322.265625}} \
    CONFIG.INTF3_GT_SETTINGS {LR0_SETTINGS {RX_REFCLK_FREQUENCY 322.265625 TX_REFCLK_FREQUENCY 322.265625}} \
    CONFIG.QUAD0_PROT0_LANES {1} \
    CONFIG.QUAD0_PROT0_TX0_EN {true} \
    CONFIG.QUAD0_PROT0_TX1_EN {false} \
    CONFIG.QUAD0_PROT0_TX2_EN {false} \
    CONFIG.QUAD0_PROT0_TX3_EN {false} \
    CONFIG.QUAD0_PROT1_TX1_EN {true} \
    CONFIG.QUAD0_PROT2_TX2_EN {true} \
    CONFIG.QUAD0_PROT3_TX3_EN {true} \
    CONFIG.QUAD0_PROT0_RX0_EN {true} \
    CONFIG.QUAD0_PROT0_RX1_EN {false} \
    CONFIG.QUAD0_PROT0_RX2_EN {false} \
    CONFIG.QUAD0_PROT0_RX3_EN {false} \
    CONFIG.QUAD0_PROT1_RX1_EN {true} \
    CONFIG.QUAD0_PROT2_RX2_EN {true} \
    CONFIG.QUAD0_PROT3_RX3_EN {true} \
    CONFIG.QUAD0_PROT0_TXMSTCLK {TX0} \
    CONFIG.QUAD0_PROT1_TXMSTCLK {TX1} \
    CONFIG.QUAD0_PROT2_TXMSTCLK {TX2} \
    CONFIG.QUAD0_PROT3_TXMSTCLK {TX3} \
    CONFIG.QUAD0_PROT0_RXMSTCLK {RX0} \
    CONFIG.QUAD0_PROT1_RXMSTCLK {RX1} \
    CONFIG.QUAD0_PROT2_RXMSTCLK {RX2} \
    CONFIG.QUAD0_PROT3_RXMSTCLK {RX3} \
    CONFIG.QUAD0_CH0_LOOPBACK_EN {true} \
    CONFIG.QUAD0_CH1_LOOPBACK_EN {true} \
    CONFIG.QUAD0_CH2_LOOPBACK_EN {true} \
    CONFIG.QUAD0_CH3_LOOPBACK_EN {true} \
  ]
}

# gt_pin: get a wizard pin. If the pin does not exist, list the pins of the cell and stop.
proc gt_pin {cell name} {
  set p [get_bd_pins -quiet ${cell}/${name}]
  if {$p eq ""} {
    puts "ERROR> pin ${cell}/${name} not found. Pins of ${cell}:"
    foreach q [lsort [get_bd_pins -of_objects [get_bd_cells $cell]]] {
      puts "   pin  [get_property NAME $q]  dir=[get_property DIR $q]  intf=[get_property -quiet INTF $q]"
    }
    foreach q [lsort [get_bd_intf_pins -of_objects [get_bd_cells $cell]]] {
      puts "   intf [get_property NAME $q]  mode=[get_property MODE $q]  vlnv=[get_property VLNV $q]"
    }
    error "gt_pin: ${cell}/${name} not found (see pin list above)"
  }
  return $p
}

# Hierarchical cell: mrmac_0_gt_wrapper
proc create_hier_cell_mrmac_0_gt_wrapper { parentCell nameHier } {
  set parentObj [check_parent_hier $parentCell $nameHier]
  if { $parentObj == "" } { return }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj
  set parent_is_root [expr [string match "/" $parentObj] ? 1 : 0]

  # Create cell and set as current instance
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  ####################################
  # Create pins
  ####################################
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 CLK_IN_D

  # raw data of each lane, MRMAC side is 160 bits
  for {set i 0} {$i < 4} {incr i} {
    create_bd_pin -dir I -from 159 -to 0 txdata_in_${i}
    create_bd_pin -dir O -from 159 -to 0 rxdata_out_${i}
  }
  create_bd_pin -dir I -from 3 -to 0 gt_reset_all_in
  create_bd_pin -dir I -from 3 -to 0 gt_reset_tx_datapath_in
  create_bd_pin -dir I -from 3 -to 0 gt_reset_rx_datapath_in
  create_bd_pin -dir O -from 3 -to 0 gt_tx_reset_done_out
  create_bd_pin -dir O -from 3 -to 0 gt_rx_reset_done_out

  create_bd_pin -dir I -from 7 -to 0 ch0_txrate
  create_bd_pin -dir I -type gt_usrclk ch0_txusrclk
  create_bd_pin -dir I -from 7 -to 0 ch1_txrate
  create_bd_pin -dir I -type gt_usrclk ch1_txusrclk
  create_bd_pin -dir I -from 7 -to 0 ch2_txrate
  create_bd_pin -dir I -type gt_usrclk ch2_txusrclk
  create_bd_pin -dir I -from 7 -to 0 ch3_txrate
  create_bd_pin -dir I -type gt_usrclk ch3_txusrclk
  create_bd_pin -dir I -from 7 -to 0 ch0_rxrate
  create_bd_pin -dir I -type gt_usrclk ch0_rxusrclk
  create_bd_pin -dir I -from 7 -to 0 ch1_rxrate
  create_bd_pin -dir I -type gt_usrclk ch1_rxusrclk
  create_bd_pin -dir I -from 7 -to 0 ch2_rxrate
  create_bd_pin -dir I -type gt_usrclk ch2_rxusrclk
  create_bd_pin -dir I -from 7 -to 0 ch3_rxrate
  create_bd_pin -dir I -type gt_usrclk ch3_rxusrclk
  create_bd_pin -dir I -from 2 -to 0 ch0_loopback
  create_bd_pin -dir I -from 2 -to 0 ch1_loopback
  create_bd_pin -dir I -from 2 -to 0 ch2_loopback
  create_bd_pin -dir I -from 2 -to 0 ch3_loopback
  create_bd_pin -dir I -type clk apb3clk_quad
  create_bd_pin -dir I -type rst apb3presetn
  create_bd_pin -dir I -from 3 -to 0 gt_rxp_in_0
  create_bd_pin -dir I -from 3 -to 0 gt_rxn_in_0
  create_bd_pin -dir O -from 3 -to 0 gt_txp_out_0
  create_bd_pin -dir O -from 3 -to 0 gt_txn_out_0
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk ch0_tx_usr_clk
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk ch0_tx_usr_clk2
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk ch2_tx_usr_clk
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk ch2_tx_usr_clk2
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk ch0_rx_usr_clk
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk ch0_rx_usr_clk2
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk ch1_rx_usr_clk
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk ch1_rx_usr_clk2
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk ch2_rx_usr_clk
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk ch2_rx_usr_clk2
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk ch3_rx_usr_clk
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk ch3_rx_usr_clk2

  ####################################
  # Create instances
  ####################################

  # Create instance: gt_wizard, and set properties
  set gt_wizard [ create_bd_cell -type ip -vlnv xilinx.com:ip:gtwiz_versal:1.0 gt_wizard ]
  set_property -dict $_nsp_hpu::GTWIZ_CONFIG $gt_wizard

  # Create instance: mbufg_gt_0, and set properties
  # TX clock of channel 0, for lanes 0 and 1
  set mbufg_gt_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 mbufg_gt_0 ]
  set_property -dict [list \
    CONFIG.C_BUFG_GT_SYNC {true} \
    CONFIG.C_BUF_TYPE {MBUFG_GT} \
  ] $mbufg_gt_0

  # Create instance: mbufg_gt_2, and set properties
  # TX clock of channel 2, for lanes 2 and 3
  set mbufg_gt_2 [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 mbufg_gt_2 ]
  set_property -dict [list \
    CONFIG.C_BUFG_GT_SYNC {true} \
    CONFIG.C_BUF_TYPE {MBUFG_GT} \
  ] $mbufg_gt_2

  # Create instance: mbufg_gt_1, and set properties
  set mbufg_gt_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 mbufg_gt_1 ]
  set_property -dict [list \
    CONFIG.C_BUFG_GT_SYNC {true} \
    CONFIG.C_BUF_TYPE {MBUFG_GT} \
  ] $mbufg_gt_1

  # Create instance: mbufg_gt_1_1, and set properties
  set mbufg_gt_1_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 mbufg_gt_1_1 ]
  set_property -dict [list \
    CONFIG.C_BUFG_GT_SYNC {true} \
    CONFIG.C_BUF_TYPE {MBUFG_GT} \
  ] $mbufg_gt_1_1

  # Create instance: mbufg_gt_1_2, and set properties
  set mbufg_gt_1_2 [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 mbufg_gt_1_2 ]
  set_property -dict [list \
    CONFIG.C_BUFG_GT_SYNC {true} \
    CONFIG.C_BUF_TYPE {MBUFG_GT} \
  ] $mbufg_gt_1_2

  # Create instance: mbufg_gt_1_3, and set properties
  set mbufg_gt_1_3 [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 mbufg_gt_1_3 ]
  set_property -dict [list \
    CONFIG.C_BUFG_GT_SYNC {true} \
    CONFIG.C_BUF_TYPE {MBUFG_GT} \
  ] $mbufg_gt_1_3

  # Create instance: util_ds_buf_0, and set properties
  set util_ds_buf_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_0 ]
  set_property CONFIG.C_BUF_TYPE {IBUFDS_GTME5} $util_ds_buf_0

  # Create instance: xlconst_mbufg_0, and set properties
  set xlconst_mbufg_0 [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 xlconst_mbufg_0 ]
  set_property -dict [list \
    CONFIG.CONST_VAL {1} \
    CONFIG.CONST_WIDTH {1} \
  ] $xlconst_mbufg_0

  # Create instance: xlconst_zero, for the wizard reset inputs that stay inactive
  set xlconst_zero [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 xlconst_zero ]
  set_property -dict [list \
    CONFIG.CONST_VAL {0} \
    CONFIG.CONST_WIDTH {1} \
  ] $xlconst_zero

  # resets: one bit of gt_reset_*_in[3:0] per wizard interface
  foreach r {all tx_datapath rx_datapath} {
    for {set i 0} {$i < 4} {incr i} {
      set s [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 slice_rst_${r}_${i} ]
      set_property -dict [list \
        CONFIG.DIN_WIDTH {4} \
        CONFIG.DIN_FROM $i \
        CONFIG.DIN_TO $i \
        CONFIG.DOUT_WIDTH {1} \
      ] $s
    }
  }

  # reset done: one 4-bit vector per direction
  set concat_4_tx_reset_done [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_4_tx_reset_done]
  set concat_4_rx_reset_done [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_4_rx_reset_done]
  set_property CONFIG.NUM_PORTS {4} [get_bd_cells -filter {NAME=~"*concat_4*"}]

  # data: the wizard data ports are 256 bits wide, the MRMAC uses 160 bits per lane.
  # TX: bits [159:0], zeros above. RX: bits [159:0].
  set xlconst_zero_96 [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 xlconst_zero_96 ]
  set_property -dict [list \
    CONFIG.CONST_VAL {0} \
    CONFIG.CONST_WIDTH {96} \
  ] $xlconst_zero_96
  for {set i 0} {$i < 4} {incr i} {
    set c [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_txdata_${i} ]
    set_property CONFIG.NUM_PORTS {2} $c
    set s [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 slice_rxdata_${i} ]
    set_property -dict [list \
      CONFIG.DIN_WIDTH {256} \
      CONFIG.DIN_FROM {159} \
      CONFIG.DIN_TO {0} \
      CONFIG.DOUT_WIDTH {160} \
    ] $s
  }

  # Create pin connections
  connect_bd_net -net apb3clk_quad_1  [get_bd_pins apb3clk_quad] [gt_pin gt_wizard gtwiz_freerun_clk]
  connect_bd_net -net ch0_loopback_1  [get_bd_pins ch0_loopback] [gt_pin gt_wizard QUAD0_ch0_loopback]
  connect_bd_net -net ch0_rxrate_1  [get_bd_pins ch0_rxrate] [gt_pin gt_wizard INTF0_RX0_ch_rxrate]
  connect_bd_net -net ch0_rxusrclk_1  [get_bd_pins ch0_rxusrclk] [gt_pin gt_wizard QUAD0_RX0_usrclk]
  connect_bd_net -net ch0_txrate_1  [get_bd_pins ch0_txrate] [gt_pin gt_wizard INTF0_TX0_ch_txrate]
  connect_bd_net -net ch0_txusrclk_1  [get_bd_pins ch0_txusrclk] [gt_pin gt_wizard QUAD0_TX0_usrclk]
  connect_bd_net -net ch1_loopback_1  [get_bd_pins ch1_loopback] [gt_pin gt_wizard QUAD0_ch1_loopback]
  connect_bd_net -net ch1_rxrate_1  [get_bd_pins ch1_rxrate] [gt_pin gt_wizard INTF1_RX0_ch_rxrate]
  connect_bd_net -net ch1_rxusrclk_1  [get_bd_pins ch1_rxusrclk] [gt_pin gt_wizard QUAD0_RX1_usrclk]
  connect_bd_net -net ch1_txrate_1  [get_bd_pins ch1_txrate] [gt_pin gt_wizard INTF1_TX0_ch_txrate]
  connect_bd_net -net ch1_txusrclk_1  [get_bd_pins ch1_txusrclk] [gt_pin gt_wizard QUAD0_TX1_usrclk]
  connect_bd_net -net ch2_loopback_1  [get_bd_pins ch2_loopback] [gt_pin gt_wizard QUAD0_ch2_loopback]
  connect_bd_net -net ch2_rxrate_1  [get_bd_pins ch2_rxrate] [gt_pin gt_wizard INTF2_RX0_ch_rxrate]
  connect_bd_net -net ch2_rxusrclk_1  [get_bd_pins ch2_rxusrclk] [gt_pin gt_wizard QUAD0_RX2_usrclk]
  connect_bd_net -net ch2_txrate_1  [get_bd_pins ch2_txrate] [gt_pin gt_wizard INTF2_TX0_ch_txrate]
  connect_bd_net -net ch2_txusrclk_1  [get_bd_pins ch2_txusrclk] [gt_pin gt_wizard QUAD0_TX2_usrclk]
  connect_bd_net -net ch3_loopback_1  [get_bd_pins ch3_loopback] [gt_pin gt_wizard QUAD0_ch3_loopback]
  connect_bd_net -net ch3_rxrate_1  [get_bd_pins ch3_rxrate] [gt_pin gt_wizard INTF3_RX0_ch_rxrate]
  connect_bd_net -net ch3_rxusrclk_1  [get_bd_pins ch3_rxusrclk] [gt_pin gt_wizard QUAD0_RX3_usrclk]
  connect_bd_net -net ch3_txrate_1  [get_bd_pins ch3_txrate] [gt_pin gt_wizard INTF3_TX0_ch_txrate]
  connect_bd_net -net ch3_txusrclk_1  [get_bd_pins ch3_txusrclk] [gt_pin gt_wizard QUAD0_TX3_usrclk]
  connect_bd_net -net gt_wizard_rx0_outclk  [gt_pin gt_wizard QUAD0_RX0_outclk] [get_bd_pins mbufg_gt_1/MBUFG_GT_I]
  connect_bd_net -net gt_wizard_tx0_outclk  [gt_pin gt_wizard QUAD0_TX0_outclk] [get_bd_pins mbufg_gt_0/MBUFG_GT_I]
  connect_bd_net -net gt_wizard_tx2_outclk  [gt_pin gt_wizard QUAD0_TX2_outclk] [get_bd_pins mbufg_gt_2/MBUFG_GT_I]
  connect_bd_net -net gt_wizard_rx1_outclk  [gt_pin gt_wizard QUAD0_RX1_outclk] [get_bd_pins mbufg_gt_1_1/MBUFG_GT_I]
  connect_bd_net -net gt_wizard_rx2_outclk  [gt_pin gt_wizard QUAD0_RX2_outclk] [get_bd_pins mbufg_gt_1_2/MBUFG_GT_I]
  connect_bd_net -net gt_wizard_rx3_outclk  [gt_pin gt_wizard QUAD0_RX3_outclk] [get_bd_pins mbufg_gt_1_3/MBUFG_GT_I]
  connect_bd_net -net gt_wizard_txn  [gt_pin gt_wizard QUAD0_txn] [get_bd_pins gt_txn_out_0]
  connect_bd_net -net gt_wizard_txp  [gt_pin gt_wizard QUAD0_txp] [get_bd_pins gt_txp_out_0]
  connect_bd_net -net gt_rxn_in_0_1  [get_bd_pins gt_rxn_in_0] [gt_pin gt_wizard QUAD0_rxn]
  connect_bd_net -net gt_rxp_in_0_1  [get_bd_pins gt_rxp_in_0] [gt_pin gt_wizard QUAD0_rxp]
  connect_bd_net -net mbufg_gt_0_MBUFG_GT_O1  [get_bd_pins mbufg_gt_0/MBUFG_GT_O1] [get_bd_pins ch0_tx_usr_clk]
  connect_bd_net -net mbufg_gt_0_MBUFG_GT_O2  [get_bd_pins mbufg_gt_0/MBUFG_GT_O2] [get_bd_pins ch0_tx_usr_clk2]
  connect_bd_net -net mbufg_gt_2_MBUFG_GT_O1  [get_bd_pins mbufg_gt_2/MBUFG_GT_O1] [get_bd_pins ch2_tx_usr_clk]
  connect_bd_net -net mbufg_gt_2_MBUFG_GT_O2  [get_bd_pins mbufg_gt_2/MBUFG_GT_O2] [get_bd_pins ch2_tx_usr_clk2]
  connect_bd_net -net mbufg_gt_1_1_MBUFG_GT_O1  [get_bd_pins mbufg_gt_1_1/MBUFG_GT_O1] [get_bd_pins ch1_rx_usr_clk]
  connect_bd_net -net mbufg_gt_1_1_MBUFG_GT_O2  [get_bd_pins mbufg_gt_1_1/MBUFG_GT_O2] [get_bd_pins ch1_rx_usr_clk2]
  connect_bd_net -net mbufg_gt_1_2_MBUFG_GT_O1  [get_bd_pins mbufg_gt_1_2/MBUFG_GT_O1] [get_bd_pins ch2_rx_usr_clk]
  connect_bd_net -net mbufg_gt_1_2_MBUFG_GT_O2  [get_bd_pins mbufg_gt_1_2/MBUFG_GT_O2] [get_bd_pins ch2_rx_usr_clk2]
  connect_bd_net -net mbufg_gt_1_3_MBUFG_GT_O1  [get_bd_pins mbufg_gt_1_3/MBUFG_GT_O1] [get_bd_pins ch3_rx_usr_clk]
  connect_bd_net -net mbufg_gt_1_3_MBUFG_GT_O2  [get_bd_pins mbufg_gt_1_3/MBUFG_GT_O2] [get_bd_pins ch3_rx_usr_clk2]
  connect_bd_net -net mbufg_gt_1_MBUFG_GT_O1  [get_bd_pins mbufg_gt_1/MBUFG_GT_O1] [get_bd_pins ch0_rx_usr_clk]
  connect_bd_net -net mbufg_gt_1_MBUFG_GT_O2  [get_bd_pins mbufg_gt_1/MBUFG_GT_O2] [get_bd_pins ch0_rx_usr_clk2]
  connect_bd_net -net gt_wizard_rx_clr_out_0  [gt_pin gt_wizard INTF0_RX_clr_out] [get_bd_pins mbufg_gt_1/MBUFG_GT_CLR]
  connect_bd_net -net gt_wizard_rx_clr_out_1  [gt_pin gt_wizard INTF1_RX_clr_out] [get_bd_pins mbufg_gt_1_1/MBUFG_GT_CLR]
  connect_bd_net -net gt_wizard_rx_clr_out_2  [gt_pin gt_wizard INTF2_RX_clr_out] [get_bd_pins mbufg_gt_1_2/MBUFG_GT_CLR]
  connect_bd_net -net gt_wizard_rx_clr_out_3  [gt_pin gt_wizard INTF3_RX_clr_out] [get_bd_pins mbufg_gt_1_3/MBUFG_GT_CLR]
  connect_bd_net -net gt_wizard_rx_clrb_leaf_out_0  [gt_pin gt_wizard INTF0_RX_clrb_leaf_out] [get_bd_pins mbufg_gt_1/MBUFG_GT_CLRB_LEAF]
  connect_bd_net -net gt_wizard_rx_clrb_leaf_out_1  [gt_pin gt_wizard INTF1_RX_clrb_leaf_out] [get_bd_pins mbufg_gt_1_1/MBUFG_GT_CLRB_LEAF]
  connect_bd_net -net gt_wizard_rx_clrb_leaf_out_2  [gt_pin gt_wizard INTF2_RX_clrb_leaf_out] [get_bd_pins mbufg_gt_1_2/MBUFG_GT_CLRB_LEAF]
  connect_bd_net -net gt_wizard_rx_clrb_leaf_out_3  [gt_pin gt_wizard INTF3_RX_clrb_leaf_out] [get_bd_pins mbufg_gt_1_3/MBUFG_GT_CLRB_LEAF]
  connect_bd_net -net gt_wizard_tx_clr_out_0  [gt_pin gt_wizard INTF0_TX_clr_out] [get_bd_pins mbufg_gt_0/MBUFG_GT_CLR]
  connect_bd_net -net gt_wizard_tx_clrb_leaf_out_0  [gt_pin gt_wizard INTF0_TX_clrb_leaf_out] [get_bd_pins mbufg_gt_0/MBUFG_GT_CLRB_LEAF]
  connect_bd_net -net gt_wizard_tx_clr_out_2  [gt_pin gt_wizard INTF2_TX_clr_out] [get_bd_pins mbufg_gt_2/MBUFG_GT_CLR]
  connect_bd_net -net gt_wizard_tx_clrb_leaf_out_2  [gt_pin gt_wizard INTF2_TX_clrb_leaf_out] [get_bd_pins mbufg_gt_2/MBUFG_GT_CLRB_LEAF]
  connect_bd_net -net apb3presetn_1  [get_bd_pins apb3presetn] [gt_pin gt_wizard QUAD0_s_axi_lite_resetn]

  # reference clock to both quad inputs, as in the example design
  connect_bd_net -net util_ds_buf_0_IBUFDS_GTME5_O  [get_bd_pins util_ds_buf_0/IBUFDS_GTME5_O] \
  [gt_pin gt_wizard QUAD0_GTREFCLK0] \
  [gt_pin gt_wizard QUAD0_GTREFCLK1]

  # resets, reset done and data of each lane
  for {set i 0} {$i < 4} {incr i} {
    connect_bd_net [get_bd_pins gt_reset_all_in]                 [get_bd_pins slice_rst_all_${i}/Din]
    connect_bd_net [get_bd_pins slice_rst_all_${i}/Dout]         [gt_pin gt_wizard INTF${i}_rst_all_in]
    connect_bd_net [get_bd_pins gt_reset_tx_datapath_in]         [get_bd_pins slice_rst_tx_datapath_${i}/Din]
    connect_bd_net [get_bd_pins slice_rst_tx_datapath_${i}/Dout] [gt_pin gt_wizard INTF${i}_rst_tx_datapath_in]
    connect_bd_net [get_bd_pins gt_reset_rx_datapath_in]         [get_bd_pins slice_rst_rx_datapath_${i}/Din]
    connect_bd_net [get_bd_pins slice_rst_rx_datapath_${i}/Dout] [gt_pin gt_wizard INTF${i}_rst_rx_datapath_in]
    connect_bd_net [get_bd_pins xlconst_zero/dout] \
                   [gt_pin gt_wizard INTF${i}_rst_tx_pll_and_datapath_in] \
                   [gt_pin gt_wizard INTF${i}_rst_rx_pll_and_datapath_in]

    connect_bd_net [gt_pin gt_wizard INTF${i}_rst_tx_done_out] [get_bd_pins concat_4_tx_reset_done/In${i}]
    connect_bd_net [gt_pin gt_wizard INTF${i}_rst_rx_done_out] [get_bd_pins concat_4_rx_reset_done/In${i}]

    connect_bd_net [get_bd_pins txdata_in_${i}]              [get_bd_pins concat_txdata_${i}/In0]
    connect_bd_net [get_bd_pins xlconst_zero_96/dout]        [get_bd_pins concat_txdata_${i}/In1]
    connect_bd_net [get_bd_pins concat_txdata_${i}/Dout]     [gt_pin gt_wizard INTF${i}_TX0_ch_txdata]
    connect_bd_net [gt_pin gt_wizard INTF${i}_RX0_ch_rxdata] [get_bd_pins slice_rxdata_${i}/Din]
    connect_bd_net [get_bd_pins slice_rxdata_${i}/Dout]      [get_bd_pins rxdata_out_${i}]
  }
  connect_bd_net [get_bd_pins concat_4_tx_reset_done/Dout] [get_bd_pins gt_tx_reset_done_out]
  connect_bd_net [get_bd_pins concat_4_rx_reset_done/Dout] [get_bd_pins gt_rx_reset_done_out]

  connect_bd_net -net xlconst_mbufg_0_dout  [get_bd_pins xlconst_mbufg_0/dout] \
  [get_bd_pins mbufg_gt_0/MBUFG_GT_CE] \
  [get_bd_pins mbufg_gt_2/MBUFG_GT_CE] \
  [get_bd_pins mbufg_gt_1/MBUFG_GT_CE] \
  [get_bd_pins mbufg_gt_1_1/MBUFG_GT_CE] \
  [get_bd_pins mbufg_gt_1_2/MBUFG_GT_CE] \
  [get_bd_pins mbufg_gt_1_3/MBUFG_GT_CE]

  # Restore current instance
  current_bd_instance $oldCurInst
}

proc create_hier_cell_mrmac_wrapper  { parentCell nameHier } {

  set parentObj [check_parent_hier $parentCell $nameHier]
  if { $parentObj == "" } { return }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj

  # Create cell and set as current instance
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  ####################################
  # get global var
  ####################################
  set AXIL_DATA_W $_nsp_hpu::AXIL_DATA_W
  set AXIS_DATA_W   $_nsp_hpu::AXIS_DATA_W
  set AXIS_DATA_MHDMA_W $_nsp_hpu::AXIS_DATA_MHDMA_W
  set AXIS_DATA_MHDMA_BYTES $_nsp_hpu::AXIS_DATA_MHDMA_BYTES

  ####################################
  # Create pins
  ####################################
  # Create interface pins
  set CLK_IN_D [ create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 CLK_IN_D ]

  set s_axil_mrmac [ create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 s_axil_mrmac ]

  create_bd_intf_pin -mode Slave -vlnv xilinx.com:display_mrmac:mrmac_ctrl_ports:2.0 ctl_tx_port0
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:display_mrmac:mrmac_ctrl_ports:2.0 ctl_tx_port1
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:display_mrmac:mrmac_ctrl_ports:2.0 ctl_tx_port2
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:display_mrmac:mrmac_ctrl_ports:2.0 ctl_tx_port3
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:display_mrmac:mrmac_statistics_ports:2.0 tx_preamblein

  # Create pins
  set gt_freerun_clk [ create_bd_pin -dir I -type clk gt_freerun_clk ]
  set gt_freerun_resetn [ create_bd_pin -dir I -type rst gt_freerun_resetn ]

  set s_axi_aclk [ create_bd_pin -dir I -type clk s_axi_aclk ]
  set s_axi_aresetn [ create_bd_pin -dir I -type rst s_axi_aresetn ]

  set s_axis_mrmac_aclk [ create_bd_pin -dir I -type clk s_axis_mrmac_aclk ]

  set gt_tx_reset_done_out [ create_bd_pin -dir O -from 3 -to 0 gt_tx_reset_done_out ]
  set gt_rx_reset_done_out [ create_bd_pin -dir O -from 3 -to 0 gt_rx_reset_done_out ]
  set gt_reset_all_in [ create_bd_pin -dir I -from 3 -to 0 gt_reset_all_in ]

  # == TX axi-stream interface
  set tx_axis_tdata_0   [ create_bd_pin -dir I -from [expr $AXIS_DATA_MHDMA_W - 1] -to 0 tx_axis_tdata_0 ]
  set tx_axis_tready_0  [ create_bd_pin -dir O tx_axis_tready_0 ]
  set tx_axis_tlast_0   [ create_bd_pin -dir I tx_axis_tlast_0 ]
  set tx_axis_tvalid_0  [ create_bd_pin -dir I tx_axis_tvalid_0 ]

  set tx_axis_tdata_2   [ create_bd_pin -dir I -from [expr $AXIS_DATA_MHDMA_W - 1] -to 0 tx_axis_tdata_2 ]
  set tx_axis_tready_2  [ create_bd_pin -dir O tx_axis_tready_2 ]
  set tx_axis_tlast_2   [ create_bd_pin -dir I tx_axis_tlast_2 ]
  set tx_axis_tvalid_2  [ create_bd_pin -dir I tx_axis_tvalid_2 ]

  set tx_axis_tdata_4   [ create_bd_pin -dir I -from [expr $AXIS_DATA_MHDMA_W - 1] -to 0 tx_axis_tdata_4 ]
  set tx_axis_tready_4  [ create_bd_pin -dir O tx_axis_tready_4 ]
  set tx_axis_tlast_4   [ create_bd_pin -dir I tx_axis_tlast_4 ]
  set tx_axis_tvalid_4  [ create_bd_pin -dir I tx_axis_tvalid_4 ]

  set tx_axis_tdata_6   [ create_bd_pin -dir I -from [expr $AXIS_DATA_MHDMA_W - 1] -to 0 tx_axis_tdata_6 ]
  set tx_axis_tready_6  [ create_bd_pin -dir O tx_axis_tready_6 ]
  set tx_axis_tlast_6   [ create_bd_pin -dir I tx_axis_tlast_6 ]
  set tx_axis_tvalid_6  [ create_bd_pin -dir I tx_axis_tvalid_6 ]

  set tx_axis_tkeep_user_0 [ create_bd_pin -dir I -from 10 -to 0 tx_axis_tkeep_user_0 ]
  set tx_axis_tkeep_user_2 [ create_bd_pin -dir I -from 10 -to 0 tx_axis_tkeep_user_2 ]
  set tx_axis_tkeep_user_4 [ create_bd_pin -dir I -from 10 -to 0 tx_axis_tkeep_user_4 ]
  set tx_axis_tkeep_user_6 [ create_bd_pin -dir I -from 10 -to 0 tx_axis_tkeep_user_6 ]

  # == RX axi-stream interface
  set rx_axis_tdata_0      [ create_bd_pin -dir O -from [expr $AXIS_DATA_MHDMA_W - 1] -to 0 rx_axis_tdata_0 ]
  set rx_axis_tkeep_user_0 [ create_bd_pin -dir O -from 10 -to 0 rx_axis_tkeep_user_0 ]
  set rx_axis_tlast_0     [ create_bd_pin -dir O rx_axis_tlast_0 ]
  set rx_axis_tvalid_0    [ create_bd_pin -dir O rx_axis_tvalid_0 ]

  set rx_axis_tdata_2      [ create_bd_pin -dir O -from [expr $AXIS_DATA_MHDMA_W - 1] -to 0 rx_axis_tdata_2 ]
  set rx_axis_tkeep_user_2 [ create_bd_pin -dir O -from 10 -to 0 rx_axis_tkeep_user_2 ]
  set rx_axis_tlast_2     [ create_bd_pin -dir O rx_axis_tlast_2 ]
  set rx_axis_tvalid_2    [ create_bd_pin -dir O rx_axis_tvalid_2 ]

  set rx_axis_tdata_4      [ create_bd_pin -dir O -from [expr $AXIS_DATA_MHDMA_W - 1] -to 0 rx_axis_tdata_4 ]
  set rx_axis_tkeep_user_4 [ create_bd_pin -dir O -from 10 -to 0 rx_axis_tkeep_user_4 ]
  set rx_axis_tlast_4     [ create_bd_pin -dir O rx_axis_tlast_4 ]
  set rx_axis_tvalid_4    [ create_bd_pin -dir O rx_axis_tvalid_4 ]

  set rx_axis_tdata_6      [ create_bd_pin -dir O -from [expr $AXIS_DATA_MHDMA_W - 1] -to 0 rx_axis_tdata_6 ]
  set rx_axis_tkeep_user_6 [ create_bd_pin -dir O -from 10 -to 0 rx_axis_tkeep_user_6 ]
  set rx_axis_tlast_6     [ create_bd_pin -dir O rx_axis_tlast_6 ]
  set rx_axis_tvalid_6    [ create_bd_pin -dir O rx_axis_tvalid_6 ]

  set gt_reset_tx_datapath_in [ create_bd_pin -dir I -from 3 -to 0 gt_reset_tx_datapath_in ]
  set gt_reset_rx_datapath_in [ create_bd_pin -dir I -from 3 -to 0 gt_reset_rx_datapath_in ]
  set pm_rdy [ create_bd_pin -dir O -from 3 -to 0 pm_rdy ]


  set ch0_loopback [ create_bd_pin -dir I -from 2 -to 0 ch0_loopback ]
  set ch0_txrate [ create_bd_pin -dir I -from 7 -to 0 ch0_txrate ]
  set ch0_rxrate [ create_bd_pin -dir I -from 7 -to 0 ch0_rxrate ]
  set ch1_loopback [ create_bd_pin -dir I -from 2 -to 0 ch1_loopback ]
  set ch1_txrate [ create_bd_pin -dir I -from 7 -to 0 ch1_txrate ]
  set ch1_rxrate [ create_bd_pin -dir I -from 7 -to 0 ch1_rxrate ]
  set ch2_loopback [ create_bd_pin -dir I -from 2 -to 0 ch2_loopback ]
  set ch2_txrate [ create_bd_pin -dir I -from 7 -to 0 ch2_txrate ]
  set ch2_rxrate [ create_bd_pin -dir I -from 7 -to 0 ch2_rxrate ]
  set ch3_loopback [ create_bd_pin -dir I -from 2 -to 0 ch3_loopback ]
  set ch3_txrate [ create_bd_pin -dir I -from 7 -to 0 ch3_txrate ]
  set ch3_rxrate [ create_bd_pin -dir I -from 7 -to 0 ch3_rxrate ]
  set gt_rxn_in_0 [ create_bd_pin -dir I -from 3 -to 0 gt_rxn_in_0 ]
  set gt_rxp_in_0 [ create_bd_pin -dir I -from 3 -to 0 gt_rxp_in_0 ]
  set gt_txn_out_0 [ create_bd_pin -dir O -from 3 -to 0 gt_txn_out_0 ]
  set gt_txp_out_0 [ create_bd_pin -dir O -from 3 -to 0 gt_txp_out_0 ]

  # Create instance: mrmac_0_core, and set properties
  # Static 4 x 25GE Narrow
  # No FEC
  # Must use GTM
  # Placement near bank 111
  set mrmac_0_core [ create_bd_cell -type ip -vlnv xilinx.com:ip:mrmac:3.2 mrmac_0_core ]
  set_property -dict [list \
    CONFIG.FAST_SIM_MODE {0} \
    CONFIG.FEC_SLICE0_CFG_C0 {FEC Disabled (Bypass)} \
    CONFIG.FEC_SLICE1_CFG_C0 {FEC Disabled (Bypass)} \
    CONFIG.FEC_SLICE2_CFG_C0 {FEC Disabled (Bypass)} \
    CONFIG.FEC_SLICE3_CFG_C0 {FEC Disabled (Bypass)} \
    CONFIG.FLEX_PORT0_DATA_RATE_C0 {25GE} \
    CONFIG.FLEX_PORT1_DATA_RATE_C0 {N/A} \
    CONFIG.FLEX_PORT2_DATA_RATE_C0 {N/A} \
    CONFIG.FLEX_PORT3_DATA_RATE_C0 {N/A} \
    CONFIG.GT_PIPELINE_STAGES {0} \
    CONFIG.GT_TYPE_C0 {GTM} \
    CONFIG.MAC_PORT0_ENABLE_TIME_STAMPING_C0 {0} \
    CONFIG.MAC_PORT0_PREEMPTION_C0 {0} \
    CONFIG.MAC_PORT0_RX_FLOW_C0 {0} \
    CONFIG.MAC_PORT0_TX_FLOW_C0 {0} \
    CONFIG.MAC_PORT0_RATE_C0 {25GE} \
    CONFIG.MAC_PORT1_RATE_C0 {25GE} \
    CONFIG.MAC_PORT2_RATE_C0 {25GE} \
    CONFIG.MAC_PORT3_RATE_C0 {25GE} \
    CONFIG.MRMAC_CLIENTS_C0 {4} \
    CONFIG.MRMAC_CONFIGURATION_TYPE {Static Configuration} \
    CONFIG.MRMAC_LOCATION_C0 {MRMAC_X0Y3} \
    CONFIG.MRMAC_MODE_C0 {MAC+PCS} \
    CONFIG.MRMAC_PRESET_C0 {4x25GE Narrow} \
    CONFIG.MRMAC_SPEED_C0 {4x25GE} \
    CONFIG.NUM_GT_CHANNELS {4} \
    CONFIG.PORT0_1588v2_Clocking_C0 {Ordinary/Boundary Clock} \
    CONFIG.PORT1_1588v2_Clocking_C0 {Ordinary/Boundary Clock} \
    CONFIG.PORT2_1588v2_Clocking_C0 {Ordinary/Boundary Clock} \
    CONFIG.PORT3_1588v2_Clocking_C0 {Ordinary/Boundary Clock} \
    CONFIG.PORT0_1588v2_Operation_MODE_C0 {No operation} \
    CONFIG.PORT1_1588v2_Operation_MODE_C0 {No operation} \
    CONFIG.PORT2_1588v2_Operation_MODE_C0 {No operation} \
    CONFIG.PORT3_1588v2_Operation_MODE_C0 {No operation} \
    CONFIG.TIMESTAMP_CLK_PERIOD_NS {4.0000} \
  ] $mrmac_0_core

  # Create instance within hier object: mrmac_0_gt_wrapper
  create_hier_cell_mrmac_0_gt_wrapper $hier_obj mrmac_0_gt_wrapper

  # modules for transceiver <-> MRMAC connections
  # resets
  set concat_4_flexif_reset    [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_4_flexif_reset]

  set ilvector_not_flexif_reset [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 ilvector_not_flexif_reset]

  set_property -dict [list \
    CONFIG.C_OPERATION {not} \
    CONFIG.C_SIZE {1} \
  ] $ilvector_not_flexif_reset

  set ilvector_not_4_tx_reset_done [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 ilvector_not_4_tx_reset_done]
  set ilvector_not_4_rx_reset_done [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 ilvector_not_4_rx_reset_done]

  set_property -dict [list \
    CONFIG.C_OPERATION {not} \
    CONFIG.C_SIZE {4} \
  ]  [get_bd_cells -filter {NAME=~"*ilvector_not_4*"}]

  # reset done to the regfile
  set cdc_tx_reset_done [create_bd_cell -type ip -vlnv xilinx.com:ip:xpm_cdc_gen:1.0 cdc_tx_reset_done]
  set cdc_rx_reset_done [create_bd_cell -type ip -vlnv xilinx.com:ip:xpm_cdc_gen:1.0 cdc_rx_reset_done]

  set_property -dict [list \
    CONFIG.CDC_TYPE {xpm_cdc_array_single} \
    CONFIG.WIDTH {4} \
    CONFIG.DEST_SYNC_FF {4} \
    CONFIG.SRC_INPUT_REG {false} \
  ]  [get_bd_cells -filter {NAME=~"*cdc_*_reset_done"}]

  # clocks
  set concat_4_clk_axis_mrmac  [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_4_clk_axis_mrmac]
  set concat_4_clk_ts          [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_4_clk_ts]
  set concat_4_clk_mhdma_control [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_4_clk_mhdma_control]

  set concat_4_rx_usr_clock  [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_4_rx_usr_clock]
  set concat_4_rx_usr_clock2 [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_4_rx_usr_clock2]
  set concat_4_tx_usr_clock  [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_4_tx_usr_clock]
  set concat_4_tx_usr_clock2 [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_4_tx_usr_clock2]

  # signals
  set concat_4_pm_tick [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_4_pm_tick]
  set ilconst_tick [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 ilconst_tick]

  set_property CONFIG.NUM_PORTS {4} [get_bd_cells -filter {NAME=~"*concat_4*"}]
  ####################################
  # Connection
  ####################################
  # clocks and resets
  connect_bd_net -net config_aresetn [get_bd_pins s_axi_aresetn] [get_bd_pins mrmac_0_core/s_axi_aresetn]

  connect_bd_net -net config_aclk [get_bd_pins s_axi_aclk] [get_bd_pins mrmac_0_core/s_axi_aclk]

  # GT <-> MRMAC connections ----------------------------------------------------------------------
  # ~mhdma_cfg_srst_n to rx_flexif_reset
  connect_bd_net [get_bd_pins s_axi_aresetn] [get_bd_pins ilvector_not_flexif_reset/Op1]

  for {set i 0} {$i < 4} {incr i} {
    connect_bd_net [get_bd_pins ilvector_not_flexif_reset/Res] [get_bd_pins concat_4_flexif_reset/In${i}]
  }

  connect_bd_net [get_bd_pins concat_4_flexif_reset/Dout] [get_bd_pins mrmac_0_core/rx_flexif_reset]

  # ~ gt_rx_reset_done -> (rx_core_reset & rx_serdes_reset), and to the synchronizer
  connect_bd_net [get_bd_pins mrmac_0_gt_wrapper/gt_rx_reset_done_out] [get_bd_pins ilvector_not_4_rx_reset_done/Op1] [get_bd_pins cdc_rx_reset_done/src_in]
  connect_bd_net [get_bd_pins ilvector_not_4_rx_reset_done/Res]  [get_bd_pins mrmac_0_core/rx_core_reset]
  connect_bd_net [get_bd_pins ilvector_not_4_rx_reset_done/Res]  [get_bd_pins mrmac_0_core/rx_serdes_reset]

  # ~ gt_tx_reset_done -> (tx_core_reset & tx_serdes_reset), and to the synchronizer
  connect_bd_net [get_bd_pins mrmac_0_gt_wrapper/gt_tx_reset_done_out] [get_bd_pins ilvector_not_4_tx_reset_done/Op1] [get_bd_pins cdc_tx_reset_done/src_in]
  connect_bd_net [get_bd_pins ilvector_not_4_tx_reset_done/Res]  [get_bd_pins mrmac_0_core/tx_core_reset]
  connect_bd_net [get_bd_pins ilvector_not_4_tx_reset_done/Res]  [get_bd_pins mrmac_0_core/tx_serdes_reset]

  # pm_tick associated to 4'b1
  for {set i 0} {$i < 4} {incr i} {
    connect_bd_net [get_bd_pins ilconst_tick/dout] [get_bd_pins concat_4_pm_tick/In${i}]
  }
  connect_bd_net [get_bd_pins concat_4_pm_tick/Dout] [get_bd_pins mrmac_0_core/pm_tick]


  # s_axis_mrmac_aclk to (tx_axi_clk & rx_axi_clk)
  for {set i 0} {$i < 4} {incr i} {
    connect_bd_net [get_bd_pins s_axis_mrmac_aclk] [get_bd_pins concat_4_clk_axis_mrmac/In${i}]
  }

  connect_bd_net [get_bd_pins concat_4_clk_axis_mrmac/Dout] \
                  [get_bd_pins mrmac_0_core/tx_axi_clk] \
                  [get_bd_pins mrmac_0_core/rx_axi_clk]

  # ts_clk: PTP unused, use gt_freerun_clk (200 MHz) to satisfy MRMAC min period
  for {set i 0} {$i < 4} {incr i} {
    connect_bd_net [get_bd_pins gt_freerun_clk] [get_bd_pins concat_4_clk_ts/In${i}]
  }
  connect_bd_net [get_bd_pins concat_4_clk_ts/Dout] \
                  [get_bd_pins mrmac_0_core/tx_ts_clk] \
                  [get_bd_pins mrmac_0_core/rx_ts_clk]

  # s_axi_aclk to (rx_flexif_clk & tx_flexif_clk)
  for {set i 0} {$i < 4} {incr i} {
    connect_bd_net [get_bd_pins s_axi_aclk] [get_bd_pins concat_4_clk_mhdma_control/In${i}]
  }

  connect_bd_net [get_bd_pins concat_4_clk_mhdma_control/Dout] \
                  [get_bd_pins mrmac_0_core/rx_flexif_clk] \
                  [get_bd_pins mrmac_0_core/tx_flexif_clk]

  connect_bd_net [get_bd_pins concat_4_rx_usr_clock/In0] [get_bd_pins mrmac_0_gt_wrapper/ch0_rx_usr_clk]
  connect_bd_net [get_bd_pins concat_4_rx_usr_clock/In1] [get_bd_pins mrmac_0_gt_wrapper/ch1_rx_usr_clk]
  connect_bd_net [get_bd_pins concat_4_rx_usr_clock/In2] [get_bd_pins mrmac_0_gt_wrapper/ch2_rx_usr_clk]
  connect_bd_net [get_bd_pins concat_4_rx_usr_clock/In3] [get_bd_pins mrmac_0_gt_wrapper/ch3_rx_usr_clk]

  connect_bd_net [get_bd_pins concat_4_rx_usr_clock/Dout] [get_bd_pins mrmac_0_core/rx_core_clk]
  connect_bd_net [get_bd_pins concat_4_rx_usr_clock/Dout] [get_bd_pins mrmac_0_core/rx_serdes_clk]

  # rx_alt_serdes_clk = {ch3_rx_usr_clk2, ch2_rx_usr_clk2, ch1_rx_usr_clk2, ch0_rx_usr_clk2};
  connect_bd_net [get_bd_pins concat_4_rx_usr_clock2/In0] [get_bd_pins mrmac_0_gt_wrapper/ch0_rx_usr_clk2]
  connect_bd_net [get_bd_pins concat_4_rx_usr_clock2/In1] [get_bd_pins mrmac_0_gt_wrapper/ch1_rx_usr_clk2]
  connect_bd_net [get_bd_pins concat_4_rx_usr_clock2/In2] [get_bd_pins mrmac_0_gt_wrapper/ch2_rx_usr_clk2]
  connect_bd_net [get_bd_pins concat_4_rx_usr_clock2/In3] [get_bd_pins mrmac_0_gt_wrapper/ch3_rx_usr_clk2]

  connect_bd_net [get_bd_pins concat_4_rx_usr_clock2/Dout] [get_bd_pins mrmac_0_core/rx_alt_serdes_clk]

  # tx_core_clk: lanes 0 and 1 on channel 0, lanes 2 and 3 on channel 2
  foreach {i ch} {0 0 1 0 2 2 3 2} {
    connect_bd_net [get_bd_pins mrmac_0_gt_wrapper/ch${ch}_tx_usr_clk] [get_bd_pins concat_4_tx_usr_clock/In${i}]
    connect_bd_net [get_bd_pins mrmac_0_gt_wrapper/ch${ch}_tx_usr_clk2] [get_bd_pins concat_4_tx_usr_clock2/In${i}]
  }
  connect_bd_net [get_bd_pins concat_4_tx_usr_clock/Dout] [get_bd_pins mrmac_0_core/tx_core_clk]
  connect_bd_net [get_bd_pins concat_4_tx_usr_clock2/Dout] [get_bd_pins mrmac_0_core/tx_alt_serdes_clk]

  connect_bd_net [get_bd_pins mrmac_0_gt_wrapper/ch0_tx_usr_clk] \
                    [get_bd_pins mrmac_0_gt_wrapper/ch0_txusrclk] \
                    [get_bd_pins mrmac_0_gt_wrapper/ch1_txusrclk]
  connect_bd_net [get_bd_pins mrmac_0_gt_wrapper/ch2_tx_usr_clk] \
                    [get_bd_pins mrmac_0_gt_wrapper/ch2_txusrclk] \
                    [get_bd_pins mrmac_0_gt_wrapper/ch3_txusrclk]

  connect_bd_net [get_bd_pins mrmac_0_gt_wrapper/ch0_rx_usr_clk]  [get_bd_pins mrmac_0_gt_wrapper/ch0_rxusrclk]
  connect_bd_net [get_bd_pins mrmac_0_gt_wrapper/ch1_rx_usr_clk]  [get_bd_pins mrmac_0_gt_wrapper/ch1_rxusrclk]
  connect_bd_net [get_bd_pins mrmac_0_gt_wrapper/ch2_rx_usr_clk]  [get_bd_pins mrmac_0_gt_wrapper/ch2_rxusrclk]
  connect_bd_net [get_bd_pins mrmac_0_gt_wrapper/ch3_rx_usr_clk]  [get_bd_pins mrmac_0_gt_wrapper/ch3_rxusrclk]


  # GT wrapper ------------------------------------------------------------------------------------
  connect_bd_intf_net -intf_net CLK_IN_D_1             [get_bd_intf_pins mrmac_0_gt_wrapper/CLK_IN_D]   [get_bd_intf_pins CLK_IN_D]
  connect_bd_intf_net -boundary_type upper             [get_bd_intf_pins mrmac_0_gt_wrapper/CLK_IN_D]   [get_bd_intf_pins mrmac_0_gt_wrapper/util_ds_buf_0/CLK_IN_D1]

  connect_bd_net -net cfg_apb3presetn                  [get_bd_pins mrmac_0_gt_wrapper/apb3presetn]     [get_bd_pins gt_freerun_resetn]
  connect_bd_net                                       [get_bd_pins mrmac_0_gt_wrapper/apb3clk_quad]    [get_bd_pins gt_freerun_clk]
  connect_bd_net -net ch0_loopback_1                   [get_bd_pins mrmac_0_gt_wrapper/ch0_loopback]    [get_bd_pins ch0_loopback]
  connect_bd_net -net ch0_rxrate_1                     [get_bd_pins mrmac_0_gt_wrapper/ch0_rxrate]      [get_bd_pins ch0_rxrate]
  connect_bd_net -net ch0_txrate_1                     [get_bd_pins mrmac_0_gt_wrapper/ch0_txrate]      [get_bd_pins ch0_txrate]
  connect_bd_net -net ch1_loopback_1                   [get_bd_pins mrmac_0_gt_wrapper/ch1_loopback]    [get_bd_pins ch1_loopback]
  connect_bd_net -net ch1_rxrate_1                     [get_bd_pins mrmac_0_gt_wrapper/ch1_rxrate]      [get_bd_pins ch1_rxrate]
  connect_bd_net -net ch1_txrate_1                     [get_bd_pins mrmac_0_gt_wrapper/ch1_txrate]      [get_bd_pins ch1_txrate]
  connect_bd_net -net ch2_loopback_1                   [get_bd_pins mrmac_0_gt_wrapper/ch2_loopback]    [get_bd_pins ch2_loopback]
  connect_bd_net -net ch2_rxrate_1                     [get_bd_pins mrmac_0_gt_wrapper/ch2_rxrate]      [get_bd_pins ch2_rxrate]
  connect_bd_net -net ch2_txrate_1                     [get_bd_pins mrmac_0_gt_wrapper/ch2_txrate]      [get_bd_pins ch2_txrate]
  connect_bd_net -net ch3_loopback_1                   [get_bd_pins mrmac_0_gt_wrapper/ch3_loopback]    [get_bd_pins ch3_loopback]
  connect_bd_net -net ch3_rxrate_1                     [get_bd_pins mrmac_0_gt_wrapper/ch3_rxrate]      [get_bd_pins ch3_rxrate]
  connect_bd_net -net ch3_txrate_1                     [get_bd_pins mrmac_0_gt_wrapper/ch3_txrate]      [get_bd_pins ch3_txrate]
  connect_bd_net -net gt_rxn_in_0_1                    [get_bd_pins mrmac_0_gt_wrapper/gt_rxn_in_0]     [get_bd_pins gt_rxn_in_0]
  connect_bd_net -net gt_rxp_in_0_1                    [get_bd_pins mrmac_0_gt_wrapper/gt_rxp_in_0]     [get_bd_pins gt_rxp_in_0]
  connect_bd_net -net gt_wizard_txn                    [get_bd_pins mrmac_0_gt_wrapper/gt_txn_out_0]    [get_bd_pins gt_txn_out_0]
  connect_bd_net -net gt_wizard_txp                    [get_bd_pins mrmac_0_gt_wrapper/gt_txp_out_0]    [get_bd_pins gt_txp_out_0]

  # GT resets, from the regfile to the wizard, and reset done, synchronized to s_axi_aclk
  connect_bd_net -net gt_reset_all_in_1                     [get_bd_pins mrmac_0_gt_wrapper/gt_reset_all_in]         [get_bd_pins gt_reset_all_in]
  connect_bd_net -net gt_reset_rx_datapath_in_1             [get_bd_pins mrmac_0_gt_wrapper/gt_reset_rx_datapath_in] [get_bd_pins gt_reset_rx_datapath_in]
  connect_bd_net -net gt_reset_tx_datapath_in_1             [get_bd_pins mrmac_0_gt_wrapper/gt_reset_tx_datapath_in] [get_bd_pins gt_reset_tx_datapath_in]
  connect_bd_net -net cdc_rx_reset_done_dest_out            [get_bd_pins cdc_rx_reset_done/dest_out]                 [get_bd_pins gt_rx_reset_done_out]
  connect_bd_net -net cdc_tx_reset_done_dest_out            [get_bd_pins cdc_tx_reset_done/dest_out]                 [get_bd_pins gt_tx_reset_done_out]
  connect_bd_net [get_bd_pins gt_freerun_clk]               [get_bd_pins cdc_rx_reset_done/src_clk]                  [get_bd_pins cdc_tx_reset_done/src_clk]
  connect_bd_net [get_bd_pins s_axi_aclk]                   [get_bd_pins cdc_rx_reset_done/dest_clk]                 [get_bd_pins cdc_tx_reset_done/dest_clk]

  # MRMAC core
  connect_bd_net -net mrmac_0_core_pm_rdy                   [get_bd_pins mrmac_0_core/pm_rdy]                  [get_bd_pins pm_rdy]

  connect_bd_intf_net -intf_net ctl_tx_pin0_1               [get_bd_intf_pins mrmac_0_core/ctl_tx_port0]              [get_bd_intf_pins ctl_tx_port0]
  connect_bd_intf_net -intf_net ctl_tx_pin1_1               [get_bd_intf_pins mrmac_0_core/ctl_tx_port1]              [get_bd_intf_pins ctl_tx_port1]
  connect_bd_intf_net -intf_net ctl_tx_pin2_1               [get_bd_intf_pins mrmac_0_core/ctl_tx_port2]              [get_bd_intf_pins ctl_tx_port2]
  connect_bd_intf_net -intf_net ctl_tx_pin3_1               [get_bd_intf_pins mrmac_0_core/ctl_tx_port3]              [get_bd_intf_pins ctl_tx_port3]
  connect_bd_intf_net -intf_net s_axi_1                     [get_bd_intf_pins mrmac_0_core/s_axi]                     [get_bd_intf_pins s_axil_mrmac]
  connect_bd_intf_net -intf_net tx_preamblein_1             [get_bd_intf_pins mrmac_0_core/tx_preamblein]             [get_bd_intf_pins tx_preamblein]

  # raw data between the MRMAC and the transceiver
  for {set i 0} {$i < 4} {incr i} {
    connect_bd_net [get_bd_pins mrmac_0_core/txdata_in_${i}]        [get_bd_pins mrmac_0_gt_wrapper/txdata_in_${i}]
    connect_bd_net [get_bd_pins mrmac_0_gt_wrapper/rxdata_out_${i}] [get_bd_pins mrmac_0_core/rxdata_out_${i}]
  }

  # on the IP side, axi stream suffix is a mix and match of different things.
  # Trying to keep something homogeous on the top of this block: lanes 0, 2, 4, 6 (from mrmac configuration) + underscore before suffix
  # == RX Lanes
  # 0
  connect_bd_net -net mrmac_0_core_rx_axis_tdata_0      [get_bd_pins mrmac_0_core/rx_axis_tdata0]       [get_bd_pins rx_axis_tdata_0]
  connect_bd_net -net mrmac_0_core_rx_axis_tkeep_user_0 [get_bd_pins mrmac_0_core/rx_axis_tkeep_user0]  [get_bd_pins rx_axis_tkeep_user_0]
  connect_bd_net -net mrmac_0_core_rx_axis_tlast_0      [get_bd_pins mrmac_0_core/rx_axis_tlast_0]      [get_bd_pins rx_axis_tlast_0]
  connect_bd_net -net mrmac_0_core_rx_axis_tvalid_0     [get_bd_pins mrmac_0_core/rx_axis_tvalid_0]     [get_bd_pins rx_axis_tvalid_0]
  # 1
  connect_bd_net -net mrmac_0_core_rx_axis_tdata_2      [get_bd_pins mrmac_0_core/rx_axis_tdata2]       [get_bd_pins rx_axis_tdata_2]
  connect_bd_net -net mrmac_0_core_rx_axis_tkeep_user_2 [get_bd_pins mrmac_0_core/rx_axis_tkeep_user2]  [get_bd_pins rx_axis_tkeep_user_2]
  connect_bd_net -net mrmac_0_core_rx_axis_tlast_2      [get_bd_pins mrmac_0_core/rx_axis_tlast_1]      [get_bd_pins rx_axis_tlast_2]
  connect_bd_net -net mrmac_0_core_rx_axis_tvalid_2     [get_bd_pins mrmac_0_core/rx_axis_tvalid_1]     [get_bd_pins rx_axis_tvalid_2]
  # 2
  connect_bd_net -net mrmac_0_core_rx_axis_tdata_4      [get_bd_pins mrmac_0_core/rx_axis_tdata4]       [get_bd_pins rx_axis_tdata_4]
  connect_bd_net -net mrmac_0_core_rx_axis_tkeep_user_4 [get_bd_pins mrmac_0_core/rx_axis_tkeep_user4]  [get_bd_pins rx_axis_tkeep_user_4]
  connect_bd_net -net mrmac_0_core_rx_axis_tlast_4      [get_bd_pins mrmac_0_core/rx_axis_tlast_2]      [get_bd_pins rx_axis_tlast_4]
  connect_bd_net -net mrmac_0_core_rx_axis_tvalid_4     [get_bd_pins mrmac_0_core/rx_axis_tvalid_2]     [get_bd_pins rx_axis_tvalid_4]
  # 3
  connect_bd_net -net mrmac_0_core_rx_axis_tdata_6      [get_bd_pins mrmac_0_core/rx_axis_tdata6]       [get_bd_pins rx_axis_tdata_6]
  connect_bd_net -net mrmac_0_core_rx_axis_tkeep_user_6 [get_bd_pins mrmac_0_core/rx_axis_tkeep_user6]  [get_bd_pins rx_axis_tkeep_user_6]
  connect_bd_net -net mrmac_0_core_rx_axis_tlast_6      [get_bd_pins mrmac_0_core/rx_axis_tlast_3]      [get_bd_pins rx_axis_tlast_6]
  connect_bd_net -net mrmac_0_core_rx_axis_tvalid_6     [get_bd_pins mrmac_0_core/rx_axis_tvalid_3]     [get_bd_pins rx_axis_tvalid_6]
  # == TX Lanes
  # 0
  connect_bd_net -net mrmac_0_core_tx_axis_tdata_0      [get_bd_pins tx_axis_tdata_0]      [get_bd_pins mrmac_0_core/tx_axis_tdata0]
  connect_bd_net -net mrmac_0_core_tx_axis_tkeep_user_0 [get_bd_pins tx_axis_tkeep_user_0] [get_bd_pins mrmac_0_core/tx_axis_tkeep_user0]
  connect_bd_net -net mrmac_0_core_tx_axis_tlast_0      [get_bd_pins tx_axis_tlast_0]      [get_bd_pins mrmac_0_core/tx_axis_tlast_0]
  connect_bd_net -net mrmac_0_core_tx_axis_tvalid_0     [get_bd_pins tx_axis_tvalid_0]     [get_bd_pins mrmac_0_core/tx_axis_tvalid_0]
  connect_bd_net -net mrmac_0_core_tx_axis_tready_0     [get_bd_pins tx_axis_tready_0]     [get_bd_pins mrmac_0_core/tx_axis_tready_0]
  # 1
  connect_bd_net -net mrmac_0_core_tx_axis_tdata_2      [get_bd_pins tx_axis_tdata_2]      [get_bd_pins mrmac_0_core/tx_axis_tdata2]
  connect_bd_net -net mrmac_0_core_tx_axis_tkeep_user_2 [get_bd_pins tx_axis_tkeep_user_2] [get_bd_pins mrmac_0_core/tx_axis_tkeep_user2]
  connect_bd_net -net mrmac_0_core_tx_axis_tlast_2      [get_bd_pins tx_axis_tlast_2]      [get_bd_pins mrmac_0_core/tx_axis_tlast_1]
  connect_bd_net -net mrmac_0_core_tx_axis_tvalid_2     [get_bd_pins tx_axis_tvalid_2]     [get_bd_pins mrmac_0_core/tx_axis_tvalid_1]
  connect_bd_net -net mrmac_0_core_tx_axis_tready_2     [get_bd_pins tx_axis_tready_2]     [get_bd_pins mrmac_0_core/tx_axis_tready_1]
  # 2
  connect_bd_net -net mrmac_0_core_tx_axis_tdata_4      [get_bd_pins tx_axis_tdata_4]      [get_bd_pins mrmac_0_core/tx_axis_tdata4]
  connect_bd_net -net mrmac_0_core_tx_axis_tkeep_user_4 [get_bd_pins tx_axis_tkeep_user_4] [get_bd_pins mrmac_0_core/tx_axis_tkeep_user4]
  connect_bd_net -net mrmac_0_core_tx_axis_tlast_4      [get_bd_pins tx_axis_tlast_4]      [get_bd_pins mrmac_0_core/tx_axis_tlast_2]
  connect_bd_net -net mrmac_0_core_tx_axis_tvalid_4     [get_bd_pins tx_axis_tvalid_4]     [get_bd_pins mrmac_0_core/tx_axis_tvalid_2]
  connect_bd_net -net mrmac_0_core_tx_axis_tready_4     [get_bd_pins tx_axis_tready_4]     [get_bd_pins mrmac_0_core/tx_axis_tready_2]
  # 3
  connect_bd_net -net mrmac_0_core_tx_axis_tdata_6      [get_bd_pins tx_axis_tdata_6]      [get_bd_pins mrmac_0_core/tx_axis_tdata6]
  connect_bd_net -net mrmac_0_core_tx_axis_tkeep_user_6 [get_bd_pins tx_axis_tkeep_user_6] [get_bd_pins mrmac_0_core/tx_axis_tkeep_user6]
  connect_bd_net -net mrmac_0_core_tx_axis_tlast_6      [get_bd_pins tx_axis_tlast_6]      [get_bd_pins mrmac_0_core/tx_axis_tlast_3]
  connect_bd_net -net mrmac_0_core_tx_axis_tvalid_6     [get_bd_pins tx_axis_tvalid_6]     [get_bd_pins mrmac_0_core/tx_axis_tvalid_3]
  connect_bd_net -net mrmac_0_core_tx_axis_tready_6     [get_bd_pins tx_axis_tready_6]     [get_bd_pins mrmac_0_core/tx_axis_tready_3]

  # Restore current instance
  current_bd_instance $oldCurInst
}
