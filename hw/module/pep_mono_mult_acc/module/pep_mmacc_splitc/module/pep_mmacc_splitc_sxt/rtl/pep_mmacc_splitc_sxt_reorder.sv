// ==============================================================================================
// BSD 3-Clause Clear License
// Copyright © 2025 ZAMA. All rights reserved.
// ----------------------------------------------------------------------------------------------
// Description  : Reorder module for sample extract.
// ----------------------------------------------------------------------------------------------
// Converts from bit-reversed to natural coefficient order (see sw/monomial_mult/mm_reorder.py).
//
// Step 1: bit-reversal within each R*PSI chunk (RD_COEF_W bits)
// Step 2: transpose + bit-reversal on the stage-iteration index (STG_ITER_SZ bits)
//
// Body beats bypass the buffer (single scalar, no reorder needed).
//
// ==============================================================================================

module pep_mmacc_splitc_sxt_reorder
  import param_tfhe_pkg::*;
  import top_common_param_pkg::*;
  import ntt_core_common_param_pkg::*;
  import pep_common_param_pkg::*;
  import pep_mmacc_common_param_pkg::*;
  import pep_mmacc_splitc_sxt_pkg::*;
#(
  parameter bit INPUT_PIPE = 1'b0
)
(
  input  logic                                 clk,
  input  logic                                 s_rst_n,

  // Input: R*PSI coefficients per beat
  input  logic [PSI-1:0][R-1:0][MOD_Q_W-1:0]   in_data,
  input  logic                                 in_is_body,
  input  logic                                 in_vld,
  output logic                                 in_rdy,

  // Output: R*PSI coefficients per beat (same width, natural order)
  output logic [PSI-1:0][R-1:0][MOD_Q_W-1:0]   out_data,
  output logic                                 out_is_body,
  output logic                                 out_vld,
  input  logic                                 out_rdy
);

// ============================================================================================== --
// localparam
// ============================================================================================== --
  localparam int ROWS_PER_BEAT = RD_COEF_NB / STG_ITER_NB;

// ============================================================================================== --
// Parameter checks
// ============================================================================================== --
  generate
    if (STG_ITER_NB < 2) begin : __UNSUPPORTED_STG_ITER_NB_
      $fatal(1,"> ERROR: STG_ITER_NB (%0d) must be >= 2 (bit-reversal on stage-iter index is degenerate below 2).", STG_ITER_NB);
    end
    if (RD_COEF_NB < 2) begin : __UNSUPPORTED_RD_COEF_NB_
      $fatal(1,"> ERROR: RD_COEF_NB (%0d) must be >= 2 (bit-reversal on coef index is degenerate below 2).", RD_COEF_NB);
    end
    if ((STG_ITER_NB & (STG_ITER_NB - 1)) != 0) begin : __STG_ITER_NB_NOT_POW2_
      $fatal(1,"> ERROR: STG_ITER_NB (%0d) must be a power of two.", STG_ITER_NB);
    end
    if ((RD_COEF_NB & (RD_COEF_NB - 1)) != 0) begin : __RD_COEF_NB_NOT_POW2_
      $fatal(1,"> ERROR: RD_COEF_NB (%0d) must be a power of two.", RD_COEF_NB);
    end
    if ((RD_COEF_NB % STG_ITER_NB) != 0) begin : __RD_COEF_NB_NOT_MULTIPLE_OF_STG_ITER_NB_
      $fatal(1,"> ERROR: RD_COEF_NB (%0d) must be a multiple of STG_ITER_NB (%0d).", RD_COEF_NB, STG_ITER_NB);
    end
  endgenerate

// ============================================================================================== --
// Optional input pipe
// ============================================================================================== --
// Same input pattern as pep_mmacc_splitc_sxt_final: DEPTH=2 with TYPE_ARRAY={4'h1,4'h2}
// Cuts both forward and backward combinational paths without throughput penalty.
  logic [PSI-1:0][R-1:0][MOD_Q_W-1:0] s0_data;
  logic                               s0_is_body;
  logic                               s0_vld;
  logic                               s0_rdy;

  generate
    if (INPUT_PIPE) begin : gen_in_pipe
      fifo_element #(
        .WIDTH          (RD_COEF_NB * MOD_Q_W + 1),
        .DEPTH          (2),
        .TYPE_ARRAY     ({4'h1, 4'h2}),
        .DO_RESET_DATA  (1'b0),
        .RESET_DATA_VAL (0)
      ) in_pipe (
        .clk      (clk),
        .s_rst_n  (s_rst_n),

        .in_data  ({in_is_body, in_data}),
        .in_vld   (in_vld),
        .in_rdy   (in_rdy),

        .out_data ({s0_is_body, s0_data}),
        .out_vld  (s0_vld),
        .out_rdy  (s0_rdy)
      );
    end
    else begin : gen_no_in_pipe
      assign s0_data    = in_data;
      assign s0_is_body = in_is_body;
      assign s0_vld     = in_vld;
      assign in_rdy     = s0_rdy;
    end
  endgenerate

