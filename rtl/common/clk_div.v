module clk_div #(
    parameter DIV = 15          // 多少拍产生一个脉冲
) (
    input  wire clk,
    input  wire rst_n,
    output reg  tick            // 单周期脉冲
);
    localparam W = $clog2(DIV);
    reg [W-1:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= {W{1'b0}};
            tick <= 1'b0;
        end else if (cnt == DIV - 1) begin
            cnt  <= {W{1'b0}};
            tick <= 1'b1;          // 只在归零这一拍拉高
        end else begin
            cnt  <= cnt + 1'b1;
            tick <= 1'b0;
        end
    end
endmodule