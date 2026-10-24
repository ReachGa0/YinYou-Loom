`timescale 1ns/1ps

module tb_expression_map;
    reg clk;
    reg rst_n;
    reg sample_valid;
    reg signed [16:0] filtered_y;
    reg [15:0] center_y;
    wire [7:0] velocity;
    wire [7:0] expression;

    integer failures = 0;

    expression_map dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_valid (sample_valid),
        .filtered_y (filtered_y),
        .center_y   (center_y),
        .velocity   (velocity),
        .expression (expression)
    );

    always #5 clk = ~clk;

    task update_map;
        begin
            @(negedge clk);
            sample_valid = 1'b1;
            @(negedge clk);
            sample_valid = 1'b0;
            repeat (6) @(posedge clk);
        end
    endtask

    task check_u8;
        input [7:0] got;
        input [7:0] expected;
        input [8*56-1:0] message;
        begin
            if (got !== expected) begin
                $display("FAIL: %0s (got=%0d expected=%0d)", message, got, expected);
                failures = failures + 1;
            end
        end
    endtask

    task check_between;
        input [7:0] got;
        input [7:0] lo;
        input [7:0] hi;
        input [8*56-1:0] message;
        begin
            if ((got < lo) || (got > hi)) begin
                $display("FAIL: %0s (got=%0d range=%0d..%0d)",
                         message, got, lo, hi);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        sample_valid = 1'b0;
        filtered_y = 17'sd0;
        center_y = 16'd4000;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        filtered_y = 17'sd4000;
        update_map();
        check_u8(velocity,   8'd128, "center maps to velocity 128");
        check_u8(expression, 8'd90,  "center maps to expression 0.35 gain");

        filtered_y = 17'sd2000;
        update_map();
        check_between(velocity,   8'd129, 8'd255, "high-voltage side raises velocity");
        check_between(expression, 8'd91,  8'd255, "high-voltage side raises expression");

        filtered_y = 17'sd6000;
        update_map();
        check_between(velocity,   8'd0,   8'd127, "low-voltage side lowers velocity");
        check_between(expression, 8'd26,  8'd89,  "low-voltage side lowers expression");

        $display("");
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
