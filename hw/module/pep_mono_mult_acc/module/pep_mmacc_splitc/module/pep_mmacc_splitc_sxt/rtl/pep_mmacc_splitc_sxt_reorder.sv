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
  // Flat coef index p = cnt*RD_COEF_NB + m spans STG_ITER_SZ + RD_COEF_W bits.
  localparam int FLAT_W = STG_ITER_SZ + RD_COEF_W;
  // localparam int ROWS_PER_BEAT = RD_COEF_NB / STG_ITER_NB;

// ============================================================================================== --
// Parameter checks
// ============================================================================================== --
// With both STG_ITER_NB and RD_COEF_NB powers of two, one always divides the other, so no
// explicit divisibility check is needed. The unified Step-2 formula handles both regimes
// (RD_COEF_NB >= STG_ITER_NB and STG_ITER_NB >= RD_COEF_NB).
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
// Step 1 pipeline
// ============================================================================================== --
// Register step1_data close to the buf_data row banks. Without this stage the bit-reversed
// data (RD_COEF_NB*MOD_Q_W bits) broadcasts combinationally to STG_ITER_NB row sinks; the
// resulting routing star limits placement freedom for buf_data. Skid-buffered (DEPTH=2,
// TYPE_ARRAY={4'h1,4'h2}) so the handshake remains lossless.
  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] s1_data;
  logic                               s1_is_body;
  logic                               s1_vld;
  logic                               s1_rdy;

  fifo_element #(
    .WIDTH          (RD_COEF_NB * MOD_Q_W + 1),
    .DEPTH          (2),
    .TYPE_ARRAY     ({4'h1, 4'h2}),
    .DO_RESET_DATA  (1'b0),
    .RESET_DATA_VAL (0)
  ) step1_pipe (
    .clk      (clk),
    .s_rst_n  (s_rst_n),

    .in_data  ({s0_is_body, step1_data}),
    .in_vld   (s0_vld),
    .in_rdy   (s0_rdy),

    .out_data ({s1_is_body, s1_data}),
    .out_vld  (s1_vld),
    .out_rdy  (s1_rdy)
  );

