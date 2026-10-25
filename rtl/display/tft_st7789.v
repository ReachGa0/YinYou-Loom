// ============================================================
// tft_st7789.v —— 2.4 寸 ST7789VW (240x320) SPI TFT 显示驱动
//
// 职责边界：只负责"把一个矩形窗口的颜色流按 SPI 时序发出去"，
//           不关心画什么。界面内容由 ui_render.v 以纯函数形式提供，
//           所以本模块没有帧缓冲、不读界面状态。
//
// 上电流程：
//   rst_n 释放 → 等 POR_MS（RES 保持低）→ 再等 RESET_MS
//   → RES 拉高 → 等 POST_RESET_MS → 发 31 条初始化序列
//   → 0x11 之后等 SLPOUT_MS → 0x29 开显示 → 进入就绪
//
// 引脚（PIN71-76，与 docs/22 一致）：
//   SCLK / MOSI / CS / DC / RES / BLK
//   BLK 上电默认三态，顶层 .cst 必须写 PULL_MODE=DOWN，
//   否则背光在配置期间会半亮（真实踩过的坑，见 docs/19）
//
// 像素接口契约（渲染器可以是组合逻辑，也可以是 1 拍寄存器输出）：
//     拍号      驱动器                      渲染器
//     n        pix_we=1，pix_x/pix_y 有效   ——
//     n+1      ——                           寄存器输出此刻对应 x/y
//     n+2      采样 pix_data                 ——（要求仍对应同一个 x/y）
//   采样发生在 pix_we 之后第 3 拍；渲染器可先寄存列选择再同步读字库。
//
// SPI：模式 0（CPOL=0 / CPHA=0），MSB first，一个窗口事务内 CS 保持低。
//      RGB565，每像素 2 字节，高字节先发（大端）。
//
// ⚠️ 初始化序列按通用 ST7789V 编写（手上没有 ST7789VW 官方手册），
//    其中 MADCTL / 反显 / RGB-BGR 三项必须上板用颜色条校准，
//    校准结果记入 docs/22。
// ============================================================

