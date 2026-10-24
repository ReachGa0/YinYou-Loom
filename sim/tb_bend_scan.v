`timescale 1ns/1ps

module tb_bend_scan;
    localparam VOICES     = 4;
    localparam PHASE_BITS = 32;

    reg clk;
    reg rst_n;
    reg sample_en;
    reg [15:0] bend_q15;
    reg [VOICES*PHASE_BITS-1:0] inc_flat;
    wire [VOICES*PHASE_BITS-1:0] inc_bent_flat;
    wire scan_done;

    integer failures;

    bend_scan #(
        .VOICES     (VOICES),
        .PHASE_BITS (PHASE_BITS)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .sample_en     (sample_en),
        .bend_q15      (bend_q15),
        .inc_flat      (inc_flat),
        .inc_bent_flat (inc_bent_flat),
        .scan_done     (scan_done)
    );

    always #5 clk = ~clk;

    task check;
        input condition;
        input [8*48-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                failures = failures + 1;
            end
        end
    endtask

    task do_scan;
        begin
            @(negedge clk);
            sample_en = 1'b1;
            @(negedge clk);
            sample_en = 1'b0;
            @(posedge scan_done);
            #1;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        sample_en = 1'b0;
        bend_q15 = 16'd16384;
        inc_flat = {32'd4, 32'd3, 32'd2, 32'd1};
        failures = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        do_scan();
        check(inc_bent_flat[0*PHASE_BITS +: PHASE_BITS] === 32'd0,
              "inc 1 x 0.5");
        check(inc_bent_flat[1*PHASE_BITS +: PHASE_BITS] === 32'd1,
              "inc 2 x 0.5");
        check(inc_bent_flat[2*PHASE_BITS +: PHASE_BITS] === 32'd1,
              "inc 3 x 0.5 truncates");
        check(inc_bent_flat[3*PHASE_BITS +: PHASE_BITS] === 32'd2,
              "inc 4 x 0.5");

        bend_q15 = 16'd32768;
        do_scan();
        check(inc_bent_flat[3*PHASE_BITS +: PHASE_BITS] === 32'd4,
              "unity gain preserves increment");

        $display("");
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
