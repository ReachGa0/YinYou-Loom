// ============================================================
// mixer.v —— 多声部逐样本求和与饱和限幅
//
// 声部样本在 scan_done 前陆续更新，mix_sample 只在
// scan_done 时锁存整帧的完整和。
// ============================================================

module mixer #(
    parameter VOICES   = 4,
    parameter SAMPLE_W = 16
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire [VOICES*SAMPLE_W-1:0] voice_sample_flat,
    input  wire                       scan_done,
    output reg signed [SAMPLE_W-1:0]  mix_sample
);
    localparam ACC_W = SAMPLE_W + ((VOICES <= 1) ? 1 : $clog2(VOICES)) + 1;

    integer i;
    reg signed [ACC_W-1:0] total;

    always @* begin
        total = {ACC_W{1'b0}};
        for (i = 0; i < VOICES; i = i + 1)
            total = total + $signed(voice_sample_flat[i*SAMPLE_W +: SAMPLE_W]);
    end

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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mix_sample <= {SAMPLE_W{1'b0}};
        else if (scan_done)
            mix_sample <= saturate(total);
    end
endmodule
