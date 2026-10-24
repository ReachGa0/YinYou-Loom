// ============================================================
// bend_scan.v —— 共享一个乘法器，顺序更新所有声部的弯音频率字
//
// 每个采样周期有 1500 个 72 MHz 时钟，32 个声部只需 32 拍。
// 因此不再为每个声部复制 32×16 乘法器，而是逐个读取 inc_flat，
// 乘同一个 bend_q15 后写回 inc_bent_flat。
//
// 相位累加器在 sample_en 当拍使用上一帧已经算好的弯音频率字，
// 因此额外引入 1 个音频样本（约 20.8us）的弯音更新延迟。
// ============================================================

module bend_scan #(
    parameter VOICES     = 32,
    parameter PHASE_BITS = 32
) (
    input  wire                           clk,
    input  wire                           rst_n,
    input  wire                           sample_en,
    input  wire [15:0]                    bend_q15,
    input  wire [VOICES*PHASE_BITS-1:0]   inc_flat,
    output reg  [VOICES*PHASE_BITS-1:0]   inc_bent_flat,
    output reg                            scan_done
);
    localparam IDX_W = (VOICES <= 1) ? 1 : $clog2(VOICES);

    reg [IDX_W-1:0] scan_idx;
    reg             scan_active;
    reg [IDX_W-1:0] mul_idx;
    reg             mul_valid;
    reg [PHASE_BITS-1:0] inc_stage;
    reg [15:0]      bend_stage;

    wire [PHASE_BITS-1:0] inc_sel =
        inc_flat[scan_idx*PHASE_BITS +: PHASE_BITS];
    wire [PHASE_BITS+15:0] bend_prod = inc_stage * bend_stage;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_idx     <= {IDX_W{1'b0}};
            scan_active  <= 1'b0;
            mul_idx      <= {IDX_W{1'b0}};
            mul_valid    <= 1'b0;
            inc_stage    <= {PHASE_BITS{1'b0}};
            bend_stage   <= 16'd32768;
            inc_bent_flat <= {VOICES*PHASE_BITS{1'b0}};
            scan_done    <= 1'b0;
        end else begin
            scan_done <= 1'b0;
            mul_valid <= 1'b0;

            if (sample_en) begin
                scan_idx    <= {IDX_W{1'b0}};
                scan_active <= 1'b1;
            end else if (scan_active) begin
                // 第一级只做 32:1 选择并寄存，第二级再共享乘法器。
                inc_stage  <= inc_sel;
                bend_stage <= bend_q15;
                mul_idx    <= scan_idx;
                mul_valid  <= 1'b1;
                if (scan_idx == VOICES - 1) begin
                    scan_active <= 1'b0;
                end else begin
                    scan_idx <= scan_idx + 1'b1;
                end
            end

            if (mul_valid) begin
                inc_bent_flat[mul_idx*PHASE_BITS +: PHASE_BITS] <=
                    bend_prod >>> 15;
                if (!scan_active && (mul_idx == VOICES - 1))
                    scan_done <= 1'b1;
            end
        end
    end
endmodule
