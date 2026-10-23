// ============================================================
// synth_top.v —— 参数化多声部合成引擎
//
// 结构：
//   N 个 voice（只保留相位、包络和乘法）
//        ↓ wave_addr
//   1 个共享 wavetable_arbiter + 2 张共享波表
//        ↓ wave_sample / wave_valid
//   1 个 mixer
// ============================================================

module synth_top #(
    parameter VOICES    = 4,
    parameter PHASE_BITS = 32,
    parameter ADDR_BITS  = 12,
    parameter SAMPLE_W   = 16,
    parameter LEVEL_W    = 16,
    parameter GAIN_W     = 16,
    parameter INIT_FILE0 = "data/wavetables/sine_4096x16.hex",
    parameter INIT_FILE1 = "data/wavetables/square_4096x16.hex",
    parameter INIT_FILE2 = "data/wavetables/saw_4096x16.hex",
    parameter INIT_FILE3 = "data/wavetables/triangle_4096x16.hex"
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              sample_en,
    input  wire [1:0]                        table_sel,
    input  wire [15:0]                       bend_q15,   // 32768 = 1.0（音高弯音）

    input  wire [VOICES*PHASE_BITS-1:0]      inc_flat,
    input  wire [VOICES-1:0]                 gate_flat,
    input  wire [VOICES*LEVEL_W-1:0]         a_step_flat,
    input  wire [VOICES*LEVEL_W-1:0]         d_step_flat,
    input  wire [VOICES*LEVEL_W-1:0]         sustain_level_flat,
    input  wire [VOICES*LEVEL_W-1:0]         r_step_flat,
    input  wire [VOICES*GAIN_W-1:0]          gain_flat,

    output wire signed [SAMPLE_W-1:0]        mix_sample,
    output wire                              scan_done,
    output wire [VOICES-1:0]                 voice_valid,
    output wire [VOICES-1:0]                 busy_flat
);
    wire [VOICES*ADDR_BITS-1:0]  wave_addr_flat;
    wire [VOICES*SAMPLE_W-1:0]   wave_sample_flat;
    wire [VOICES-1:0]            wave_valid_flat;
    wire [VOICES*SAMPLE_W-1:0]   voice_sample_flat;
    wire                         arb_scan_done;
    wire                         mix_valid;

    // ---- 音高弯音：所有声部乘同一个 Q15 系数 ----
    // 放在这一层，voice / voice_osc 不用改；4 个 32×16 乘法正好用 DSP。
    wire [VOICES*PHASE_BITS-1:0] inc_bent_flat;

    genvar j;
    generate
        for (j = 0; j < VOICES; j = j + 1) begin : g_bend
            // 32×16 的乘积必须用 48 位中间量承接：
            // Verilog 中乘法结果宽度取两个操作数的最大宽度，直接写会截断。
            wire [PHASE_BITS+15:0] bend_prod =
                inc_flat[j*PHASE_BITS +: PHASE_BITS] * bend_q15;
            assign inc_bent_flat[j*PHASE_BITS +: PHASE_BITS] = bend_prod >>> 15;
        end
    endgenerate

    wavetable_arbiter #(
        .VOICES    (VOICES),
        .ADDR_BITS (ADDR_BITS),
        .SAMPLE_W  (SAMPLE_W),
        .INIT_FILE0 (INIT_FILE0),
        .INIT_FILE1 (INIT_FILE1),
        .INIT_FILE2 (INIT_FILE2),
        .INIT_FILE3 (INIT_FILE3)
    ) u_arbiter (
        .clk              (clk),
        .rst_n            (rst_n),
        .sample_en        (sample_en),
        .table_sel        (table_sel),
        .wave_addr_flat   (wave_addr_flat),
        .wave_sample_flat (wave_sample_flat),
        .wave_valid       (wave_valid_flat),
        .scan_done        (arb_scan_done)
    );

    genvar i;
    generate
        for (i = 0; i < VOICES; i = i + 1) begin : g_voice
            voice #(
                .PHASE_BITS (PHASE_BITS),
                .ADDR_BITS  (ADDR_BITS),
                .SAMPLE_W   (SAMPLE_W),
                .LEVEL_W    (LEVEL_W),
                .GAIN_W     (GAIN_W)
            ) u_voice (
                .clk           (clk),
                .rst_n         (rst_n),
                .sample_en     (sample_en),
                .inc           (inc_bent_flat[i*PHASE_BITS +: PHASE_BITS]),
                .gate          (gate_flat[i]),
                .a_step        (a_step_flat[i*LEVEL_W +: LEVEL_W]),
                .d_step        (d_step_flat[i*LEVEL_W +: LEVEL_W]),
                .sustain_level (sustain_level_flat[i*LEVEL_W +: LEVEL_W]),
                .r_step        (r_step_flat[i*LEVEL_W +: LEVEL_W]),
                .gain_q15      (gain_flat[i*GAIN_W +: GAIN_W]),
                .wave_addr     (wave_addr_flat[i*ADDR_BITS +: ADDR_BITS]),
                .wave_sample   (wave_sample_flat[i*SAMPLE_W +: SAMPLE_W]),
                .wave_valid    (wave_valid_flat[i]),
                .sample        (voice_sample_flat[i*SAMPLE_W +: SAMPLE_W]),
                .sample_valid  (voice_valid[i]),
                .busy          (busy_flat[i])
            );
        end
    endgenerate

    mixer #(
        .VOICES   (VOICES),
        .SAMPLE_W (SAMPLE_W)
    ) u_mixer (
        .clk               (clk),
        .rst_n             (rst_n),
        .voice_sample_flat (voice_sample_flat),
        // 归一化按"仍在发声"计数：gate 或 ADSR 释放未结束都算在响，
        // 避免最后一音松开时系数突变产生"咔"声。
        .sound_flat        (gate_flat | busy_flat),
        .scan_done         (arb_scan_done),
        .mix_sample        (mix_sample),
        .mix_valid         (mix_valid)
    );

    assign scan_done = mix_valid;
endmodule
