// ============================================================
// encoder_ab_test_top.v —— 只验证 A/B 两相的 FPGA 专项测试
//
// A -> PIN25
// B -> PIN27
//
// LED0：左旋事件
// LED1：右旋事件
// LED2：A 当前高电平
// LED3：B 当前高电平
// LED4：A 边沿活动
// LED5：B 边沿活动
// ============================================================

module encoder_ab_test_top (
    input  wire       clk,
    input  wire       enc_a,
    input  wire       enc_b,
    output wire [5:0] led_n
);
    reg [15:0] por_cnt;
    wire rst_n = &por_cnt;

    reg a0, a1;
    reg b0, b1;
    reg a_toggle;
    reg b_toggle;
    reg left_toggle;
    reg right_toggle;

    wire rotate_left;
    wire rotate_right;
    wire sw_pressed;
    wire sw_press;

    always @(posedge clk) begin
        if (!rst_n)
            por_cnt <= por_cnt + 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a0           <= 1'b0;
            a1           <= 1'b0;
            b0           <= 1'b0;
            b1           <= 1'b0;
            a_toggle     <= 1'b0;
            b_toggle     <= 1'b0;
            left_toggle  <= 1'b0;
            right_toggle <= 1'b0;
        end else begin
            a0 <= enc_a;
            a1 <= a0;
            b0 <= enc_b;
            b1 <= b0;

            if (a0 ^ a1)
                a_toggle <= ~a_toggle;
            if (b0 ^ b1)
                b_toggle <= ~b_toggle;
            if (rotate_left)
                left_toggle <= ~left_toggle;
            if (rotate_right)
                right_toggle <= ~right_toggle;
        end
    end

    rotary_decode #(
        .DEBOUNCE_CYCLES (27000)
    ) u_encoder (
        .clk          (clk),
        .rst_n        (rst_n),
        .enc_a        (enc_a),
        .enc_b        (enc_b),
        .enc_sw_n     (1'b1),
        .rotate_left  (rotate_left),
        .rotate_right (rotate_right),
        .sw_pressed   (sw_pressed),
        .sw_press     (sw_press)
    );

    assign led_n[0] = ~left_toggle;
    assign led_n[1] = ~right_toggle;
    assign led_n[2] = ~a1;
    assign led_n[3] = ~b1;
    assign led_n[4] = ~a_toggle;
    assign led_n[5] = ~b_toggle;
endmodule
