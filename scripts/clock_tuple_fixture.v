// Tiny out-of-context design for native placement/deskew DRC validation.
module clock_tuple_fixture(input clk, input [2:0] d, output [2:0] q);
  wire fabric_clk;
  BUFGCE #(.SIM_DEVICE("VERSAL_HBM")) bufg (.I(clk), .CE(1'b1), .O(fabric_clk));
  (* DONT_TOUCH = "TRUE" *) FDRE r0 (.C(fabric_clk), .CE(1'b1), .R(1'b0), .D(d[0]), .Q(q[0]));
  (* DONT_TOUCH = "TRUE" *) FDRE r1 (.C(fabric_clk), .CE(1'b1), .R(1'b0), .D(d[1]), .Q(q[1]));
  (* DONT_TOUCH = "TRUE" *) FDRE r2 (.C(fabric_clk), .CE(1'b1), .R(1'b0), .D(d[2]), .Q(q[2]));
endmodule