// ============================================================================================== --
// Buffer + control
// ============================================================================================== --
  logic [STG_ITER_NB-1:0][RD_COEF_NB-1:0][MOD_Q_W-1:0] buf_data;
  logic [STG_ITER_W-1:0]  cnt;       // shared counter for write and read phases
  logic                   buf_avail; // 0 = write phase, 1 = read phase
  logic                   cnt_last;
  logic                   wr_en;
  logic                   rd_en;
  logic                   pipe_rdy;  // Pre-pipe ready: controls buffer drain rate

  assign cnt_last = (cnt == STG_ITER_W'(STG_ITER_NB - 1));

  // Bodies bypass the buffer: while filling a mask group (~buf_avail), a body beat may arrive at
  // any cnt in [0..STG_ITER_NB-1].
  // It is forwarded via body_pass without advancing cnt or disturbing buf_data, partially filled
  // mask group resumes on the next mask beat.
  assign wr_en  = ~buf_avail & s1_vld & ~s1_is_body;
  assign rd_en  =  buf_avail & pipe_rdy;

  // Decompose the global wr_en into STG_ITER_NB per-row local enables
  logic [STG_ITER_NB-1:0] wr_en_row;

  always_comb
    for (int r = 0; r < STG_ITER_NB; r++)
      wr_en_row[r] = wr_en & (cnt == STG_ITER_W'(r));

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
    for (int r = 0; r < STG_ITER_NB; r++)
      if (wr_en_row[r])
        buf_data[r] <= s1_data; // step1_l.append(...)  (r == cnt == i in range(STG_ITER_NB))

// ============================================================================================== --
// Step 2: read with transpose + bit-reversed column index
// ============================================================================================== --
  // Output beat k emits natural coef indices p in [k*RD_COEF_NB .. (k+1)*RD_COEF_NB-1].
  // Since both sizes are powers of two, p = {cnt, m} (FLAT_W bits) splits cleanly:
  //   i = p[FLAT_W-1 : STG_ITER_SZ] | high bits -> row in step1_l (i in R*PSI)
  //   j = p[STG_ITER_SZ-1 : 0]      | low  bits -> column (j in STG_ITER_NB)
  //   rd_data[m] = step1_l[rev(j, STG_ITER_SZ)][i]
  // Pure wiring; valid for both RD_COEF_NB >= STG_ITER_NB and STG_ITER_NB >= RD_COEF_NB.

  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] rd_data;

  // always_comb
  //   for (int s = 0; s < ROWS_PER_BEAT; s++)                                      // for i in range(R*PSI)
  //     for (int t = 0; t < STG_ITER_NB; t++) begin                                // for j in range(STG_ITER_NB):
  //       logic [STG_ITER_SZ-1:0] rev_t;
  //       for (int b = 0; b < STG_ITER_SZ; b++)
  //         rev_t[b] = t[STG_ITER_SZ-1-b];                                         // reverse(j, STG_ITER_SZ)
  //       rd_data[s * STG_ITER_NB + t] = buf_data[rev_t][cnt * ROWS_PER_BEAT + s]; // step1_l[reverse(j,STG_ITER_SZ)][i]
  //     end

  // Flat-index form of the (s,t) loop: {cnt,m} splits into row i (upper bits) and
  // stage-iter j (lower STG_ITER_SZ bits, then bit-reversed).
  always_comb
    for (int m = 0; m < RD_COEF_NB; m++) begin     // coef within output beat
      logic [FLAT_W-1:0]      flat_p;
      logic [RD_COEF_W-1:0]   i_outer;
      logic [STG_ITER_SZ-1:0] j_outer;
      logic [STG_ITER_SZ-1:0] rev_j;
      flat_p  = {cnt, RD_COEF_W'(m)};            // p = k*R*PSI + m
      i_outer = flat_p[FLAT_W-1 : STG_ITER_SZ];  // p / STG_ITER_NB     (i in range(R*PSI))
      j_outer = flat_p[STG_ITER_SZ-1 : 0];       // p % STG_ITER_NB     (j in range(STG_ITER_NB))
      for (int b = 0; b < STG_ITER_SZ; b++)
        rev_j[b] = j_outer[STG_ITER_SZ-1-b];     // reverse(j, STG_ITER_SZ)
      rd_data[m] = buf_data[rev_j][i_outer];     // step1_l[reverse(j,STG_ITER_SZ)][i]
    end

// ============================================================================================== --
// Pre-pipe interface
// ============================================================================================== --
  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] pipe_data;
  logic                               pipe_is_body;
  logic                               pipe_vld;
  logic                               body_pass;

  assign body_pass    = ~buf_avail & s1_vld & s1_is_body;

  assign s1_rdy       = buf_avail ? 1'b0 : body_pass ? pipe_rdy : 1'b1;

  assign pipe_vld     = buf_avail | body_pass;
  assign pipe_is_body = body_pass;

  // Body scalar lives at flat index 0 (s1_data[0] == bit-reversed step1_data[0] == s0_data[0][0]
  // before pipelining: rev(0)=0, so step1_data[0] equals the first PSI/R lane).
  always_comb begin
    pipe_data = '0;
    if (buf_avail)
      pipe_data = rd_data;
    else if (body_pass)
      pipe_data[0] = s1_data[0];
  end

// ============================================================================================== --
// Read-data pipe stage
// ============================================================================================== --
// Pipeline register that captures rd_data right at the mux output, so the long buf_data -> step-2 mux
// to output register path no longer crosses a fifo stage.
// Note that this fifo element is not merged with output pipe for clarity. This is mandatory.
logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] mid_data;
  logic                               mid_is_body;
  logic                               mid_vld;
  logic                               mid_rdy;

  fifo_element #(
    .WIDTH          (RD_COEF_NB * MOD_Q_W + 1),
    .DEPTH          (1),
    .TYPE_ARRAY     (4'h1),
    .DO_RESET_DATA  (1'b0),
    .RESET_DATA_VAL (0)
  ) rd_pipe (
    .clk      (clk),
    .s_rst_n  (s_rst_n),

    .in_data  ({pipe_is_body, pipe_data}),
    .in_vld   (pipe_vld),
    .in_rdy   (pipe_rdy),

    .out_data ({mid_is_body, mid_data}),
    .out_vld  (mid_vld),
    .out_rdy  (mid_rdy)
  );

// ============================================================================================== --
// Output pipe
// ============================================================================================== --
  fifo_element #(
    .WIDTH          (RD_COEF_NB * MOD_Q_W + 1),
    .DEPTH          (2),
    .TYPE_ARRAY     ({4'h1,4'h2}),
    .DO_RESET_DATA  (1'b0),
    .RESET_DATA_VAL (0)
  ) out_pipe (
    .clk      (clk),
    .s_rst_n  (s_rst_n),

    .in_data  ({mid_is_body, mid_data}),
    .in_vld   (mid_vld),
    .in_rdy   (mid_rdy),

    .out_data ({out_is_body, out_data}),
    .out_vld  (out_vld),
    .out_rdy  (out_rdy)
  );

endmodule
