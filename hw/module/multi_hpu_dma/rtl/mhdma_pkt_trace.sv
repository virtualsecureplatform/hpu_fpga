// ================================================================================================
// BSD 3-Clause Clear License
// Copyright © 2025 ZAMA. All rights reserved.
// ------------------------------------------------------------------------------------------------
// Description  : Multi-HPU DMA packet-trace debug buffer
//
// Circular capture of decoded packet headers (+ trace_aux side-band) for post-mortem debug.
//
// Capture (clk_mhdma):
//  - Each header_valid strobe writes one entry into a dual-clock RAM. The write pointer wraps
//    and overwrites the oldest entry. An entry holds the decoded header, the trace_aux side-band
//    (FSM state and error bits), and a timestamp.
//  - When an error occurs (error_detected = OR of all mhdma errors), the buffer captures
//    TRACE_TAIL more entries and then freezes. The frozen buffer holds ~TRACE_DEPTH/2 headers
//    from before the error and ~TRACE_TAIL headers from after it.
//    A timeout (TRACE_TAIL_TIMEOUT clk_mhdma cycles) forces the freeze if RX traffic stops
//    after the error and the tail does not fill.
//  - SW can force a freeze at any time (trace_freeze). After a SW freeze, before/after
//    split above does not apply.
//
// Readout (clk_mhdma_cfg): after the freeze, the RAM is static.
//    The regif reads the RAM through the cfg-clock read port.
//    The read pointer increments on each read (pop-on-read, one 32-bit word for each regif read).
//    A re-arm strobe (trace_arm) resets the pointers and starts the capture again.
//
// NOTEs:
//  * the wptr/wrapped CDC is safe only because trace_wptr_q/trace_wrapped_q are static by the time they are published.
//  * re-arm resets the pointers/counters but does NOT clear the RAM.
//
// ================================================================================================

module mhdma_pkt_trace
  import mhdma_pkg::*;             // multi-hpu-dma
  import axi_if_shell_axil_pkg::*; // REG_DATA_W
