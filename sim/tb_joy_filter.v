`timescale 1ns/1ps

module tb_joy_filter;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_valid = 1'b0;
    reg sample_fault = 1'b0;
    reg [15:0] sample_in = 16'd0;
    wire signed [16:0] filtered_out;

    integer failures = 0;

    joy_filter #(
        .WIDTH (16),
        .SHIFT (3)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_valid (sample_valid),
        .sample_fault (sample_fault),
        .sample_in    (sample_in),
        .filtered_out (filtered_out)
    );

    always #5 clk = ~clk;

    task check;
        input condition;
        input [8*56-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                failures = failures + 1;
            end
        end
    endtask

    task push_sample;
        input [15:0] value;
        begin
            @(negedge clk);
            sample_in    = value;
            sample_valid = 1'b1;
            @(negedge clk);
            sample_valid = 1'b0;
            repeat (3) @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        push_sample(16'd4000);
        check(filtered_out == 17'sd4000, "first sample primes filter directly");

        push_sample(16'd4000);
        push_sample(16'd4000);
        check(filtered_out == 17'sd4000, "steady input remains at center code");

        push_sample(16'd12000);
        check(filtered_out == 17'sd4000, "single-sample spike is rejected by median");
        push_sample(16'd4000);
        check(filtered_out == 17'sd4000, "filter returns to steady input after spike");

        push_sample(16'd4800);
        push_sample(16'd4800);
        push_sample(16'd4800);
        check(filtered_out > 17'sd4000, "sustained real movement passes through filter");

        sample_fault = 1'b1;
        push_sample(16'd0);
        check(filtered_out > 17'sd4000, "fault sample does not corrupt last valid value");
        sample_fault = 1'b0;

        $display("");
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
