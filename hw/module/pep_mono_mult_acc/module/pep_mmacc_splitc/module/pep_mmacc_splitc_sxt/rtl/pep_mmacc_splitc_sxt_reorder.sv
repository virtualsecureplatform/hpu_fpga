// ==============================================================================================
// BSD 3-Clause Clear License
// Copyright © 2025 ZAMA. All rights reserved.
// ----------------------------------------------------------------------------------------------
// Description  : Reorder module for sample extract.
// ----------------------------------------------------------------------------------------------
// This module has been made for Xilinx FPGA only : its architecture has been chosen depending
// on V80 resource usage we had avail. This module has constraints embedded in the file.
//
// Converts from bit-reversed to natural coefficient order (see sw/monomial_mult/mm_reorder.py).
//
// Step 1: bit-reversal within each R*PSI chunk (RD_COEF_W bits)
// Step 2: transpose + bit-reversal on the stage-iteration index (STG_ITER_W bits)
//
// Body beats bypass the buffer (single scalar, no reorder needed).
//
// For understanding this module see python file sw/monomial_mult/mm_reorder.py.
// ==============================================================================================

// without keep_hierarchy vivado retimes some registers (s1_data) and ends up deleting all logic
(* keep_hierarchy = "yes" *)
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

  // direct translation from python step1 to RTL (pure wiring)
  generate
    for (genvar i = 0; i < RD_COEF_NB; i++) begin : gen_step1
      localparam logic [RD_COEF_W-1:0] REV_I = { << {RD_COEF_W'(i)} }; // reverse(x, RD_COEF_W)
      assign step1_data[i] = in_data_flat[REV_I];
    end
  endgenerate

  // =========================================================================================== --
  // Step 1 pipeline
  // Register step1_data close to the bank-mem write rotator.
  // Without this stage the bit-reversed data (RD_COEF_NB*MOD_Q_W bits) broadcasts combinationally
  // into the sinks. Resulting routing star limits placement freedom for the buffer.
  // =========================================================================================== --
  // Keep is mandatory : Vivado will remove this signal & this leads to catastrophic failure
  (* keep = "true" *) logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] s1_data;
  logic                                                   s1_is_body;
  logic                                                   s1_vld;
  logic                                                   s1_rdy;

  fifo_element #(
    .WIDTH          (RD_COEF_NB * MOD_Q_W + 1), // +1 for is_body
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
  // To help placement we write data into LUTRAMs : this module resides in SLR2 which is crowded.
  // Bodies bypass the buffer: while filling a mask group (~buf_avail), a body beat may arrive at
  // any cnt in [0..STG_ITER_NB-1].
  // =========================================================================================== --
  // Control --------------------------------------------------------------------------------------
  logic                  buf_avail; // 0 = write phase, 1 = read phase
  logic                  pipe_rdy;  // Pre-pipe ready: controls buffer drain rate
  logic [STG_ITER_W-1:0] cnt;       // shared counter for write and read phases
  logic                  cnt_last;
  logic                  wr_en;
  logic                  rd_en;

  assign wr_en = ~buf_avail & s1_vld & ~s1_is_body;
  assign rd_en =  buf_avail & pipe_rdy;
  assign cnt_last = (cnt == STG_ITER_W'(STG_ITER_NB - 1));

  always_ff @(posedge clk) begin
    if (~s_rst_n) begin
      cnt       <= 'h0;
      buf_avail <= 1'b0;
    end else if (wr_en | rd_en) begin
      cnt       <= cnt_last ? 'h0 : cnt + STG_ITER_W'(1);
      buf_avail <= cnt_last ? ~buf_avail : buf_avail;
    end
  end

  // Slice the shared counter:
  //   cnt_hi     = cnt[STG_ITER_W-1:RG_W] - drives the write/read rotator, N_BANK_W bits (cnt_hi in [0, N_BANK)).
  //   rev_cnt_lo = rev(cnt[RG_W-1:0])     - offset within the row-group for read address, RG_W bits.
  // REV_CNT_LO_W clamps to >=1 so the type is legal when RG_W=0 (RD_COEF_NB >= STG_ITER_NB);
  // in that case rev_cnt_lo is a dummy 1-bit zero that zero-extends harmlessly into rd_addr_b.
  localparam int REV_CNT_LO_W = (RG_W == 0) ? 1 : RG_W;
  logic [N_BANK_W-1:0]     cnt_hi;
  logic [REV_CNT_LO_W-1:0] rev_cnt_lo;

  assign cnt_hi = cnt[STG_ITER_W-1:RG_W];

  generate
    if (RG_W > 0) assign rev_cnt_lo = { << {cnt[RG_W-1:0]} };
    else          assign rev_cnt_lo = 'h0;
  endgenerate

  // Datapath -------------------------------------------------------------------------------------
  // Reinterpret the registered input row as N_BANK col-groups (CG_BITS each).
  logic [N_BANK-1:0][CG_BITS-1:0] s1_cg;

  assign s1_cg = s1_data;

  // Write rotator: wr_in[b] = s1_cg[(b - cnt_hi) mod N_BANK].
  // Subtraction in N_BANK_W bits wraps modulo 2^N_BANK_W = N_BANK (N_BANK is a power of two), so
  // no explicit modulo. Parameter check of this constraint is in the guardrails.
  // Synthesised as a log-stage barrel on N_BANK CG_BITS-wide lanes.
  logic [N_BANK-1:0][CG_BITS-1:0] wr_in;
  generate
    for (genvar b = 0; b < N_BANK; b++) begin : gen_wr_rot
      assign wr_in[b] = s1_cg[N_BANK_W'(b) - cnt_hi];
    end
  endgenerate

  // Per-bank single-port LUTRAM - Bank-skewed transpose buffer
  // The outer dimension is unpacked so each bank is its own array slice;
  // The inner dimension is packed.
  // This shape is what the distributed-RAM extractor recognises per UG901 RAM HDL Coding Techniques
  (* keep = "true" *) logic [N_BANK-1:0][CG_BITS-1:0] bank_out;

  generate
    for (genvar gb = 0; gb < N_BANK; gb++) begin : gen_bank
      (* RAM_STYLE = "distributed" *) logic [CG_BITS-1:0] mem [STG_ITER_NB];

      // Write: one bank, one address (cnt), one CG_BITS word per cycle.
      always_ff @(posedge clk)
        if (wr_en) mem[cnt] <= wr_in[gb];

      // Read addr = (rg_b << RG_W) | rev_cnt_lo where rg_b = (gb - cnt_hi) mod N_BANK.
      // RG_H is a power of two, so "* RG_H + rev_cnt_lo" reduces to a left-shift OR-ed with rev_cnt_lo.
      logic [N_BANK_W-1:0]   rg_b;
      logic [STG_ITER_W-1:0] rd_addr_b;

      assign rg_b         = N_BANK_W'(gb) - cnt_hi;
      assign rd_addr_b    = (STG_ITER_W'(rg_b) << RG_W) | STG_ITER_W'(rev_cnt_lo);
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
  logic [N_BANK_W-1:0]            cnt_hi_q;
  logic                           body_pass_q;
  logic [MOD_Q_W-1:0]             s1_data_lane0_q;
  logic                           mid1_vld;
  logic                           mid1_rdy;

  // Forward register: cuts the data path between bank read and the output de-skew rotator.
  // Only cnt_hi (N_BANK_W bits) is consumed downstream, so the low RG_W bits of cnt are not piped.
  // Width = N_BANK * CG_BITS + N_BANK_W + 1 + MOD_Q_W (= RD_COEF_NB*MOD_Q_W + N_BANK_W + 1 + MOD_Q_W).
  fifo_element #(
    .WIDTH          (N_BANK*CG_BITS + N_BANK_W + 1 + MOD_Q_W),
    .DEPTH          (1),
    .TYPE_ARRAY     (4'h1),
    .DO_RESET_DATA  (1'b0),
    .RESET_DATA_VAL (0)
  ) step2_stage1_pipeline (
    .clk      (clk),
    .s_rst_n  (s_rst_n),

    .in_data  ({bank_out, cnt_hi, body_pass, s1_data[0]}),
    .in_vld   (pipe_vld),
    .in_rdy   (pipe_rdy),

    .out_data ({bank_out_q, cnt_hi_q, body_pass_q, s1_data_lane0_q}),
    .out_vld  (mid1_vld),
    .out_rdy  (mid1_rdy)
  );

  // =========================================================================================== --
  // Output de-skew + lane unpack
  // =========================================================================================== --
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

  generate
    for (genvar m_lo = 0; m_lo < N_BANK; m_lo++) begin : gen_out_unpack
      localparam logic [N_BANK_W-1:0] REV_M_LO = { << {N_BANK_W'(m_lo)} };
      logic [N_BANK_W-1:0] band_idx;
      assign band_idx = REV_M_LO + cnt_hi_q;
      for (genvar m_hi = 0; m_hi < CG_W; m_hi++) begin : gen_lane
        assign rd_data[m_hi * N_BANK + m_lo] = bank_out_q[band_idx][m_hi*MOD_Q_W +: MOD_Q_W];
      end
    end
  endgenerate

  // Body bypass: body scalar lives at flat index 0 (rev(0)=0; step1_data[0] = s0_data[0][0]).
  // Piped path on body: s0_data[0][0] -> step1_data[0] -> s1_data[0] -> (mid pipe) -> s1_data_lane0_q.
  (* DONT_TOUCH = "TRUE" *) logic [RD_COEF_NB-1:0][MOD_Q_W-1:0] pipe_data;

  always_comb begin
    pipe_data = 'h0;
    if (body_pass_q) begin
      pipe_data[0] = s1_data_lane0_q;
    end else begin
      pipe_data = rd_data;
    end
  end

// ============================================================================================== --
// Output pipe
// ============================================================================================== --
// Backward register (type 2) only: cuts just the rdy backpressure path, which is the/ timing-critical one here.
// Keep it control-only: a forward register on the data path was tried (depth-2, type {1,2}) and made TNS ~50% worse. do not re-add it.
  fifo_element #(
    .WIDTH          (RD_COEF_NB * MOD_Q_W + 1),
    .DEPTH          (1),
    .TYPE_ARRAY     (4'h2),
    .DO_RESET_DATA  (1'b0),
    .RESET_DATA_VAL (0)
  ) out_pipe (
    .clk      (clk),
    .s_rst_n  (s_rst_n),

    .in_data  ({body_pass_q, pipe_data}),
    .in_vld   (mid1_vld),
    .in_rdy   (mid1_rdy),

    .out_data ({out_is_body, out_data}),
    .out_vld  (out_vld),
    .out_rdy  (out_rdy)
  );

endmodule
