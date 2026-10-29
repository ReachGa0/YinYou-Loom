// ============================================================
// mixer.v —— 多声部逐样本求和、发声数归一化与饱和限幅
//
// 声部样本在 scan_done 前陆续更新。为支持 32 声部且避免 32 输入
// 组合加法链，mixer 按 voice_valid_flat 的有效脉冲顺序累加：
//   sample_en → 清零累加器 → 逐个累加 → scan_done 后排空 → 归一化
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
    input  wire                       sample_en,
    input  wire [VOICES*SAMPLE_W-1:0] voice_sample_flat,
    input  wire [VOICES-1:0]          voice_valid_flat,
    input  wire [VOICES*16-1:0]       gain_flat,
    input  wire [VOICES-1:0]          sound_flat,
    input  wire                       scan_done,
    output reg signed [SAMPLE_W-1:0]  mix_sample,
    output reg                        mix_valid
);
    localparam ACC_W = SAMPLE_W + ((VOICES <= 1) ? 1 : $clog2(VOICES)) + 1;
    localparam CNT_W = (VOICES <= 1) ? 1 : $clog2(VOICES + 1);

    integer i;
    reg signed [SAMPLE_W-1:0] selected_sample;
    reg        [15:0]         selected_gain;
    reg                       selected_sound;
    reg [VOICES-1:0]          valid_d1;
    reg                       add_valid;
    reg signed [SAMPLE_W-1:0] add_sample;
    reg        [15:0]         add_gain;
    reg                       add_sound;
    reg                       sum_valid;
    reg signed [SAMPLE_W-1:0] sum_sample;
    reg                       sum_sound;
    reg signed [ACC_W-1:0]    sum_acc;
    reg [CNT_W-1:0]           count_acc;
    reg signed [ACC_W-1:0] total_reg;
    reg [CNT_W-1:0]        count_reg;
    reg [15:0]             gain_cur;          // 当前增益（Q15）
    reg                    scan_done_seen;
    reg                    capture;
    reg                    capture_d1;
    reg                    capture_d2;
    reg signed [ACC_W+15:0] scaled_q;

    always @* begin
        selected_sample = {SAMPLE_W{1'b0}};
        selected_gain   = 16'd32768;
        selected_sound  = 1'b0;
        for (i = 0; i < VOICES; i = i + 1)
            if (valid_d1[i]) begin
                selected_sample = voice_sample_flat[i*SAMPLE_W +: SAMPLE_W];
                selected_gain   = gain_flat[i*16 +: 16];
                selected_sound  = sound_flat[i];
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
                5: target_gain = 16'd6554;
                6: target_gain = 16'd5461;
                7: target_gain = 16'd4681;
                8: target_gain = 16'd4096;
                9: target_gain = 16'd3641;
                10: target_gain = 16'd3277;
                11: target_gain = 16'd2979;
                12: target_gain = 16'd2731;
                13: target_gain = 16'd2521;
                14: target_gain = 16'd2341;
                15: target_gain = 16'd2185;
                16: target_gain = 16'd2048;
                17: target_gain = 16'd1928;
                18: target_gain = 16'd1820;
                19: target_gain = 16'd1725;
                20: target_gain = 16'd1638;
                21: target_gain = 16'd1560;
                22: target_gain = 16'd1489;
                23: target_gain = 16'd1425;
                24: target_gain = 16'd1365;
                25: target_gain = 16'd1311;
                26: target_gain = 16'd1260;
                27: target_gain = 16'd1214;
                28: target_gain = 16'd1170;
                29: target_gain = 16'd1130;
                30: target_gain = 16'd1092;
                31: target_gain = 16'd1057;
                32: target_gain = 16'd1024;
                default: target_gain = 16'd1024;
            endcase
        end
    endfunction

    wire [15:0] gain_tgt = target_gain(count_acc);

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
    wire signed [31:0] gain_prod = add_sample * $signed({1'b0, add_gain});
    wire signed [SAMPLE_W-1:0] gain_sample = gain_prod[30:15];
    wire valid_any_d1 = |valid_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_reg    <= {ACC_W{1'b0}};
            count_reg    <= {CNT_W{1'b0}};
            gain_cur     <= 16'd32768;
            valid_d1     <= {VOICES{1'b0}};
            add_valid    <= 1'b0;
            add_sample   <= {SAMPLE_W{1'b0}};
            add_gain     <= 16'd32768;
            add_sound    <= 1'b0;
            sum_valid    <= 1'b0;
            sum_sample   <= {SAMPLE_W{1'b0}};
            sum_sound    <= 1'b0;
            sum_acc      <= {ACC_W{1'b0}};
            count_acc    <= {CNT_W{1'b0}};
            scan_done_seen <= 1'b0;
            capture      <= 1'b0;
            capture_d1   <= 1'b0;
            capture_d2   <= 1'b0;
            scaled_q     <= {(ACC_W+16){1'b0}};
            mix_sample   <= {SAMPLE_W{1'b0}};
            mix_valid    <= 1'b0;
        end else begin
            valid_d1   <= voice_valid_flat;
            add_valid  <= valid_any_d1;
            sum_valid  <= add_valid;
            capture_d1 <= capture;
            capture_d2 <= capture_d1;
            mix_valid  <= capture_d2;
            scaled_q   <= scaled;
            capture    <= 1'b0;

            if (valid_any_d1) begin
                add_sample <= selected_sample;
                add_gain   <= selected_gain;
                add_sound  <= selected_sound;
            end

            if (add_valid) begin
                sum_sample <= gain_sample;
                sum_sound  <= add_sound;
            end

            if (sample_en) begin
                sum_acc        <= {ACC_W{1'b0}};
                count_acc      <= {CNT_W{1'b0}};
                scan_done_seen <= 1'b0;
            end else begin
                if (scan_done)
                    scan_done_seen <= 1'b1;

                if (sum_valid) begin
                    sum_acc <= sum_acc + sum_sample;
                    if (sum_sound)
                        count_acc <= count_acc + 1'b1;
                end

                // scan_done 后等待 valid/add/sum 流水排空，保证最后一个声部也被累计。
                if (scan_done_seen && !valid_any_d1 && !add_valid && !sum_valid) begin
                    total_reg      <= sum_acc;
                    count_reg      <= count_acc;
                    gain_cur       <= gain_next;
                    capture        <= 1'b1;
                    scan_done_seen <= 1'b0;
                end
            end

            if (capture_d2)
                mix_sample <= saturate(scaled_q >>> 15);
        end
    end
endmodule