// ============================================================================================== --
// Step 1: bit-reverse within R*PSI (pure wiring)
// ============================================================================================== --
  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] in_data_flat;
  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] step1_data;

  assign in_data_flat = s0_data;

  always_comb
    for (int i = 0; i < RD_COEF_NB; i++) begin // for x in range(R*PSI)
      logic [RD_COEF_W-1:0] rev_i;
      for (int b = 0; b < RD_COEF_W; b++)
        rev_i[b] = i[RD_COEF_W-1-b];           // reverse(x,RPSI_SZ)
      step1_data[i] = in_data_flat[rev_i];
    end

// ============================================================================================== --
// Buffer + control
// ============================================================================================== --
  logic [STG_ITER_NB-1:0][RD_COEF_NB-1:0][MOD_Q_W-1:0] buf_data;

  logic [STG_ITER_W-1:0] cnt;       // shared counter for write and read phases
  logic                  buf_avail; // 0 = write phase, 1 = read phase
  logic                  cnt_last;
  logic                  wr_en;
  logic                  rd_en;
  logic                  pipe_rdy; // Pre-pipe ready: controls buffer drain rate

  assign cnt_last = (cnt == STG_ITER_W'(STG_ITER_NB - 1));

  // Bodies bypass the buffer: while filling a mask group (~buf_avail), a body beat may arrive at
  // any cnt in [0..STG_ITER_NB-1]. It is forwarded via body_pass without advancing cnt or
  // disturbing buf_data, so the partially filled mask group resumes on the next mask beat.
  assign wr_en  = ~buf_avail & s0_vld & ~s0_is_body;
  assign rd_en  =  buf_avail & pipe_rdy;

  always_ff @(posedge clk) begin
    if (~s_rst_n) begin
      cnt       <= '0;
      buf_avail <= 1'b0;
    end else if (wr_en | rd_en) begin
      cnt       <= cnt_last ? 'h0 : cnt + STG_ITER_W'(1);
      buf_avail <= cnt_last ? ~buf_avail : buf_avail;
    end
  end

  always_ff @(posedge clk)
    if (wr_en)
      buf_data[cnt] <= step1_data;            // step1_l.append(...)  (cnt == i in range(STG_ITER_NB))

// ============================================================================================== --
// Step 2: read with transpose + bit-reversed column index
// ============================================================================================== --
  // Output beat k (cnt=k during read phase) contains natural indices [k*RD_COEF_NB .. (k+1)*RD_COEF_NB-1].
  // Position m = s * STG_ITER_NB + t within beat:
  //   row = k * ROWS_PER_BEAT + s    (s = 0..ROWS_PER_BEAT-1)
  //   col = rev(t, STG_ITER_SZ)      (t = 0..STG_ITER_NB-1)
  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] rd_data;

  always_comb
    for (int s = 0; s < ROWS_PER_BEAT; s++)                                      // for i in range(R*PSI)
      for (int t = 0; t < STG_ITER_NB; t++) begin                                // for j in range(STG_ITER_NB):
        logic [STG_ITER_SZ-1:0] rev_t;
        for (int b = 0; b < STG_ITER_SZ; b++)
          rev_t[b] = t[STG_ITER_SZ-1-b];                                         // reverse(j, STG_ITER_SZ)
        rd_data[s * STG_ITER_NB + t] = buf_data[rev_t][cnt * ROWS_PER_BEAT + s]; // step1_l[reverse(j,STG_ITER_SZ)][i]
      end

// ============================================================================================== --
// Pre-pipe interface
// ============================================================================================== --
  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] pipe_data;
  logic                               pipe_is_body;
  logic                               pipe_vld;
  logic                               body_pass;

  assign body_pass    = ~buf_avail & s0_vld & s0_is_body;

  assign s0_rdy       = buf_avail ? 1'b0 : body_pass ? pipe_rdy : 1'b1;

  assign pipe_vld     = buf_avail | body_pass;
  assign pipe_is_body = body_pass;

  always_comb begin
    pipe_data = '0;
    if (buf_avail)
      pipe_data = rd_data;
    else if (body_pass)
      pipe_data[0] = s0_data[0][0];
  end

// ============================================================================================== --
// Output pipe
// ============================================================================================== --
// try syntehsis with DEPTH=1 when more time
  fifo_element #(
    .WIDTH          (RD_COEF_NB * MOD_Q_W + 1),
    .DEPTH          (2),
    .TYPE_ARRAY     ({4'h1,4'h2}),
    .DO_RESET_DATA  (1'b0),
    .RESET_DATA_VAL (0)
  ) out_pipe (
    .clk      (clk),
    .s_rst_n  (s_rst_n),

    .in_data  ({pipe_is_body, pipe_data}),
    .in_vld   (pipe_vld),
    .in_rdy   (pipe_rdy),

    .out_data ({out_is_body, out_data}),
    .out_vld  (out_vld),
    .out_rdy  (out_rdy)
  );

endmodule
