`timescale 1ns/1ps
`include "loom_defs.vh"

module tb_voice_osc;

    //clock and reset
    reg clk = 0;
    reg rst_n = 0;

    //100MHz clock: reverse every 5ns
    always #5 clk = ~clk;

    //reset sequence: pull low for 100ns, then high
    initial begin
        rst_n = 0;
        #100;
        rst_n = 1;
    end

    reg signed [15:0] wavetable [0:`TABLE_SIZE-1]; // `TABLE_SIZE samples, 16-bit signed
    reg [`PHASE_BITS-1:0] phase = 0;               // 32-bit phase accumulator
    wire [`TABLE_BITS-1:0] addr;                   // table address
    wire signed [15:0] sample;                     // 16-bit signed output sample

    reg [11:0] sample_cnt = 0;            // sample counter for simulation

    localparam ADDR_LSB = `PHASE_BITS - `TABLE_BITS; // 20
    localparam INC = `INC_440;                       // 440Hz @ 48kHz
    localparam SAMPLE_DIV = 2083;                    // 100MHz / 2083 ≈ 48kHz (simulation only)

    // 上电时加载正弦波表
    initial begin
        $readmemh(`WAVETABLE_SINE, wavetable);
    end

    // 相位高 TABLE_BITS 位 -> 表地址；地址 -> 样本
    assign addr = phase[`PHASE_BITS-1 : ADDR_LSB];
    assign sample = wavetable[addr];

    // every SAMPLE_DIV clock cycles, increment phase accumulator
    always @(posedge clk) begin
        if (!rst_n) begin
            phase <= 0;
            sample_cnt <= 0;
        end else if (sample_cnt == SAMPLE_DIV - 1) begin
            sample_cnt <= 0;
            phase <= phase + INC;
        end else begin
            sample_cnt <= sample_cnt + 1;
        end
    end

    //采样文件
    integer f;        //句柄
    integer i;        //循环变量

    initial begin
        // 等待复位释放
        @(posedge rst_n);

        // 打开文件
        f = $fopen("sim/out/sine_440.txt", "w");
        if (f == 0) begin
            $display("ERROR: cannot open sim/out/sine_440.txt for writing");
            $finish;
        end

        // 写 4800 个样本 （约 0.1 秒 @ 48kHz）
        for (i = 0; i < 4800; i = i + 1) begin
            repeat (SAMPLE_DIV) @(posedge clk);
            $fwrite(f, "%d\n", sample);
        end

        // 关闭文件
        $fclose(f);
        $display("Sample data written to sim/out/sine_440.txt");
        $finish;
    end

endmodule
