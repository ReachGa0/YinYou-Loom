// ============================================================
// tft_pin_probe_top.v —— ST7789 接线/二极管探针（临时顶层，诊断专用）
//
// 目的：用万用表逐根判定 PIN71-76 到模块排针的通路是否成立。
//       把 5 根信号线各自输出一个"节奏不同"的超慢方波，同时在板载
//       LED0-4 上镜像同样的节奏 —— 看"LED 在跳、模块那一脚也在跳"
//       就等于这根线通了，而且低/高电平都能传到面板侧。
//
// 频率分配（27MHz 晶振直接分频，不用 PLL，减少变量）：
//   LED0 ↔ SCLK (PIN71)  cnt[24]  约 0.62s 翻转
//   LED1 ↔ MOSI (PIN72)  cnt[25]  约 1.24s 翻转
//   LED2 ↔ CS   (PIN73)  cnt[26]  约 2.48s 翻转
//   LED3 ↔ DC   (PIN74)  cnt[27]  约 4.97s 翻转
//   LED4 ↔ RES  (PIN75)  常高      —— LED4 常亮 = RES 一直无效（正常）
//   BLK  (PIN76)  常高     —— 背光常亮，作为"供电正常"的基准
//
// 万用表用法：黑表笔接 GND，红表笔点在模块排针对应脚上，直流档。
//   正常应看到电压跟着对应 LED 的节奏在 0V 与约 3V 之间来回；
//   一直 3.3V（不动）→ 这根线没接到、或靠上拉顶住（低电平传不进去）；
//   一直 0V → 线接错或短路。
//
// ⚠️ 本顶层只是探针，验证完就换回 tft_bringup_top。
// ============================================================

module tft_pin_probe_top (
    input  wire       clk,          // 板载 27 MHz（PIN4）
    output wire       sclk,
    output wire       mosi,
    output wire       cs_n,
    output wire       dc,
    output wire       res_n,
    output wire       blk,
    output wire [4:0] led_n         // PIN15-19，低电平点亮
);

    reg [27:0] cnt;

    always @(posedge clk) begin
        cnt <= cnt + 28'd1;
    end

    // ---- 5 根信号线：各一个慢方波（RES 常高）----
    assign sclk  = cnt[24];
    assign mosi  = cnt[25];
    assign cs_n  = cnt[26];
    assign dc    = cnt[27];
    assign res_n = 1'b1;      // 不复位，让面板保持在上电态
    assign blk   = 1'b1;      // 背光常亮

    // ---- LED 镜像同样的信号，方便一一对照 ----
    assign led_n[0] = ~cnt[24];
    assign led_n[1] = ~cnt[25];
    assign led_n[2] = ~cnt[26];
    assign led_n[3] = ~cnt[27];
    assign led_n[4] = 1'b0;   // 常亮：RES 为高

endmodule
