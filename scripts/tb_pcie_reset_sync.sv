`timescale 1ns/1ps
module tb_pcie_reset_sync;
    reg clk = 0;
    reg running = 1;
    reg resetn_in = 0;
    reg software_enable = 0;
    wire resetn_out;
    wire interrupt_request = software_enable & ~resetn_out;
    hpu_pcie_reset_sync dut(.*);
    always #5 if (running) clk = ~clk;

    task release_reset;
        @(negedge clk);
        resetn_in = 1;
        repeat (3) begin
            @(posedge clk); #1;
            if (resetn_out !== 0) $fatal(1, "Reset released before four destination clocks");
        end
        @(posedge clk); #1;
        if (resetn_out !== 1) $fatal(1, "Reset failed to release synchronously");
    endtask

    initial begin
        #1;
        if (interrupt_request !== 0) $fatal(1, "Unarmed startup generated interrupt");
        release_reset();
        software_enable = 1;
        @(negedge clk); #1;
        resetn_in = 0;
        #0.1;
        if (interrupt_request !== 1) $fatal(1, "Short reset assertion lost");
        resetn_in = 1;
        repeat (3) begin
            @(posedge clk); #1;
            if (interrupt_request !== 1) $fatal(1, "Short pulse not held");
        end
        @(posedge clk); #1;
        if (interrupt_request !== 0) $fatal(1, "Pulse not released");
        @(negedge clk); running = 0;
        #2; resetn_in = 0;
        #1;
        if (interrupt_request !== 1) $fatal(1, "Stopped clock prevented assertion");
        software_enable = 0;
        #1;
        if (interrupt_request !== 0) $fatal(1, "Software mask failed");
        resetn_in = 1;
        #20;
        if (resetn_out !== 0) $fatal(1, "Reset released without destination clock");
        running = 1;
        repeat (4) @(posedge clk);
        #1;
        if (resetn_out !== 1) $fatal(1, "Reset stuck after clock restart");
        $display("RESET_SIMULATION_PASSED");
        $finish;
    end
    initial begin #1000; $fatal(1, "Simulation timeout"); end
endmodule
