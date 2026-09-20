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
    output wire scl,          // I2C 时钟  -> OLED SCL
    inout  wire sda           // I2C 数据  -> OLED SDA
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
    wire rst_n = por_done & key_n;

    // ---- SH1106 控制器 ----
    oled_sh1106 #(
        .CLK_HZ     (27_000_000),
        .SCL_HZ     (100_000),
        .POR_CYCLES (27_000_000 / 5)      // 上电等待约 200ms
    ) u_oled (
        .clk   (clk),
        .rst_n (rst_n),
        .scl   (scl),
        .sda   (sda)
    );

endmodule
