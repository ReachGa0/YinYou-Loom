// ============================================================
// joy_filter.v —— 摇杆 RC 采样去尖峰 + 一阶低通
//
// 输入是 rc_adc 每次 valid 时给出的 16 位充电计数值。
// 连续 3 个有效样本取中值，可滤掉单次异常尖峰；随后执行
// y += (x - y) / 2^SHIFT。输出扩展到 WIDTH+1 位，保留符号。
//
// fault=1 时不更新历史值或滤波输出，保持最后有效值。
// 第一次有效采样直接作为初值，避免上电从 0 缓慢爬升。
// ============================================================

module joy_filter #(
    parameter WIDTH = 16,
    parameter SHIFT = 3
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   sample_valid,
    input  wire                   sample_fault,
    input  wire [WIDTH-1:0]       sample_in,
    output reg  signed [WIDTH:0]  filtered_out
);
    reg [WIDTH-1:0] hist0;
    reg [WIDTH-1:0] hist1;
    reg             primed;

    function [WIDTH-1:0] median3;
        input [WIDTH-1:0] a;
        input [WIDTH-1:0] b;
        input [WIDTH-1:0] c;
        begin
            if (((a >= b) && (b >= c)) || ((c >= b) && (b >= a)))
                median3 = b;
            else if (((b >= a) && (a >= c)) || ((c >= a) && (a >= b)))
                median3 = a;
            else
                median3 = c;
        end
    endfunction

    reg [WIDTH-1:0] raw_q;
    reg [WIDTH-1:0] med_q;
    reg             valid_q1;
    reg             valid_q2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hist0        <= {WIDTH{1'b0}};
            hist1        <= {WIDTH{1'b0}};
            raw_q        <= {WIDTH{1'b0}};
            med_q        <= {WIDTH{1'b0}};
            valid_q1     <= 1'b0;
            valid_q2     <= 1'b0;
            primed       <= 1'b0;
            filtered_out <= {WIDTH + 1{1'b0}};
        end else begin
            valid_q1 <= sample_valid && !sample_fault;
            valid_q2 <= valid_q1;

            // 第一级只寄存原始样本，第二级计算三数中值，第三级做低通。
            if (sample_valid && !sample_fault)
                raw_q <= sample_in;

            if (valid_q1) begin
                if (!primed) begin
                    med_q <= raw_q;
                    hist0 <= raw_q;
                    hist1 <= raw_q;
                end else begin
                    med_q <= median3(raw_q, hist0, hist1);
                    hist0 <= raw_q;
                    hist1 <= hist0;
                end
            end

            if (valid_q2) begin
                if (!primed) begin
                    primed       <= 1'b1;
                    filtered_out <= $signed({1'b0, med_q});
                end else begin
                    filtered_out <= filtered_out +
                        (($signed({1'b0, med_q}) - filtered_out) >>> SHIFT);
                end
            end
        end
    end
endmodule
