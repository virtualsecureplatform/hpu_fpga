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

// ============================================================================================= --
// localparam
// ============================================================================================= --
  // Flat coef index p = cnt*RD_COEF_NB + m spans STG_ITER_SZ + RD_COEF_W bits.
  localparam int FLAT_W = STG_ITER_SZ + RD_COEF_W;
  // localparam int ROWS_PER_BEAT = RD_COEF_NB / STG_ITER_NB;

  // Two-stage read-mux split: a single STG_ITER_NB:1 mux is too deep for timing once STG_ITER_SZ grows.
  // A mux's logic depth scales with its select width. A way to halve the depth is to feed each
  // half of the select to a different mux. HI_SZ/LO_SZ define the partition between the two muxes:
  //  - stage 1 consumes cnt[hi] (HI_SZ bits, ceiling half),
  //  - stage 2 consumes cnt[lo] (LO_SZ bits, floor half).
  // Ceiling goes to HI_SZ because stage 1 already spans the wide gather and can absorb the extra select bit.
  // Stage 2 stays narrow so it packs into smaller muxes.
  localparam int HI_SZ = (STG_ITER_SZ + 1) / 2; // upper select bits (gets ceiling half)
  localparam int LO_SZ =  STG_ITER_SZ      / 2; // lower select bits (floor half)
  localparam int N_LO  = 1 << LO_SZ;            // number of stage-1 candidates fed to stage 2

