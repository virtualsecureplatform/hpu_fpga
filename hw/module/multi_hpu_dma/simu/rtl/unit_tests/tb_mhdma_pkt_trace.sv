// ==============================================================================================
// BSD 3-Clause Clear License
// Copyright (c) 2025 ZAMA. All rights reserved.
// ----------------------------------------------------------------------------------------------
// Description  : Unit testbench for mhdma_pkt_trace
//
// mhdma_pkt_trace is the packet-trace debug buffer: a circular capture of decoded packet headers
// that freezes around the first mhdma error, and read out word-by-word over the (slow) cfg clock.
//
// Two clock domains:
//   > clk_mhdma     (fast) : capture side  - header_valid/header_data/error_detected/trace_aux
//   > clk_mhdma_cfg (slow) : readout/ctrl  - trace_arm/trace_rd_en/trace_rd_data/frozen/wptr
//
// Scenarios:
//   > default_all_headers : X packets of all 4 command types, no error -> never freezes
//   > error_timeout       : error then traffic stops -> freeze via timeout backstop
//   > partial_tail_timeout: error + a few (< tail) post writes then stop -> timeout, full & partial
//   > error_restart       : overwrite ring, sticky trigger, full readback, re-arm (x N, de-glitch)
//   > sustained_traffic   : error mid-stream while pushing -> exactly TRACE_TAIL tail, half/half
//   > reset_underfill     : reset, then empty / under-filled ring
//   > rearm_sticky_error  : re-arm with error still asserted -> immediate re-trigger
//   > coincident_error    : error_detected on the same edge as a header push (real overflow trigger)
//   > full_throughput     : header_valid held high on consecutive cycles -> one write/cycle, exact tail
//   > wrapped_boundary    : exactly DEPTH-1 (partial, wrapped=0) vs DEPTH (full, wrapped=1) writes
//   > sw_freeze           : software freeze (no error, no tail) -> freezes on demand, partial & full ring
//   > sw_freeze_midstream : software freeze issued WHILE capture traffic is live (gates trace_we mid-write)
//   > sw_freeze_during_tail: software freeze pre-empts an error tail still counting down
//
// Every freeze point also checks trace_wrapped (ring-filled flag): it must be 1 iff >= TRACE_DEPTH
// headers were captured this session (rotate-by-wptr full ring) and 0 for a partial fill.
//
// Simulation timeout: SIM_TIMEOUT.
// ==============================================================================================

