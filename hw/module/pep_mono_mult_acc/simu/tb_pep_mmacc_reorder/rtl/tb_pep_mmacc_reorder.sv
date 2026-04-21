// ==============================================================================================
// BSD 3-Clause Clear License
// Copyright © 2025 ZAMA. All rights reserved.
// ----------------------------------------------------------------------------------------------
// Description  :
// ----------------------------------------------------------------------------------------------
//
// Unit testbench for pep_mmacc_splitc_sxt_reorder.
//
// The DUT consumes
//  -> STG_ITER_NB beats of R*PSI coefficients (reverse order)
// emits STG_ITER_NB beats of
//  -> R*PSI coefficients (natural order)
// Body bypasses the buffer: out_data[0][0] = in_data[0][0], other positions are zero.
//
// Strategy
// --------
//  * Scenario builds a random sequence of mask groups and body beats, and simultaneously
//    pushes the expected output beat(s) into a queue in the exact order the DUT should emit
//    them:
//      - Body beats are pushed immediately as they are submitted (they pass through in
//        ST_WRITE).
//      - A mask group yields STG_ITER_NB expected output beats only after its STG_ITER_NB
//        input beats are submitted (the DUT transitions to ST_READ after the last one).
//  * Input driver consumes `in_q` with random valid-pacing.
//  * Output consumer back-pressures out_rdy randomly.
//  * Output checker pops from `expected_q` and compares.
//
// The check is parameter-agnostic: it reproduces the DUT's documented mapping
//    out_beat[k][s*STG_ITER_NB + t] =
//        in_beat[rev(t, STG_ITER_SZ)][rev(k*ROWS_PER_BEAT + s, RPSI_SZ)]
// with ROWS_PER_BEAT = R*PSI/STG_ITER_NB and RPSI_SZ = $clog2(R*PSI).
//
// ==============================================================================================

