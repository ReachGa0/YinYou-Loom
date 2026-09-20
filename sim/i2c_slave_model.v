`timescale 1ns/1ps

// ============================================================
// i2c_slave_model.v —— 严格模拟 I2C 从机
//
// 与真实器件一样，它按"事务"理解总线：
//   START 之后收到的第 1 个字节是"从机地址"，后续字节才是数据。
//
// 因此它能抓到一类关键错误：
//   如果主机每发一个字节就 STOP，那么控制字节和数据字节会被当成
//   "新的从机地址"，从机不会把它们计入同一次事务 —— addr_match 与
//   nbytes 会直接暴露这个问题。
// ============================================================

module i2c_slave_model #(
    parameter [7:0] ADDR = 8'h78          // 本从机地址（含读写位）
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       scl,
    inout  wire       sda,
    output reg        trans_end,          // 单周期脉冲：检测到 STOP
    output reg        addr_match,         // 本事务地址是否匹配
    output reg [7:0]  rx_addr,            // 事务内第 1 个字节
    output reg [7:0]  rx_ctrl,            // 事务内第 2 个字节
    output reg [7:0]  rx_payload,         // 事务内第 3 个字节
    output reg [7:0]  nbytes              // 本事务共收到几个字节
);
    reg sda_d, scl_d;
    always @(posedge clk) begin
        sda_d <= sda;
        scl_d <= scl;
    end

    wire start_cond = scl && scl_d && sda_d && !sda;
    wire stop_cond  = scl && scl_d && !sda_d && sda;
    wire scl_rise   = scl && !scl_d;
    wire scl_fall   = !scl && scl_d;

    reg       in_frame;
    reg       is_first;
    reg [3:0] bitn;
    reg [7:0] sh;
    reg       acking;

    reg [7:0] nbuf;
    reg [7:0] b0, b1, b2;

    assign sda = acking ? 1'b0 : 1'bz;    // 只在应答时拉低

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_frame   <= 1'b0;
            is_first   <= 1'b1;
            bitn       <= 4'd0;
            sh         <= 8'd0;
            acking     <= 1'b0;
            nbuf       <= 8'd0;
            b0         <= 8'd0;
            b1         <= 8'd0;
            b2         <= 8'd0;
            trans_end  <= 1'b0;
            addr_match <= 1'b0;
            rx_addr    <= 8'd0;
            rx_ctrl    <= 8'd0;
            rx_payload <= 8'd0;
            nbytes     <= 8'd0;
        end else begin
            trans_end <= 1'b0;

            if (start_cond) begin
                in_frame <= 1'b1;
                is_first <= 1'b1;
                bitn     <= 4'd0;
                nbuf     <= 8'd0;
            end else if (stop_cond) begin
                in_frame   <= 1'b0;
                acking     <= 1'b0;
                trans_end  <= 1'b1;
                rx_addr    <= b0;
                rx_ctrl    <= b1;
                rx_payload <= b2;
                nbytes     <= nbuf;
                addr_match <= (b0 == ADDR);
            end else if (scl_rise && in_frame) begin
                if (bitn < 4'd8) begin
                    sh   <= {sh[6:0], sda};       // 高位在前
                    bitn <= bitn + 1'b1;
                end else begin
                    if (is_first) begin
                        b0       <= sh;           // 事务第 1 字节 = 地址
                        is_first <= 1'b0;
                    end else begin
                        case (nbuf)
                            8'd1: b1 <= sh;
                            8'd2: b2 <= sh;
                            default: ;
                        endcase
                    end
                    nbuf <= nbuf + 1'b1;
                    bitn <= 4'd0;
                end
            end else if (scl_fall && in_frame) begin
                acking <= (bitn == 4'd8);         // 第 9 个时钟拉低应答
            end
        end
    end

endmodule
