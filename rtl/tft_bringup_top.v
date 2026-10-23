// ============================================================
// tft_bringup_top.v —— ST7789 上板点亮自检（临时顶层，不属于产品路径）
//
// 图案设计：一次上板把 4 个未知量全部锁死
//   1. 8 条标准色条（白 黄 青 绿 品红 红 蓝 黑，自上而下 30px 一条）
//        → 判断颜色顺序（RGB / BGR）
//        → 判断是否反显（不反显时"白在最上、黑在最下"）
//   2. 1 像素红边框 → 320x240 窗口是否与屏幕精确对齐（四面都必须可见）
//   3. 四角标记 20x20（左上黑 / 右上绿 / 左下白 / 右下青）
//        → 判断横屏方向（四个角颜色互不相同，任何旋转都能一眼看出）
//   4. 左上标记每约 0.47s 在黑↔白之间闪
//        → "位流在跑"的可见证据，同时验证重复窗口事务
//   5. LED0-4（PIN15-19）用二进制显示驱动状态机状态
//        → 屏不亮时不用示波器也能定位卡在哪一步
//
// SCLK 逐档试：改 SCLK_HZ 重编即可。从 72MHz 分频的合法档位是
//   36 / 18 / 12 / 9 / 7.2 / 6 / 5.14 / 4.5 MHz（对应 DIV = 1..8）
// 建议顺序：12 MHz（默认，也是产品要用的档）→ 18 → 36。
//
// ⚠️ 本顶层只用于点亮与校准；产品显示接在 p6_test_demo 上。
// ============================================================

