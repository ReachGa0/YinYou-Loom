// ============================================================
// mixer.v —— 多声部逐样本求和、按键数归一化与饱和限幅
//
// 声部样本在 scan_done 前陆续更新，mix_sample 在本帧结束后锁存。
// gate_flat 用来统计同时按下的声部数，归一化后再限幅。
// ============================================================

module mixer #(
    parameter VOICES   = 4,
    parameter SAMPLE_W = 16
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire [VOICES*SAMPLE_W-1:0] voice_sample_flat,
    input  wire [VOICES-1:0]          gate_flat,
    input  wire                       scan_done,
    output reg signed [SAMPLE_W-1:0]  mix_sample,
    output reg                        mix_valid
);
    localparam ACC_W = SAMPLE_W + ((VOICES <= 1) ? 1 : $clog2(VOICES)) + 1;
    localparam CNT_W = (VOICES <= 1) ? 1 : $clog2(VOICES + 1);

    integer i;
    reg signed [ACC_W-1:0] total;
    reg [CNT_W-1:0]        gate_count;
    reg signed [ACC_W-1:0] total_reg;
    reg [CNT_W-1:0]        count_reg;
    reg                    scan_done_d1;

    always @* begin
        total = {ACC_W{1'b0}};
        gate_count = {CNT_W{1'b0}};
        for (i = 0; i < VOICES; i = i + 1) begin
            total = total + $signed(voice_sample_flat[i*SAMPLE_W +: SAMPLE_W]);
            gate_count = gate_count + gate_flat[i];
        end
    end

    function signed [ACC_W-1:0] normalize;
        input signed [ACC_W-1:0] value;
        input [CNT_W-1:0]        count;
        begin
            case (count)
                1: normalize = value;
                2: normalize = value >>> 1;
                // 21/64 与 1/3 只差约 0.045 dB，避免引入硬件除法器。
                3: normalize = (value >>> 2) + (value >>> 4) + (value >>> 6);
                4: normalize = value >>> 2;
                default: normalize = value;
            endcase
        end
    endfunction

    function signed [SAMPLE_W-1:0] saturate;
        input signed [ACC_W-1:0] value;
        begin
            if (value > 32767)
                saturate = 16'sh7fff;
            else if (value < -32768)
                saturate = 16'sh8000;
            else
                saturate = value[SAMPLE_W-1:0];
        end
    endfunction

    wire signed [ACC_W-1:0] normalized = normalize(total_reg, count_reg);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_reg    <= {ACC_W{1'b0}};
            count_reg    <= {CNT_W{1'b0}};
            scan_done_d1 <= 1'b0;
            mix_sample   <= {SAMPLE_W{1'b0}};
            mix_valid    <= 1'b0;
        end else begin
            scan_done_d1 <= scan_done;
            mix_valid    <= scan_done_d1;

            if (scan_done) begin
                total_reg <= total;
                count_reg <= gate_count;
            end

            if (scan_done_d1)
                mix_sample <= saturate(normalized);
        end
    end
endmodule
