// ==============================================================================================
// BSD 3-Clause Clear License
// Copyright © 2025 ZAMA. All rights reserved.
// ----------------------------------------------------------------------------------------------
// Description  :
// ----------------------------------------------------------------------------------------------
//
// NTT core gf64 computes the NTT and INTT in goldilocks 64 domain.
// This prime = 2**64-2**32+1 has many properties. In particular :
// 1. We use the following one to simplify all the twiddle multiplications :
//    It exists a 64th root of unity in GF64 which value is 8=2**3 : w_64 = 2**3, so
//    a power of 2.
// 2. This prime is a solinas2, with the following pattern : 2**W-2**W/2+1.
//    The modular reduction can be done efficiently, especially if we do partial
//    modular reduction (PMR). Which means that we do not reduce completely,
//    and the data path contains additional bits.
//
// This module also performs the external multiplication with the BSK.
//
// ==============================================================================================

module ntt_split_vector
  import common_definition_pkg::*;
  import pep_common_param_pkg::*;
  import param_tfhe_pkg::*;
  import param_ntt_pkg::*;
  import ntt_core_common_param_pkg::*;
  import ntt_core_gf64_common_param_pkg::*;
#(
  parameter  arith_mult_type_e PHI_MULT_TYPE    = MULT_CORE, // PHI multiplier, when needed
  parameter  arith_mult_type_e PP_MULT_TYPE     = MULT_CORE, // Multiplier used in PP
  parameter  int               RAM_LATENCY      = 1,
  parameter  int               ROM_LATENCY      = 1,
  parameter int LINK_PIPE = 2,
  parameter  string            TWD_GF64_FILE_PREFIX  = $sformatf("memory_file/twiddle/NTT_CORE_ARCH_GF64/R%0d_PSI%0d/twd_phi",R,PSI),
  localparam int               ERROR_W          = 1    // pp
)
(
  input  logic                                                 clk,
  input  logic                                                 s_rst_n,

  // Data from decomposition
  input  logic [PSI-1:0][R-1:0][PBS_B_W:0]                     decomp_ntt_data, // 2s complement
  input  logic [PSI-1:0][R-1:0]                                decomp_ntt_data_vld,
  output logic [PSI-1:0][R-1:0]                                decomp_ntt_data_rdy,
  input  logic                                                 decomp_ntt_sob,
  input  logic                                                 decomp_ntt_eob,
  input  logic                                                 decomp_ntt_sol,
  input  logic                                                 decomp_ntt_eol,
  input  logic                                                 decomp_ntt_sog,
  input  logic                                                 decomp_ntt_eog,
  input  logic [BPBS_ID_W-1:0]                                 decomp_ntt_pbs_id,
  input  logic                                                 decomp_ntt_ctrl_vld,
  output logic                                                 decomp_ntt_ctrl_rdy,

  // output logic data to acc
  output logic [PSI-1:0][R-1:0][MOD_NTT_W-1:0]                 ntt_acc_data,
  output logic [PSI-1:0][R-1:0]                                ntt_acc_data_avail,
  output logic                                                 ntt_acc_sob,
  output logic                                                 ntt_acc_eob,
  output logic                                                 ntt_acc_sol,
  output logic                                                 ntt_acc_eol,
  output logic                                                 ntt_acc_sog,
  output logic                                                 ntt_acc_eog,
  output logic [BPBS_ID_W-1:0]                                 ntt_acc_pbs_id,
  output logic                                                 ntt_acc_ctrl_avail,

  // Matrix factors : BSK
  input  logic [PSI-1:0][R-1:0][GLWE_K_P1-1:0][MOD_NTT_W-1:0]  bsk,
  input  logic [PSI-1:0][R-1:0][GLWE_K_P1-1:0]                 bsk_vld,
  output logic [PSI-1:0][R-1:0][GLWE_K_P1-1:0]                 bsk_rdy,

  // Error
  output logic [ERROR_W-1:0]                                   error
);

  // ============================================================================================ //
  // Signals
  // ============================================================================================ //
  logic [PSI-1:0][R-1:0][MOD_NTT_W+1:0] next_data;
  logic [PSI-1:0][R-1:0]                next_avail;
  logic                                 next_sob;
  logic                                 next_eob;
  logic                                 next_sol;
  logic                                 next_eol;
  logic                                 next_sos;
  logic                                 next_eos;
  logic [BPBS_ID_W-1:0]                 next_pbs_id;

  logic                                 ntt_error;
  logic                                 intt_error;
  logic middle_error;
  typedef struct packed {
    logic [PSI-1:0][R-1:0][MOD_NTT_W+1:0] data;
    logic [PSI-1:0][R-1:0] avail;
    logic sob,eob,sol,eol,sos,eos;
    logic [BPBS_ID_W-1:0] pid;
  } link_t;
  link_t hwire, hin, mraw, min;
  link_t hpipe[0:LINK_PIPE], mpipe[0:LINK_PIPE];
  assign hwire={next_data,next_avail,next_sob,next_eob,next_sol,next_eol,next_sos,next_eos,next_pbs_id};
  assign hpipe[0]=hwire;
  assign mpipe[0]=mraw;
  for(genvar i=0;i<LINK_PIPE;i++) begin : pipe_link
    always_ff @(posedge clk) begin
      hpipe[i+1] <= hpipe[i]; mpipe[i+1] <= mpipe[i];
      if(!s_rst_n) begin hpipe[i+1].avail<='0; mpipe[i+1].avail<='0; end
    end
  end
  assign hin=hpipe[LINK_PIPE];
  assign min=mpipe[LINK_PIPE];

  // ============================================================================================ //
  // Error
  // ============================================================================================ //
  logic errorD;

  assign errorD = ntt_error | intt_error | middle_error;

  always_ff @(posedge clk)
    if (!s_rst_n) error <= 1'b0;
    else          error <= errorD;

  // ============================================================================================ //
  // Head
  // ============================================================================================ //
  ntt_core_gf64_head
  #(
    .S_NB             (DELTA+1),
    .USE_PP           (1'b0),
    .PHI_MULT_TYPE    (PHI_MULT_TYPE),
    .PP_MULT_TYPE     (PP_MULT_TYPE),
    .RAM_LATENCY      (RAM_LATENCY),
    .ROM_LATENCY      (ROM_LATENCY),
    .TWD_GF64_FILE_PREFIX (TWD_GF64_FILE_PREFIX)
  ) ntt_core_gf64_head (
    .clk                 (clk),
    .s_rst_n             (s_rst_n),

    .decomp_ntt_data     (decomp_ntt_data),
    .decomp_ntt_data_vld (decomp_ntt_data_vld),
    .decomp_ntt_data_rdy (decomp_ntt_data_rdy),
    .decomp_ntt_sob      (decomp_ntt_sob),
    .decomp_ntt_eob      (decomp_ntt_eob),
    .decomp_ntt_sol      (decomp_ntt_sol),
    .decomp_ntt_eol      (decomp_ntt_eol),
    .decomp_ntt_sog      (decomp_ntt_sog),
    .decomp_ntt_eog      (decomp_ntt_eog),
    .decomp_ntt_pbs_id   (decomp_ntt_pbs_id),
    .decomp_ntt_ctrl_vld (decomp_ntt_ctrl_vld),
    .decomp_ntt_ctrl_rdy (decomp_ntt_ctrl_rdy),

    .next_data           (next_data),
    .next_avail          (next_avail),
    .next_sob            (next_sob),
    .next_eob            (next_eob),
    .next_sol            (next_sol),
    .next_eol            (next_eol),
    .next_sos            (next_sos),
    .next_eos            (next_eos),
    .next_pbs_id         (next_pbs_id),

    .bsk                 ('0),
    .bsk_vld             ('0),
    .bsk_rdy             (),

    .error               (ntt_error)
  );

  // ============================================================================================ //
  // Tail
  // ============================================================================================ //
  ntt_core_gf64_tail
  #(
    .S_INIT           (2*S-1-DELTA),
    .S_NB             (DELTA+1),
    .USE_PP           (1'b0),
    .PHI_MULT_TYPE    (PHI_MULT_TYPE),
    .PP_MULT_TYPE     (PP_MULT_TYPE),
    .RAM_LATENCY      (RAM_LATENCY),
    .ROM_LATENCY      (ROM_LATENCY),
    .IN_PIPE          (1'b1),
    .TWD_GF64_FILE_PREFIX (TWD_GF64_FILE_PREFIX)
  ) ntt_core_gf64_tail (
    .clk                (clk),
    .s_rst_n            (s_rst_n),

    .prev_data          (min.data),
    .prev_avail         (min.avail),
    .prev_sob           (min.sob),
    .prev_eob           (min.eob),
    .prev_sol           (min.sol),
    .prev_eol           (min.eol),
    .prev_sos           (min.sos),
    .prev_eos           (min.eos),
    .prev_pbs_id        (min.pid),

    .ntt_acc_data       (ntt_acc_data),
    .ntt_acc_data_avail (ntt_acc_data_avail),
    .ntt_acc_sob        (ntt_acc_sob),
    .ntt_acc_eob        (ntt_acc_eob),
    .ntt_acc_sol        (ntt_acc_sol),
    .ntt_acc_eol        (ntt_acc_eol),
    .ntt_acc_sog        (ntt_acc_sog),
    .ntt_acc_eog        (ntt_acc_eog),
    .ntt_acc_pbs_id     (ntt_acc_pbs_id),
    .ntt_acc_ctrl_avail (ntt_acc_ctrl_avail),

    .bsk                ('x), /*UNUSED*/
    .bsk_vld            ('0), /*UNUSED*/
    .bsk_rdy            (/*UNUSED*/),

    .error              (intt_error)
  );

  ntt_core_gf64_middle #(
    .S_INIT(S-1-(DELTA+1)), .S_NB(2*S-2*(DELTA+1)), .USE_PP(1'b1),
    .PHI_MULT_TYPE(PHI_MULT_TYPE), .PP_MULT_TYPE(PP_MULT_TYPE),
    .RAM_LATENCY(RAM_LATENCY), .ROM_LATENCY(ROM_LATENCY), .IN_PIPE(1'b1),
    .TWD_GF64_FILE_PREFIX(TWD_GF64_FILE_PREFIX)
  ) middle (
    .clk(clk), .s_rst_n(s_rst_n),
    .prev_data(hin.data), .prev_avail(hin.avail), .prev_sob(hin.sob), .prev_eob(hin.eob),
    .prev_sol(hin.sol), .prev_eol(hin.eol), .prev_sos(hin.sos), .prev_eos(hin.eos), .prev_pbs_id(hin.pid),
    .next_data(mraw.data), .next_avail(mraw.avail), .next_sob(mraw.sob), .next_eob(mraw.eob),
    .next_sol(mraw.sol), .next_eol(mraw.eol), .next_sos(mraw.sos), .next_eos(mraw.eos), .next_pbs_id(mraw.pid),
    .bsk(bsk), .bsk_vld(bsk_vld), .bsk_rdy(bsk_rdy), .error(middle_error)
  );

endmodule
