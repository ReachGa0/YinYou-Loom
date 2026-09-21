// ============================================================
// encoder_test_top.v —— 五引脚 EC11 模块安全测试顶层
//
// 只接收 A/B/C 三个输入，全部使用内部上拉。
// LED 显示：
//   LED0 左旋事件翻转
//   LED1 右旋事件翻转
//   LED2 按压事件翻转
//   LED3 C 引脚消抖状态
//   LED4 A 原始状态
//   LED5 B 原始状态
// ============================================================

module encoder_test_top (
    input  wire       clk,
    input  wire       enc_a,
    input  wire       enc_b,
    input  wire       enc_c,
    output wire [5:0] led_n,
    output wire       scl,
    inout  wire       sda
);
    reg [15:0] por_cnt;
    wire rst_n = &por_cnt;

    reg left_toggle;
    reg right_toggle;
    reg press_toggle;

    wire rotate_left;
    wire rotate_right;
    wire sw_pressed;
    wire sw_press;
    wire [5:0] indicator_bits;

    reg a_sync0, a_sync1;
    reg b_sync0, b_sync1;
    reg c_sync0, c_sync1;

    always @(posedge clk) begin
        if (!rst_n)
            por_cnt <= por_cnt + 1'b1;
    end

    rotary_decode #(
        .DEBOUNCE_CYCLES (27000)
    ) u_encoder (
        .clk         (clk),
        .rst_n       (rst_n),
        .enc_a       (enc_a),
        .enc_b       (enc_b),
        .enc_sw_n    (enc_c),
        .rotate_left (rotate_left),
        .rotate_right(rotate_right),
        .sw_pressed  (sw_pressed),
        .sw_press    (sw_press)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            left_toggle  <= 1'b0;
            right_toggle <= 1'b0;
            press_toggle <= 1'b0;
        end else begin
            if (rotate_left)
                left_toggle <= ~left_toggle;
            if (rotate_right)
                right_toggle <= ~right_toggle;
            if (sw_press)
                press_toggle <= ~press_toggle;
        end
    end

    always @(posedge clk) begin
        a_sync0 <= enc_a;
        a_sync1 <= a_sync0;
        b_sync0 <= enc_b;
        b_sync1 <= b_sync0;
        c_sync0 <= enc_c;
        c_sync1 <= c_sync0;
    end

    assign indicator_bits = {
        b_sync1,
        a_sync1,
        sw_pressed,
        press_toggle,
        right_toggle,
        left_toggle
    };

    oled_sh1106 #(
        .CLK_HZ       (27_000_000),
        .SCL_HZ       (25_000),
        .POR_CYCLES   (27_000_000 / 5),
        .PATTERN_MODE (1)
    ) u_oled (
        .clk            (clk),
        .rst_n          (rst_n),
        .ssd1306_mode   (1'b0),
        .indicator_bits (indicator_bits),
        .scl            (scl),
        .sda            (sda),
        .dbg_phase      (),
        .dbg_ack_seen   ()
    );

    assign led_n[0] = ~left_toggle;
    assign led_n[1] = ~right_toggle;
    assign led_n[2] = ~press_toggle;
    assign led_n[3] = ~sw_pressed;
    assign led_n[4] = ~enc_a;
    assign led_n[5] = ~enc_b;
endmodule
