// Exact external product: signed decomposition -> GF64 NTT -> BSK multiply -> INTT.
module tb_ntt_pbs_vector;
  import common_definition_pkg::*;
  import param_tfhe_pkg::*;
  import param_ntt_pkg::*;
  import pep_common_param_pkg::*;
  import ntt_core_common_param_pkg::*;
  `timescale 1ns/1ps
  parameter string VECTOR_DIR = "";
  parameter bit INJECT_REF_ERROR = 0;
  parameter bit INPUT_GAPS = 0;
  parameter bit SPLIT_CORE = 0;
  parameter int MAX_CYCLES = 20000;
  localparam int LANES = PSI*R;
  localparam int BEATS = (N/LANES)*GLWE_K_P1;
  bit clk=0, s_rst_n=0, loaded=0;
  always #1 clk=~clk;
  logic [63:0] decomp [0:2*N-1], expected [0:2*N-1], key_mem [0:4*N-1];
  logic [PSI-1:0][R-1:0][PBS_B_W:0] in_data;
  logic [PSI-1:0][R-1:0] in_vld='0, in_rdy, out_avail;
  logic in_sob=0, in_eob=0, in_sol=0, in_eol=0, in_sog=0, in_eog=0;
  logic in_ctrl=0, in_ctrl_rdy;
  logic [PSI-1:0][R-1:0][63:0] out_data;
  logic out_sob,out_eob,out_sol,out_eol,out_sog,out_eog,out_ctrl;
  logic [BPBS_ID_W-1:0] out_pid;
  logic [PSI-1:0][R-1:0][GLWE_K_P1-1:0][63:0] bsk;
  logic [PSI-1:0][R-1:0][GLWE_K_P1-1:0] bsk_vld,bsk_rdy;
  logic error;
  integer key_pos [PSI][R][GLWE_K_P1];
  integer out_pos [PSI][R];
  integer modsw_pos [PSI][R];
  integer cycles=0, ctrl_pos=0;

  function automatic integer reverse11(input integer value);
    reverse11=0;
    for (int i=0;i<11;i++) reverse11=(reverse11<<1)|((value>>i)&1);
  endfunction

  if (!SPLIT_CORE) begin : monolithic
  ntt_core_gf64 #(.RAM_LATENCY(2), .ROM_LATENCY(2)) dut (
    .clk(clk), .s_rst_n(s_rst_n),
    .decomp_ntt_data(in_data), .decomp_ntt_data_vld(in_vld), .decomp_ntt_data_rdy(in_rdy),
    .decomp_ntt_sob(in_sob), .decomp_ntt_eob(in_eob),
    .decomp_ntt_sol(in_sol), .decomp_ntt_eol(in_eol),
    .decomp_ntt_sog(in_sog), .decomp_ntt_eog(in_eog),
    .decomp_ntt_pbs_id({BPBS_ID_W{1'b0}}), .decomp_ntt_ctrl_vld(in_ctrl), .decomp_ntt_ctrl_rdy(in_ctrl_rdy),
    .ntt_acc_data(out_data), .ntt_acc_data_avail(out_avail),
    .ntt_acc_sob(out_sob), .ntt_acc_eob(out_eob), .ntt_acc_sol(out_sol), .ntt_acc_eol(out_eol),
    .ntt_acc_sog(out_sog), .ntt_acc_eog(out_eog), .ntt_acc_pbs_id(out_pid), .ntt_acc_ctrl_avail(out_ctrl),
    .bsk(bsk), .bsk_vld(bsk_vld), .bsk_rdy(bsk_rdy), .error(error)
  );
  end else begin : split_core
  ntt_split_vector #(.RAM_LATENCY(2), .ROM_LATENCY(2)) dut (
    .clk(clk), .s_rst_n(s_rst_n),
    .decomp_ntt_data(in_data), .decomp_ntt_data_vld(in_vld), .decomp_ntt_data_rdy(in_rdy),
    .decomp_ntt_sob(in_sob), .decomp_ntt_eob(in_eob),
    .decomp_ntt_sol(in_sol), .decomp_ntt_eol(in_eol),
    .decomp_ntt_sog(in_sog), .decomp_ntt_eog(in_eog),
    .decomp_ntt_pbs_id({BPBS_ID_W{1'b0}}), .decomp_ntt_ctrl_vld(in_ctrl), .decomp_ntt_ctrl_rdy(in_ctrl_rdy),
    .ntt_acc_data(out_data), .ntt_acc_data_avail(out_avail),
    .ntt_acc_sob(out_sob), .ntt_acc_eob(out_eob), .ntt_acc_sol(out_sol), .ntt_acc_eol(out_eol),
    .ntt_acc_sog(out_sog), .ntt_acc_eog(out_eog), .ntt_acc_pbs_id(out_pid), .ntt_acc_ctrl_avail(out_ctrl),
    .bsk(bsk), .bsk_vld(bsk_vld), .bsk_rdy(bsk_rdy), .error(error)
  );
  end

  for (genvar p=0;p<PSI;p++) begin : gp
    for (genvar r=0;r<R;r++) begin : gr
      logic [63:0] torus;
      logic torus_avail;
      mod_switch_to_2powerN #(
        .MOD_Q_W(64),.MOD_P_W(64),.MOD_P(64'hffffffff00000001),
        .MOD_P_INV_TYPE(GOLDILOCKS_INV),.MULT_TYPE(MULT_CORE),
        .PRECISION_W(96),.IN_PIPE(1'b1),.SIDE_W(1)
      ) modsw (
        .clk(clk),.s_rst_n(s_rst_n),.a(out_data[p][r]),.z(torus),
        .in_avail(out_avail[p][r]),.out_avail(torus_avail),.in_side(1'b0),.out_side()
      );
      always @(posedge clk)
        if(!s_rst_n) modsw_pos[p][r]<=0;
        else if(torus_avail) begin
          integer idx;
          logic[127:0] wide;
          logic[63:0] ref_torus;
          idx=(modsw_pos[p][r]%2)*N+reverse11((modsw_pos[p][r]/2)*LANES+p*R+r);
          wide=({64'b0,expected[idx]}<<64)+128'h7fffffff80000000;
          ref_torus=64'(wide/128'hffffffff00000001);
          if(modsw_pos[p][r]>=BEATS || torus !== ref_torus)
            $fatal(1,"Prime-to-torus mismatch index=%0d actual=%h expected=%h",idx,torus,ref_torus);
          modsw_pos[p][r]<=modsw_pos[p][r]+1;
        end
      for (genvar g=0;g<GLWE_K_P1;g++) begin : gg
        always_comb begin
          bsk_vld[p][r][g]=loaded && s_rst_n && key_pos[p][r][g]<BEATS;
          bsk[p][r][g]='0;
          if (bsk_vld[p][r][g])
            bsk[p][r][g]=key_mem[g*2*N + key_pos[p][r][g]*LANES+p*R+r];
        end
        always @(posedge clk)
          if (!s_rst_n) key_pos[p][r][g]<=0;
          else if (bsk_rdy[p][r][g]) begin
            if (!bsk_vld[p][r][g] || $isunknown(bsk[p][r][g])) $fatal(1,"Missing BSK");
            key_pos[p][r][g]<=key_pos[p][r][g]+1;
          end
      end
      always @(posedge clk)
        if (!s_rst_n) out_pos[p][r]<=0;
        else if (out_avail[p][r]) begin
          integer idx;
          idx=(out_pos[p][r]%2)*N + reverse11((out_pos[p][r]/2)*LANES+p*R+r);
          if (out_pos[p][r]>=BEATS || $isunknown(out_data[p][r]) || out_data[p][r] !== expected[idx])
            $fatal(1,"PBS external-product mismatch p=%0d r=%0d beat=%0d index=%0d expected=%h actual=%h",
                   p,r,out_pos[p][r],idx,expected[idx],out_data[p][r]);
          out_pos[p][r]<=out_pos[p][r]+1;
        end
    end
  end

  always @(posedge clk) if (s_rst_n) begin
    cycles<=cycles+1;
    if (cycles>=MAX_CYCLES) $fatal(1,"PBS watchdog: output beats=%0d",ctrl_pos);
    if (error !== 1'b0) $fatal(1,"NTT/BSK error");
    if (in_ctrl && (in_ctrl_rdy !== 1'b1 || in_rdy !== {LANES{1'b1}})) $fatal(1,"Input not ready");
    if (out_ctrl) begin
      if (out_pid !== '0 ||
          {out_sob,out_eob,out_sol,out_eol,out_sog,out_eog} !==
          {1'(ctrl_pos==0),1'(ctrl_pos==BEATS-1),1'(ctrl_pos%2==0),1'(ctrl_pos%2==1),1'(ctrl_pos==0),1'(ctrl_pos==BEATS-1)})
        $fatal(1,"PBS output control mismatch beat=%0d",ctrl_pos);
      ctrl_pos<=ctrl_pos+1;
    end
  end

  initial begin
    if (N!=2048 || PSI!=64 || R!=2 || GLWE_K!=1 || PBS_L!=1 || PBS_B_W!=23 ||
        NTT_RDX_CUT_NB!=2 || NTT_RDX_CUT_S[0]!=5 || NTT_RDX_CUT_S[1]!=6)
      $fatal(1,"Unexpected PBS vector parameters");
    $readmemh({VECTOR_DIR,"/decomp.hex"},decomp);
    $readmemh({VECTOR_DIR,"/expected.hex"},expected);
    $readmemh({VECTOR_DIR,"/bsk_hpu.hex"},key_mem);
    foreach(decomp[i])
      if ($isunknown(decomp[i]) || $isunknown(expected[i])) $fatal(1,"Missing vector coefficient");
    foreach(key_mem[i]) if ($isunknown(key_mem[i])) $fatal(1,"Missing key coefficient");
    if (INJECT_REF_ERROR) expected[0]=expected[0]^64'd1;
    loaded=1;
    repeat(10) @(negedge clk);
    s_rst_n=1;
    repeat(30) @(negedge clk);
    for (int beat=0;beat<BEATS;beat++) begin
      @(negedge clk);
      in_vld='1; in_ctrl=1;
      in_sob=beat==0; in_eob=beat==BEATS-1;
      in_sol=beat%2==0; in_eol=beat%2==1;
      in_sog=beat==0; in_eog=beat==BEATS-1;
      for (int p=0;p<PSI;p++) for(int r=0;r<R;r++)
        in_data[p][r]=decomp[(beat%2)*N+reverse11((beat/2)*LANES+p*R+r)];
      if (INPUT_GAPS && beat%2==1) begin
        @(negedge clk); in_vld='0; in_ctrl=0;
        repeat(beat%3+1) @(negedge clk);
      end
    end
    @(negedge clk); in_vld='0; in_ctrl=0;
    wait(ctrl_pos==BEATS);
    repeat(128) @(negedge clk);
    for(int p=0;p<PSI;p++) for(int r=0;r<R;r++) begin
      if(out_pos[p][r]!=BEATS) $fatal(1,"Incomplete output");
      if(modsw_pos[p][r]!=BEATS) $fatal(1,"Incomplete modulus-switch output");
      for(int g=0;g<GLWE_K_P1;g++)
        if(key_pos[p][r][g]!=BEATS) $fatal(1,"Incomplete key consumption");
    end
    $display("PBS_VECTOR_PASS: %0d external-product coefficients match CPU; cycles=%0d gaps=%0d",2*N,cycles,INPUT_GAPS);
    $finish;
  end
endmodule
