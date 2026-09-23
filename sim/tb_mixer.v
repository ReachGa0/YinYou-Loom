`timescale 1ns/1ps

module tb_mixer;
    parameter VOICES   = 4;
    parameter SAMPLE_W = 16;

    reg                           clk;
    reg                           rst_n;
    reg  [VOICES*SAMPLE_W-1:0]    voice_sample_flat;
    reg  [VOICES-1:0]             gate_flat;
    reg                           scan_done;
    wire signed [SAMPLE_W-1:0]    mix_sample;
    wire                          mix_valid;

    integer failures;

    mixer #(
        .VOICES   (VOICES),
        .SAMPLE_W (SAMPLE_W)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .voice_sample_flat (voice_sample_flat),
        .sound_flat        (gate_flat),
        .scan_done         (scan_done),
        .mix_sample        (mix_sample),
        .mix_valid         (mix_valid)
    );

    always #5 clk = ~clk;

    task latch_mix;
        begin
            @(negedge clk);
            scan_done = 1'b1;
            @(negedge clk);
            scan_done = 1'b0;
            @(posedge mix_valid);
            #1;
        end
    endtask

    // 增益带斜坡，计数变化后要等它走到目标值（Q15 全量程约 256 个样本）
    task settle;
        begin
            repeat (400) latch_mix;
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
        gate_flat         = {VOICES{1'b0}};
        failures          = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // 1 键：原样输出（单路 1000）。
        voice_sample_flat = {16'd0, 16'd0, 16'd0, 16'h03e8};
        gate_flat = 4'b0001;
        settle;
        check(16'sd1000, "one gate passthrough");

        // 2 键：两路各 1000，总和除以 2。
        voice_sample_flat = {16'd0, 16'd0, 16'h03e8, 16'h03e8};
        gate_flat = 4'b0011;
        settle;
        check(16'sd1000, "two gates halve");

        // 增益斜坡：计数从 1 变到 2 时，输出必须逐样本缓慢变化，不能瞬间跳一半。
        voice_sample_flat = {16'd0, 16'd0, 16'd0, 16'h03e8};
        gate_flat = 4'b0001;
        settle;
        voice_sample_flat = {16'd0, 16'd0, 16'h03e8, 16'h03e8};
        gate_flat = 4'b0011;
        latch_mix;
        begin : ramp_check
            reg signed [SAMPLE_W-1:0] s1, s2;
            s1 = mix_sample;
            latch_mix;
            s2 = mix_sample;
            if ((s1 - s2) > 16) begin
                $display("FAIL: gain ramps smoothly (got %0d -> %0d)", s1, s2);
                failures = failures + 1;
            end
        end

        // 3 键：三路各 1000，使用 21/64 近似除以 3。
        voice_sample_flat = {16'd0, 16'h03e8, 16'h03e8, 16'h03e8};
        gate_flat = 4'b0111;
        settle;
        check(16'sd984, "three gates approximately one third");

        // 4 键：四路各 1000，总和除以 4。
        voice_sample_flat = {16'h03e8, 16'h03e8, 16'h03e8, 16'h03e8};
        gate_flat = 4'b1111;
        settle;
        check(16'sd1000, "four gates quarter");

        // 归一化后仍应保护极端峰值。
        voice_sample_flat = {16'd0, 16'd0, 16'h7530, 16'h7530};
        gate_flat = 4'b0001;
        settle;
        check(16'sd32767, "positive saturation");

        voice_sample_flat = {16'd0, 16'd0, -16'sd30000, -16'sd30000};
        gate_flat = 4'b0001;
        settle;
        check(-16'sd32768, "negative saturation");

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $finish;
    end
endmodule
