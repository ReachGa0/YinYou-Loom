`timescale 1ns/1ps
`include "loom_defs.vh"

// voice.v 的整体行为测试：验证"振荡器 + ADSR"接起来之后
//   1. Attack 阶段包络上升
//   2. 到达峰值后 Decay 下降
//   3. 按住期间保持在 Sustain 电平
//   4. 松开后 Release 衰减到 0，busy 落下
//
// 输出：sim/out/voice_dump.txt
// 分析：tools/adsr_check.py

module tb_voice;

    reg clk       = 0;
    reg rst_n     = 0;
    reg sample_en = 0;
    reg gate      = 0;

    always #5 clk = ~clk;

    initial begin
        rst_n = 0;
        #100;
        rst_n = 1;
    end

    // ---- 采样使能：单周期脉冲 ----
    // 这里用比 48kHz 更快的分频只为加速仿真：
    // ADSR 的形状只取决于"样本数"，与时钟分频比无关，行为等价。
    localparam SAMPLE_DIV = 208;

    reg [11:0] div_cnt = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            div_cnt   <= 0;
            sample_en <= 0;
        end else if (div_cnt == SAMPLE_DIV - 1) begin
            div_cnt   <= 0;
            sample_en <= 1;
        end else begin
            div_cnt   <= div_cnt + 1;
            sample_en <= 0;
        end
    end

    // ---- ADSR 参数（模拟钢琴：快起音、中速衰减、较长释放）----
    localparam [15:0] A_STEP     = 16'd100;    // Attack 约 655 采样
    localparam [15:0] D_STEP     = 16'd20;     // Decay 约 1.8k 采样
    localparam [15:0] SUSTAIN_LV = 16'd30000;  // 保持电平
    localparam [15:0] R_STEP     = 16'd20;     // Release 约 1.5k 采样

    localparam GATE_OFF_SAMPLE = 3000;         // 第几个样本松开按键

    wire signed [15:0] sample;
    wire               sample_valid;
    wire               busy;

    synth_top #(
        .VOICES     (1),
        .PHASE_BITS (32),
        .ADDR_BITS  (12),
        .SAMPLE_W   (16),
        .LEVEL_W    (16),
        .INIT_FILE0 (`WAVETABLE_SINE),
        .INIT_FILE1 (`WAVETABLE_SQUARE)
    ) u_synth (
        .clk                (clk),
        .rst_n              (rst_n),
        .sample_en          (sample_en),
        .table_sel          (1'b0),
        .inc_flat           (`INC_440),
        .gate_flat          (gate),
        .a_step_flat        (A_STEP),
        .d_step_flat        (D_STEP),
        .sustain_level_flat (SUSTAIN_LV),
        .r_step_flat        (R_STEP),
        .gain_flat          (16'd32768),
        .mix_sample         (sample),
        .scan_done          (sample_valid),
        .voice_valid        (),
        .busy_flat          (busy)
    );

    integer f;
    integer n;
    integer clk_cnt;

    initial begin
        @(posedge rst_n);

        f = $fopen("sim/out/voice_dump.txt", "w");
        if (f == 0) begin
            $display("ERROR: cannot open sim/out/voice_dump.txt");
            $finish;
        end

        gate    = 1;
        n       = 0;
        clk_cnt = 0;

        // 在 busy 期间采集样本；带硬超时，防止 DUT 行为异常时仿真挂死
        while ((busy || n == 0) && clk_cnt < 3000000) begin
            @(posedge clk);
            clk_cnt = clk_cnt + 1;
            if (sample_valid) begin
                $fwrite(f, "%d\n", sample);
                n = n + 1;
                if (n == GATE_OFF_SAMPLE)
                    gate = 0;
            end
        end

        $fclose(f);
        $display("done: %0d samples captured, clk_cnt=%0d, busy=%0d", n, clk_cnt, busy);
        $finish;
    end

endmodule