`timescale 1ns/10ps

module tb_pep_mmacc_reorder;
  import param_tfhe_pkg::*;
  import top_common_param_pkg::*;
  import ntt_core_common_param_pkg::*;
  import pep_common_param_pkg::*;
  import pep_mmacc_common_param_pkg::*;
  import pep_mmacc_splitc_sxt_pkg::*;

// ============================================================================================== --
// Parameter / localparam
// ============================================================================================== --
  localparam int CLK_HALF_PERIOD = 1;
  localparam int ARST_ACTIVATION = 17;

  localparam int ROWS_PER_BEAT = RD_COEF_NB / STG_ITER_NB;

  parameter int MASK_GROUP_NB = 500;
  parameter int BODY_NB       = 100;

  initial begin
    $display("> INFO: R             = %0d", R);
    $display("> INFO: PSI           = %0d", PSI);
    $display("> INFO: MOD_Q_W       = %0d", MOD_Q_W);
    $display("> INFO: STG_ITER_NB   = %0d", STG_ITER_NB);
    $display("> INFO: STG_ITER_SZ   = %0d", STG_ITER_SZ);
    $display("> INFO: RD_COEF_NB    = %0d", RD_COEF_NB);
    $display("> INFO: RD_COEF_W     = %0d", RD_COEF_W);
    $display("> INFO: ROWS_PER_BEAT = %0d", ROWS_PER_BEAT);
  end

// ============================================================================================== --
// Function
// ============================================================================================== --
  // Bit-reversal of the column (iteration) index over STG_ITER_SZ bits.
  function automatic int rev_col(input int t);
    rev_col = 0;
    for (int b=0; b<STG_ITER_SZ; b=b+1)
      rev_col[b] = t[STG_ITER_SZ-1-b];
  endfunction

  // Bit-reversal of the row (within R*PSI) index over RD_COEF_W bits.
  function automatic int rev_row(input int j);
    rev_row = 0;
    for (int b=0; b<RD_COEF_W; b=b+1)
      rev_row[b] = j[RD_COEF_W-1-b];
  endfunction

// ============================================================================================== --
// Clock / reset
// ============================================================================================== --
  bit clk;
  bit a_rst_n;
  bit s_rst_n;

  initial begin
    clk     = 1'b0;
    a_rst_n = 1'b0;
    #ARST_ACTIVATION a_rst_n = 1'b1;
  end

  always #CLK_HALF_PERIOD clk = ~clk;

  always_ff @(posedge clk)
    s_rst_n <= a_rst_n;

// ============================================================================================== --
// End of test / error
// ============================================================================================== --
  bit end_of_test;
  bit error;

  initial begin
    wait (end_of_test);
    @(posedge clk) $display("%t > SUCCEED !", $time);
    $finish;
  end

  always_ff @(posedge clk)
    if (error) begin
      $display("%t > FAILURE !", $time);
      $finish;
    end

// ============================================================================================== --
// DUT
// ============================================================================================== --
  logic [PSI-1:0][R-1:0][MOD_Q_W-1:0] in_data;
  logic                               in_is_body;
  logic                               in_vld;
  logic                               in_rdy;

  logic [PSI-1:0][R-1:0][MOD_Q_W-1:0] out_data;
  logic                               out_is_body;
  logic                               out_vld;
  logic                               out_rdy;

  pep_mmacc_splitc_sxt_reorder pep_mmacc_splitc_sxt_reorder (
    .clk         (clk        ),
    .s_rst_n     (s_rst_n    ),

    .in_data     (in_data    ),
    .in_is_body  (in_is_body ),
    .in_vld      (in_vld     ),
    .in_rdy      (in_rdy     ),

    .out_data    (out_data   ),
    .out_is_body (out_is_body),
    .out_vld     (out_vld    ),
    .out_rdy     (out_rdy    )
  );

// ============================================================================================== --
// Reference queues
// ============================================================================================== --
  typedef struct packed {
    logic                               is_body;
    logic [PSI-1:0][R-1:0][MOD_Q_W-1:0] data;
  } beat_t;

  beat_t in_q[$];
  beat_t expected_q[$];

  logic stim_done;

// ============================================================================================== --
// Scenario: build input stream and expected output stream
// ============================================================================================== --
  initial begin : scenario
    int mask_sent;
    int body_sent;
    int accum_cnt;
    logic [PSI-1:0][R-1:0][MOD_Q_W-1:0] accum [STG_ITER_NB];

    stim_done = 1'b0;
    mask_sent = 0;
    body_sent = 0;
    accum_cnt = 0;

    wait (s_rst_n);
    @(posedge clk);

    while (mask_sent < MASK_GROUP_NB || body_sent < BODY_NB) begin
      logic do_body;

      do_body = (body_sent < BODY_NB) && ((mask_sent == MASK_GROUP_NB) || ($urandom_range(0,9) == 0));

      if (do_body) begin
        beat_t b;
        beat_t e;

        b.is_body = 1'b1;
        for (int p=0; p<PSI; p++)
          for (int r=0; r<R; r++)
            b.data[p][r] = {$urandom(), $urandom()};
        in_q.push_back(b);

        // Expected: only [0][0] propagates, rest zero.
        e.is_body    = 1'b1;
        e.data       = '0;
        e.data[0][0] = b.data[0][0];
        expected_q.push_back(e);

        body_sent++;
      end else begin
        beat_t b;

        b.is_body = 1'b0;
        for (int p=0; p<PSI; p++)
          for (int r=0; r<R; r++)
            b.data[p][r] = {$urandom(), $urandom()};

        in_q.push_back(b);
        accum[accum_cnt] = b.data;
        accum_cnt++;

        if (accum_cnt == STG_ITER_NB) begin
          // Mask group complete: push STG_ITER_NB expected output beats.
          for (int k=0; k<STG_ITER_NB; k++) begin
            beat_t e;
            e.is_body = 1'b0;
            e.data    = '0;
            for (int s=0; s<ROWS_PER_BEAT; s++)
              for (int t=0; t<STG_ITER_NB; t++) begin
                int m;
                int j;
                int rj;
                int rt;
                m  = s*STG_ITER_NB + t;
                rt = rev_col(t);
                j  = k*ROWS_PER_BEAT + s;
                rj = rev_row(j);
                e.data[m/R][m%R] = accum[rt][rj/R][rj%R];
              end
            expected_q.push_back(e);
          end
          mask_sent++;
          accum_cnt = 0;
        end
      end
    end

    wait (in_q.size() == 0);
    @(posedge clk);
    stim_done = 1'b1;
  end

// ============================================================================================== --
// Input driver (random valid pacing)
// ============================================================================================== --
  always_ff @(posedge clk)
    if (!s_rst_n) begin
      in_vld     <= 1'b0;
      in_data    <= '0;
      in_is_body <= 1'b0;
    end else if (!in_vld || in_rdy) begin
      if ((in_q.size() > 0) && ($urandom_range(0,99) < 70)) begin : drv_push
        beat_t b;
        b = in_q.pop_front();
        in_vld     <= 1'b1;
        in_data    <= b.data;
        in_is_body <= b.is_body;
      end else begin
        in_vld <= 1'b0;
      end
    end

// ============================================================================================== --
// Output back-pressure
// ============================================================================================== --
  always_ff @(posedge clk)
    if (!s_rst_n) out_rdy <= 1'b0;
    else          out_rdy <= ($urandom_range(0,99) < 80);

// ============================================================================================== --
// Output check
// ============================================================================================== --
  int out_beat_cnt;

  always_ff @(posedge clk)
    if (!s_rst_n) begin
      error        <= 1'b0;
      out_beat_cnt <= 0;
    end
    else if (out_vld && out_rdy) begin : do_check
      beat_t exp;
      if (expected_q.size() == 0) begin
        $display("%t > ERROR: unexpected output beat (reference queue empty)", $time);
        error <= 1'b1;
      end
      else begin
        exp = expected_q.pop_front();
        if (exp.is_body !== out_is_body) begin
          $display("%t > ERROR: is_body mismatch at beat %0d  exp=%b seen=%b",
                    $time, out_beat_cnt, exp.is_body, out_is_body);
          error <= 1'b1;
        end
        if (exp.data !== out_data) begin
          $display("%t > ERROR: data mismatch at beat %0d (is_body=%b)",
                    $time, out_beat_cnt, out_is_body);
          for (int p=0; p<PSI; p++)
            for (int r=0; r<R; r++)
              if (exp.data[p][r] !== out_data[p][r])
                $display("         [%0d][%0d] exp=0x%0x seen=0x%0x",
                          p, r, exp.data[p][r], out_data[p][r]);
          error <= 1'b1;
        end
        out_beat_cnt <= out_beat_cnt + 1;
        if ((out_beat_cnt % 500) == 0)
          $display("%t > INFO: output beat #%0d", $time, out_beat_cnt);
      end
    end

// ============================================================================================== --
// End-of-test
// ============================================================================================== --
  initial begin
    end_of_test = 1'b0;
    wait (stim_done);
    wait (expected_q.size() == 0);
    repeat(20) @(posedge clk);
    end_of_test = 1'b1;
  end

endmodule
