// ============================================================
// tft_ui_top.v —— 横屏 UI 上板 demo（独立于已验收工程）
//
// 结构：PLL(72MHz) → tft_st7789（驱动）+ ui_render（渲染）+ font8x16_rom（字库）
//
// 本 demo 自带一个"假演奏状态"发生器，用来在真屏上验证动态效果：
//   音色    每 ~1.9s 切换（波形在正弦/方波之间变）
//   音符    锯齿扫描 MIDI 48→72（波长在一屏 2.5→7.5 个周期之间连续变化）
//   发声数  0/1/2/3 循环 + 音色位时为 4（幅度 0→±40px 变化）
//   效果/模式 每 ~3.7s / ~7.5s 切换（对应列的选中反白跟着跑，验证事件式局部刷新）
//
// 板载 LED 镜像内部状态，便于无示波器定位：
//   LED0 = 驱动器就绪；LED1-3 = 区域码（0 整屏 / 1 波形带 / 2,3,4 三列选项区）；
//   LED4 = 当前音色
//
// 接进 p6_test_demo 时，把这里的"假状态发生器"换成真实演奏状态即可（其余不动）。
// ============================================================

module tft_ui_top (
    input  wire       clk,          // 板载 27 MHz（PIN4）
    output wire       sclk,
    output wire       mosi,
    output wire       cs_n,
    output wire       dc,
    output wire       res_n,
    output wire       blk,
    output wire [4:0] led_n         // PIN15-19，低电平点亮
);

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
    // 假演奏状态发生器（仅 demo 用）
    // ------------------------------------------------------------
    reg [29:0] t_cnt;
    always @(posedge clk_sys) begin
        if (!rst_n) t_cnt <= 30'd0;
        else        t_cnt <= t_cnt + 30'd1;
    end

    // 音符：48 → 72 锯齿扫描，约 25×0.117s ≈ 2.9s 一轮
    reg [4:0] note_off;
    always @(posedge clk_sys) begin
        if (!rst_n) note_off <= 5'd0;
        else if (t_cnt[22:0] == 23'd0)
            note_off <= (note_off == 5'd24) ? 5'd0 : (note_off + 5'd1);
    end

    wire [1:0] st_timbre = {1'b0, t_cnt[27]};                 // ~1.9s 切换
    wire [1:0] st_fx     = {1'b0, t_cnt[28]};                 // ~3.7s 切换
    wire [1:0] st_mode   = {1'b0, t_cnt[29]};                 // ~7.5s 切换
    wire [6:0] st_note   = 7'd48 + {2'b0, note_off};
    wire [2:0] st_voices = t_cnt[27] ? 3'd4 : {1'b0, t_cnt[26], t_cnt[25]};

    // ------------------------------------------------------------
    // 渲染器 + 驱动
    // ------------------------------------------------------------
    wire        win_start;
    wire [9:0]  win_x0, win_x1, win_y0, win_y1;
    wire [15:0] px_data;
    wire [8:0]  pix_x;
    wire [7:0]  pix_y;
    wire        busy, done;
    wire [2:0]  dbg_region;

    ui_render u_ui (
        .clk        (clk_sys),
        .rst_n      (rst_n),
        .st_timbre  (st_timbre),
        .st_fx      (st_fx),
        .st_mode    (st_mode),
        .st_note    (st_note),
        .st_voices  (st_voices),
        .st_key_root(7'd0),                 // 调式占位（旋钮未接）
        .win_start  (win_start),
        .win_x0     (win_x0),
        .win_x1     (win_x1),
        .win_y0     (win_y0),
        .win_y1     (win_y1),
        .px_data    (px_data),
        .px_x       (pix_x),
        .px_y       (pix_y),
        .busy       (busy),
        .done       (done),
        .dbg_region (dbg_region)
    );

    tft_st7789 #(
        .CLK_HZ     (72_000_000),
        .SCLK_HZ    (12_000_000),           // 阶梯实测：12 干净、18 贴门限、36 不通
        .MADCTL_VAL (8'hA0),                // 实测锁定：0x60 会 180° 反向
        .INVERT_ON  (1'b0)                  // 实测锁定：本板原生极性相反
    ) u_tft (
        .clk       (clk_sys),
        .rst_n     (rst_n),
        .win_start (win_start),
        .win_x0    (win_x0),
        .win_x1    (win_x1),
        .win_y0    (win_y0),
        .win_y1    (win_y1),
        .pix_data  (px_data),
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
        .dbg_state ()
    );

    // ------------------------------------------------------------
    // LED 诊断镜像
    // ------------------------------------------------------------
    assign led_n[0] = ~(busy == 1'b0);      // 亮 = 驱动器就绪
    assign led_n[1] = ~dbg_region[0];
    assign led_n[2] = ~dbg_region[1];
    assign led_n[3] = ~dbg_region[2];
    assign led_n[4] = ~st_timbre[0];        // 亮 = SQUARE

endmodule