// ============================================================================================= --
// Parameter checks
// ============================================================================================= --
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
    if (STG_ITER_SZ < 2) begin : __SPLIT_READ_NEEDS_STG_ITER_SZ_GE_2_
      $fatal(1, "> ERROR: split read mux requires STG_ITER_SZ >= 2 (STG_ITER_NB >= 4); got %0d.", STG_ITER_SZ);
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
  // Register step1_data close to the buf_data row banks.
  // Without this stage the bit-reversed data (RD_COEF_NB*MOD_Q_W bits) broadcasts combinationally
  // to STG_ITER_NB row sinks. Resulting routing star limits placement freedom for buf_data.
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
// EXTRACT_ENABLE="no" tells Vivado to implement the per-row write enable as a D-pin feedback mux
// on each buf_data FDRE rather than driving the FDRE CE pin.
// Without, vivado does a device-wide CE control set (STG_ITER_NB*RD_COEF_NB*MOD_Q_W flops sharing one CE)
  (* EXTRACT_ENABLE = "no" *) logic [STG_ITER_NB-1:0][RD_COEF_NB-1:0][MOD_Q_W-1:0] buf_data;

  logic buf_avail; // 0 = write phase, 1 = read phase
  logic pipe_rdy;  // Pre-pipe ready: controls buffer drain rate
  logic wr_en;
  logic rd_en;

  // Bodies bypass the buffer: while filling a mask group (~buf_avail), a body beat may arrive at
  // any cnt in [0..STG_ITER_NB-1].
  assign wr_en = ~buf_avail & s1_vld & ~s1_is_body;
  assign rd_en =  buf_avail & pipe_rdy;

   logic [STG_ITER_W-1:0] cnt;      // shared counter for write and read phases
   logic                  cnt_last; // pulse on last stage iter
   logic [HI_SZ-1:0]      cnt_hi;
   logic [LO_SZ-1:0]      cnt_lo;

  always_ff @(posedge clk) begin
    if (~s_rst_n) begin
      cnt       <= 'h0;
      buf_avail <= 1'b0;
    end else if (wr_en | rd_en) begin
      cnt       <= cnt_last ? 'h0 : cnt + STG_ITER_W'(1);
      buf_avail <= cnt_last ? ~buf_avail : buf_avail;
    end
  end

  assign cnt_last = (cnt == STG_ITER_W'(STG_ITER_NB - 1));
  assign cnt_hi   = cnt[STG_ITER_SZ-1 : LO_SZ];
  assign cnt_lo   = cnt[LO_SZ-1 : 0];

  // Decompose the global wr_en into STG_ITER_NB per-row local enables
  logic [STG_ITER_NB-1:0] wr_en_row;

  always_comb
    for (int r = 0; r < STG_ITER_NB; r++)
      wr_en_row[r] = wr_en & (cnt == STG_ITER_W'(r));

  always_ff @(posedge clk)
    for (int r = 0; r < STG_ITER_NB; r++)
      if (wr_en_row[r])
        buf_data[r] <= s1_data; // step1_l.append(...) (r == cnt == i in range(STG_ITER_NB))

  // =========================================================================================== --
  // Step 2: read with transpose + bit-reversed column index
  // =========================================================================================== --
  // The original formula rd_data[m] = buf_data[buf_row][buf_col] with {buf_row,buf_col} a
  // bit-sliced function of {cnt,m} hides a per-output-coef STG_ITER_NB:1 mux behind a bit-reverse.
  // Vivado's mux extractor doesn't see through the reversed select and falls back to fabric LUTs:
  // at PSI=64 / STG_ITER_NB=16 each output bit becomes a 3-LUT cascade gathering across the 8192-
  // bit-wide buf_data (leading to timing violations).
  //
  // Solution to this is structured into two parts:
  //   (a) Combinationally permute buf_data into buf_data_perm[k][m] = buf_data[buf_row(k,m)][buf_col(k,m)].
  //       rd_data[m] becomes the indexed read buf_data_perm[cnt][m].
  //   (b) Two-stage indexed mux on `cnt` (see HI_SZ/LO_SZ near the localparams for the rationale):
  //       Stage 1 (sel=cnt_hi) narrows STG_ITER_NB candidates down to N_LO=2^LO_SZ;
  //       Stage 2 (sel=cnt_lo) picks the final row from that N_LO-deep blob.
  //       The registered mux_partial_q between the two stages also lets the placer keep stage 2
  //       spatially local.

  // Original write:
  // always_comb
  //   for (int s = 0; s < ROWS_PER_BEAT; s++)                                      // for i in range(R*PSI)
  //     for (int t = 0; t < STG_ITER_NB; t++) begin                                // for j in range(STG_ITER_NB):
  //       logic [STG_ITER_SZ-1:0] rev_t;
  //       for (int b = 0; b < STG_ITER_SZ; b++)
  //         rev_t[b] = t[STG_ITER_SZ-1-b];                                         // reverse(j, STG_ITER_SZ)
  //       rd_data[s * STG_ITER_NB + t] = buf_data[rev_t][cnt * ROWS_PER_BEAT + s]; // step1_l[reverse(j,STG_ITER_SZ)][i]
  //     end

  // (a) Combinationally permute buf_data into buf_data_perm[k][m]
  logic [STG_ITER_NB-1:0][RD_COEF_NB-1:0][MOD_Q_W-1:0] buf_data_perm;

  always_comb begin
    logic [FLAT_W-1:0]      flat_p;
    logic [STG_ITER_SZ-1:0] buf_row;
    logic [RD_COEF_W-1:0]   buf_col;

    for (int k = 0; k < STG_ITER_NB; k++)
      for (int m = 0; m < RD_COEF_NB; m++) begin
        flat_p  = {STG_ITER_SZ'(k), RD_COEF_W'(m)}; // preparing signals for bit-reverse
        buf_row = {<<{flat_p[STG_ITER_SZ-1 : 0]}};  // low bits, bit-reversed
        buf_col = flat_p[FLAT_W-1 : STG_ITER_SZ];   // high bits
        buf_data_perm[k][m] = buf_data[buf_row][buf_col];
      end
  end

  // (b) Two-stage indexed mux --------------------------------------------------------------------

  // Stage-1 partial: gather N_LO candidates per output coef, indexed on cnt_hi only.
  logic [N_LO-1:0][RD_COEF_NB-1:0][MOD_Q_W-1:0] mux_partial;
  logic                                         pipe_vld;
  logic                                         body_pass;

  always_comb
    for (int k_lo = 0; k_lo < N_LO; k_lo++)
      for (int m = 0; m < RD_COEF_NB; m++)
        mux_partial[k_lo][m] = buf_data_perm[{cnt_hi, LO_SZ'(k_lo)}][m];

  assign body_pass = ~buf_avail & s1_vld & s1_is_body;
  assign s1_rdy    = buf_avail ? 1'b0 : body_pass ? pipe_rdy : 1'b1;
  assign pipe_vld  = buf_avail | body_pass;

  // Stage 1 pipeline: captures mux_partial + needed singal for stage 2
  //  - cnt_lo selects the final mux input one cycle later
  //  - body_pass + s1_data[0] override pipe_data[0] for the body so they share the same latency as buffered reads
  // Body scalar lives at flat index 0 (rev(0)=0; step1_data[0] = s0_data[0][0] bit-reversed).
  logic [N_LO-1:0][RD_COEF_NB-1:0][MOD_Q_W-1:0] mux_partial_q;
  logic [LO_SZ-1:0]                             cnt_lo_q;
  logic                                         body_pass_q;
  logic [MOD_Q_W-1:0]                           s1_data_lane0_q;
  logic                                         mid1_vld;
  logic                                         mid1_rdy;

  // configured as forward register to break data-path
  fifo_element #(
    .WIDTH          (N_LO*RD_COEF_NB*MOD_Q_W + LO_SZ + 1 + MOD_Q_W),
    .DEPTH          (1),
    .TYPE_ARRAY     (4'h1),
    .DO_RESET_DATA  (1'b0),
    .RESET_DATA_VAL (0)
  ) step2_stage1_pipeline (
    .clk      (clk),
    .s_rst_n  (s_rst_n),

    .in_data  ({mux_partial, cnt_lo, body_pass, s1_data[0]}),
    .in_vld   (pipe_vld),
    .in_rdy   (pipe_rdy),

    .out_data ({mux_partial_q, cnt_lo_q, body_pass_q, s1_data_lane0_q}),
    .out_vld  (mid1_vld),
    .out_rdy  (mid1_rdy)
  );

  // Stage-2 final mux + body bypass.
  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] rd_data;
  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] pipe_data;

  always_comb
    for (int m = 0; m < RD_COEF_NB; m++)
      rd_data[m] = mux_partial_q[cnt_lo_q][m];

  always_comb begin
    pipe_data = '0;
    if (body_pass_q)
      pipe_data[0] = s1_data_lane0_q;
    else
      pipe_data = rd_data;
  end

  // Stage 2 pipeline
  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] mid_data;
  logic                               mid_is_body;
  logic                               mid_vld;
  logic                               mid_rdy;

  // configured as forward register to break data-path
  fifo_element #(
    .WIDTH          (RD_COEF_NB * MOD_Q_W + 1),
    .DEPTH          (1),
    .TYPE_ARRAY     (4'h1),
    .DO_RESET_DATA  (1'b0),
    .RESET_DATA_VAL (0)
  ) step2_stage2_pipeline (
    .clk      (clk),
    .s_rst_n  (s_rst_n),

    .in_data  ({body_pass_q, pipe_data}),
    .in_vld   (mid1_vld),
    .in_rdy   (mid1_rdy),

    .out_data ({mid_is_body, mid_data}),
    .out_vld  (mid_vld),
    .out_rdy  (mid_rdy)
  );

// ============================================================================================== --
// Output pipe
// ============================================================================================== --
// configured as backward register to break control-path
  fifo_element #(
    .WIDTH          (RD_COEF_NB * MOD_Q_W + 1),
    .DEPTH          (1),
    .TYPE_ARRAY     (4'h2),
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
