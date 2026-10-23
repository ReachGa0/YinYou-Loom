`timescale 1ns/1ps

// ============================================================
// tb_test_mode.v —— 测试模式（P6.1 / P6.3）仿真
//
// 组成：test_mode + 真实 synth_engine(VOICES=4)，与上板顶层同一套模块，
//       因此这里"数出来的峰"就是产品通路产生的峰。
//
// 时钟：100 MHz，每 32 个周期一个 sample_en。波形按"每个 sample_en 一个样本"
//       解释，所以仿真时间轴与真实 48 kHz 时间无关，只影响仿真速度
//       （与既有 tb_p4_chord.v 的处理一致）。
//
// 断言：
//   1. note_on / note_off 必须是单周期脉冲（voice_alloc 电平敏感）
//   2. enable 后 4 个声部全部起音，且发声期间一直保持
//   3. enable 撤销后全部释放，test_mode 回到空闲
//   4. 混音不饱和（峰值 < 32000，留约 2% 余量）
//
// 输出：sim/out/test_mode_tones.txt（4800 点）
//       交给 pcm2wav.py + spectrum_peaks.py 数出 4 条谱线：
//       433.59375 / 527.34375 / 656.25 / 785.15625 Hz
// ============================================================

module tb_test_mode;
    localparam VOICES     = 4;
    localparam PHASE_BITS = 32;
    localparam CLK_MHZ    = 100;          // TB 时钟
    localparam DIV        = 31;           // 每 32 周期一个 sample_en
    localparam DUMP_LEN   = 4800;         // 与既有音频分析一致

    reg         clk;
    reg         rst_n;
    reg         sample_en;
    reg         enable;
    wire        note_on;
    wire        note_off;
    wire [6:0]  note_id;
    wire [31:0] note_inc;
    wire        busy;
    wire [5:0]  active_cnt;
    wire signed [15:0] mix_sample;
    wire        scan_done;
    wire [VOICES-1:0]  voice_active;
    wire [VOICES-1:0]  voice_busy;

    integer div;
    integer out_fd;
    integer i;
    integer failures;
    integer guard;

    // note_on / note_off 连续为高的最长周期数
    integer on_run, on_run_max;
    integer off_run, off_run_max;

    integer max_abs;
    reg     capturing;

    test_mode #(
        .CLK_MHZ (CLK_MHZ),
        .N_TONES (VOICES),
        .HOLD_US (500)
    ) u_test (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (enable),
        .note_on    (note_on),
        .note_off   (note_off),
        .note_id    (note_id),
        .note_inc   (note_inc),
        .busy       (busy),
        .active_cnt (active_cnt)
    );

    synth_engine #(
        .VOICES        (VOICES),
        .PHASE_BITS    (PHASE_BITS),
        .ADDR_BITS     (12),
        .SAMPLE_W      (16),
        .LEVEL_W       (16),
        .NOTE_ID_W     (7),
        .SUSTAIN_LEVEL (16'd32768),
        .INIT_FILE0    ("data/wavetables/sine_4096x16.hex"),
        .INIT_FILE1    ("data/wavetables/square_4096x16.hex")
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_en    (sample_en),
        .table_sel    (2'd0),                 // 正弦：谱线最干净
        .bend_q15     (16'd32768),
        .velocity     (8'd255),
        .note_on      (note_on),
        .note_off     (note_off),
        .note_id      (note_id),
        .note_inc     (note_inc),
        .mix_sample   (mix_sample),
        .scan_done    (scan_done),
        .voice_active (voice_active),
        .voice_busy   (voice_busy)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!rst_n) begin
            div       <= 0;
            sample_en <= 1'b0;
        end else if (div == DIV) begin
            div       <= 0;
            sample_en <= 1'b1;
        end else begin
            div       <= div + 1;
            sample_en <= 1'b0;
        end
    end

    // 脉冲宽度监视
    always @(posedge clk) begin
        if (note_on) begin
            on_run <= on_run + 1;
        end else begin
            if (on_run > on_run_max) on_run_max <= on_run;
            on_run <= 0;
        end

        if (note_off) begin
            off_run <= off_run + 1;
        end else begin
            if (off_run > off_run_max) off_run_max <= off_run;
            off_run <= 0;
        end
    end

    // 峰值监视（只统计导出窗口内的样本）
    always @(posedge clk) begin
        if (sample_en && capturing) begin
            if (mix_sample > max_abs)  max_abs <= mix_sample;
            if (mix_sample < -max_abs) max_abs <= -mix_sample;
        end
    end

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

    task wait_samples;
        input integer n;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge scan_done);
        end
    endtask

    initial begin
        clk       = 1'b0;
        rst_n     = 1'b0;
        sample_en = 1'b0;
        enable    = 1'b0;
        div       = 0;
        failures  = 0;
        on_run    = 0;
        on_run_max = 0;
        off_run   = 0;
        off_run_max = 0;
        max_abs   = 0;
        capturing = 1'b0;
        guard     = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ---- 进入测试模式 ----
        enable = 1'b1;

        guard = 0;
        while ((voice_active !== 4'b1111) && (guard < 200000)) begin
            @(posedge clk);
            guard = guard + 1;
        end
        check(voice_active === 4'b1111, "4 voices active after entering test mode");
        check(active_cnt === 6'd4,      "active_cnt reports 4 tones");

        // ---- 等包络稳定后导出 4800 点 ----
        wait_samples(400);

        out_fd = $fopen("sim/out/test_mode_tones.txt", "w");
        if (out_fd == 0) begin
            $display("ERROR: cannot open sim/out/test_mode_tones.txt");
            $finish;
        end

        capturing = 1'b1;
        for (i = 0; i < DUMP_LEN; i = i + 1) begin
            @(posedge scan_done);
            $fwrite(out_fd, "%d\n", mix_sample);
        end
        capturing = 1'b0;
        $fclose(out_fd);

        check(voice_active === 4'b1111, "voices stay active while sounding");
        check(max_abs < 32000,          "mix does not saturate (peak < 32000)");

        // ---- 退出测试模式 ----
        enable = 1'b0;

        guard = 0;
        while ((voice_active !== 4'b0000) && (guard < 200000)) begin
            @(posedge clk);
            guard = guard + 1;
        end
        check(voice_active === 4'b0000, "all voices released after leaving test mode");
        check(busy === 1'b0,            "test_mode returns to idle");

        // ---- 脉冲宽度 ----
        repeat (4) @(posedge clk);
        check(on_run_max == 1,  "note_on is a single-cycle pulse");
        check(off_run_max == 1, "note_off is a single-cycle pulse");

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $display("INFO: dumped %0d samples to sim/out/test_mode_tones.txt", DUMP_LEN);
        $display("INFO: expected peaks = 433.59375 / 527.34375 / 656.25 / 785.15625 Hz");

        $finish;
    end
endmodule
