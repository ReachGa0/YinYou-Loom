module voice #(
    parameter PHASE_BITS = 32,
    parameter ADDR_BITS  = 12,
    parameter SAMPLE_W   = 16,
    parameter LEVEL_W    = 16,
    parameter GAIN_W     = 16
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
    input  wire                       one_shot,       // 1 = 拨弦（一次性衰减）
    input  wire [GAIN_W-1:0]          gain_q15,       // Q1.15, 32768 = 1.0

    output wire [ADDR_BITS-1:0]       wave_addr,
    input  wire signed [SAMPLE_W-1:0] wave_sample,
    input  wire                       wave_valid,

    output reg  signed [SAMPLE_W-1:0] sample,         // 包络调制后的样本
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
        .one_shot      (one_shot),
        .level         (env_level),
        .busy          (busy)
    );

    // ---- 包络调制：sample = osc_sample × env_level / 65536 ----
    wire signed [SAMPLE_W-1:0] osc_ext = osc_sample;
    wire signed [LEVEL_W:0]    env_ext = {1'b0, env_level};

    wire signed [31:0] env_product = osc_ext * env_ext;

    wire signed [SAMPLE_W-1:0] env_sample = env_product[31:16];
    // 通用 Q15 增益（32768 = 1.0）。
    // 原来是一个只认 4 个 A 加权常量的 case，其它值（例如力度算出的
    // 16384/24576）会落到 default=1.0，导致力度完全不起作用。
    wire signed [31:0] gain_prod = env_sample * $signed({1'b0, gain_q15});
    wire signed [SAMPLE_W-1:0] mixed_sample = gain_prod[30:15];   // >>15

    // 一级输出流水：打断 ADSR -> 乘法/增益 -> mixer 的长组合路径。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sample <= {SAMPLE_W{1'b0}};
        else if (wave_valid)
            sample <= mixed_sample;
    end
endmodule
