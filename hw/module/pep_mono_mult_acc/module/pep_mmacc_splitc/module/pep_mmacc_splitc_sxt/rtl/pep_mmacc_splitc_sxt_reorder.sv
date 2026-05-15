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
// For understanding this module see python file sw/monomial_mult/mm_reorder.py.
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

  // =========================================================================================== --
  // localparam
  // =========================================================================================== --
  localparam int N_BANK   = (STG_ITER_NB < RD_COEF_NB) ? STG_ITER_NB : RD_COEF_NB;
  localparam int N_BANK_W = $clog2(N_BANK);
  localparam int RG_H     = STG_ITER_NB / N_BANK;  // Row-Group height
  localparam int CG_W     = RD_COEF_NB  / N_BANK;  // Column-Group width - lanes per entry
  localparam int RG_W     = $clog2(RG_H);
  localparam int CG_BITS  = CG_W * MOD_Q_W;

  // Parameters guarrails
  generate
    if (STG_ITER_NB < 2) begin : _UNSUPPORTED_STG_ITER_NB_
      $fatal(1,"> ERROR: STG_ITER_NB (%0d) must be >= 2 (bit-reversal on stage-iter index is degenerate below 2).", STG_ITER_NB);
    end
    if (RD_COEF_NB < 2) begin : _UNSUPPORTED_RD_COEF_NB_
      $fatal(1,"> ERROR: RD_COEF_NB (%0d) must be >= 2 (bit-reversal on coef index is degenerate below 2).", RD_COEF_NB);
    end
    if ((STG_ITER_NB & (STG_ITER_NB - 1)) != 0) begin : _STG_ITER_NB_NOT_POW2_
      $fatal(1,"> ERROR: STG_ITER_NB (%0d) must be a power of two (diagonal-skew indexing uses mod N_BANK).", STG_ITER_NB);
    end
    if ((RD_COEF_NB & (RD_COEF_NB - 1)) != 0) begin : _RD_COEF_NB_NOT_POW2_
      $fatal(1,"> ERROR: RD_COEF_NB (%0d) must be a power of two.", RD_COEF_NB);
    end
  endgenerate


  // =========================================================================================== --
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

  // =========================================================================================== --
  // Step 1: bit-reverse within R*PSI (pure wiring)
  // =========================================================================================== --
  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] in_data_flat;
  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] step1_data;

  assign in_data_flat = s0_data;

  // direct translation from python step1 to RTL
  always_comb
    for (int i = 0; i < RD_COEF_NB; i++) begin // for x in range(R*PSI)
      logic [RD_COEF_W-1:0] rev_i;
      for (int b = 0; b < RD_COEF_W; b++)
        rev_i[b] = i[RD_COEF_W-1-b];           // reverse(x,RPSI_SZ)
      step1_data[i] = in_data_flat[rev_i];
    end

  // =========================================================================================== --
  // Step 1 pipeline
  // =========================================================================================== --
  // Register step1_data close to the bank-mem write rotator.
  // Without this stage the bit-reversed data (RD_COEF_NB*MOD_Q_W bits) broadcasts combinationally
  // into the sinks. Resulting routing star limits placement freedom for buf_data.
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

  // =========================================================================================== --
  // Step 2
  // =========================================================================================== --
  // To help placement we write data into LUTRAMs : this modules resides in SLR2 that is croweded.
  // Bodies bypass the buffer: while filling a mask group (~buf_avail), a body beat may arrive at
  // any cnt in [0..STG_ITER_NB-1].

  // Control --------------------------------------------------------------------------------------
  logic                  buf_avail; // 0 = write phase, 1 = read phase
  logic                  pipe_rdy;  // Pre-pipe ready: controls buffer drain rate
  logic                  wr_en;
  logic                  rd_en;
  logic [STG_ITER_W-1:0] cnt; // shared counter for write and read phases
  logic                  cnt_last;

  assign wr_en = ~buf_avail & s1_vld & ~s1_is_body;
  assign rd_en =  buf_avail & pipe_rdy;

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

  // Slice the shared counter:
  //   cnt_hi = cnt[STG_ITER_W-1:RG_W] - drives the write/read rotator fits in N_BANK_W bits since cnt_hi in [0, N_BANK).
  //   rev_cnt_lo = rev(cnt[RG_W-1:0]) - offset within the row-group for read address.
  logic [N_BANK_W-1:0]   cnt_hi;
  logic [STG_ITER_W-1:0] rev_cnt_lo;

  assign cnt_hi = cnt[STG_ITER_W-1:RG_W];

  // Bit-reverse cnt_lo over RG_W bits, kept at STG_ITER_W width so the concat below is uniform.
  // Upper bits stay 0; when RG_W=0 the for-loop body never executes and rev_cnt_lo == 0.
  always_comb begin
    rev_cnt_lo = 'h0;
    for (int b = 0; b < RG_W; b++)
      rev_cnt_lo[b] = cnt[RG_W-1-b];
  end

  // Datapath -------------------------------------------------------------------------------------
  // Reinterpret the registered input row as N_BANK col-groups (CG_BITS each).
  logic [N_BANK-1:0][CG_BITS-1:0] s1_cg;

  assign s1_cg = s1_data;

  // Write rotator: wr_in[b] = s1_cg[(b - cnt_hi) mod N_BANK].
  // Subtraction in N_BANK_W bits wraps modulo 2^N_BANK_W = N_BANK (N_BANK is a power of two), so
  // no explicit modulo. Paramter check of this constraint is in the guardrails.
  // Synthesised as a log-stage barrel on N_BANK CG_BITS-wide lanes.
  logic [N_BANK-1:0][CG_BITS-1:0] wr_in;
  logic [N_BANK_W-1:0]            wr_src;
  always_comb begin
    wr_src = 'h0;
    for (int b = 0; b < N_BANK; b++) begin
      wr_src   = N_BANK_W'(b) - cnt_hi;
      wr_in[b] = s1_cg[wr_src];
    end
  end

  // Per-bank single-port LUTRAM - Bank-skewed transpose buffer
  // The outer dimension is unpacked so each bank is its own array slice;
  // The inner dimension is packed.
  // This shape is what the distributed-RAM extractor recognises per UG901 RAM HDL Coding Techniques
  logic [N_BANK-1:0][CG_BITS-1:0] bank_out;

  genvar gb;
  generate
    for (gb = 0; gb < N_BANK; gb++) begin : gen_bank
      (* RAM_STYLE = "distributed" *) logic [CG_BITS-1:0] mem [STG_ITER_NB];

      // Write: one bank, one address (cnt), one CG_BITS word per cycle.
      always_ff @(posedge clk)
        if (wr_en) mem[cnt] <= wr_in[gb];

      // Read addr = {rg_b, rev_cnt_lo[RG_W-1:0]} where rg_b = (gb - cnt_hi) mod N_BANK.
      // RG_H is a power of two, so "* RG_H + rev_cnt_lo" reduces to a left-shift OR-ed with
      // rev_cnt_lo - pure wiring. Case A (RG_W=0): collapses to rg_b.
      logic [N_BANK_W-1:0]   rg_b;
      logic [STG_ITER_W-1:0] rd_addr_b;
      assign rg_b         = N_BANK_W'(gb) - cnt_hi;
      assign rd_addr_b    = (STG_ITER_W'(rg_b) << RG_W) | rev_cnt_lo;
      assign bank_out[gb] = mem[rd_addr_b];
    end
  endgenerate

  // =========================================================================================== --
  // Step 2 - Stage-1 pipeline
  // =========================================================================================== --
  logic body_pass;
  logic pipe_vld;

  assign body_pass = ~buf_avail & s1_vld & s1_is_body;
  assign s1_rdy    = buf_avail ? 1'b0 : body_pass ? pipe_rdy : 1'b1;
  assign pipe_vld  = buf_avail | body_pass;

  logic [N_BANK-1:0][CG_BITS-1:0] bank_out_q;
  logic [STG_ITER_W-1:0]          cnt_q;
  logic                           body_pass_q;
  logic [MOD_Q_W-1:0]             s1_data_lane0_q;
  logic                           mid1_vld;
  logic                           mid1_rdy;

  // Forward register: cuts the data path between bank read and the output de-skew rotator.
  // Width = N_BANK * CG_BITS + STG_ITER_W + 1 + MOD_Q_W (≈ RD_COEF_NB*MOD_Q_W + STG_ITER_W + 1 + MOD_Q_W).
  fifo_element #(
    .WIDTH          (N_BANK*CG_BITS + STG_ITER_W + 1 + MOD_Q_W),
    .DEPTH          (1),
    .TYPE_ARRAY     (4'h1),
    .DO_RESET_DATA  (1'b0),
    .RESET_DATA_VAL (0)
  ) step2_stage1_pipeline (
    .clk      (clk),
    .s_rst_n  (s_rst_n),

    .in_data  ({bank_out, cnt, body_pass, s1_data[0]}),
    .in_vld   (pipe_vld),
    .in_rdy   (pipe_rdy),

    .out_data ({bank_out_q, cnt_q, body_pass_q, s1_data_lane0_q}),
    .out_vld  (mid1_vld),
    .out_rdy  (mid1_rdy)
  );

  // =========================================================================================== --
  // Output de-skew + lane unpack
  // =========================================================================================== --
  // Recover the row-group index from the pipelined counter, N_BANK_W bits wide.
  logic [N_BANK_W-1:0] cnt_hi_q;
  assign cnt_hi_q = cnt_q[STG_ITER_W-1:RG_W];

  // Output unpack: build one natural-order beat of RD_COEF_NB lanes from the N_BANK bank outputs.
  // Three operations fused as pure wiring + one small adder:
  //   1. Bit-reverse on the low N_BANK_W bits of the lane index (rev_m_lo).
  //      This is the algorithmic reverse-to-natural permutation; rev_m_lo depends only on the
  //      loop index, so it's a compile-time wiring pattern, not a runtime mux.
  //   2. De-skew of the diagonal storage: the bank holding lane m_lo is
  //        band_idx = (rev_m_lo + cnt_hi_q) mod N_BANK (the inverse of the write-side rotation).
  //      Mod is implicit - addition in N_BANK_W bits wraps modulo 2^N_BANK_W = N_BANK.
  //   3. Lane unpack inside the bank entry: m_hi picks one MOD_Q_W slice out of CG_W.
  //
  // Lane index decomposition:  m = m_hi * N_BANK + m_lo
  //   m_lo in [0, N_BANK)  -> chooses a bank (after bit-reverse + de-skew)
  //   m_hi in [0, CG_W)    -> chooses which MOD_Q_W lane within that bank's entry
  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] rd_data;
  logic [N_BANK_W-1:0]                rev_m_lo;
  logic [N_BANK_W-1:0]                band_idx;
  always_comb begin
    rev_m_lo = 'h0;
    band_idx     = 'h0;
    for (int m_lo = 0; m_lo < N_BANK; m_lo++) begin
      for (int b = 0; b < N_BANK_W; b++)
        rev_m_lo[b] = m_lo[N_BANK_W-1-b];
      band_idx = rev_m_lo + cnt_hi_q;
      for (int m_hi = 0; m_hi < CG_W; m_hi++)
        rd_data[m_hi * N_BANK + m_lo] = bank_out_q[band_idx][m_hi*MOD_Q_W +: MOD_Q_W];
    end
  end

  // Body bypass: body scalar lives at flat index 0 (rev(0)=0; step1_data[0] = s0_data[0][0]).
  logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] pipe_data;
  always_comb begin
    pipe_data = 'h0;
    if (body_pass_q) begin
      pipe_data[0] = s1_data_lane0_q;
    end else begin
      pipe_data = rd_data;
    end
  end

// ============================================================================================== --
// Stage 2 pipeline
// TODO: try without and see if it holds
// ============================================================================================== --
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
