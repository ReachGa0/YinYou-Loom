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
    integer reverb_clip_count = 0;

    always #5 clk = ~clk;

    // 饱和函数命中极值说明混响反馈链已经削波。
    always @(posedge clk) begin
        #1;
        if (dut.ram_we &&
            ((dut.ram_wdata == 16'sh7fff) || (dut.ram_wdata == 16'sh8000)))
            reverb_clip_count = reverb_clip_count + 1;
    end

    fx_engine #(
        .SAMPLE_W        (SAMPLE_W),
        .CHORUS_ADDR_W   (5),
        .CHORUS_MIN_DLY  (4),
        .LFO_STEP        (24'd0),
        .MEM_ADDR_W      (6),
        .DELAY_SAMPLES   (4),
        .CLEAR_SAMPLES   (64),
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
            // 预留状态机与共享 RAM 清空的空闲周期，模拟 48 kHz 样本间隔。
            repeat (16) @(posedge clk);
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
        push_capture(16'sd1000);  // 首个新模式样本先输出干声并启动清空
        if (sample_out !== 16'sd1000) begin
            $display("FAIL: CHORUS switch should output dry sample");
            failures = failures + 1;
        end
        repeat (40) push_capture(16'sd0);
        push_capture(16'sd3000);
        repeat (4) push_capture(16'sd0);
        if (sample_out !== 16'sd1500) begin
            $display("FAIL: CHORUS tap should return half of the delayed impulse, got %0d", sample_out);
            failures = failures + 1;
        end

        mode = 2'd2;
        push_capture(16'sd1000);
        if (sample_out !== 16'sd1000) begin
            $display("FAIL: DELAY switch should output dry sample");
            failures = failures + 1;
        end
        repeat (40) push_capture(16'sd0);
        push_capture(16'sd3000);
        repeat (4) push_capture(16'sd0);
        if (sample_out !== 16'sd1500) begin
            $display("FAIL: DELAY tap should return half of the delayed impulse, got %0d", sample_out);
            failures = failures + 1;
        end

        mode = 2'd3;
        push_capture(16'sd1000);
        if (sample_out !== 16'sd1000) begin
            $display("FAIL: REVERB switch should output dry sample");
            failures = failures + 1;
        end
        repeat (40) push_capture(16'sd0);
        push_capture(16'sd3000);
        repeat (4) push_capture(16'sd0);
        if (sample_out !== 16'sd93) begin
            $display("FAIL: REVERB shortest line should return scaled impulse, got %0d", sample_out);
            failures = failures + 1;
        end

        // 重新清空后输入持续强方波，覆盖反馈共振最坏情况。
        mode = 2'd0;
        push_capture(16'sd0);
        mode = 2'd3;
        push_capture(16'sd0);
        repeat (40) push_capture(16'sd0);
        reverb_clip_count = 0;
        // 以最短延迟长度重复脉冲，逼近单条 comb 的稳态共振最坏情况。
        for (i = 0; i < 1024; i = i + 1)
            push_capture(((i % 4) == 0) ? 16'sd32767 : 16'sd0);
        if (reverb_clip_count != 0) begin
            $display("FAIL: REVERB resonant input clipped %0d times", reverb_clip_count);
            failures = failures + 1;
        end

        // 再输入持续强方波，覆盖宽带高电平输入。
        mode = 2'd0;
        push_capture(16'sd0);
        mode = 2'd3;
        push_capture(16'sd0);
        repeat (40) push_capture(16'sd0);
        reverb_clip_count = 0;
        for (i = 0; i < 4096; i = i + 1)
            push_capture(((i % 128) < 64) ? 16'sd32000 : -16'sd32000);
        if (reverb_clip_count != 0) begin
            $display("FAIL: REVERB feedback clipped %0d times", reverb_clip_count);
            failures = failures + 1;
        end

        $display("");
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
