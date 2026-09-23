// ============================================================
// mixer.v —— 多声部逐样本求和、发声数归一化与饱和限幅
//
// 声部样本在 scan_done 前陆续更新，mix_sample 在本帧结束后锁存。
// sound_flat 是"仍在发声"的声部掩码（gate | ADSR busy），用来决定目标增益。
// 两个抗"咔"设计：
//   1. 计数含 ADSR busy：最后一个音松开时计数不会立刻掉到 0，
//      还在响的释放尾音不会被瞬间放大。
//   2. 增益带斜坡：目标增益变化时每个样本只挪 GAIN_INC（Q15），
//      所以"已有音在响时再按下一个音"不会让旧音瞬间跌一半。
// ============================================================

module mixer #(
    parameter VOICES   = 4,
    parameter SAMPLE_W = 16,
    parameter GAIN_INC = 128      // Q15/样本：48kHz 下 1/1 -> 1/2 约 2.7ms
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire [VOICES*SAMPLE_W-1:0] voice_sample_flat,
    input  wire [VOICES-1:0]          sound_flat,
    input  wire                       scan_done,
    output reg signed [SAMPLE_W-1:0]  mix_sample,
    output reg                        mix_valid
);
    localparam ACC_W = SAMPLE_W + ((VOICES <= 1) ? 1 : $clog2(VOICES)) + 1;
    localparam CNT_W = (VOICES <= 1) ? 1 : $clog2(VOICES + 1);

    integer i;
    reg signed [ACC_W-1:0] total;
    reg [CNT_W-1:0]        sound_count;
    reg signed [ACC_W-1:0] total_reg;
    reg [CNT_W-1:0]        count_reg;
    reg [15:0]             gain_cur;          // 当前增益（Q15）
    reg                    scan_done_d1;

    always @* begin
        total = {ACC_W{1'b0}};
        sound_count = {CNT_W{1'b0}};
        for (i = 0; i < VOICES; i = i + 1) begin
            total = total + $signed(voice_sample_flat[i*SAMPLE_W +: SAMPLE_W]);
            sound_count = sound_count + sound_flat[i];
        end
    end

    // 目标增益（Q15）：1/1、1/2、21/64≈1/3、1/4
    function [15:0] target_gain;
        input [CNT_W-1:0] count;
        begin
            case (count)
                1: target_gain = 16'd32768;
                2: target_gain = 16'd16384;
                // 21/64 与 1/3 只差约 0.045 dB，避免引入硬件除法器。
                3: target_gain = 16'd10752;   // 21/64
                4: target_gain = 16'd8192;
                default: target_gain = 16'd32768;
            endcase
        end
    endfunction

    wire [15:0] gain_tgt = target_gain(count_reg);

    // 每个样本朝目标挪一步（不跨过目标）
    wire [15:0] gain_next = (gain_cur < gain_tgt) ?
                            ((gain_tgt - gain_cur > GAIN_INC) ? gain_cur + GAIN_INC
                                                              : gain_tgt) :
                            ((gain_cur - gain_tgt > GAIN_INC) ? gain_cur - GAIN_INC
                                                              : gain_tgt);

    function signed [SAMPLE_W-1:0] saturate;
        input signed [ACC_W+15:0] value;
        begin
            if (value > 32767)
                saturate = 16'sh7fff;
            else if (value < -32768)
                saturate = 16'sh8000;
            else
                saturate = value[SAMPLE_W-1:0];
        end
    endfunction

    wire signed [ACC_W+15:0] scaled = total_reg * $signed({1'b0, gain_cur});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_reg    <= {ACC_W{1'b0}};
            count_reg    <= {CNT_W{1'b0}};
            gain_cur     <= 16'd32768;
            scan_done_d1 <= 1'b0;
            mix_sample   <= {SAMPLE_W{1'b0}};
            mix_valid    <= 1'b0;
        end else begin
            scan_done_d1 <= scan_done;
            mix_valid    <= scan_done_d1;

            if (scan_done) begin
                total_reg <= total;
                count_reg <= sound_count;
                gain_cur  <= gain_next;
            end

            if (scan_done_d1)
                mix_sample <= saturate(scaled >>> 15);
        end
    end
endmodule
