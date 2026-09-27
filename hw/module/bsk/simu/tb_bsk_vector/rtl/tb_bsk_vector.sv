// Real BSK loader/cache/manager; host-striped modeled memory, not physical HBM.
`timescale 1ns/1ps
module tb_bsk_vector;
  import param_tfhe_pkg::*;
  import param_ntt_pkg::*;
  import top_common_param_pkg::*;
  import pep_common_param_pkg::*;
  import ntt_core_common_param_pkg::*;
  import bsk_mgr_common_param_pkg::*;
  import bsk_if_common_param_pkg::*;
  import axi_if_bsk_axi_pkg::*;
  parameter string VECTOR_DIR="";
  parameter integer INJECT_REF_ERROR=0;
  parameter integer AXI_STAGGER=0;
  localparam integer STEP_WORDS=4*N;
  localparam integer BEATS=2*N/(PSI*R);
  localparam integer BANK_BYTES=LWE_K*STEP_WORDS/BSK_PC*8;
  bit clk=0;
  always #2 clk=~clk;
  bit s_rst_n=0, loaded=0, batch_start=0, cmd_avail=0;
  br_batch_cmd_t cmd;
  logic [63:0] key0[0:STEP_WORDS-1], key1[0:STEP_WORDS-1];
  logic [BSK_PC-1:0][AXI4_ID_W-1:0] arid,rid;
  logic [BSK_PC-1:0][AXI4_ADD_W-1:0] araddr;
  logic [BSK_PC-1:0][7:0] arlen;
  logic [BSK_PC-1:0][2:0] arsize;
  logic [BSK_PC-1:0][1:0] arburst,rresp;
  logic [BSK_PC-1:0] arvalid,arready,rlast,rvalid,rready;
  logic [BSK_PC-1:0][AXI4_DATA_W-1:0] rdata;
  logic [BSK_PC_MAX-1:0][AXI4_ADD_W-1:0] base;
  logic [BSK_CUT_NB-1:0] wr_en;
  logic [BSK_CUT_NB-1:0][BSK_CUT_FCOEF_NB-1:0][63:0] wr_data;
  logic [BSK_CUT_NB-1:0][BSK_RAM_ADD_W-1:0] wr_add;
  logic [BSK_CUT_NB-1:0][GLWE_K_P1_W-1:0] wr_g;
  logic [BSK_CUT_NB-1:0][BSK_SLOT_W-1:0] wr_slot;
  logic [BSK_CUT_NB-1:0][LWE_K_W-1:0] wr_loop;
  logic inc_rd,inc_wr;
  logic [PSI-1:0][R-1:0][GLWE_K_P1-1:0][63:0] bsk;
  logic [PSI-1:0][R-1:0][GLWE_K_P1-1:0] bsk_vld,bsk_rdy;
  pep_bsk_error_t error;
  integer cycles=0, credits=0, active_loop=0;
  integer pos[PSI][R][GLWE_K_P1];
  bit consume=0;
  // First two slices are real seeded keys. Later slices repeat those with a
  // distinct per-loop salt to expose wrong-slot reuse without a huge fixture.
  function automatic logic[63:0] word_at(input integer idx);
    integer loop_id, ofs;
    loop_id=idx/STEP_WORDS; ofs=idx%STEP_WORDS;
    return (loop_id%2 ? key1[ofs] : key0[ofs]) ^ (64'(loop_id/2)<<32);
  endfunction
  bsk_if loader (
    .clk(clk),.s_rst_n(s_rst_n),.reset_cache(1'b0),.reset_cache_done(),
    .m_axi4_arid(arid),.m_axi4_araddr(araddr),.m_axi4_arlen(arlen),
    .m_axi4_arsize(arsize),.m_axi4_arburst(arburst),.m_axi4_arvalid(arvalid),.m_axi4_arready(arready),
    .m_axi4_rid(rid),.m_axi4_rdata(rdata),.m_axi4_rresp(rresp),.m_axi4_rlast(rlast),
    .m_axi4_rvalid(rvalid),.m_axi4_rready(rready),
    .bsk_mem_avail(loaded && s_rst_n),.bsk_mem_addr(base),
    .batch_start_1h(batch_start),.inc_bsk_wr_ptr(inc_wr),.inc_bsk_rd_ptr(inc_rd),
    .bsk_mgr_wr_en(wr_en),.bsk_mgr_wr_data(wr_data),.bsk_mgr_wr_add(wr_add),
    .bsk_mgr_wr_g_idx(wr_g),.bsk_mgr_wr_slot(wr_slot),.bsk_mgr_wr_br_loop(wr_loop),
    .load_bsk_pc_recp_dur(),.bskif_rif_info()
  );
  bsk_manager #(.OP_W(64),.RAM_LATENCY(4)) manager (
    .clk(clk),.s_rst_n(s_rst_n),.reset_cache(1'b0),
    .bsk(bsk),.bsk_vld(bsk_vld),.bsk_rdy(bsk_rdy),
    .batch_cmd(cmd),.batch_cmd_avail(cmd_avail),
    .wr_en(wr_en),.wr_data(wr_data),.wr_add(wr_add),.wr_g_idx(wr_g),
    .wr_slot(wr_slot),.wr_br_loop(wr_loop),.inc_bsk_rd_ptr(inc_rd),.bsk_mgr_error(error)
  );
  always @(posedge clk) if(s_rst_n) begin
    cycles<=cycles+1;
    credits<=credits+int'(inc_wr)-int'(cmd_avail);
    if (cycles>1000000) $fatal(1,"BSK_VECTOR_TIMEOUT loop=%0d credits=%0d",active_loop,credits);
    if (error !== '0 || credits<0) $fatal(1,"BSK manager error=%h credits=%0d",error,credits);
  end
  for(genvar p=0;p<PSI;p++) for(genvar r=0;r<R;r++) for(genvar g=0;g<GLWE_K_P1;g++) begin
    // Match the PP consumer: columns are one clock apart, lanes in a cut
    // move together. Arbitrary independent backpressure violates this API.
    if(g==0) begin
      assign bsk_rdy[p][r][g]=consume && bsk_vld[p][r][g] && pos[p][r][g]<(active_loop+1)*BEATS
                              && (!AXI_STAGGER || cycles%5!=0);
    end else begin
      always @(posedge clk)
        if(!s_rst_n) bsk_rdy[p][r][g]<=0;
        else bsk_rdy[p][r][g]<=bsk_rdy[p][r][g-1];
    end
    always @(posedge clk) begin
      if(!s_rst_n) pos[p][r][g]<=0;
      else if(bsk_rdy[p][r][g]) begin
        integer idx;
        if(!bsk_vld[p][r][g]) $fatal(1,"Missing BSK valid");
        idx=active_loop*STEP_WORDS+g*2*N+(pos[p][r][g]%BEATS)*PSI*R+p*R+r;
        if($isunknown(bsk[p][r][g]) || bsk[p][r][g] !== word_at(idx))
          $fatal(1,"BSK mismatch loop=%0d p=%0d r=%0d g=%0d beat=%0d got=%h expected=%h",
                 active_loop,p,r,g,pos[p][r][g]%BEATS,bsk[p][r][g],word_at(idx));
        pos[p][r][g]<=pos[p][r][g]+1;
      end
    end
  end
  for(genvar pc=0;pc<BSK_PC;pc++) begin : bank
    bit busy=0;
    integer beat=0,beats=0,delay_left=0, bank_word;
    logic [AXI4_ID_W-1:0] saved_id;
    logic [63:0] offset;
    always_comb begin
      arready[pc]=s_rst_n && !busy && (!AXI_STAGGER || (cycles+pc)%5!=0);
      rvalid[pc]=busy && delay_left==0;
      rid[pc]=saved_id; rresp[pc]=0; rlast[pc]=beat==beats-1;
      bank_word=int'(offset/8)+beat*4;
      rdata[pc]='0;
      // Host BSK stripes eight u64 words per PC, unlike the KSK's four.
      if(busy) for(int lane=0;lane<4;lane++)
        rdata[pc][lane*64+:64]=word_at(((bank_word+lane)/8)*128+pc*8+(bank_word+lane)%8);
      if(INJECT_REF_ERROR && pc==0 && bank_word==0) rdata[pc][0]=~rdata[pc][0];
    end
    always @(posedge clk) begin
      if(!s_rst_n) begin
        busy<=0; beat<=0; beats<=0; delay_left<=0; offset<=0; saved_id<=0;
      end else begin
        if(arvalid[pc] && arready[pc]) begin
          if($isunknown({araddr[pc],arlen[pc],arsize[pc],arburst[pc],arid[pc]}) ||
             araddr[pc]<base[pc] || araddr[pc]+(int'(arlen[pc])+1)*32>base[pc]+BANK_BYTES ||
             araddr[pc][4:0]!=0 || arsize[pc]!=5 || arburst[pc]!=1 ||
             int'(araddr[pc][11:0])+(int'(arlen[pc])+1)*32>4096)
            $fatal(1,"Invalid BSK burst pc=%0d address=%h",pc,araddr[pc]);
          busy<=1; offset<=araddr[pc]-base[pc]; beats<=int'(arlen[pc])+1;
          beat<=0; saved_id<=arid[pc]; delay_left<=AXI_STAGGER ? pc+3 : 0;
        end
        if(busy && delay_left>0) delay_left<=delay_left-1;
        if(rvalid[pc] && rready[pc]) begin
          if($isunknown(rdata[pc])) $fatal(1,"Missing BSK memory");
          if(rlast[pc]) busy<=0;
          else begin beat<=beat+1; delay_left<=AXI_STAGGER ? (beat+pc)%3 : 0; end
        end
      end
    end
  end
  initial begin
    if(N!=2048 || PSI!=64 || R!=2 || GLWE_K!=1 || PBS_L!=1 || LWE_K!=879 ||
       BSK_PC!=16 || BSK_CUT_NB!=16 || BSK_SLOT_NB!=8 || AXI4_DATA_W!=256 || TOTAL_BATCH_NB!=1)
      $fatal(1,"Unsupported fixture parameters");
    $readmemh({VECTOR_DIR,"/step0/bsk_hpu.hex"},key0);
    $readmemh({VECTOR_DIR,"/step1/bsk_hpu.hex"},key1);
    foreach(key0[i]) if($isunknown(key0[i]) || $isunknown(key1[i])) $fatal(1,"Missing key");
    for(int pc=0;pc<BSK_PC_MAX;pc++)
      base[pc]=64'h4000000000+64'(pc<8 ? pc+8 : pc+16)*64'h20000000+64'h1000;
    cmd='0; loaded=1;
    repeat(10) @(negedge clk);
    s_rst_n=1;
    repeat(40) @(negedge clk);
    batch_start=1;
    @(negedge clk); batch_start=0;
    for(int loop_id=0;loop_id<LWE_K;loop_id++) begin
      bit all_done;
      wait(credits>0);
      @(negedge clk);
      active_loop=loop_id; cmd.br_loop=LWE_K_W'(loop_id); cmd.pbs_nb=1; cmd_avail=1;
      @(negedge clk); cmd_avail=0; consume=1;
      do begin
        @(negedge clk); all_done=1;
        foreach(pos[p,r,g]) all_done &= pos[p][r][g]==(loop_id+1)*BEATS;
      end while(!all_done);
      consume=0;
    end
    repeat(128) @(negedge clk);
    if(bsk_vld !== '0) $fatal(1,"Unexpected extra BSK output");
    $display("BSK_VECTOR_PASS: %0d words, %0d loops, %0d cycles",LWE_K*STEP_WORDS,LWE_K,cycles);
    $finish;
  end
endmodule