module tft_bringup_top #(
    // 逐档试 SCLK。12 MHz / 2.25 MHz 都是全白，说明这颗模块的高电平
    // 是被 4.7k 上拉"喂"出来的（串联肖特基 + 上拉，见原理图）：
    //   上升时间 τ ≈ 4.7k × C，C 含面板输入 + 20cm 杜邦线（约 20~30pF）
    //   → τ ≈ 165~235ns → 12MHz(41ns) 与 2.25MHz(222ns) 都充不满
    // 1 MHz 的高电平相有 500ns，可充到约 95%（≈2.9V），先在这里验证。
    // 提速阶梯实测：1M ✓ / 12M ✓ / 18M ✓(贴门限) / 36M ✗(白屏)
    // 产品值取 12 MHz：上升沿能到 84% 门限，留余量；18 MHz 只是"刚好够"
    parameter SCLK_HZ    = 12_000_000,
    parameter REPAINT_MS = 1500        // 每 1.5s 重画整屏（便于万用表测 SCL，也能看出位流在跑）
)(
    input  wire       clk,          // 板载 27 MHz 晶振（PIN4）
    output wire       sclk,
    output wire       mosi,
    output wire       cs_n,
    output wire       dc,
    output wire       res_n,
    output wire       blk,
    output wire [4:0] led_n         // PIN15-19，低电平点亮
);

    localparam integer SCREEN_W = 320;
    localparam integer SCREEN_H = 240;

    // ---- RGB565 调色板 ----
    localparam [15:0] C_WHITE   = 16'hFFFF,
                      C_YELLOW  = 16'hFFE0,
                      C_CYAN    = 16'h07FF,
                      C_GREEN   = 16'h07E0,
                      C_MAGENTA = 16'hF81F,
                      C_RED     = 16'hF800,
                      C_BLUE    = 16'h001F,
                      C_BLACK   = 16'h0000;

    wire clk_sys;
    wire pll_lock;
    wire rst_n;

    Gowin_rPLL u_pll (
        .clkin  (clk),
        .reset  (1'b0),
        .clkout (clk_sys),
        .lock   (pll_lock)
    );

    sync_reset u_rst (
        .clk    (clk_sys),
        .arst_n (pll_lock),
        .rst_n  (rst_n)
    );

    // ------------------------------------------------------------
    // 定时重画：每 REPAINT_MS 重画整屏，左上角标记每次翻转一次。
    // 这样 SCL 线上大部分时间在活动，便于用万用表测平均电压验证接线；
    // 同时也是"位流在跑"的可见证据。
    // ------------------------------------------------------------
    localparam integer REPAINT_CYCLES = 72_000 * REPAINT_MS;   // clk_sys = 72MHz → 每 ms 72000 拍
    reg [31:0] repaint_cnt;
    reg        frame_toggle;
    wire       repaint_tick = (repaint_cnt == REPAINT_CYCLES - 1);

    always @(posedge clk_sys) begin
        if (!rst_n) begin
            repaint_cnt  <= 32'd0;
            frame_toggle <= 1'b0;
        end else if (repaint_tick) begin
            repaint_cnt  <= 32'd0;
            frame_toggle <= ~frame_toggle;
        end else begin
            repaint_cnt <= repaint_cnt + 32'd1;
        end
    end

    // ------------------------------------------------------------
    // 像素纯函数：pixel(x, y) → RGB565
    // ------------------------------------------------------------
    reg [15:0] pix_data;
    wire [15:0] bar_color =
          (pix_y <  30) ? C_WHITE
        : (pix_y <  60) ? C_YELLOW
        : (pix_y <  90) ? C_CYAN
        : (pix_y < 120) ? C_GREEN
        : (pix_y < 150) ? C_MAGENTA
        : (pix_y < 180) ? C_RED
        : (pix_y < 210) ? C_BLUE
        :                 C_BLACK;

    always @(*) begin
        pix_data = bar_color;

        // 1 像素红边框：四面都必须贴边，用来验证窗口与屏幕精确对齐
        if (pix_x == 0 || pix_x == SCREEN_W - 1 ||
            pix_y == 0 || pix_y == SCREEN_H - 1) pix_data = C_RED;

        // 四角方向标记（压在色条之上）
        if (pix_x >= 4 && pix_x <= 23 && pix_y >= 4 && pix_y <= 23)
            pix_data = frame_toggle ? C_WHITE : C_BLACK; // 左上：每次重画翻转
        if (pix_x >= 296 && pix_x <= 315 && pix_y >= 4 && pix_y <= 23)
            pix_data = C_GREEN;                          // 右上
        if (pix_x >= 4 && pix_x <= 23 && pix_y >= 216 && pix_y <= 235)
            pix_data = C_WHITE;                          // 左下
        if (pix_x >= 296 && pix_x <= 315 && pix_y >= 216 && pix_y <= 235)
            pix_data = C_CYAN;                           // 右下
    end

    // ------------------------------------------------------------
    // 窗口调度：上电整屏画一次，之后每 REPAINT_MS 重画整屏
    // ------------------------------------------------------------
    wire        busy, done;
    wire [8:0]  pix_x;
    wire [7:0]  pix_y;
    reg         win_start;
    reg         send_pending;
    reg  [9:0]  wx0, wx1, wy0, wy1;

    always @(posedge clk_sys) begin
        if (!rst_n) begin
            win_start     <= 1'b0;
            wx0 <= 10'd0; wx1 <= 10'd319; wy0 <= 10'd0; wy1 <= 10'd239;
            send_pending  <= 1'b1;          // 上电先整屏画一次
        end else begin
            win_start <= 1'b0;
            if (send_pending && !busy) begin
                win_start    <= 1'b1;
                send_pending <= 1'b0;
            end else if (!busy && repaint_tick) begin
                send_pending  <= 1'b1;      // 周期性整屏重画
            end
        end
    end

    // ------------------------------------------------------------
    // 屏驱动
    // ------------------------------------------------------------
    wire [3:0] dbg_state;

    tft_st7789 #(
        .CLK_HZ    (72_000_000),
        .SCLK_HZ   (SCLK_HZ),
        .MADCTL_VAL(8'hA0),        // 横屏：0x60 实测是 180° 反的，改 0xA0（差 MX|MY）
        .INVERT_ON (1'b0)          // 上一版 0x21 实测颜色被整体取反，本板原生极性相反
    ) u_tft (
        .clk       (clk_sys),
        .rst_n     (rst_n),
        .win_start (win_start),
        .win_x0    (wx0),
        .win_x1    (wx1),
        .win_y0    (wy0),
        .win_y1    (wy1),
        .pix_data  (pix_data),
        .pix_we    (),
        .pix_x     (pix_x),
        .pix_y     (pix_y),
        .busy      (busy),
        .done      (done),
        .sclk      (sclk),
        .mosi      (mosi),
        .cs_n      (cs_n),
        .dc        (dc),
        .res_n     (res_n),
        .blk       (blk),
        .dbg_state (dbg_state)
    );

    // ------------------------------------------------------------
    // LED 诊断：LED0 = 就绪（初始化完成），LED1-4 = 状态机状态二进制
    // ------------------------------------------------------------
    assign led_n[0] = ~((dbg_state == 4'd4));     // 亮 = 已就绪
    assign led_n[1] = ~dbg_state[0];
    assign led_n[2] = ~dbg_state[1];
    assign led_n[3] = ~dbg_state[2];
    assign led_n[4] = ~dbg_state[3];

endmodule
