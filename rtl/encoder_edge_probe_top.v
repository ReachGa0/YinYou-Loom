// ============================================================
// encoder_edge_probe_top.v —— A/B/C 单引脚活动探针
//
// LED0：检测到 A 边沿，翻转一次
// LED1：检测到 B 边沿，翻转一次
// LED2：检测到 C 边沿，翻转一次
// LED3/4/5：A/B/C 当前高电平状态
// ============================================================

module encoder_edge_probe_top (
    input  wire       clk,
    input  wire       enc_a,
    input  wire       enc_b,
    input  wire       enc_c,
    output wire [5:0] led_n
);
    reg [15:0] por_cnt;
    wire rst_n = &por_cnt;

    reg a0, a1;
    reg b0, b1;
    reg c0, c1;
    reg a_toggle;
    reg b_toggle;
    reg c_toggle;

    always @(posedge clk) begin
        if (!rst_n)
            por_cnt <= por_cnt + 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a0       <= 1'b0;
            a1       <= 1'b0;
            b0       <= 1'b0;
            b1       <= 1'b0;
            c0       <= 1'b0;
            c1       <= 1'b0;
            a_toggle <= 1'b0;
            b_toggle <= 1'b0;
            c_toggle <= 1'b0;
        end else begin
            a0 <= enc_a;
            a1 <= a0;
            b0 <= enc_b;
            b1 <= b0;
            c0 <= enc_c;
            c1 <= c0;

            if (a0 ^ a1)
                a_toggle <= ~a_toggle;
            if (b0 ^ b1)
                b_toggle <= ~b_toggle;
            if (c0 ^ c1)
                c_toggle <= ~c_toggle;
        end
    end

    assign led_n[0] = ~a_toggle;
    assign led_n[1] = ~b_toggle;
    assign led_n[2] = ~c_toggle;
    assign led_n[3] = ~a1;
    assign led_n[4] = ~b1;
    assign led_n[5] = ~c1;
endmodule