(
  // Capture side (clk_mhdma) ---------------------------------------------------------------------
  input  logic                     clk_mhdma,
  input  logic                     resetn_mhdma,
  input  logic                     header_valid,   // 1-cycle strobe: one decoded header to capture
  input  command_t                 header_data,    // decoded header (FIFO push, pre-buffer)
  input  logic                     error_detected, // OR of all mhdma errors. It starts the tail capture window
  input  logic [TRACE_AUX_W-1:0]   trace_aux,      // per-entry side-band: {FSM state, errors}
  // Readout / control side (clk_mhdma_cfg) -------------------------------------------------------
  input  logic                     clk_mhdma_cfg,
  input  logic                     resetn_mhdma_cfg,
  input  logic                     trace_arm,      // 1-cycle strobe: reset the pointers and re-arm the capture
  input  logic                     trace_freeze,   // 1-cycle strobe: SW requests a freeze
  input  logic                     trace_rd_en,    // 1-cycle strobe: pop one 32-bit trace word
  output logic [REG_DATA_W-1:0]    trace_rd_data,  // current trace word
  output logic                     trace_frozen,   // capture is frozen (synchronized to cfg)
  output logic [TRACE_AW-1:0]      trace_wptr,     // write pointer at freeze: the oldest entry if wrapped, else the next free slot
  output logic                     trace_wrapped   // 1 = the ring wrapped and all TRACE_DEPTH entries are valid. 0 = only [0 .. wptr-1] are valid
);

  // =========================================================================================== //
  // Localparam
  // =========================================================================================== //
  localparam int TRACE_CDC_STAGES = 4;

  // Timeout (in clk_mhdma cycles): force the freeze this long after the trigger if the tail
  // window never fills (e.g. RX traffic stops after the error)
  localparam int TRACE_TAIL_TIMEOUT    = 1024;
  localparam int TRACE_TAIL            = TRACE_DEPTH / 2; // entries captured after the trigger
  localparam int TRACE_TAIL_AW         = $clog2(TRACE_TAIL + 1);
  localparam int TRACE_TAIL_TIMEOUT_AW = $clog2(TRACE_TAIL_TIMEOUT + 1);

  // Freeze margin: keep trace_frozen_q low for this many clk_mhdma cycles after trace_tail_done.
  localparam int TRACE_FREEZE_MARGIN   = TRACE_CDC_STAGES;
  localparam int TRACE_FREEZE_CNT_W    = $clog2(TRACE_FREEZE_MARGIN + 1);

  localparam int TRACE_TS_W  = REG_DATA_W - TRACE_AUX_W; // the timestamp uses the remaining bits of the last word (it wraps)

  localparam int TRACE_W        = $bits(command_t) + TRACE_AUX_W + TRACE_TS_W;
  localparam int TRACE_WORDS    = TRACE_W / REG_DATA_W;
  localparam int TRACE_WORD_AW  = $clog2(TRACE_WORDS);
  localparam int TRACE_RD_PTR_W = TRACE_AW + TRACE_WORD_AW;   // {entry, word} read pointer width

  // pragma translate_off
  initial begin
    assert (TRACE_DEPTH == (1 << TRACE_AW))
    else $error("[ERROR]: TRACE_DEPTH (%0d) must be a power of 2", TRACE_DEPTH);
    assert ((TRACE_W % REG_DATA_W) == 0)
    else $error("[ERROR]: TRACE_W (%0d) must be a multiple of REG_DATA_W (%0d)", TRACE_W, REG_DATA_W);
    assert (TRACE_AUX_W < REG_DATA_W)
    else $error("[ERROR]: TRACE_AUX_W (%0d) must be < REG_DATA_W (%0d)", TRACE_AUX_W, REG_DATA_W);
  end
  // pragma translate_on

  // Synthesis-visible elaboration guard ----------------------------------------------------------
  // TRACE_TS_W = REG_DATA_W - TRACE_AUX_W must leave at least one timestamp bit.
  if (TRACE_TS_W < 1) begin : gen_trace_ts_w_illegal
    $fatal(1, "[ERROR]: TRACE_TS_W (%0d) < 1: TRACE_AUX_W (%0d) leaves no timestamp bits in REG_DATA_W (%0d); reduce ETH_PC/PEM_PC", TRACE_TS_W, TRACE_AUX_W, REG_DATA_W);
  end

  // =========================================================================================== //
  // ARMING TRACE
  // =========================================================================================== //
  // Re-arm strobe --------------------------------------------------------------------------------
  logic trace_arm_mhdma;
  logic trace_arm_mhdma_q;
  logic trace_rearm; // 1-cycle clk_mhdma re-arm pulse

  // SRC_INPUT_REG=1: trace_arm/trace_freeze are combinational decodes (wr_en & frozen bit)
  // The src-side flop filters the decode glitch before the synchronizer.
  xpm_cdc_single_wrapper #(
    .CDC_SYNC_STAGES (TRACE_CDC_STAGES),
    .SRC_INPUT_REG   (1               )
  ) cdc_trace_arm (
    .src_clk  (clk_mhdma_cfg  ),
    .dest_clk (clk_mhdma      ),
    .src_in   (trace_arm      ),
    .dest_out (trace_arm_mhdma)
  );

  always_ff @(posedge clk_mhdma) begin
    if (~resetn_mhdma) trace_arm_mhdma_q <= 1'b0;
    else               trace_arm_mhdma_q <= trace_arm_mhdma;
  end

  assign trace_rearm = trace_arm_mhdma & ~trace_arm_mhdma_q;

  // SW freeze strobe (cfg -> mhdma) --------------------------------------------------------------
  logic trace_freeze_mhdma;
  logic trace_freeze_mhdma_q;
  logic trace_sw_freeze_q; // sticky: SW requested a freeze (a re-arm clears it)

  xpm_cdc_single_wrapper #(
    .CDC_SYNC_STAGES (TRACE_CDC_STAGES),
    .SRC_INPUT_REG   (1               )
  ) cdc_trace_freeze (
    .src_clk  (clk_mhdma_cfg     ),
    .dest_clk (clk_mhdma         ),
    .src_in   (trace_freeze      ),
    .dest_out (trace_freeze_mhdma)
  );

  always_ff @(posedge clk_mhdma) begin
    if (~resetn_mhdma) trace_freeze_mhdma_q <= 1'b0;
    else               trace_freeze_mhdma_q <= trace_freeze_mhdma;
  end

  always_ff @(posedge clk_mhdma) begin
    if      (~resetn_mhdma)                              trace_sw_freeze_q <= 1'b0;
    else if (trace_rearm)                                trace_sw_freeze_q <= 1'b0;
    else if (trace_freeze_mhdma & ~trace_freeze_mhdma_q) trace_sw_freeze_q <= 1'b1;
  end

  // Compute timestamp (clk_mhdma) ------------------------------------------------------------------------
  logic [TRACE_TS_W-1:0] trace_timestamp;

  // The free-running timestamp gives the relative time between captured headers.
  always_ff @(posedge clk_mhdma) begin
    if (~resetn_mhdma)    trace_timestamp <= '0;
    else if (trace_rearm) trace_timestamp <= '0;
    else                  trace_timestamp <= trace_timestamp + 1'b1;
  end

  // =========================================================================================== //
  // Write: capture window
  // =========================================================================================== //
  // capture-side (clk_mhdma) signals
  logic                             trace_triggered_q;  // an error started the tail capture window
  logic [TRACE_TAIL_AW-1:0]         trace_tail_cnt;     // remaining tail entries to capture
  logic [TRACE_TAIL_TIMEOUT_AW-1:0] trace_timeout_cnt;  // tail timeout counter
  logic                             trace_tail_filled;  // all tail entries captured after the trigger
  logic                             trace_tail_timeout; // the tail timeout expired
  logic                             trace_err_freeze;   // error-triggered freeze request
  logic                             trace_tail_done;
  logic [TRACE_FREEZE_CNT_W-1:0]    trace_freeze_cnt;  // cycles since trace_tail_done (freeze margin)
  logic                             trace_frozen_q;
  logic [TRACE_AW-1:0]              trace_wptr_q;
  logic                             trace_wrapped_q;   // set when the write pointer wraps in this session
  logic                             trace_we;
  logic [TRACE_W-1:0]               trace_wr_data;

  always_ff @(posedge clk_mhdma) begin
    if (~resetn_mhdma)       trace_triggered_q <= 1'b0;
    else if (trace_rearm)    trace_triggered_q <= 1'b0;
    else if (error_detected) trace_triggered_q <= 1'b1;
  end

  // The tail counter decrements for each captured tail entry.
  always_ff @(posedge clk_mhdma) begin
    if (~resetn_mhdma)    trace_tail_cnt <= TRACE_TAIL_AW'(TRACE_TAIL);
    else if (trace_rearm) trace_tail_cnt <= TRACE_TAIL_AW'(TRACE_TAIL);
    else if (trace_triggered_q & trace_we & (trace_tail_cnt != 0)) trace_tail_cnt <= trace_tail_cnt - 1'b1;
  end

  assign trace_tail_filled = (trace_tail_cnt == 0);

  // Tail timeout counter (it saturates).
  always_ff @(posedge clk_mhdma) begin
    if (~resetn_mhdma) begin
      trace_timeout_cnt <= '0;
    end else begin
      if (trace_rearm) begin
        trace_timeout_cnt <= '0;
      end else if (trace_triggered_q & ~trace_frozen_q & ~trace_tail_timeout) begin
        trace_timeout_cnt <= trace_timeout_cnt + 1'b1;
      end
    end
  end

  assign trace_tail_timeout = (trace_timeout_cnt == TRACE_TAIL_TIMEOUT_AW'(TRACE_TAIL_TIMEOUT));

  assign trace_err_freeze = trace_triggered_q & (trace_tail_filled | trace_tail_timeout);
  assign trace_tail_done  = trace_sw_freeze_q | trace_err_freeze;

  // Freeze margin --------------------------------------------------------------------------------
  // trace_wptr_q and trace_wrapped_q must be static for at least the synchronizer depth before
  // trace_frozen_q asserts. Then the cfg-side sample of wptr/wrapped always sees stable values.
  always_ff @(posedge clk_mhdma) begin
    if (~resetn_mhdma) begin
      trace_freeze_cnt <= '0;
    end else if (trace_rearm) begin
      trace_freeze_cnt <= '0;
    end else if (trace_tail_done & (trace_freeze_cnt != TRACE_FREEZE_CNT_W'(TRACE_FREEZE_MARGIN))) begin
      trace_freeze_cnt <= trace_freeze_cnt + 1'b1;
    end
  end

  always_ff @(posedge clk_mhdma) begin
    if (~resetn_mhdma)    begin
      trace_frozen_q <= 1'b0;
    end else if (trace_rearm) begin
      trace_frozen_q <= 1'b0;
    end else if (trace_tail_done & (trace_freeze_cnt == TRACE_FREEZE_CNT_W'(TRACE_FREEZE_MARGIN))) begin
      trace_frozen_q <= 1'b1;
    end
  end

  // Write one entry for each header push. Stop at freeze and at trace_tail_done, so the tail
  // holds at most TRACE_TAIL entries (fewer on a timeout or a SW freeze).
  assign trace_we = header_valid & ~trace_frozen_q & ~trace_tail_done;

  // The write pointer wraps and overwrites the oldest entry, so at freeze it points to the oldest entry.
  always_ff @(posedge clk_mhdma) begin
    if (~resetn_mhdma)    trace_wptr_q <= '0;
    else if (trace_rearm) trace_wptr_q <= '0;
    else if (trace_we)    trace_wptr_q <= trace_wptr_q + 1'b1;
  end

  // trace wrapping -------------------------------------------------------------------------------
  // A re-arm does not clear the RAM. Before the first wrap, only entries [0 .. wptr-1] hold
  // data from this session. The other entries hold stale data from a previous capture.
  // Software uses trace_wrapped to know if it must rotate the full ring or read only [0 .. wptr-1].
  always_ff @(posedge clk_mhdma) begin
    if (~resetn_mhdma)                                      trace_wrapped_q <= 1'b0;
    else if (trace_rearm)                                   trace_wrapped_q <= 1'b0;
    else if (trace_we & (trace_wptr_q == {TRACE_AW{1'b1}})) trace_wrapped_q <= 1'b1;
  end

  assign trace_wr_data = {trace_timestamp, trace_aux, header_data};

  // =========================================================================================== //
  // Read pointer (clk_mhdma_cfg)
  // =========================================================================================== //
  logic [TRACE_RD_PTR_W-1:0] trace_rd_ptr;
  logic [TRACE_WORD_AW-1:0]  trace_word_sel_q;

  // The read pointer increments only while the trace is frozen.
  // Before the freeze, the RAM is not stable.
  always_ff @(posedge clk_mhdma_cfg) begin
    if (~resetn_mhdma_cfg)                trace_rd_ptr <= '0;
    else if (trace_arm)                   trace_rd_ptr <= '0;
    else if (trace_rd_en & trace_frozen)  trace_rd_ptr <= trace_rd_ptr + 1'b1;
  end

  // Delay the word-select by 1 cfg cycle to match the SDPRAM READ_LATENCY=1
  always_ff @(posedge clk_mhdma_cfg) begin
    if (~resetn_mhdma_cfg) trace_word_sel_q <= '0;
    else                   trace_word_sel_q <= trace_rd_ptr[TRACE_WORD_AW-1:0];
  end

  // =========================================================================================== //
  // Dual-clock RAM
  // =========================================================================================== //
  logic [TRACE_W-1:0] trace_rd_entry;

  // NOTE: it is mandatory for the IP to be a BRAM
  xpm_mem_sdpram_wrapper #(
    .DATA_W           (TRACE_W    ),
    .DEPTH            (TRACE_DEPTH),
    .READ_LATENCY     (1          ),
    .MEMORY_PRIMITIVE ("block"    )
  ) trace_ram (
    // clk_mhdma write port
    .wr_clk  (clk_mhdma                                       ),
    .wr_en   (trace_we                                        ),
    .wr_addr (trace_wptr_q                                    ),
    .wr_data (trace_wr_data                                   ),
    // clk_mhdma_cfg read port
    .rd_clk  (clk_mhdma_cfg                                   ),
    .rd_rstn (resetn_mhdma_cfg                                ),
    .rd_en   (1'b1                                            ),
    .rd_addr (trace_rd_ptr[TRACE_RD_PTR_W-1:TRACE_WORD_AW]    ), // entry index
    .rd_data (trace_rd_entry                                  )
  );

  // Return zero when the trace is not frozen.
  assign trace_rd_data = trace_frozen ? trace_rd_entry[trace_word_sel_q*REG_DATA_W +: REG_DATA_W] : '0;

  // =========================================================================================== //
  // Status CDC
  // =========================================================================================== //
  // Each signal crosses on its own synchronizer. The freeze margin makes trace_wptr_q static
  // before trace_frozen_q asserts, so the cfg side samples a coherent wptr while frozen is high.
  logic                frozen_cfg;          // synced frozen
  logic                frozen_cfg_q;        // +1 cfg-cycle delay (publish stage)
  logic [TRACE_AW-1:0] wptr_cfg;            // synced wptr (static while frozen)
  logic                wrapped_cfg;         // synced wrapped flag (static while frozen)
  logic                frozen_clr_pending;  // masks stale frozen after re-arm

  // frozen and wrapped are single-bit status signals. Each bit crosses on its own single-bit
  // synchronizer. Inter-bit coherency is not necessary because both bits are static when the
  // cfg side samples frozen.
  localparam int TRACE_ST_W       = 2;
  localparam int TRACE_ST_FROZEN  = 0;
  localparam int TRACE_ST_WRAPPED = 1;
  logic [TRACE_ST_W-1:0] trace_st_src; // {wrapped, frozen} in clk_mhdma
  logic [TRACE_ST_W-1:0] trace_st_cfg; // synced into clk_mhdma_cfg

  assign trace_st_src[TRACE_ST_FROZEN]  = trace_frozen_q;
  assign trace_st_src[TRACE_ST_WRAPPED] = trace_wrapped_q;

  for (genvar i = 0; i < TRACE_ST_W; i++) begin : gen_cdc_trace_status
    xpm_cdc_single_wrapper #(
      .CDC_SYNC_STAGES (TRACE_CDC_STAGES),
      .SRC_INPUT_REG   (1               )
    ) cdc_trace_status (
      .src_clk  (clk_mhdma        ),
      .dest_clk (clk_mhdma_cfg    ),
      .src_in   (trace_st_src[i]  ),
      .dest_out (trace_st_cfg[i]  )
    );
  end

  assign frozen_cfg  = trace_st_cfg[TRACE_ST_FROZEN];
  assign wrapped_cfg = trace_st_cfg[TRACE_ST_WRAPPED];

  // wptr is multi-bit but static once frozen, so array-single is safe (and stops report_cdc
  // flagging a per-bit sync on a bus).
  xpm_cdc_array_single_wrapper #(
    .WIDTH           (TRACE_AW       ),
    .CDC_SYNC_STAGES (TRACE_CDC_STAGES)
  ) cdc_trace_wptr (
    .src_clk  (clk_mhdma   ),
    .dest_clk (clk_mhdma_cfg),
    .src_in   (trace_wptr_q),
    .dest_out (wptr_cfg     )
  );

  // After a re-arm, frozen_cfg holds the stale frozen value of the previous capture for a few
  // cycles. frozen_clr_pending masks the published frozen until the stale value clears.
  always_ff @(posedge clk_mhdma_cfg) begin
    if (~resetn_mhdma_cfg) frozen_clr_pending <= 1'b0;
    else if (trace_arm)    frozen_clr_pending <= 1'b1;
    else if (~frozen_cfg)  frozen_clr_pending <= 1'b0;
  end

  always_ff @(posedge clk_mhdma_cfg) begin
    if (~resetn_mhdma_cfg) begin
      frozen_cfg_q  <= 1'b0;
      trace_frozen  <= 1'b0;
      trace_wptr    <= '0;
      trace_wrapped <= 1'b0;
    end else begin
      frozen_cfg_q <= frozen_cfg;
      // publish frozen 1 cycle later; held low while a re-arm is still flushing the stale frozen
      trace_frozen <= frozen_cfg_q & ~frozen_clr_pending;
      if (frozen_cfg) begin              // wptr/wrapped stable while frozen
        trace_wptr    <= wptr_cfg;
        trace_wrapped <= wrapped_cfg;
      end
    end
  end

endmodule
