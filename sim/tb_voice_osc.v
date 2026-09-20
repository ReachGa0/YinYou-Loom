`timescale 1ns/1ps
`include "loom_defs.vh"

module tb_voice_osc;

    reg clk = 0;
    reg rst_n = 0;
    reg run = 1;

    always #5 clk = ~clk;

    initial begin
        rst_n = 0;
        #100;
        rst_n = 1;
    end

    // ---- 48kHz 采样使能：单周期脉冲 ----
    localparam SAMPLE_DIV = 2083;   // 100MHz / 2083 ≈ 48kHz（仿真用）

    reg [11:0] div_cnt = 0;
    reg        sample_en = 0;

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

    // ---- 被测模块 ----
    wire signed [15:0] sample;
    wire               sample_valid;

    voice_osc #(
        .PHASE_BITS (32),
        .ADDR_BITS  (12),
        .SAMPLE_W   (16),
        .INIT_FILE  (`WAVETABLE_SINE)
    ) u_osc (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_en    (sample_en),
        .inc          (`INC_440),
        .run          (run),
        .sample       (sample),
        .sample_valid (sample_valid)
    );

    // ---- 采样写文件 ----
    integer f;
    integer i;

    initial begin
        @(posedge rst_n);

        f = $fopen("sim/out/sine_440.txt", "w");
        if (f == 0) begin
            $display("ERROR: cannot open sim/out/sine_440.txt");
            $finish;
        end

        for (i = 0; i < 4800; i = i + 1) begin
            @(posedge clk);
            while (!sample_valid)
                @(posedge clk);
            $fwrite(f, "%d\n", sample);
        end

        $fclose(f);
        $display("done: wrote 4800 samples to sim/out/sine_440.txt");
        $finish;
    end

endmodule
