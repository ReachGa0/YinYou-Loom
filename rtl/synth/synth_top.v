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
    parameter INIT_FILE0 = "data/wavetables/sine_4096x16.hex",
    parameter INIT_FILE1 = "data/wavetables/square_4096x16.hex"
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              sample_en,
    input  wire                              table_sel,

    input  wire [VOICES*PHASE_BITS-1:0]      inc_flat,
    input  wire [VOICES-1:0]                 gate_flat,
    input  wire [VOICES*LEVEL_W-1:0]         a_step_flat,
    input  wire [VOICES*LEVEL_W-1:0]         d_step_flat,
    input  wire [VOICES*LEVEL_W-1:0]         sustain_level_flat,
    input  wire [VOICES*LEVEL_W-1:0]         r_step_flat,

    output wire signed [SAMPLE_W-1:0]        mix_sample,
    output wire                              scan_done,
    output wire [VOICES-1:0]                 voice_valid,
    output wire [VOICES-1:0]                 busy_flat
);
    wire [VOICES*ADDR_BITS-1:0]  wave_addr_flat;
    wire [VOICES*SAMPLE_W-1:0]   wave_sample_flat;
    wire [VOICES-1:0]            wave_valid_flat;
    wire [VOICES*SAMPLE_W-1:0]   voice_sample_flat;

    wavetable_arbiter #(
        .VOICES    (VOICES),
        .ADDR_BITS (ADDR_BITS),
        .SAMPLE_W  (SAMPLE_W),
        .INIT_FILE0 (INIT_FILE0),
        .INIT_FILE1 (INIT_FILE1)
    ) u_arbiter (
        .clk              (clk),
        .rst_n            (rst_n),
        .sample_en        (sample_en),
        .table_sel        (table_sel),
        .wave_addr_flat   (wave_addr_flat),
        .wave_sample_flat (wave_sample_flat),
        .wave_valid       (wave_valid_flat),
        .scan_done        (scan_done)
    );

    genvar i;
    generate
        for (i = 0; i < VOICES; i = i + 1) begin : g_voice
            voice #(
                .PHASE_BITS (PHASE_BITS),
                .ADDR_BITS  (ADDR_BITS),
                .SAMPLE_W   (SAMPLE_W),
                .LEVEL_W    (LEVEL_W)
            ) u_voice (
                .clk           (clk),
                .rst_n         (rst_n),
                .sample_en     (sample_en),
                .inc           (inc_flat[i*PHASE_BITS +: PHASE_BITS]),
                .gate          (gate_flat[i]),
                .a_step        (a_step_flat[i*LEVEL_W +: LEVEL_W]),
                .d_step        (d_step_flat[i*LEVEL_W +: LEVEL_W]),
                .sustain_level (sustain_level_flat[i*LEVEL_W +: LEVEL_W]),
                .r_step        (r_step_flat[i*LEVEL_W +: LEVEL_W]),
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
        .scan_done         (scan_done),
        .mix_sample        (mix_sample)
    );
endmodule