`resetall
`timescale 1ns/10ps
module tb_mhdma_pkt_trace;
  import mhdma_pkg::*;
  import axi_if_shell_axil_pkg::*;
  import axi_if_common_param_pkg::*;
  import axi_if_mhdma_axi_pkg::*;
  import pem_common_param_pkg::*;

  `include "tb_mhdma_tasks.sv"

// ============================================================================================== --
// localparam
// ============================================================================================== --
  localparam int CLK_HALF_PERIOD_MHDMA = 1;  // fast capture clock
  localparam int CLK_HALF_PERIOD_CFG   = 4;  // slow cfg clock (matches tb_mhdma_errors ratio)
  localparam int ARST_ACTIVATION       = 17;
  localparam int SIM_TIMEOUT           = 2_000_000;

  // Trace geometry (mirror of the DUT localparams; TRACE_DEPTH/AW/AUX_W come from mhdma_pkg).
  localparam int TRACE_TAIL         = TRACE_DEPTH / 2;          // entries captured after the trigger
  localparam int TRACE_TAIL_TIMEOUT = 1024;                     // (clk_mhdma) cycles (DUT backstop)
  localparam int TRACE_TS_W         = REG_DATA_W - TRACE_AUX_W; // timestamp width (narrow, wraps)
  localparam int TRACE_W            = $bits(command_t) + TRACE_AUX_W + TRACE_TS_W;
  localparam int TRACE_WORDS        = TRACE_W / REG_DATA_W;     // 32-bit words per entry (=4)
  localparam int header_W              = $bits(command_t);

  // Enough cfg cycles to cover the timeout backstop (1024 mhdma cycles) plus CDC/publish latency.
  localparam int FREEZE_WAIT_CFG = (TRACE_TAIL_TIMEOUT * CLK_HALF_PERIOD_MHDMA) / CLK_HALF_PERIOD_CFG + 200;
  // The timeout expressed in cfg cycles (~256 at the 4:1 ratio). A window safely BELOW it: if the
  // buffer freezes within this window after a trigger with no post-traffic, the timeout terminal
  // compare fired too early (premature saturation / off-by-one). Deterministic, no model needed.
  localparam int TIMEOUT_CFG        = (TRACE_TAIL_TIMEOUT * CLK_HALF_PERIOD_MHDMA) / CLK_HALF_PERIOD_CFG;
  localparam int TIMEOUT_EARLY_WIN  = (TIMEOUT_CFG * 3) / 4;   // ~3/4 of the timeout, safely early
  // SW freeze latency (arm/freeze CDC + freeze margin + status publish CDC): tens of cfg cycles, and
  // safely below TIMEOUT_CFG so a freeze within this bound can only be the SW path (no error asserted).
  localparam int FREEZE_SW_WAIT_CFG = 100;

// ============================================================================================== --
// clocks
// ============================================================================================== --
  bit clk_mhdma;
  bit clk_mhdma_cfg;

  initial clk_mhdma     = 1'b0;
  initial clk_mhdma_cfg = 1'b0;

  always #CLK_HALF_PERIOD_MHDMA clk_mhdma     = ~clk_mhdma;
  always #CLK_HALF_PERIOD_CFG   clk_mhdma_cfg = ~clk_mhdma_cfg;

// ============================================================================================== --
// reset (controllable so a scenario can force a fresh reset)
// ============================================================================================== --
  bit arst_n;          // asynchronous reset (drives both domains)
  bit resetn_mhdma;    // synchronous reset, mhdma domain
  bit resetn_mhdma_cfg;// synchronous reset, cfg domain

  initial begin
    arst_n = 1'b0;
    #ARST_ACTIVATION arst_n = 1'b1;
  end

  always_ff @(posedge clk_mhdma)     resetn_mhdma     <= arst_n;
  always_ff @(posedge clk_mhdma_cfg) resetn_mhdma_cfg <= arst_n;

  // Pulse a full reset on both domains (used by reset_underfill).
  task automatic pulse_reset();
    begin
      arst_n = 1'b0;
      repeat (5) @(posedge clk_mhdma);
      repeat (5) @(posedge clk_mhdma_cfg);
      arst_n = 1'b1;
      repeat (5) @(posedge clk_mhdma);
      repeat (5) @(posedge clk_mhdma_cfg);
    end
  endtask

// ============================================================================================== --
// End of test / global timeout
// ============================================================================================== --
  bit end_of_test;

  initial begin
    wait (end_of_test);
    @(posedge clk_mhdma_cfg) $display("%t > SUCCEED !", $time);
    $finish;
  end

  initial begin
    #SIM_TIMEOUT;
    $display("%t > TIMEOUT: simulation did not complete in time!", $time);
    $finish;
  end

// ============================================================================================== --
// Error aggregation
// ============================================================================================== --
  bit error;
  bit error_frozen;   // freeze / de-glitch / no-false-freeze
  bit error_wptr;     // write pointer at freeze
  bit error_wrapped;  // ring-filled (wrapped) flag at freeze
  bit error_content;  // read-back header / aux mismatch
  bit error_order;    // oldest->newest ordering (rotation by wptr)
  bit error_ts;       // timestamp delta / wrap
  bit error_tail;     // tail length (half/half)
  bit error_assert;   // concurrent SVA violation (white-box invariants)

  assign error = error_frozen | error_wptr | error_wrapped | error_content | error_order | error_ts | error_tail | error_assert;

  always_ff @(posedge clk_mhdma_cfg)
    if (error) begin
      $display("%t > FAILURE !", $time);
      $finish;
    end

// ============================================================================================== --
// DUT
// ============================================================================================== --
  logic                   header_valid;
  command_t               header_data;
  logic                   error_detected;
  logic [TRACE_AUX_W-1:0] trace_aux;

  logic                   trace_arm;
  logic                   trace_freeze;
  logic                   trace_rd_en;
  logic [REG_DATA_W-1:0]  trace_rd_data;
  logic                   trace_frozen;
  logic [TRACE_AW-1:0]    trace_wptr;
  logic                   trace_wrapped;

  mhdma_pkt_trace dut (
    // capture side (clk_mhdma)
    .clk_mhdma        (clk_mhdma       ),
    .resetn_mhdma     (resetn_mhdma    ),
    .header_valid     (header_valid    ),
    .header_data      (header_data     ),
    .error_detected   (error_detected  ),
    .trace_aux        (trace_aux       ),
    // readout / control side (clk_mhdma_cfg)
    .clk_mhdma_cfg    (clk_mhdma_cfg   ),
    .resetn_mhdma_cfg (resetn_mhdma_cfg),
    .trace_arm        (trace_arm       ),
    .trace_freeze     (trace_freeze    ),
    .trace_rd_en      (trace_rd_en     ),
    .trace_rd_data    (trace_rd_data   ),
    .trace_frozen     (trace_frozen    ),
    .trace_wptr       (trace_wptr      ),
    .trace_wrapped    (trace_wrapped   )
  );

// ============================================================================================== --
// Concurrent assertions (white-box: reference DUT internals). A failure sets error_assert.
// ============================================================================================== --
  // Freeze margin: a write (trace_we) must be followed by >= TRACE_FREEZE_MARGIN quiet clk_mhdma
  // cycles before trace_frozen_q rises, so wptr_q/wrapped_q are static before they cross to cfg.
  assert property (@(posedge clk_mhdma) disable iff (~resetn_mhdma)
    dut.trace_we |-> (~dut.trace_frozen_q)[*dut.TRACE_FREEZE_MARGIN])
  else begin
    $display("%t > [ASSERT] trace_we within the freeze margin of trace_frozen_q rising", $time);
    error_assert = 1'b1;
  end

  // Static-while-frozen: the published pointer/flag must not change while frozen (the multi-bit wptr
  // and the wrapped flag cross on plain synchronizers, so they must be quasi-static here).
  assert property (@(posedge clk_mhdma) disable iff (~resetn_mhdma)
    dut.trace_frozen_q |-> $stable(dut.trace_wptr_q) && $stable(dut.trace_wrapped_q))
  else begin
    $display("%t > [ASSERT] trace_wptr_q/trace_wrapped_q changed while trace_frozen_q high", $time);
    error_assert = 1'b1;
  end

  // Read gating: while not frozen the readout returns a sentinel and the read pointer does not
  // advance on a read strobe (prevents torn reads racing live capture).
  assert property (@(posedge clk_mhdma_cfg) disable iff (~resetn_mhdma_cfg)
    ~trace_frozen |-> (trace_rd_data == '0))
  else begin
    $display("%t > [ASSERT] trace_rd_data non-zero while not frozen", $time);
    error_assert = 1'b1;
  end

  assert property (@(posedge clk_mhdma_cfg) disable iff (~resetn_mhdma_cfg)
    (trace_rd_en & ~trace_frozen & ~trace_arm) |=> $stable(dut.trace_rd_ptr))
  else begin
    $display("%t > [ASSERT] trace_rd_ptr advanced on a read while not frozen", $time);
    error_assert = 1'b1;
  end

// ============================================================================================== --
// Free-running mhdma cycle counter (for wrap-aware timestamp delta checks)
// ============================================================================================== --
  int tb_cyc;
  always_ff @(posedge clk_mhdma)
    if (~resetn_mhdma) tb_cyc <= 0;
    else               tb_cyc <= tb_cyc + 1;

  // White-box count of accepted writes (dut.trace_we) since the last re-arm. Used by the
  // sw_freeze_midstream scenario, where the exact accepted count is non-deterministic (the freeze
  // edge races live traffic through the CDC) - the DUT itself reports the ground-truth count.
  int dut_we_cnt;
  always_ff @(posedge clk_mhdma)
    if      (~resetn_mhdma)    dut_we_cnt <= 0;
    else if (dut.trace_rearm)  dut_we_cnt <= 0;
    else if (dut.trace_we)     dut_we_cnt <= dut_we_cnt + 1;

// ============================================================================================== --
// Golden model
// Mirrors the RTL write decision so read-back can be checked field-by-field.
// ============================================================================================== --
  command_t               gm_header [TRACE_DEPTH]; // expected header per absolute RAM index
  logic [TRACE_AUX_W-1:0] gm_aux [TRACE_DEPTH];    // expected aux per absolute RAM index
  int                     gm_cyc [TRACE_DEPTH];    // tb_cyc when that index was written
  bit                     gm_vld [TRACE_DEPTH];    // index has been written since last arm
  int                     gm_wptr;                 // next write index (0..DEPTH-1)
  int                     gm_count;                // total accepted writes since arm
  bit                     gm_triggered;            // error seen (sticky)
  int                     gm_tail_left;            // remaining tail writes before freeze
  bit                     gm_frozen;               // capture frozen

  task automatic gm_arm();
    begin
      for (int i = 0; i < TRACE_DEPTH; i++) gm_vld[i] = 1'b0;
      gm_wptr      = 0;
      gm_count     = 0;
      gm_triggered = 1'b0;
      gm_tail_left = TRACE_TAIL;
      gm_frozen    = 1'b0;
    end
  endtask

  // Set the sticky trigger in the model (call in a traffic gap so no push races the error edge).
  task automatic gm_trigger();
    if (!gm_frozen) gm_triggered = 1'b1;
  endtask

  // Force freeze without a write (timeout backstop path, when traffic has stopped).
  task automatic gm_force_frozen();
    gm_frozen = 1'b1;
  endtask

  // Mirror one header beat: record iff the RTL would assert trace_we.
  task automatic gm_record(input command_t header, input logic [TRACE_AUX_W-1:0] aux, input int cyc);
    bit tail_done;
    begin
      tail_done = gm_triggered & (gm_tail_left == 0);
      if (!gm_frozen && !tail_done) begin
        gm_header[gm_wptr] = header;
        gm_aux[gm_wptr] = aux;
        gm_cyc[gm_wptr] = cyc;
        gm_vld[gm_wptr] = 1'b1;
        gm_wptr         = (gm_wptr + 1) % TRACE_DEPTH;
        gm_count        = gm_count + 1;
        if (gm_triggered) begin
          gm_tail_left = gm_tail_left - 1;
          if (gm_tail_left == 0) gm_frozen = 1'b1; // next push is blocked -> effectively frozen
        end
      end
    end
  endtask

// ============================================================================================== --
// Stimulus helpers
// ============================================================================================== --
  int  push_idx;                          // global monotonic push index (embedded in header)
  logic [REQ_ID_W-1:0] REQ_TYPES [4];

  // Per-beat log of driven traffic (in push order), for sw_freeze_midstream: after a mid-stream
  // freeze, the golden model is rebuilt from the first dut_we_cnt logged beats (drop-oldest ring).
  localparam int LOG_DEPTH = 4 * TRACE_DEPTH;
  command_t               log_hdr [LOG_DEPTH];
  logic [TRACE_AUX_W-1:0] log_aux [LOG_DEPTH];
  int                     log_cyc [LOG_DEPTH];
  int                     log_n;

  initial begin
    REQ_TYPES[0] = REQ_ID_NOTIFY;
    REQ_TYPES[1] = REQ_ID_NOTIFY_ACK;
    REQ_TYPES[2] = REQ_ID_READ;
    REQ_TYPES[3] = REQ_ID_EMISSION;
  end

  // Build a header with fully RANDOM content, except src_addr which carries the push index.
  // The golden model stores the exact random value, so read-back is a bit-for-bit data-integrity check.
  function automatic command_t rand_header(input int idx);
    command_t h;
    begin
      h.src_mac_addr = $urandom;
      h.seq_num      = $urandom;
      h.hpu_id       = $urandom;
      h.rsvd         = $urandom;
      h.flag         = $urandom;
      h.mode         = $urandom;
      h.req_id       = REQ_TYPES[$urandom % 4]; // random, but always a valid command type
      h.iop_id       = $urandom;
      h.src_addr     = idx[SRC_ADDR_W-1:0];     // ordering marker
      h.dst_addr     = $urandom;
      return h;
    end
  endfunction

  function automatic logic [TRACE_AUX_W-1:0] rand_aux();
    return TRACE_AUX_W'($urandom);
  endfunction

  // Drive one header beat (clk_mhdma), optionally spacing extra idle cycles between beats, and
  // update the golden model with the exact (random) content driven.
  task automatic push_one(input int extra_gap = 0);
    command_t               header;
    logic [TRACE_AUX_W-1:0]  aux;
    begin
      header = rand_header(push_idx);
      aux = rand_aux();

      @(posedge clk_mhdma);
      header_data  = header;
      trace_aux    = aux;
      header_valid = 1'b1;
      gm_record(header, aux, tb_cyc);   // sample model at the same edge the write happens
      @(posedge clk_mhdma);
      header_valid = 1'b0;

      push_idx = push_idx + 1;
      repeat (extra_gap) @(posedge clk_mhdma);
    end
  endtask

  task automatic push_n(input int n, input int extra_gap = 0);
    for (int i = 0; i < n; i++) push_one(extra_gap);
  endtask

  // Drive one header beat with error_detected asserted on the SAME clk_mhdma edge as the push (the
  // real-world trigger: e.g. error_fifo_rx_ovf is set by the very header push that overflows). The
  // RTL registers trace_triggered_q, so this coincident header is a pre-trigger ("before") entry and
  // the tail starts the next cycle. Model: record with the trigger not yet sticky, THEN set it.
  task automatic push_one_with_error();
    command_t                header;
    logic [TRACE_AUX_W-1:0]  aux;
    begin
      header = rand_header(push_idx);
      aux    = rand_aux();

      @(posedge clk_mhdma);
      header_data    = header;
      trace_aux      = aux;
      header_valid   = 1'b1;
      error_detected = 1'b1;             // error coincident with the push
      gm_record(header, aux, tb_cyc);    // recorded as a "before" entry (trigger not yet sticky)
      gm_trigger();                      // trigger becomes effective from the next beat
      @(posedge clk_mhdma);
      header_valid   = 1'b0;

      push_idx = push_idx + 1;
    end
  endtask

  // Drive n headers on n CONSECUTIVE clk_mhdma cycles (header_valid held high, new data each cycle):
  // full-throughput capture, one write per cycle. Exercises the per-cycle wptr increment and tail
  // decrement that the spaced push_one never hits.
  task automatic push_burst(input int n);
    command_t                header;
    logic [TRACE_AUX_W-1:0]  aux;
    begin
      for (int i = 0; i < n; i++) begin
        header = rand_header(push_idx);
        aux    = rand_aux();
        @(posedge clk_mhdma);
        header_data  = header;
        trace_aux    = aux;
        header_valid = 1'b1;
        gm_record(header, aux, tb_cyc);
        push_idx = push_idx + 1;
      end
      @(posedge clk_mhdma);
      header_valid = 1'b0;
    end
  endtask

  // Drive + log (NO gm_record): sw_freeze_midstream reconstructs the model afterward from the DUT's
  // accepted-write count, so these must not touch the golden model. Timing mirrors push_burst.
  task automatic drive_burst_log(input int n);   // continuous: header_valid held high, one write/cycle
    command_t               header;
    logic [TRACE_AUX_W-1:0]  aux;
    begin
      for (int i = 0; i < n; i++) begin
        header = rand_header(push_idx);
        aux    = rand_aux();
        @(posedge clk_mhdma);
        header_data  = header;
        trace_aux    = aux;
        header_valid = 1'b1;
        log_hdr[log_n] = header; log_aux[log_n] = aux; log_cyc[log_n] = tb_cyc; log_n = log_n + 1;
        push_idx = push_idx + 1;
      end
      @(posedge clk_mhdma);
      header_valid = 1'b0;
    end
  endtask

  // Drive + log, spaced (mirrors push_one): freeze edge can land in a gap (header_valid low).
  task automatic drive_spaced_log(input int n, input int gap);
    command_t               header;
    logic [TRACE_AUX_W-1:0]  aux;
    begin
      for (int i = 0; i < n; i++) begin
        header = rand_header(push_idx);
        aux    = rand_aux();
        @(posedge clk_mhdma);
        header_data  = header;
        trace_aux    = aux;
        header_valid = 1'b1;
        log_hdr[log_n] = header; log_aux[log_n] = aux; log_cyc[log_n] = tb_cyc; log_n = log_n + 1;
        @(posedge clk_mhdma);
        header_valid = 1'b0;
        push_idx = push_idx + 1;
        repeat (gap) @(posedge clk_mhdma);
      end
    end
  endtask

  // Assert / clear error_detected (level). Set the model trigger in the gap.
  task automatic assert_error();
    begin
      @(posedge clk_mhdma);
      error_detected = 1'b1;
      gm_trigger();
      repeat (3) @(posedge clk_mhdma); // let the level set trace_triggered_q (sticky)
    end
  endtask

  task automatic clear_error();
    begin
      @(posedge clk_mhdma);
      error_detected = 1'b0;
      repeat (3) @(posedge clk_mhdma);
    end
  endtask

// ============================================================================================== --
// Control / readout helpers (clk_mhdma_cfg)
// ============================================================================================== --
  // Flush + re-arm the DUT, wait for the re-arm pulse to cross into clk_mhdma, then reset model.
  task automatic do_arm();
    begin
      @(posedge clk_mhdma_cfg);
      trace_arm = 1'b1;
      @(posedge clk_mhdma_cfg);
      trace_arm = 1'b0;
      // wait out the arm CDC (cfg->mhdma, TRACE_CDC_STAGES) + a margin before capturing / modeling
      repeat (30) @(posedge clk_mhdma_cfg);
      repeat (30) @(posedge clk_mhdma);
      gm_arm();
    end
  endtask

  // Software freeze: pulse trace_freeze (cfg domain). Caller stops traffic first, then waits for the
  // freeze to cross into clk_mhdma (wait_frozen) before mirroring it in the model (gm_force_frozen).
  task automatic do_freeze();
    begin
      @(posedge clk_mhdma_cfg);
      trace_freeze = 1'b1;
      @(posedge clk_mhdma_cfg);
      trace_freeze = 1'b0;
    end
  endtask

  // Pop one 32-bit trace word (pointer stable + settled on entry, advanced on exit).
  task automatic read_word(output logic [REG_DATA_W-1:0] data);
    begin
      @(posedge clk_mhdma_cfg);
      data        = trace_rd_data;   // word at current pointer (settled)
      trace_rd_en = 1'b1;            // request advance
      @(posedge clk_mhdma_cfg);
      trace_rd_en = 1'b0;
      @(posedge clk_mhdma_cfg);      // settle RAM READ_LATENCY + word-select for the new pointer
    end
  endtask

  // Wait for trace_frozen, bounded.
  task automatic wait_frozen(input int scen_id, input int max_cfg);
    int c;
    begin
      c = 0;
      while (!trace_frozen && (c < max_cfg)) begin
        @(posedge clk_mhdma_cfg);
        c = c + 1;
      end
      assert (trace_frozen) else begin
        $display("[ERROR:%0d]: trace did not freeze within %0d cfg cycles", scen_id, max_cfg);
        error_frozen = 1'b1;
      end
    end
  endtask

  // Check trace_frozen stays low for a window (no false / stale freeze).
  task automatic check_not_frozen(input int scen_id, input int window_cfg);
    begin
      for (int i = 0; i < window_cfg; i++) begin
        @(posedge clk_mhdma_cfg);
        assert (!trace_frozen) else begin
          $display("[ERROR:%0d]: trace unexpectedly frozen", scen_id);
          error_frozen = 1'b1;
        end
      end
    end
  endtask

  // Read back the whole (frozen) buffer and check content + ordering + timestamps.
  //   valid_count : number of real entries (== gm_count, capped at DEPTH)
  //   full        : buffer wrapped at least once (ring full -> rotation-by-wptr ordering applies)
  task automatic read_and_check(input int scen_id, input int valid_count, input bit full);
    logic [REG_DATA_W-1:0]  w [TRACE_WORDS];
    logic [TRACE_W-1:0]     entry;
    command_t               rb_header [TRACE_DEPTH];
    logic [TRACE_AUX_W-1:0] rb_aux [TRACE_DEPTH];
    logic [TRACE_TS_W-1:0]  rb_ts  [TRACE_DEPTH];
    int                     wptr_rd;
    int                     abs, prev_abs;
    int                     prev_idx, cur_idx;
    logic [TRACE_TS_W-1:0]  exp_dts;
    logic [TRACE_TS_W-1:0]  got_dts;
    int                     first;
    begin
      wptr_rd = trace_wptr;

      // read pointer starts at 0 -> read order == absolute RAM index
      repeat (6) @(posedge clk_mhdma_cfg); // extra settle before the very first read
      for (int e = 0; e < TRACE_DEPTH; e++) begin
        for (int k = 0; k < TRACE_WORDS; k++) read_word(w[k]);
        entry     = {w[3], w[2], w[1], w[0]};
        rb_header[e] = entry[0        +: header_W];
        rb_aux[e] = entry[header_W    +: TRACE_AUX_W];
        rb_ts[e]  = entry[header_W + TRACE_AUX_W +: TRACE_TS_W];
      end

      // ---- content: compare each valid absolute index against the golden model -----------------
      for (int e = 0; e < TRACE_DEPTH; e++) begin
        if (gm_vld[e]) begin
          assert (rb_header[e] == gm_header[e]) else begin
            $display("[ERROR:%0d]: header mismatch @idx %0d exp=%h got=%h",
                     scen_id, e, gm_header[e], rb_header[e]);
            error_content = 1'b1;
          end
          assert (rb_aux[e] == gm_aux[e]) else begin
            $display("[ERROR:%0d]: aux mismatch @idx %0d exp=%h got=%h",
                     scen_id, e, gm_aux[e], rb_aux[e]);
            error_content = 1'b1;
          end
        end
      end

      // ---- ordering: rotate by wptr -> embedded push-index must strictly increase --------------
      // full buffer  : oldest is at wptr, walk DEPTH entries wrapping.
      // partial       : oldest is at 0, walk valid_count entries (no wrap).
      first    = full ? wptr_rd : 0;
      prev_idx = -1;
      prev_abs = -1;
      for (int k = 0; k < (full ? TRACE_DEPTH : valid_count); k++) begin
        abs     = (first + k) % TRACE_DEPTH;
        cur_idx = rb_header[abs].src_addr;             // embedded monotonic marker
        if (prev_idx >= 0) begin
          assert (cur_idx > prev_idx) else begin
            $display("[ERROR:%0d]: order broken (rotate by wptr=%0d): idx %0d after %0d", scen_id, wptr_rd, cur_idx, prev_idx);
            error_order = 1'b1;
          end
          // timestamp delta (wrap-aware): (ts[k]-ts[k-1]) mod 2^TS_W == (cyc delta) mod 2^TS_W
          exp_dts = TRACE_TS_W'(gm_cyc[abs] - gm_cyc[prev_abs]);
          got_dts = rb_ts[abs] - rb_ts[prev_abs];
          assert (got_dts == exp_dts) else begin
            $display("[ERROR:%0d]: ts delta mismatch @idx %0d exp=%0d got=%0d", scen_id, abs, exp_dts, got_dts);
            error_ts = 1'b1;
          end
        end
        prev_idx = cur_idx;
        prev_abs = abs;
      end
    end
  endtask

  // Check trace_wptr against the model.
  task automatic check_wptr(input int scen_id, input int exp);
    assert (trace_wptr == exp[TRACE_AW-1:0]) else begin
      $display("[ERROR:%0d]: wptr=%0d expected %0d", scen_id, trace_wptr, exp[TRACE_AW-1:0]);
      error_wptr = 1'b1;
    end
  endtask

  // Check trace_wrapped (ring-filled flag) against the model. wrapped == 1 iff the ring wrapped at
  // least once this session (>= TRACE_DEPTH accepted writes); pass the model's own count so the
  // expectation tracks the randomized traffic. Must be read while frozen (published only then).
  task automatic check_wrapped(input int scen_id, input bit exp);
    assert (trace_wrapped == exp) else begin
      $display("[ERROR:%0d]: wrapped=%0b expected %0b (gm_count=%0d)", scen_id, trace_wrapped, exp, gm_count);
      error_wrapped = 1'b1;
    end
  endtask

// ============================================================================================== --
// Scenarios
// ============================================================================================== --
  int scenario_id;

  // -------------------------------------------------------------------------
  // Scenario : baseline, all header types, no error -> never freezes
  // -------------------------------------------------------------------------
  task automatic run_scenario_default_all_headers();
    int n_def, gap_def;
    begin
      scenario_start(scenario_id, "default: all header types, no error, no freeze");
      n_def   = TRACE_DEPTH + $urandom_range(10, 40); // > DEPTH so the ring wraps
      gap_def = $urandom_range(0, 10);
      do_arm();
      fork
        push_n(n_def, gap_def);
        check_not_frozen(scenario_id, 40); // in parallel, prove no false freeze early on
      join
      // never asserted an error: must still be capturing (not frozen)
      assert (!trace_frozen) else begin
        $display("[ERROR:%0d]: frozen without any error", scenario_id);
        error_frozen = 1'b1;
      end
      scenario_end(scenario_id, clk_mhdma_cfg);
    end
  endtask

  // -------------------------------------------------------------------------
  // Scenario : error, then traffic stops -> freeze via timeout backstop
  //            (folds: freeze+wptr, no-capture-after-freeze, timestamps)
  // -------------------------------------------------------------------------
  task automatic run_scenario_error_timeout();
    int n;
    begin
      scenario_start(scenario_id, "error + traffic stops -> timeout freeze");
      n = $urandom_range(3, TRACE_DEPTH - 1); // < DEPTH : partially filled ring
      do_arm();
      // wide spacing (> 2^TRACE_TS_W cycles between beats) so consecutive-entry timestamp deltas
      // wrap -> exercises the wrap-aware timestamp checker (gap D).
      push_n(n, (1 << TRACE_TS_W) + $urandom_range(20, 120));

      // error while traffic is stopped: the "after" half never fills -> timeout forces freeze
      assert_error();
      // timeout backstop must NOT fire early: no freeze for a window well below TRACE_TAIL_TIMEOUT
      // (catches a premature terminal compare / early saturation of trace_timeout_cnt).
      check_not_frozen(scenario_id, TIMEOUT_EARLY_WIN);
      wait_frozen(scenario_id, FREEZE_WAIT_CFG);
      gm_force_frozen();

      check_wptr(scenario_id, gm_count);          // no post-error writes -> wptr == n
      check_wrapped(scenario_id, gm_count >= TRACE_DEPTH); // partial ring -> wrapped == 0
      read_and_check(scenario_id, gm_count, 1'b0);

      // pushing after freeze must not change anything
      push_n($urandom_range(1, 10), $urandom_range(0, 3));
      check_wptr(scenario_id, n);
      assert (gm_count == n) else begin
        $display("[ERROR:%0d]: model captured after freeze", scenario_id);
        error_content = 1'b1;
      end

      clear_error();
      scenario_end(scenario_id, clk_mhdma_cfg);
    end
  endtask

  // -------------------------------------------------------------------------
  // Scenario : error, a FEW post-trigger packets (< TRACE_TAIL), then traffic stops
  //            -> freeze via the timeout backstop with a PARTIALLY-decremented tail counter.
  //            Exercises the tail_cnt <-> timeout_cnt interaction, on both a full and a
  //            partial ring. (gaps kept small so the k writes finish well before the timeout,
  //            otherwise the DUT could freeze mid-burst and diverge from the model.)
  // -------------------------------------------------------------------------
  task automatic run_scenario_partial_tail_timeout();
    int pre, k, gap;
    begin
      scenario_start(scenario_id, "partial tail + timeout (full & partial ring)");

      // (a) FULL ring: pre >= DEPTH, a few post-trigger writes, then stop -> timeout freeze
      pre = TRACE_DEPTH + $urandom_range(0, 30);
      k   = $urandom_range(1, TRACE_TAIL - 1);   // fewer than the tail -> timeout wins, not counter
      gap = $urandom_range(0, 3);
      do_arm();
      push_n(pre, gap);
      assert_error();
      push_n(k, gap);                            // partial tail (tail_cnt decremented but != 0)
      wait_frozen(scenario_id, FREEZE_WAIT_CFG); // no more traffic -> timeout backstop fires
      gm_force_frozen();
      check_wptr(scenario_id, gm_wptr);          // also catches any premature (mid-burst) freeze
      check_wrapped(scenario_id, gm_count >= TRACE_DEPTH);
      read_and_check(scenario_id, gm_count, gm_count >= TRACE_DEPTH);
      clear_error();

      // (b) PARTIAL ring: pre + k < DEPTH so the ring never wraps
      pre = $urandom_range(1, 10);
      k   = $urandom_range(1, TRACE_TAIL - 1);
      gap = $urandom_range(0, 3);
      do_arm();
      push_n(pre, gap);
      assert_error();
      push_n(k, gap);
      wait_frozen(scenario_id, FREEZE_WAIT_CFG);
      gm_force_frozen();
      check_wptr(scenario_id, gm_wptr);
      check_wrapped(scenario_id, gm_count >= TRACE_DEPTH);
      read_and_check(scenario_id, gm_count, gm_count >= TRACE_DEPTH);
      clear_error();

      scenario_end(scenario_id, clk_mhdma_cfg);
    end
  endtask

  // -------------------------------------------------------------------------
  // Scenario : overwrite ring + sticky trigger + full readback + re-arm loop
  //            (folds: circular overwrite, content, trigger-sticky, de-glitch, repeat)
  // -------------------------------------------------------------------------
  task automatic run_scenario_error_restart();
    int pre, reps, tail_split, gap;
    begin
      scenario_start(scenario_id, "overwrite + sticky trigger + readback + re-arm (loop)");

      reps = $urandom_range(2, 4);
      for (int rep = 0; rep < reps; rep++) begin
        pre        = TRACE_DEPTH + $urandom_range(1, 40); // > DEPTH : force wrap / drop-oldest
        tail_split = $urandom_range(1, TRACE_TAIL - 1);   // where the 2nd (ignored) error lands
        gap        = $urandom_range(0, 5);                // small -> tail counter wins over timeout
        do_arm();
        push_n(pre, gap);

        assert_error();
        // a SECOND error pulse after the trigger must have no effect (trigger already sticky)
        push_n(tail_split, gap);  // some tail writes
        assert_error();
        push_n(TRACE_DEPTH, gap); // keep pushing; tail counter must freeze after TRACE_TAIL total

        wait_frozen(scenario_id, FREEZE_WAIT_CFG);

        // full buffer -> exactly DEPTH valid entries, rotation ordering applies
        check_wptr(scenario_id, gm_wptr);
        check_wrapped(scenario_id, gm_count >= TRACE_DEPTH); // pre > DEPTH -> wrapped == 1
        read_and_check(scenario_id, TRACE_DEPTH, 1'b1);

        clear_error();
      end

      // after the last re-arm inside the loop the published frozen must have de-glitched already;
      // do one more explicit arm and confirm it is low (no stale freeze from the CDC round-trip).
      do_arm();
      check_not_frozen(scenario_id, 40);

      scenario_end(scenario_id, clk_mhdma_cfg);
    end
  endtask

  // -------------------------------------------------------------------------
  // Scenario : sustained traffic -> tail is exactly TRACE_TAIL, window straddles the fault
  //            (folds: half/half split w/ content boundary, back-to-back reads)
  // -------------------------------------------------------------------------
  task automatic run_scenario_sustained_traffic();
    int pre, cnt_before, cnt_after, gap;
    begin
      scenario_start(scenario_id, "sustained traffic -> exact tail, half/half window");
      pre = TRACE_DEPTH + $urandom_range(0, 30); // >= DEPTH so the ring is full before the error
      gap = $urandom_range(0, 4);                // small -> tail counter wins over timeout
      do_arm();
      push_n(pre, gap);

      cnt_before = gm_count;

      // assert error but KEEP pushing so the tail fills from the counter (not the timeout)
      assert_error();
      push_n(TRACE_TAIL + $urandom_range(5, 30), gap); // more than the tail; must stop after TRACE_TAIL
      wait_frozen(scenario_id, FREEZE_WAIT_CFG);

      // exactly TRACE_TAIL post-trigger writes were accepted
      cnt_after = gm_count - cnt_before;
      assert (cnt_after == TRACE_TAIL) else begin
        $display("[ERROR:%0d]: tail=%0d expected %0d", scenario_id, cnt_after, TRACE_TAIL);
        error_tail = 1'b1;
      end

      check_wptr(scenario_id, gm_wptr);
      check_wrapped(scenario_id, gm_count >= TRACE_DEPTH); // full ring -> wrapped == 1
      read_and_check(scenario_id, TRACE_DEPTH, 1'b1);
      clear_error();
      scenario_end(scenario_id, clk_mhdma_cfg);
    end
  endtask

  // -------------------------------------------------------------------------
  // Scenario : fresh reset then no-capture / under-filled ring
  //            (folds: reset clean-state, error-before-any-capture, partial fill)
  // NOTE: reset (and re-arm) only clear the pointers/FSM, NOT the RAM array - BRAM contents
  //       survive reset and still hold stale data from previous scenarios. So the "no-capture"
  //       sub-case only checks wptr (== 0) and does NOT read back: with zero writes there are no
  //       valid entries and a read would just return stale RAM, which is not part of the contract.
  // -------------------------------------------------------------------------
  task automatic run_scenario_reset_underfill();
    int m;
    begin
      scenario_start(scenario_id, "reset + no-capture / under-filled ring");

      // (a) hard reset, arm, then error with ZERO packets -> timeout freeze, wptr == 0.
      //     RAM is NOT cleared (stale data remains) -> verify wptr only, do not read back.
      pulse_reset();
      do_arm();
      assert_error();
      wait_frozen(scenario_id, FREEZE_WAIT_CFG);
      gm_force_frozen();
      check_wptr(scenario_id, 0);
      check_wrapped(scenario_id, 1'b0);           // zero writes -> not wrapped
      clear_error();

      // (b) arm, push M (< DEPTH) then error -> wptr == M, only M entries valid
      m = $urandom_range(1, TRACE_DEPTH - 1);
      do_arm();
      push_n(m, $urandom_range(0, 5));
      assert_error();
      wait_frozen(scenario_id, FREEZE_WAIT_CFG);
      gm_force_frozen();
      check_wptr(scenario_id, m);
      check_wrapped(scenario_id, gm_count >= TRACE_DEPTH); // m < DEPTH -> not wrapped
      read_and_check(scenario_id, m, 1'b0);
      clear_error();

      scenario_end(scenario_id, clk_mhdma_cfg);
    end
  endtask

  // -------------------------------------------------------------------------
  // Scenario : re-arm while the (sticky) error is still asserted -> immediate re-trigger
  // -------------------------------------------------------------------------
  task automatic run_scenario_rearm_sticky_error();
    begin
      scenario_start(scenario_id, "re-arm with error still asserted -> immediate re-trigger");

      // first capture: freeze via timeout, leave error asserted
      do_arm();
      push_n($urandom_range(1, TRACE_DEPTH - 1), $urandom_range(0, 5));
      assert_error();
      wait_frozen(scenario_id, FREEZE_WAIT_CFG);
      gm_force_frozen();
      check_wrapped(scenario_id, gm_count >= TRACE_DEPTH); // < DEPTH pushed -> not wrapped

      // re-arm WITHOUT clearing the error. error_detected is still high -> must re-trigger and,
      // with no new traffic, re-freeze via the timeout backstop.
      do_arm();
      // model: error still high -> trigger immediately after re-arm
      gm_trigger();
      wait_frozen(scenario_id, FREEZE_WAIT_CFG);
      gm_force_frozen();
      assert (trace_frozen) else begin
        $display("[ERROR:%0d]: sticky error did not re-freeze after re-arm", scenario_id);
        error_frozen = 1'b1;
      end
      check_wrapped(scenario_id, gm_count >= TRACE_DEPTH); // re-arm cleared wrapped; no new traffic -> 0

      clear_error();
      // clean re-arm now that the error is gone: must stay unfrozen
      do_arm();
      check_not_frozen(scenario_id, 60);

      scenario_end(scenario_id, clk_mhdma_cfg);
    end
  endtask

  // -------------------------------------------------------------------------
  // Scenario : error_detected coincident with a header push (same clk_mhdma edge) - the most likely
  //            real trigger (an overflowing push sets the error). The coincident header must be a
  //            pre-trigger entry, and the tail must still be exactly TRACE_TAIL.
  // -------------------------------------------------------------------------
  task automatic run_scenario_coincident_error();
    int pre, cnt_before, cnt_after;
    begin
      scenario_start(scenario_id, "error coincident with a header push (same edge)");
      pre = TRACE_DEPTH + $urandom_range(0, 20); // full ring before the trigger
      do_arm();
      push_n(pre, $urandom_range(0, 3));
      cnt_before = gm_count;
      push_one_with_error();                                 // error on the same edge as this push
      push_n(TRACE_TAIL + $urandom_range(4, 12), $urandom_range(0, 2)); // fill the tail
      wait_frozen(scenario_id, FREEZE_WAIT_CFG);

      // coincident push is a "before" entry, so post-trigger writes = TRACE_TAIL exactly
      cnt_after = gm_count - cnt_before - 1; // -1 for the coincident (before) entry
      assert (cnt_after == TRACE_TAIL) else begin
        $display("[ERROR:%0d]: coincident-trigger tail=%0d expected %0d", scenario_id, cnt_after, TRACE_TAIL);
        error_tail = 1'b1;
      end
      check_wptr(scenario_id, gm_wptr);
      check_wrapped(scenario_id, gm_count >= TRACE_DEPTH);
      read_and_check(scenario_id, TRACE_DEPTH, 1'b1);
      clear_error();
      scenario_end(scenario_id, clk_mhdma_cfg);
    end
  endtask

  // -------------------------------------------------------------------------
  // Scenario : full-throughput capture - header_valid held high on consecutive clk_mhdma cycles
  //            (one write/cycle) before and across the trigger. The tail must still be exactly
  //            TRACE_TAIL at full rate (per-cycle wptr increment + tail decrement).
  // -------------------------------------------------------------------------
  task automatic run_scenario_full_throughput();
    int pre, cnt_before, cnt_after;
    begin
      scenario_start(scenario_id, "full-throughput: back-to-back header_valid, exact tail");
      pre = TRACE_DEPTH + $urandom_range(0, 20);
      do_arm();
      push_burst(pre);                                // fill the ring at one write per cycle
      cnt_before = gm_count;
      assert_error();                                 // trigger in the gap after the burst
      push_burst(TRACE_TAIL + $urandom_range(4, 12)); // tail at full rate; extra beats must be dropped
      wait_frozen(scenario_id, FREEZE_WAIT_CFG);

      cnt_after = gm_count - cnt_before;
      assert (cnt_after == TRACE_TAIL) else begin
        $display("[ERROR:%0d]: full-rate tail=%0d expected %0d", scenario_id, cnt_after, TRACE_TAIL);
        error_tail = 1'b1;
      end
      check_wptr(scenario_id, gm_wptr);
      check_wrapped(scenario_id, gm_count >= TRACE_DEPTH);
      read_and_check(scenario_id, TRACE_DEPTH, 1'b1);
      clear_error();
      scenario_end(scenario_id, clk_mhdma_cfg);
    end
  endtask

  // -------------------------------------------------------------------------
  // Scenario : wrapped-flag boundary. Exactly DEPTH-1 writes (partial, wrapped=0)
  //            vs exactly DEPTH writes (ring just filled by the DEPTH-th write,
  //            wrapped=1). Traffic stops before the error so the freeze is via the
  //            timeout backstop and the accepted write count is exact.
  // -------------------------------------------------------------------------
  task automatic run_scenario_wrapped_boundary();
    begin
      scenario_start(scenario_id, "wrapped boundary: DEPTH-1 (partial) vs DEPTH (full)");

      // (a) exactly DEPTH-1 writes -> ring one short of full -> wrapped == 0
      do_arm();
      push_n(TRACE_DEPTH - 1, $urandom_range(0, 3));
      assert_error();
      wait_frozen(scenario_id, FREEZE_WAIT_CFG);
      gm_force_frozen();
      check_wptr(scenario_id, TRACE_DEPTH - 1);
      check_wrapped(scenario_id, 1'b0);
      read_and_check(scenario_id, gm_count, 1'b0);
      clear_error();

      // (b) exactly DEPTH writes -> the DEPTH-th write wraps wptr to 0 -> wrapped == 1
      do_arm();
      push_n(TRACE_DEPTH, $urandom_range(0, 3));
      assert_error();
      wait_frozen(scenario_id, FREEZE_WAIT_CFG);
      gm_force_frozen();
      check_wptr(scenario_id, 0);
      check_wrapped(scenario_id, 1'b1);
      read_and_check(scenario_id, TRACE_DEPTH, 1'b1);
      clear_error();

      scenario_end(scenario_id, clk_mhdma_cfg);
    end
  endtask

  // -------------------------------------------------------------------------
  // Scenario : software-initiated freeze, NO error. SW freeze is immediate (no tail); with no error
  //            the timeout backstop can never fire, so freezing at all proves the SW path. Covers a
  //            partial ring (wrapped=0) and a full ring (wrapped=1), and that a re-arm clears it.
  // -------------------------------------------------------------------------
  task automatic run_scenario_sw_freeze();
    int m, pre, exp_wptr, exp_count;
    begin
      scenario_start(scenario_id, "software freeze (no error): partial & full ring");

      // (a) PARTIAL ring: arm, push M < DEPTH, then SW-freeze
      m = $urandom_range(1, TRACE_DEPTH - 1);
      do_arm();
      push_n(m, $urandom_range(0, 5));
      do_freeze();
      wait_frozen(scenario_id, FREEZE_SW_WAIT_CFG); // must freeze fast, without the error timeout
      gm_force_frozen();
      check_wptr(scenario_id, gm_wptr);
      check_wrapped(scenario_id, gm_count >= TRACE_DEPTH); // partial -> 0
      read_and_check(scenario_id, gm_count, gm_count >= TRACE_DEPTH);

      // pushing after a SW freeze must not capture anything
      exp_wptr  = gm_wptr;
      exp_count = gm_count;
      push_n($urandom_range(1, 10), $urandom_range(0, 3));
      check_wptr(scenario_id, exp_wptr);
      assert (gm_count == exp_count) else begin
        $display("[ERROR:%0d]: model captured after SW freeze", scenario_id);
        error_content = 1'b1;
      end

      // (b) FULL ring: arm, push > DEPTH (wraps), then SW-freeze -> wrapped == 1
      pre = TRACE_DEPTH + $urandom_range(1, 30);
      do_arm();
      push_n(pre, $urandom_range(0, 3));
      do_freeze();
      wait_frozen(scenario_id, FREEZE_SW_WAIT_CFG);
      gm_force_frozen();
      check_wptr(scenario_id, gm_wptr);
      check_wrapped(scenario_id, 1'b1);
      read_and_check(scenario_id, TRACE_DEPTH, 1'b1);

      // re-arm clears the SW freeze -> capturing again, not frozen
      do_arm();
      check_not_frozen(scenario_id, 60);

      scenario_end(scenario_id, clk_mhdma_cfg);
    end
  endtask

  // -------------------------------------------------------------------------
  // Scenario : SW freeze issued WHILE capture traffic is live (header_valid still asserting when the
  //            freeze edge lands). Stresses the one path unique to SW freeze: trace_sw_freeze_q ->
  //            trace_tail_done gating trace_we mid-write. The freeze edge races the traffic through
  //            the CDC, so the accepted-write count is non-deterministic -> rebuild the golden model
  //            from the DUT's own accepted count (dut_we_cnt). Two phases: continuous (edge coincident
  //            with a beat) and spaced (edge can fall in a gap).
  // -------------------------------------------------------------------------
  task automatic run_scenario_sw_freeze_midstream();
    int freeze_delay_cfg, accepted, n_beats;
    begin
      scenario_start(scenario_id, "SW freeze mid-stream: freeze while capture traffic is live");

      for (int phase = 0; phase < 2; phase++) begin
        do_arm();
        log_n           = 0;
        n_beats         = 2 * TRACE_DEPTH + $urandom_range(10, 40); // long enough to still be driving at the freeze
        freeze_delay_cfg = $urandom_range(2, 8);                    // fire partway into the burst

        // drive traffic and pulse the freeze concurrently
        fork
          begin
            if (phase == 0) drive_burst_log(n_beats);
            else            drive_spaced_log(n_beats, $urandom_range(1, 3));
          end
          begin
            repeat (freeze_delay_cfg) @(posedge clk_mhdma_cfg);
            do_freeze();
          end
        join
        wait_frozen(scenario_id, FREEZE_SW_WAIT_CFG);

        // Rebuild the model from the first `accepted` logged beats (drop-oldest ring), then check
        // content / ordering / timestamps / wptr / wrapped exactly as the deterministic scenarios do.
        accepted = dut_we_cnt;
        gm_arm();
        for (int i = 0; i < accepted; i++) gm_record(log_hdr[i], log_aux[i], log_cyc[i]);
        gm_force_frozen();

        check_wptr(scenario_id, gm_wptr);
        check_wrapped(scenario_id, gm_count >= TRACE_DEPTH);
        read_and_check(scenario_id, gm_count, gm_count >= TRACE_DEPTH);

        // no write may be accepted after the freeze, even with traffic still driving
        accepted = dut_we_cnt;
        if (phase == 0) drive_burst_log(TRACE_DEPTH);
        else            drive_spaced_log(10, 2);
        assert (dut_we_cnt == accepted) else begin
          $display("[ERROR:%0d]: %0d writes accepted after SW freeze", scenario_id, dut_we_cnt - accepted);
          error_content = 1'b1;
        end
        check_wptr(scenario_id, gm_wptr);
      end

      // clean re-arm -> capturing again, not frozen
      do_arm();
      check_not_frozen(scenario_id, 60);
      scenario_end(scenario_id, clk_mhdma_cfg);
    end
  endtask

  // -------------------------------------------------------------------------
  // Scenario :
  // SW freeze while an error tail is still counting down.
  // trace_tail_done is (sw_freeze | err_freeze);
  // -------------------------------------------------------------------------
  task automatic run_scenario_sw_freeze_during_tail();
    int pre, tail_pushed;
    begin
      scenario_start(scenario_id, "SW freeze pre-empts an in-progress error tail");

      pre         = $urandom_range(3, 10);
      tail_pushed = $urandom_range(1, TRACE_TAIL - 1); // strictly fewer than a full tail

      do_arm();
      push_n(pre, $urandom_range(0, 3));

      assert_error();                     // starts the tail countdown and the timeout backstop
      push_n(tail_pushed, $urandom_range(0, 2));

      do_freeze();                        // pre-empt: tail is not filled, timeout has not expired
      wait_frozen(scenario_id, FREEZE_SW_WAIT_CFG);
      gm_force_frozen();

      check_wptr(scenario_id, gm_wptr);
      check_wrapped(scenario_id, gm_count >= TRACE_DEPTH);
      read_and_check(scenario_id, gm_count, gm_count >= TRACE_DEPTH);

      // clear the error before re-arming, otherwise the sticky level re-triggers immediately
      clear_error();
      do_arm();
      check_not_frozen(scenario_id, 60);

      scenario_end(scenario_id, clk_mhdma_cfg);
    end
  endtask

// ============================================================================================== --
// Main
// ============================================================================================== --
  initial begin
    header_valid   = 1'b0;
    header_data    = '0;
    error_detected = 1'b0;
    trace_aux      = '0;
    trace_arm      = 1'b0;
    trace_freeze   = 1'b0;
    trace_rd_en    = 1'b0;
    push_idx       = 0;
    log_n          = 0;
    scenario_id    = 0;

    wait (resetn_mhdma & resetn_mhdma_cfg);
    repeat (20) @(posedge clk_mhdma_cfg);

    run_scenario_default_all_headers();
    run_scenario_error_timeout();
    run_scenario_partial_tail_timeout();
    run_scenario_error_restart();
    run_scenario_sustained_traffic();
    run_scenario_reset_underfill();
    run_scenario_rearm_sticky_error();
    run_scenario_coincident_error();
    run_scenario_full_throughput();
    run_scenario_wrapped_boundary();
    run_scenario_sw_freeze();
    run_scenario_sw_freeze_midstream();
    run_scenario_sw_freeze_during_tail();

    repeat (20) @(posedge clk_mhdma_cfg);
    end_of_test = 1'b1;
  end

endmodule
