// BSD 3-Clause Clear License
// Capture reset even when PCIe clocks stop; release in the management domain.
module hpu_pcie_reset_sync (
    input wire clk,
    input wire resetn_in,
    output wire resetn_out
);
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg [3:0] release_pipe = 4'b0000;
    always @(posedge clk or negedge resetn_in) begin
        if (!resetn_in)
            release_pipe <= 4'b0000;
        else
            release_pipe <= {release_pipe[2:0], 1'b1};
    end
    assign resetn_out = release_pipe[3];
endmodule
