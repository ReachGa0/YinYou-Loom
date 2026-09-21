`timescale 1ns/1ps

module tb_mixer;
    parameter VOICES   = 4;
    parameter SAMPLE_W = 16;

    reg                           clk;
    reg                           rst_n;
    reg  [VOICES*SAMPLE_W-1:0]    voice_sample_flat;
    reg                           scan_done;
    wire signed [SAMPLE_W-1:0]    mix_sample;

    integer failures;

    mixer #(
        .VOICES   (VOICES),
        .SAMPLE_W (SAMPLE_W)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .voice_sample_flat (voice_sample_flat),
        .scan_done         (scan_done),
        .mix_sample        (mix_sample)
    );

    always #5 clk = ~clk;

    task latch_mix;
        begin
            @(negedge clk);
            scan_done = 1'b1;
            @(negedge clk);
            scan_done = 1'b0;
            #1;
        end
    endtask

    task check;
        input signed [SAMPLE_W-1:0] expected;
        input [8*32-1:0] message;
        begin
            if (mix_sample !== expected) begin
                $display("FAIL: %0s got %0d expected %0d",
                    message, mix_sample, expected);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        clk               = 1'b0;
        rst_n             = 1'b0;
        scan_done         = 1'b0;
        voice_sample_flat = {VOICES*SAMPLE_W{1'b0}};
        failures          = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        voice_sample_flat = {16'h03e8, 16'h03e8, 16'h03e8, 16'h03e8};
        latch_mix;
        check(16'sd4000, "normal sum");

        voice_sample_flat = {16'h4e20, 16'h4e20, 16'h4e20, 16'h4e20};
        latch_mix;
        check(16'sd32767, "positive saturation");

        voice_sample_flat = {16'hb1e0, 16'hb1e0, 16'hb1e0, 16'hb1e0};
        latch_mix;
        check(-16'sd32768, "negative saturation");

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $finish;
    end
endmodule
