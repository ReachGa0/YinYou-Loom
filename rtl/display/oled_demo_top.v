// ============================================================
// oled_demo_top.v —— SH1106 I2C 屏幕实验的顶层
//
//   时钟：板载 27MHz 晶振（PIN4），本实验不使用 PLL
//   复位：上电复位 + 板载按键 S1（按下为低）
//   I2C ：SCL = PIN52，SDA = PIN53
// ============================================================

module oled_demo_top (
    input  wire clk,          // 27MHz
    input  wire key_n,        // 板载按键 S1，按下为低，可随时重新初始化
    input  wire key2_n,       // 板载按键 S2，按下为低：按住时使用 SSD1306 初始化序列
    output wire scl,          // I2C 时钟  -> OLED SCL
    inout  wire sda,          // I2C 数据  -> OLED SDA
    output wire [2:0] led_n   // 板载 LED（低电平点亮），仅作调试指示
);
    // ---- 上电复位：约 2.4ms（65536 × 37ns）----
    reg [15:0] por_cnt  = 16'd0;
    reg        por_done = 1'b0;

    always @(posedge clk) begin
        if (!por_done) begin
            if (por_cnt == 16'hFFFF)
                por_done <= 1'b1;
            else
                por_cnt <= por_cnt + 1'b1;
        end
    end

    // 上电稳定 + 按键松开，才释放复位
    wire rst_n = por_done;

    wire [1:0] dbg_phase;
    wire       dbg_ack_seen;

    // 按住 S2 → SSD1306 模式；否则 SH1106 模式。
    // 注意：模式在"初始化阶段"被采样，所以改变模式后要按一下 S1 重新初始化。
    wire ssd1306_mode = ~key2_n;

    // ---- SH1106 控制器 ----
    oled_sh1106 #(
        .CLK_HZ     (27_000_000),
        .SCL_HZ     (25_000),             // 诊断阶段降速：给上拉与线容留 4 倍余量
        .POR_CYCLES (27_000_000 / 5)      // 上电等待约 200ms
    ) u_oled (
        .clk          (clk),
        .rst_n        (rst_n),
        .ssd1306_mode (ssd1306_mode),
        .scl          (scl),
        .sda          (sda),
        .dbg_phase    (dbg_phase),
        .dbg_ack_seen (dbg_ack_seen)
    );

    // ---------------- 调试指示 ----------------
    // LED0：心跳，约 1.6Hz（27MHz / 2^24）
    reg [23:0] hb_cnt = 24'd0;
    always @(posedge clk)
        hb_cnt <= hb_cnt + 1'b1;

    // LED1：I2C 总线活动 —— SCL 有跳变就清零静默计数，静默够久则熄灭
    reg        scl_d     = 1'b1;
    reg [21:0] quiet_cnt = 22'd0;
    always @(posedge clk) begin
        scl_d <= scl;
        if (scl != scl_d)
            quiet_cnt <= 22'd0;
        else if (quiet_cnt != 22'h3FFFFF)
            quiet_cnt <= quiet_cnt + 1'b1;
    end

    assign led_n[0] = ~hb_cnt[23];                 // 心跳
    assign led_n[1] = (quiet_cnt != 22'h3FFFFF);   // I2C 有活动
    // LED2：亮 = 从机应答过（I2C 打通）；灭 = 从机从未应答
    assign led_n[2] = ~dbg_ack_seen;

endmodule
