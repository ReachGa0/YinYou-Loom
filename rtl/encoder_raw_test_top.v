// ============================================================
// encoder_raw_test_top.v —— A/B/C 原始电平探针
//
// LED 含义（板载 LED 低电平点亮）：
//   LED0 = A 为低，LED1 = A 为高
//   LED2 = B 为低，LED3 = B 为高
//   LED4 = C 为低，LED5 = C 为高
// ============================================================

module encoder_raw_test_top (
    input  wire       clk,
    input  wire       enc_a,
    input  wire       enc_b,
    input  wire       enc_c,
    output wire [5:0] led_n
);
    reg a0, a1;
    reg b0, b1;
    reg c0, c1;

    always @(posedge clk) begin
        a0 <= enc_a;
        a1 <= a0;
        b0 <= enc_b;
        b1 <= b0;
        c0 <= enc_c;
        c1 <= c0;
    end

    // 0 = 低电平点亮，1 = 高电平点亮
    assign led_n[0] = a1;
    assign led_n[1] = ~a1;
    assign led_n[2] = b1;
    assign led_n[3] = ~b1;
    assign led_n[4] = c1;
    assign led_n[5] = ~c1;
endmodule