module tft_st7789 #(
    parameter CLK_HZ        = 72_000_000,
    parameter SCLK_HZ       = 12_000_000,
    parameter POR_MS        = 10,          // 上电等待（RES 仍保持低）
    parameter RESET_MS      = 1,           // RES 低脉宽（手册要求 ≥10us，这里留 1ms）
    parameter POST_RESET_MS = 120,         // RES 拉高到第一条命令
    parameter SLPOUT_MS     = 120,         // 0x11 之后的等待
    parameter MADCTL_VAL    = 8'h60,       // 横屏（待上板校准）
    parameter COLMOD_VAL    = 8'h55,       // 16bit RGB565
    parameter INVERT_ON     = 1'b1,        // 0x21 反显（IPS 屏常见）
    parameter BLK_EARLY     = 1'b1         // 1=初始化前就点背光（便于排查）
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 矩形窗口事务 ----
    input  wire        win_start,           // 单周期脉冲，只在 busy=0 时有效
    input  wire [9:0]  win_x0,
    input  wire [9:0]  win_x1,
    input  wire [9:0]  win_y0,
    input  wire [9:0]  win_y1,
    input  wire [15:0] pix_data,            // 当前像素 RGB565
    output reg         pix_we,              // 请求像素：见上方契约
    output reg  [8:0]  pix_x,
    output reg  [7:0]  pix_y,
    output wire        busy,
    output reg         done,                // 事务完成单周期脉冲

    // ---- 屏引脚 ----
    output reg         sclk,
    output reg         mosi,
    output reg         cs_n,
    output reg         dc,
    output reg         res_n,
    output reg         blk,

    // ---- 调试 ----
    output wire [3:0]  dbg_state
);

    // ------------------------------------------------------------
    // 时钟与毫秒换算
    // ------------------------------------------------------------
    // SCLK = CLK / (2*DIV)：DIV 是一个半周期包含的 clk 拍数
    localparam integer DIV_RAW = CLK_HZ / (2 * SCLK_HZ);
    localparam integer DIV     = (DIV_RAW < 1) ? 1 : DIV_RAW;
    localparam integer MS_DIV  = (CLK_HZ / 1000 < 1) ? 1 : (CLK_HZ / 1000);

    // 毫秒 → clk 拍数。等待计数器由主状态机自己持有：
    // 进入等待那一拍同时装载，下一拍起就是完整值，不会出现"装载晚一拍、
    // 等待被立刻跳过"的跨 always 块竞态（这个坑在仿真里踩过一次）。
    localparam [3:0] W_POR    = 4'd1,
                     W_RESET  = 4'd2,
                     W_POST   = 4'd3,
                     W_SLPOUT = 4'd4;

    function [31:0] ms_to_clk;
        input [3:0] sel;
        begin
            case (sel)
                W_POR   : ms_to_clk = POR_MS        * MS_DIV;
                W_RESET : ms_to_clk = RESET_MS      * MS_DIV;
                W_POST  : ms_to_clk = POST_RESET_MS * MS_DIV;
                default : ms_to_clk = SLPOUT_MS     * MS_DIV;
            endcase
        end
    endfunction

    // ------------------------------------------------------------
    // SPI 字节发送引擎（模式 0，MSB first）
    // ------------------------------------------------------------
    localparam [2:0] T_IDLE = 3'd0,
                     T_LOW  = 3'd1,
                     T_HIGH = 3'd2;

    reg  [2:0]  tx_state;
    reg  [7:0]  shifter;
    reg  [2:0]  bit_cnt;
    reg  [15:0] div_cnt;
    wire        tick = (div_cnt == DIV - 1);

    reg         tx_start;      // 单周期脉冲，由主状态机给
    reg  [7:0]  tx_byte;
    reg         tx_dc;
    reg         tx_done;       // 单周期脉冲
    reg         cs_release;    // 主状态机请求拉高 CS（引擎是 cs_n 的唯一驱动源）
    wire        tx_busy = (tx_state != T_IDLE);

    always @(posedge clk) begin
        if (!rst_n) begin
            tx_state <= T_IDLE;
            shifter  <= 8'h00;
            bit_cnt  <= 3'd0;
            div_cnt  <= 16'd0;
            sclk     <= 1'b0;
            mosi     <= 1'b0;
            cs_n     <= 1'b1;
            dc       <= 1'b0;
            tx_done  <= 1'b0;
        end else begin
            tx_done <= 1'b0;
            case (tx_state)
                T_IDLE: begin
                    div_cnt <= 16'd0;
                    sclk    <= 1'b0;
                    if (tx_start) begin
                        shifter  <= tx_byte;
                        bit_cnt  <= 3'd7;
                        cs_n     <= 1'b0;
                        dc       <= tx_dc;
                        tx_state <= T_LOW;
                    end else if (cs_release) begin
                        cs_n     <= 1'b1;      // 事务收尾：只在这里拉高 CS
                    end
                end
                T_LOW: begin
                    mosi <= shifter[7];          // 上升沿之前数据已稳定
                    if (tick) begin
                        div_cnt  <= 16'd0;
                        sclk     <= 1'b1;
                        tx_state <= T_HIGH;
                    end else begin
                        div_cnt <= div_cnt + 16'd1;
                    end
                end
                T_HIGH: begin
                    if (tick) begin
                        div_cnt <= 16'd0;
                        sclk    <= 1'b0;
                        if (bit_cnt == 3'd0) begin
                            tx_done  <= 1'b1;
                            tx_state <= T_IDLE;
                        end else begin
                            shifter  <= {shifter[6:0], 1'b0};
                            bit_cnt  <= bit_cnt - 3'd1;
                            tx_state <= T_LOW;
                        end
                    end else begin
                        div_cnt <= div_cnt + 16'd1;
                    end
                end
                default: tx_state <= T_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------
    // 初始化序列表（31 项）
    // INIT_DC_MASK 的 bit i = 1 表示第 i 项是数据，0 表示命令
    // 数据项下标：2 4 7 8 9 10 11 13 15 17 19 21 23 25 27 28
    // ------------------------------------------------------------
    localparam INIT_LEN     = 31;
    localparam [31:0] INIT_DC_MASK = 32'h1AAAAF94;

    function [7:0] init_byte;
        input [5:0] i;
        begin
            case (i)
                6'd0 : init_byte = 8'h11;                       // sleep out
                6'd1 : init_byte = 8'h3A;                       // COLMOD
                6'd2 : init_byte = COLMOD_VAL;
                6'd3 : init_byte = 8'h36;                       // MADCTL
                6'd4 : init_byte = MADCTL_VAL;
                6'd5 : init_byte = INVERT_ON ? 8'h21 : 8'h20;   // INVON / INVOFF
                6'd6 : init_byte = 8'hB2;                       // porch
                6'd7 : init_byte = 8'h0C;
                6'd8 : init_byte = 8'h0C;
                6'd9 : init_byte = 8'h00;
                6'd10: init_byte = 8'h33;
                6'd11: init_byte = 8'h33;
                6'd12: init_byte = 8'hB7;                       // gate control
                6'd13: init_byte = 8'h35;
                6'd14: init_byte = 8'hBB;                       // VCOM
                6'd15: init_byte = 8'h19;
                6'd16: init_byte = 8'hC0;                       // LCM control
                6'd17: init_byte = 8'h2C;
                6'd18: init_byte = 8'hC2;                       // VDV/VRH enable
                6'd19: init_byte = 8'h01;
                6'd20: init_byte = 8'hC3;                       // VRH
                6'd21: init_byte = 8'h12;
                6'd22: init_byte = 8'hC4;                       // VDV
                6'd23: init_byte = 8'h20;
                6'd24: init_byte = 8'hC6;                       // FR control 2
                6'd25: init_byte = 8'h0F;
                6'd26: init_byte = 8'hD0;                       // power control 1
                6'd27: init_byte = 8'hAA;
                6'd28: init_byte = 8'hA0;
                6'd29: init_byte = 8'h13;                       // normal display
                default: init_byte = 8'h29;                     // display on
            endcase
        end
    endfunction

    // ------------------------------------------------------------
    // 窗口命令头（11 项）：0x2A + x0,x1 + 0x2B + y0,y1 + 0x2C
    // HDR_DC_MASK 的 bit i = 1 表示第 i 项是数据
    // ------------------------------------------------------------
    localparam HDR_LEN    = 11;
    localparam [10:0] HDR_DC_MASK = 11'h3DE;

    reg [15:0] wx0, wx1, wy0, wy1;      // 零扩展到 16 位，方便拆高低字节

    function [7:0] hdr_byte;
        input [3:0] i;
        begin
            case (i)
                4'd0 : hdr_byte = 8'h2A;        // 列地址设置
                4'd1 : hdr_byte = wx0[15:8];
                4'd2 : hdr_byte = wx0[7:0];
                4'd3 : hdr_byte = wx1[15:8];
                4'd4 : hdr_byte = wx1[7:0];
                4'd5 : hdr_byte = 8'h2B;        // 行地址设置
                4'd6 : hdr_byte = wy0[15:8];
                4'd7 : hdr_byte = wy0[7:0];
                4'd8 : hdr_byte = wy1[15:8];
                4'd9 : hdr_byte = wy1[7:0];
                default: hdr_byte = 8'h2C;      // 写 GRAM
            endcase
        end
    endfunction

    // ------------------------------------------------------------
    // 主状态机
    // ------------------------------------------------------------
    localparam [3:0] S_POR   = 4'd0,
                     S_RESET = 4'd1,
                     S_POST  = 4'd2,
                     S_INIT  = 4'd3,
                     S_READY = 4'd4,
                     S_HDR   = 4'd5,
                     S_PIX   = 4'd6,
                     S_END   = 4'd7,
                     S_WAIT  = 4'd8;

    reg [3:0]  state;
    reg [3:0]  wait_next;
    reg [31:0] wait_cnt;

    reg [5:0] init_idx;
    reg [3:0] hdr_idx;
    reg [2:0] pix_step;
    reg [8:0] cur_x;
    reg [7:0] cur_y;
    reg [15:0] pix_rgb;

    assign dbg_state = state;
    assign busy      = (state != S_READY);

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_POR;
            wait_next   <= S_RESET;
            wait_cnt    <= 32'd0;
            res_n       <= 1'b0;
            blk         <= 1'b0;
            done        <= 1'b0;
            tx_start    <= 1'b0;
            cs_release  <= 1'b0;
            tx_byte     <= 8'h00;
            tx_dc       <= 1'b0;
            init_idx    <= 6'd0;
            hdr_idx     <= 4'd0;
            pix_step    <= 3'd0;
            pix_we      <= 1'b0;
            pix_x       <= 9'd0;
            pix_y       <= 8'd0;
            pix_rgb     <= 16'h0000;
            wx0 <= 16'd0; wx1 <= 16'd0; wy0 <= 16'd0; wy1 <= 16'd0;
            cur_x <= 9'd0; cur_y <= 8'd0;
        end else begin
            done       <= 1'b0;
            tx_start   <= 1'b0;
            cs_release <= 1'b0;

            case (state)
                // ---------------- 上电与复位 ----------------
                S_WAIT: begin
                    if (wait_cnt == 32'd0) state <= wait_next;
                    else                   wait_cnt <= wait_cnt - 32'd1;
                end
                S_POR: begin
                    wait_cnt <= ms_to_clk(W_POR);
                    wait_next <= S_RESET; state <= S_WAIT;
                end
                S_RESET: begin
                    res_n <= 1'b0;
                    wait_cnt <= ms_to_clk(W_RESET);
                    wait_next <= S_POST; state <= S_WAIT;
                end
                S_POST: begin
                    res_n <= 1'b1;
                    if (BLK_EARLY) blk <= 1'b1;
                    wait_cnt <= ms_to_clk(W_POST);
                    wait_next <= S_INIT; state <= S_WAIT;
                end

                // ---------------- 初始化序列 ----------------
                S_INIT: begin
                    if (init_idx < INIT_LEN) begin
                        if (tx_done) begin
                            init_idx <= init_idx + 6'd1;
                            if (init_idx == 6'd0) begin      // 0x11 之后要等 120ms
                                wait_cnt <= ms_to_clk(W_SLPOUT);
                                wait_next <= S_INIT; state <= S_WAIT;
                            end
                        end else if (!tx_busy) begin
                            tx_start <= 1'b1;
                            tx_byte  <= init_byte(init_idx);
                            tx_dc    <= INIT_DC_MASK[init_idx];
                        end
                    end else begin
                        if (!BLK_EARLY) blk <= 1'b1;
                        cs_release <= 1'b1;
                        init_idx <= 6'd0;
                        state    <= S_READY;
                    end
                end

                // ---------------- 等待窗口事务 ----------------
                S_READY: begin
                    if (win_start) begin
                        wx0 <= {6'b0, win_x0};
                        wx1 <= {6'b0, win_x1};
                        wy0 <= {6'b0, win_y0};
                        wy1 <= {6'b0, win_y1};
                        cur_x   <= win_x0[8:0];
                        cur_y   <= win_y0[7:0];
                        hdr_idx <= 4'd0;
                        pix_step <= 3'd0;
                        state   <= S_HDR;
                    end
                end

                // ---------------- 窗口命令头 ----------------
                S_HDR: begin
                    if (hdr_idx < HDR_LEN) begin
                        if (tx_done) begin
                            hdr_idx <= hdr_idx + 4'd1;
                        end else if (!tx_busy) begin
                            tx_start <= 1'b1;
                            tx_byte  <= hdr_byte(hdr_idx);
                            tx_dc    <= HDR_DC_MASK[hdr_idx];
                        end
                    end else begin
                        pix_step <= 3'd0;
                        state    <= S_PIX;
                    end
                end

                // ---------------- 像素流 ----------------
                S_PIX: begin
                    case (pix_step)
                        3'd0: begin
                            pix_we  <= 1'b1;
                            pix_x   <= cur_x;
                            pix_y   <= cur_y;
                            pix_step <= 3'd1;
                        end
                        3'd1: begin
                            pix_we   <= 1'b0;          // 等渲染器（寄存器输出）稳定
                            pix_step <= 3'd2;
                        end
                        3'd2: begin
                            pix_step <= 3'd3;          // 渲染器字模流水多等一拍
                        end
                        3'd3: begin
                            pix_rgb  <= pix_data;      // pix_we 之后第 3 拍采样
                            pix_step <= 3'd4;
                        end
                        3'd4: begin
                            if (!tx_busy && !tx_done) begin
                                tx_start <= 1'b1;
                                tx_byte  <= pix_rgb[15:8];
                                tx_dc    <= 1'b1;
                                pix_step <= 3'd5;
                            end
                        end
                        3'd5: begin
                            if (tx_done) pix_step <= 3'd6;
                        end
                        3'd6: begin
                            if (!tx_busy && !tx_done) begin
                                tx_start <= 1'b1;
                                tx_byte  <= pix_rgb[7:0];
                                tx_dc    <= 1'b1;
                                pix_step <= 3'd7;
                            end
                        end
                        default: begin                 // 3'd7：推进到下一个像素
                            if (tx_done) begin
                                if (cur_x == wx1[8:0]) begin
                                    cur_x <= wx0[8:0];
                                    if (cur_y == wy1[7:0]) begin
                                        state <= S_END;
                                    end else begin
                                        cur_y    <= cur_y + 8'd1;
                                        pix_step <= 3'd0;
                                    end
                                end else begin
                                    cur_x    <= cur_x + 9'd1;
                                    pix_step <= 3'd0;
                                end
                            end
                        end
                    endcase
                end

                // ---------------- 事务收尾 ----------------
                S_END: begin
                    cs_release <= 1'b1;
                    done  <= 1'b1;
                    state <= S_READY;
                end

                default: state <= S_POR;
            endcase
        end
    end

endmodule
