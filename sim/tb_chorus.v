`timescale 1ns/1ps

module tb_chorus;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_en = 1'b0;
    reg [1:0] mode = 2'd0;          // 0=DRY 1=CHORUS
    reg signed [15:0] sample_in = 16'sd0;

    wire signed [15:0] sample_out;
    wire               sample_valid_out;

    integer failures = 0;
    integer checks   = 0;
    integer i;

    always #5 clk = ~clk;

    chorus #(
        .SAMPLE_W  (16),
        .ADDR_W    (5),
        .MIN_DELAY (4),
        .LFO_STEP  (24'd0)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .sample_en        (sample_en),
        .mode             (mode),
        .sample_in        (sample_in),
        .sample_out       (sample_out),
        .sample_valid_out (sample_valid_out)
    );

    task push_sample;
        input [15:0] value;
        begin
            @(negedge clk);
            sample_in = value;
            sample_en = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            sample_en = 1'b0;
        end
    endtask

    task check_output;
        input [15:0] expected;
        input [8*24-1:0] label;
        integer guard;
        begin
            // 分数插值让流水从 2 拍变成 3~4 拍，改成等 sample_valid_out 脉冲
            guard = 0;
            while (!sample_valid_out && guard < 12) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
            end
            #1;
            checks = checks + 1;
            if (!sample_valid_out || sample_out !== $signed(expected)) begin
                $display("FAIL: %0s expected=%0d got=%0d valid=%0b",
                         label, $signed(expected), sample_out, sample_valid_out);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Bypass must preserve positive and negative full-scale samples.
        push_sample(16'h04D2);
        check_output(16'h04D2, "bypass positive");

        push_sample(16'hF6D7);
        check_output(16'hF6D7, "bypass negative");

        push_sample(16'h7FFF);
        check_output(16'h7FFF, "bypass max");

        push_sample(16'h8000);
        check_output(16'h8000, "bypass min");

        // Fill the delay line before enabling the wet path. The first tested
        // wet samples then have a deterministic delayed value of 4000.
        for (i = 0; i < 8; i = i + 1) begin
            push_sample(16'd4000);
            check_output(16'd4000, "fill delay");
        end

        mode = 2'd1;
        push_sample(16'd1000);
        check_output(16'd2500, "chorus mix positive");

        push_sample(-16'sd1000);
        check_output(16'd1500, "chorus mix negative dry");

        // One sample_en pulse must produce exactly one output-valid pulse.
        @(posedge clk);
        #1;
        checks = checks + 1;
        if (sample_valid_out) begin
            $display("FAIL: valid pulse lasted more than one sample period");
            failures = failures + 1;
        end

        $display("");
        $display("PASS=%0d  FAIL=%0d", checks - failures, failures);
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
