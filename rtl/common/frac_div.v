// ============================================================
// frac_div.v —— 分数分频器（平均频率精确）
//
// 每个时钟累加 STEP；达到 DEN 时输出一个单周期 tick。
// 平均输出频率 = f_clk * STEP / DEN
// 例：72 MHz * 8 / 125 = 4.608 MHz
// ============================================================

module frac_div #(
    parameter integer STEP = 8,
    parameter integer DEN  = 125
) (
    input  wire clk,
    input  wire rst_n,
    output reg  tick
);
    localparam W = $clog2(DEN);

    localparam [W:0] STEP_VALUE = STEP;
    localparam [W:0] DEN_VALUE  = DEN;

    reg  [W-1:0] acc;
    wire [W:0]   sum = {1'b0, acc} + STEP_VALUE;
    wire [W:0]   diff = sum - DEN_VALUE;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc  <= {W{1'b0}};
            tick <= 1'b0;
        end else if (sum >= DEN_VALUE) begin
            acc  <= diff[W-1:0];
            tick <= 1'b1;
        end else begin
            acc  <= sum[W-1:0];
            tick <= 1'b0;
        end
    end
endmodule
