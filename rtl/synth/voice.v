module voice #(
    parameter PHASE_BITS = 32,
    parameter ADDR_BITS  = 12,
    parameter SAMPLE_W   = 16,
    parameter LEVEL_W    = 16
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       sample_en,      // 48kHz 单周期脉冲
    input  wire [PHASE_BITS-1:0]      inc,            // 调音字（音高）
    input  wire                       gate,           // 1=按下, 0=松开
    input  wire [LEVEL_W-1:0]         a_step,
    input  wire [LEVEL_W-1:0]         d_step,
    input  wire [LEVEL_W-1:0]         sustain_level,
    input  wire [LEVEL_W-1:0]         r_step,

    output wire [ADDR_BITS-1:0]       wave_addr,
    input  wire signed [SAMPLE_W-1:0] wave_sample,
    input  wire                       wave_valid,

    output wire signed [SAMPLE_W-1:0] sample,         // 包络调制后的样本
    output wire                       sample_valid,
    output wire                       busy
);
    wire signed [SAMPLE_W-1:0] osc_sample;
    wire [LEVEL_W-1:0]         env_level;

    // 释放段振荡器必须继续跑，否则声音会被"冻"成一个直流值
    wire run = gate | busy;

    // ---- 振荡器 ----
    voice_osc #(
        .PHASE_BITS (PHASE_BITS),
        .ADDR_BITS  (ADDR_BITS),
        .SAMPLE_W   (SAMPLE_W)
    ) u_osc (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_en    (sample_en),
        .inc          (inc),
        .run          (run),
        .addr         (wave_addr),
        .wave_sample  (wave_sample),
        .wave_valid   (wave_valid),
        .sample       (osc_sample),
        .sample_valid (sample_valid)
    );

    // ---- ADSR 包络 ----
    voice_adsr #(
        .LEVEL_W (LEVEL_W)
    ) u_adsr (
        .clk           (clk),
        .rst_n         (rst_n),
        .sample_en     (sample_en),
        .gate          (gate),
        .a_step        (a_step),
        .d_step        (d_step),
        .sustain_level (sustain_level),
        .r_step        (r_step),
        .level         (env_level),
        .busy          (busy)
    );

    // ---- 包络调制：sample = osc_sample × env_level / 65536 ----
    wire signed [SAMPLE_W-1:0] osc_ext = osc_sample;
    wire signed [LEVEL_W:0]    env_ext = {1'b0, env_level};

    wire signed [31:0] env_product = osc_ext * env_ext;

    assign sample = env_product[31:16];
endmodule
