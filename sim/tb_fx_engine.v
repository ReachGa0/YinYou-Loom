`timescale 1ns/1ps

module tb_fx_engine;
    localparam SAMPLE_W = 16;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_en = 1'b0;
    reg [1:0] mode = 2'd0;
    reg signed [SAMPLE_W-1:0] sample_in = 16'sd0;
    wire signed [SAMPLE_W-1:0] sample_out;
    wire valid_out;

    integer failures = 0;
    integer guard;
    integer i;

    always #5 clk = ~clk;

    fx_engine #(
        .SAMPLE_W        (SAMPLE_W),
        .CHORUS_ADDR_W   (5),
        .CHORUS_MIN_DLY  (4),
        .LFO_STEP        (24'd0),
        .DELAY_ADDR_W    (5),
        .DELAY_SAMPLES   (4),
        .REVERB_ADDR_W   (4),
        .REV_LEN0        (4),
        .REV_LEN1        (5),
        .REV_LEN2        (7),
        .REV_LEN3        (9),
        .FADE_SAMPLES    (0)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .sample_en        (sample_en),
        .mode             (mode),
        .sample_in        (sample_in),
        .sample_out       (sample_out),
        .sample_valid_out (valid_out)
    );

    task push_capture;
        input signed [SAMPLE_W-1:0] value;
        begin
            @(negedge clk);
            sample_in = value;
            sample_en = 1'b1;
            @(negedge clk);
            sample_en = 1'b0;

            guard = 0;
            while (!valid_out && guard < 64) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
            end
            if (!valid_out) begin
                $display("FAIL: fx_engine output timeout");
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Prime all delay memories with a known signal.
        repeat (16) push_capture(16'sd0);
        mode = 2'd0;
        repeat (2) push_capture(16'sd1000);
        if (sample_out !== 16'sd1000) begin
            $display("FAIL: DRY mode should pass sample");
            failures = failures + 1;
        end

        mode = 2'd1;
        repeat (12) push_capture(16'sd1000);
        if (sample_out <= 0) begin
            $display("FAIL: CHORUS mode should produce non-zero output");
            failures = failures + 1;
        end

        mode = 2'd2;
        repeat (8) push_capture(16'sd1000);
        if (sample_out <= 0) begin
            $display("FAIL: DELAY mode should produce non-zero output");
            failures = failures + 1;
        end

        mode = 2'd3;
        repeat (16) push_capture(16'sd1000);
        if (sample_out <= 0) begin
            $display("FAIL: REVERB mode should produce non-zero output");
            failures = failures + 1;
        end

        $display("");
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
