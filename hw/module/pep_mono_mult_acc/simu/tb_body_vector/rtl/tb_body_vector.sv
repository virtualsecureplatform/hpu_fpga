`timescale 1ns/1ps
module tb_body_vector;
  import param_tfhe_pkg::*;
  import pep_common_param_pkg::*;
  parameter string VECTOR_DIR = "";
  parameter integer INJECT_REF_ERROR = 0;
  parameter integer AXI_STAGGER = 0; // Shared runner interface; no AXI in this bench.
  bit clk=0;
  always #2 clk=~clk;
  logic s_rst_n=0;
  logic ks_boram_wr_en=0, ks_boram_wr_parity=0;
  logic [MOD_KSK_W-1:0] ks_boram_wr_data=0;
  logic [PID_W-1:0] ks_boram_wr_pid=0;
  logic seq_boram_corr_wr_en=0;
  logic [KS_CORR_W-1:0] seq_boram_corr_wr_data=0;
  logic [PID_W-1:0] seq_boram_corr_wr_pid=0;
  logic [PID_W-1:0] boram_rd_pid=0;
  logic boram_rd_parity=0, boram_rd_vld=0, boram_rd_rdy;
  logic [LWE_COEF_W-1:0] boram_sxt_data;
  logic boram_sxt_data_vld, boram_sxt_data_rdy=0;
  logic [63:0] raw_body[0:0], corr[0:LWE_K-1];
  integer checks=0;
  pep_mmacc_body_ram dut (.reset_cache(1'b0), .*);
  initial begin
    repeat(20000) @(posedge clk);
    $fatal(1,"BODY_VECTOR_TIMEOUT");
  end
  initial begin
    $readmemh({VECTOR_DIR,"/expected_body.hex"},raw_body);
    $readmemh({VECTOR_DIR,"/expected_corr.hex"},corr);
    if ($isunknown(raw_body[0]) || LWE_K != 879) $fatal(1,"Invalid fixture/parameters");
    repeat(10) @(negedge clk);
    s_rst_n=1;
    repeat(TOTAL_PBS_NB+10) @(negedge clk);
    // Reuse each PID, and exercise adjacent corrections and gapped delivery.
    for (int run_id=0;run_id<4;run_id++) begin
      ks_boram_wr_pid=PID_W'(run_id%2);
      seq_boram_corr_wr_pid=ks_boram_wr_pid;
      boram_rd_pid=ks_boram_wr_pid;
      ks_boram_wr_parity=1'(run_id/2);
      boram_rd_parity=ks_boram_wr_parity;
      ks_boram_wr_data=MOD_KSK_W'(raw_body[0]);
      ks_boram_wr_en=1;
      @(negedge clk);
      ks_boram_wr_en=0;
      for (int i=0;i<LWE_K;i++) begin
        if ($isunknown(corr[i])) $fatal(1,"Missing correction %0d",i);
        seq_boram_corr_wr_data=KS_CORR_W'(corr[i]);
        seq_boram_corr_wr_en=1;
        @(negedge clk);
        if (run_id%2) begin
          seq_boram_corr_wr_en=0;
          repeat(2) @(negedge clk);
        end
      end
      seq_boram_corr_wr_en=0;
      boram_rd_vld=1;
      do @(posedge clk); while (!boram_rd_rdy);
      @(negedge clk);
      boram_rd_vld=0;
      wait(boram_sxt_data_vld);
      // Hold output backpressured and require a stable, valid answer.
      repeat(7) begin
        @(negedge clk);
        if (boram_sxt_data_vld !== 1'b1 || boram_sxt_data !== LWE_COEF_W'(980+INJECT_REF_ERROR))
          $fatal(1,"BODY_VECTOR_MISMATCH run=%0d got=%0d expected=%0d",run_id,boram_sxt_data,980+INJECT_REF_ERROR);
      end
      boram_sxt_data_rdy=1;
      @(negedge clk);
      boram_sxt_data_rdy=0;
      repeat(10) begin
        @(negedge clk);
        if (boram_sxt_data_vld) $fatal(1,"Unexpected extra output");
      end
      checks++;
    end
    $display("BODY_VECTOR_PASS: %0d runs, corrected body=980",checks);
    $finish;
  end
endmodule
