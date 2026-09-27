// Behavioral bank memory -> real ksk_if/cache -> real ksk_manager.
// Models the host's four-u64 stripe across 16 PCs; no physical HBM simulation.
module ks_vector_cached_source
  import param_tfhe_pkg::*;
  import top_common_param_pkg::*;
  import pep_common_param_pkg::*;
  import pep_ks_common_param_pkg::*;
  import ksk_mgr_common_param_pkg::*;
  import axi_if_ksk_axi_pkg::*;
#(
  parameter string VECTOR_DIR = "",
  parameter bit AXI_STAGGER = 0,
  parameter bit INJECT_MEM_ERROR = 0
)(
  input logic clk, s_rst_n, loaded, batch_start,
  input logic [KS_BATCH_CMD_W-1:0] batch_cmd,
  input logic batch_avail,
  output logic key_loaded,
  output logic [LBX-1:0][LBY-1:0][LBZ-1:0][MOD_KSK_W-1:0] ksk,
  output logic [LBX-1:0][LBY-1:0] ksk_vld,
  input logic [LBX-1:0][LBY-1:0] ksk_rdy
);
  localparam int WORDS = KS_BLOCK_COL_NB * LBX * KS_BLOCK_LINE_NB * KS_LG_NB * LBY;
  localparam int BANK_BYTES = WORDS / 16 * 8;
  logic [63:0] memory_words [0:WORDS-1];
  logic [KSK_PC-1:0][AXI4_ID_W-1:0] arid, rid;
  logic [KSK_PC-1:0][AXI4_ADD_W-1:0] araddr;
  logic [KSK_PC-1:0][7:0] arlen;
  logic [KSK_PC-1:0][2:0] arsize;
  logic [KSK_PC-1:0][1:0] arburst, rresp;
  logic [KSK_PC-1:0] arvalid, arready, rlast, rvalid, rready;
  logic [KSK_PC-1:0][AXI4_DATA_W-1:0] rdata;
  logic [KSK_PC_MAX-1:0][AXI4_ADD_W-1:0] base;
  logic [KSK_CUT_NB-1:0] wr_en;
  logic [KSK_CUT_NB-1:0][KSK_CUT_FCOEF_NB-1:0][LBZ-1:0][MOD_KSK_W-1:0] wr_data;
  logic [KSK_CUT_NB-1:0][KSK_RAM_ADD_W-1:0] wr_add;
  logic [KSK_CUT_NB-1:0][LBX_W-1:0] wr_x;
  logic [KSK_CUT_NB-1:0][KSK_SLOT_W-1:0] wr_slot;
  logic [KSK_CUT_NB-1:0][KS_BLOCK_COL_W-1:0] wr_loop;
  logic inc_rd;
  pep_ksk_error_t error;
  integer cycle = 0;

  initial begin
    if (KSK_PC != 16 || KSK_CUT_NB != 16 || KSK_SLOT_NB != 8 ||
        KSK_CUT_FCOEF_NB != 4 || AXI4_DATA_W != 256 || TOTAL_BATCH_NB != 1)
      $fatal(1, "Unexpected KSK integration parameters");
    $readmemh({VECTOR_DIR,"/ksk.hex"}, memory_words);
    // Same physical bank addresses as the host configuration, plus a nonzero
    // aligned allocation offset to test that base addresses are honored.
    for (int pc=0; pc<KSK_PC_MAX; pc++)
      base[pc] = 64'h4000000000 + 64'(pc < 8 ? pc : pc+8) * 64'h20000000 + 64'h1000;
  end
  always @(posedge clk) if (s_rst_n) begin
    cycle <= cycle + 1;
    if (error !== '0) $fatal(1, "KSK manager error: %h", error);
  end

  ksk_if loader (
    .clk(clk), .s_rst_n(s_rst_n), .reset_cache(1'b0), .reset_cache_done(),
    .m_axi4_arid(arid), .m_axi4_araddr(araddr), .m_axi4_arlen(arlen),
    .m_axi4_arsize(arsize), .m_axi4_arburst(arburst),
    .m_axi4_arvalid(arvalid), .m_axi4_arready(arready),
    .m_axi4_rid(rid), .m_axi4_rdata(rdata), .m_axi4_rresp(rresp),
    .m_axi4_rlast(rlast), .m_axi4_rvalid(rvalid), .m_axi4_rready(rready),
    .ksk_mem_avail(loaded && s_rst_n), .ksk_mem_addr(base),
    .batch_start_1h(batch_start), .inc_ksk_wr_ptr(key_loaded), .inc_ksk_rd_ptr(inc_rd),
    .ksk_mgr_wr_en(wr_en), .ksk_mgr_wr_data(wr_data), .ksk_mgr_wr_add(wr_add),
    .ksk_mgr_wr_x_idx(wr_x), .ksk_mgr_wr_slot(wr_slot), .ksk_mgr_wr_ks_loop(wr_loop),
    .load_ksk_pc_recp_dur()
  );
  // hpu_3parts_1in3_core passes hpu_common_param_pkg::URAM_LATENCY = 4.
  ksk_manager #(.RAM_LATENCY(4)) manager (
    .clk(clk), .s_rst_n(s_rst_n), .reset_cache(1'b0),
    .ksk(ksk), .ksk_vld(ksk_vld), .ksk_rdy(ksk_rdy),
    .batch_cmd(batch_cmd), .batch_cmd_avail(batch_avail),
    .wr_en(wr_en), .wr_data(wr_data), .wr_add(wr_add),
    .wr_x_idx(wr_x), .wr_slot(wr_slot), .wr_ks_loop(wr_loop),
    .inc_ksk_rd_ptr(inc_rd), .error(error)
  );

  // One outstanding burst per PC is legal AXI. Channels run independently;
  // optional deterministic delays exercise unequal arrival times/backpressure.
  for (genvar pc=0; pc<KSK_PC; pc++) begin : bank
    bit busy = 0;
    integer beat = 0, beats = 0, delay_left = 0;
    integer beat_index;
    logic [AXI4_ID_W-1:0] saved_id;
    logic [63:0] offset;
    always_comb begin
      arready[pc] = s_rst_n && !busy && (!AXI_STAGGER || (cycle+pc)%5 != 0);
      rvalid[pc] = busy && delay_left == 0;
      rid[pc] = saved_id;
      rresp[pc] = 0;
      rlast[pc] = beat == beats-1;
      beat_index = int'(offset / 32) + beat;
      rdata[pc] = '0;
      if (busy)
        for (int lane=0; lane<4; lane++)
          rdata[pc][lane*64+:64] = memory_words[beat_index*64 + pc*4 + lane];
      if (INJECT_MEM_ERROR && pc == 0 && beat_index == 0)
        rdata[pc][0] = ~rdata[pc][0];
    end
    always @(posedge clk) begin
      if (!s_rst_n) begin
        busy <= 0;
        beat <= 0;
        beats <= 0;
        delay_left <= 0;
        offset <= 0;
        saved_id <= 0;
      end else begin
        if (arvalid[pc] && arready[pc]) begin
          if ($isunknown({araddr[pc], arlen[pc], arsize[pc], arburst[pc], arid[pc]}) ||
              araddr[pc] < base[pc] || araddr[pc] + (int'(arlen[pc])+1)*32 > base[pc]+BANK_BYTES ||
              araddr[pc][4:0] != 0 || arsize[pc] != 5 || arburst[pc] != 1 ||
              int'(araddr[pc][11:0]) + (int'(arlen[pc])+1)*32 > 4096)
            $fatal(1, "Invalid KSK AXI burst pc=%0d address=%h length=%0d", pc,araddr[pc],arlen[pc]);
          busy <= 1;
          offset <= araddr[pc] - base[pc];
          beats <= int'(arlen[pc]) + 1;
          beat <= 0;
          saved_id <= arid[pc];
          delay_left <= AXI_STAGGER ? 3 + pc : 0;
        end
        if (busy && delay_left > 0) delay_left <= delay_left-1;
        if (rvalid[pc] && rready[pc]) begin
          if ($isunknown(rdata[pc])) $fatal(1, "Missing KSK memory pc=%0d beat=%0d",pc,beat_index);
          if (rlast[pc]) busy <= 0;
          else begin
            beat <= beat + 1;
            delay_left <= AXI_STAGGER ? (beat+pc)%3 : 0;
          end
        end
      end
    end
  end
endmodule
