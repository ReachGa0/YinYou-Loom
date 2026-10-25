`timescale 1ns/1ps

// tft_st7789 的验证测试台（只测驱动，不含界面）
//
// 用一个 SPI 从机模型在 SCLK 上升沿逐位采样，然后把总线上发生的一切
// 按字节记录，检查：
//   1. RES 低脉宽、RES 拉高到第一条命令的延时（复位时序）
//   2. 31 条初始化序列的字节与 DC（命令/数据）逐项正确
//   3. SCLK 实际周期（按 clk 拍数测量，验证分频参数）
//   4. 窗口事务：0x2A/0x2B 的双字节参数、0x2C、像素字节数与顺序
//   5. 像素接口契约：pix_we 之后第 3 拍采样；测试模型使用 1 拍寄存器输出，
//      验证接口能容纳渲染器内部同步字库流水
//   6. CS 在事务内保持低、事务之间拉高；每个窗口一次 done 脉冲
//
// 仿真参数：1 MHz 时钟 + 100 kHz SCLK（半周期 = 5 拍），毫秒延时压到 1 ms，
// 全部检查与真实参数无关，只与"时序关系"和"字节内容"有关。
//
// 用法：
//   iverilog -g2012 -o tb.vvp sim/tb_tft_st7789.v rtl/display/tft_st7789.v
//   -Ptb_tft_st7789.INVERT=0  切换 0x21/0x20 反显分支

module tb_tft_st7789;

    parameter CLK_HZ  = 1_000_000;
    parameter SCLK_HZ = 100_000;        // DIV = 5 → SCLK 周期 = 10 clk 拍
    parameter INVERT  = 1;              // 1 → 初始化第 5 项是 0x21，0 → 0x20

    localparam integer EXPECT_HALF = CLK_HZ / (2 * SCLK_HZ);   // 5
    localparam integer MS_CYCLES   = CLK_HZ / 1000;            // 1000

    reg clk   = 0;
    reg rst_n = 0;
    always #500 clk = ~clk;             // 1 MHz

    // ---------------- 窗口事务激励 ----------------
    reg        win_start = 0;
    reg [9:0]  win_x0 = 0, win_x1 = 0, win_y0 = 0, win_y1 = 0;

    // 像素数据：故意做成"寄存器输出"，模拟真实渲染器
    wire [15:0] pix_data;
    reg  [15:0] pix_data_q;
    wire        pix_we;
    wire [8:0]  pix_x;
    wire [7:0]  pix_y;
    wire        busy, done;
    wire        sclk, mosi, cs_n, dc, res_n, blk;
    wire [3:0]  dbg_state;

    // ---------------- 被测驱动 ----------------
    tft_st7789 #(
        .CLK_HZ        (CLK_HZ),
        .SCLK_HZ       (SCLK_HZ),
        .POR_MS        (1),
        .RESET_MS      (1),
        .POST_RESET_MS (1),
        .SLPOUT_MS     (1),
        .MADCTL_VAL    (8'h60),
        .COLMOD_VAL    (8'h55),
        .INVERT_ON     (INVERT != 0),
        .BLK_EARLY     (1'b1)
    ) u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .win_start  (win_start),
        .win_x0     (win_x0),
        .win_x1     (win_x1),
        .win_y0     (win_y0),
        .win_y1     (win_y1),
        .pix_data   (pix_data),
        .pix_we     (pix_we),
        .pix_x      (pix_x),
        .pix_y      (pix_y),
        .busy       (busy),
        .done       (done),
        .sclk       (sclk),
        .mosi       (mosi),
        .cs_n       (cs_n),
        .dc         (dc),
        .res_n      (res_n),
        .blk        (blk),
        .dbg_state  (dbg_state)
    );

    // 渲染器模型：pix_data = {x[7:0], y[7:0]}，1 拍寄存器输出
    always @(posedge clk) pix_data_q <= {pix_x[7:0], pix_y[7:0]};
    assign pix_data = pix_data_q;

    // ---------------- SPI 从机模型 ----------------
    reg [7:0]  cap_byte [0:255];
    reg        cap_dc   [0:255];
    integer    cap_idx  = 0;
    reg [7:0]  shreg    = 8'h00;
    integer    bitcnt   = 0;
    reg        cur_dc   = 0;

    integer    cyc             = 0;
    integer    res_fall_cyc    = -1;
    integer    res_rise_cyc    = -1;
    integer    first_sclk_cyc  = -1;
    integer    last_sclk_cyc   = -1;
    integer    sclk_period     = 0;
    integer    sclk_edges      = 0;
    reg        busy_at_first_sclk = 0;
    integer    cs_falls = 0, cs_rises = 0;
    integer    done_cnt = 0;
    integer    pix_req_cnt = 0;

    reg res_n_d = 0;
    reg cs_n_d  = 1;

    always @(posedge clk) begin
        cyc <= cyc + 1;

        res_n_d <= res_n;
        if (res_n_d && !res_n) res_fall_cyc <= cyc;
        if (!res_n_d && res_n) res_rise_cyc <= cyc;

        cs_n_d <= cs_n;
        if (cs_n_d && !cs_n) cs_falls <= cs_falls + 1;
        if (!cs_n_d && cs_n) cs_rises <= cs_rises + 1;

        if (done) done_cnt <= done_cnt + 1;
        if (pix_we) pix_req_cnt <= pix_req_cnt + 1;
    end

    // SCLK 上升沿逐位采样（模式 0：数据在上升沿已稳定）
    always @(posedge sclk) begin
        if (!cs_n) begin
            if (first_sclk_cyc < 0) begin
                first_sclk_cyc    = cyc;
                busy_at_first_sclk = busy;
            end
            if (sclk_edges > 0) sclk_period = cyc - last_sclk_cyc;
            last_sclk_cyc = cyc;
            sclk_edges    = sclk_edges + 1;

            if (bitcnt == 0) cur_dc = dc;        // 字节起始处锁存 DC
            shreg = {shreg[6:0], mosi};
            if (bitcnt == 7) begin
                if (cap_idx < 256) begin
                    cap_byte[cap_idx] = shreg;
                    cap_dc  [cap_idx] = cur_dc;
                end
                cap_idx = cap_idx + 1;
                bitcnt  = 0;
            end else begin
                bitcnt = bitcnt + 1;
            end
        end
    end

    // ---------------- 期望的初始化序列 ----------------
    reg [7:0] exp_init [0:30];
    reg       exp_dc   [0:30];
    integer   k;
    initial begin
        exp_init[0]=8'h11; exp_dc[0]=1'b0;
        exp_init[1]=8'h3A; exp_dc[1]=1'b0;
        exp_init[2]=8'h55; exp_dc[2]=1'b1;      // COLMOD
        exp_init[3]=8'h36; exp_dc[3]=1'b0;
        exp_init[4]=8'h60; exp_dc[4]=1'b1;      // MADCTL（横屏）
        exp_init[5]=INVERT ? 8'h21 : 8'h20; exp_dc[5]=1'b0;
        exp_init[6]=8'hB2; exp_dc[6]=1'b0;
        exp_init[7]=8'h0C; exp_dc[7]=1'b1;
        exp_init[8]=8'h0C; exp_dc[8]=1'b1;
        exp_init[9]=8'h00; exp_dc[9]=1'b1;
        exp_init[10]=8'h33; exp_dc[10]=1'b1;
        exp_init[11]=8'h33; exp_dc[11]=1'b1;
        exp_init[12]=8'hB7; exp_dc[12]=1'b0;
        exp_init[13]=8'h35; exp_dc[13]=1'b1;
        exp_init[14]=8'hBB; exp_dc[14]=1'b0;
        exp_init[15]=8'h19; exp_dc[15]=1'b1;
        exp_init[16]=8'hC0; exp_dc[16]=1'b0;
        exp_init[17]=8'h2C; exp_dc[17]=1'b1;
        exp_init[18]=8'hC2; exp_dc[18]=1'b0;
        exp_init[19]=8'h01; exp_dc[19]=1'b1;
        exp_init[20]=8'hC3; exp_dc[20]=1'b0;
        exp_init[21]=8'h12; exp_dc[21]=1'b1;
        exp_init[22]=8'hC4; exp_dc[22]=1'b0;
        exp_init[23]=8'h20; exp_dc[23]=1'b1;
        exp_init[24]=8'hC6; exp_dc[24]=1'b0;
        exp_init[25]=8'h0F; exp_dc[25]=1'b1;
        exp_init[26]=8'hD0; exp_dc[26]=1'b0;
        exp_init[27]=8'hAA; exp_dc[27]=1'b1;
        exp_init[28]=8'hA0; exp_dc[28]=1'b1;
        exp_init[29]=8'h13; exp_dc[29]=1'b0;
        exp_init[30]=8'h29; exp_dc[30]=1'b0;
    end

    // ---------------- 检查工具 ----------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk8(input [8*30-1:0] name, input [7:0] got, input [7:0] exp);
        begin
            if (got === exp) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s = 0x%02X (期望 0x%02X)", name, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task chkn(input [8*40-1:0] name, input integer got, input integer exp);
        begin
            if (got === exp) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s = %0d (期望 %0d)", name, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task chkge(input [8*40-1:0] name, input integer got, input integer lim);
        begin
            if (got >= lim) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s = %0d (要求 >= %0d)", name, got, lim);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ---------------- 主流程 ----------------
    integer i;
    integer x_exp, y_exp;
    integer win1_base, win2_base;

    initial begin
        rst_n = 0;
        #2000;
        rst_n = 1;

        // 等初始化结束（busy 落下）
        wait (!busy);
        repeat (4) @(posedge clk);

        // ---- 窗口 1：4x2 = 8 像素，x=10..13, y=20..21（含行回绕）----
        win_x0 = 10;  win_x1 = 13;  win_y0 = 20;  win_y1 = 21;
        // 在 negedge 驱动脉冲，避免与 posedge 采样发生竞争
        @(negedge clk); win_start <= 1'b1;
        @(negedge clk); win_start <= 1'b0;
        wait (done);
        repeat (4) @(posedge clk);

        // ---- 窗口 2：单像素 (300,239)，验证 >255 的双字节参数 ----
        win_x0 = 300; win_x1 = 300; win_y0 = 239; win_y1 = 239;
        @(negedge clk); win_start <= 1'b1;
        @(negedge clk); win_start <= 1'b0;
        wait (done);
        repeat (20) @(posedge clk);

        $display("");
        $display("=== 复位时序 ===");
        if (res_rise_cyc - res_fall_cyc < MS_CYCLES) begin
            $display("  FAIL  res_low_cycles = %0d (要求 >= %0d)",
                     res_rise_cyc - res_fall_cyc, MS_CYCLES);
            fail_cnt = fail_cnt + 1;
        end else begin
            pass_cnt = pass_cnt + 1;
        end
        chkge("res_to_first_sclk", first_sclk_cyc - res_rise_cyc, MS_CYCLES);
        chkn("busy_at_first_sclk", busy_at_first_sclk, 1);

        $display("");
        $display("=== SCLK 时序 ===");
        chkn("sclk_half_period(clk拍)", sclk_period / 2, EXPECT_HALF);
        chkn("sclk_edges_per_byte*8", sclk_edges % 8, 0);

        $display("");
        $display("=== 初始化序列（31 项）===");
        for (k = 0; k < 31; k = k + 1) begin
            chk8("init.byte", cap_byte[k], exp_init[k]);
            chkn("init.dc",   cap_dc[k],   exp_dc[k]);
        end

        // 窗口 1 = 初始化 31 字节 + 头 11 字节
        win1_base = 31 + 11;
        win2_base = win1_base + 16 + 11;

        $display("");
        $display("=== 窗口 1：命令头（x=10..13, y=20..21）===");
        chk8("w1.0x2A", cap_byte[31], 8'h2A);
        chk8("w1.x0h ", cap_byte[32], 8'h00);
        chk8("w1.x0l ", cap_byte[33], 8'h0A);
        chk8("w1.x1h ", cap_byte[34], 8'h00);
        chk8("w1.x1l ", cap_byte[35], 8'h0D);
        chk8("w1.0x2B", cap_byte[36], 8'h2B);
        chk8("w1.y0h ", cap_byte[37], 8'h00);
        chk8("w1.y0l ", cap_byte[38], 8'h14);
        chk8("w1.y1h ", cap_byte[39], 8'h00);
        chk8("w1.y1l ", cap_byte[40], 8'h15);
        chk8("w1.0x2C", cap_byte[41], 8'h2C);
        chkn("w1.hdr.dc", (cap_dc[32] & cap_dc[33] & cap_dc[34] & cap_dc[35] &
                           cap_dc[37] & cap_dc[38] & cap_dc[39] & cap_dc[40]), 1);

        $display("");
        $display("=== 窗口 1：像素流（8 像素 = 16 字节，大端 + 行优先）===");
        for (i = 0; i < 8; i = i + 1) begin
            x_exp = 10 + (i % 4);
            y_exp = 20 + (i / 4);
            chk8("w1.pix_hi", cap_byte[win1_base + 2*i],     x_exp[7:0]);
            chk8("w1.pix_lo", cap_byte[win1_base + 2*i + 1], y_exp[7:0]);
            chkn("w1.pix_dc", cap_dc[win1_base + 2*i], 1);
        end

        $display("");
        $display("=== 窗口 2：单像素 (300,239) ===");
        chk8("w2.0x2A", cap_byte[win2_base - 11], 8'h2A);
        chk8("w2.x0h ", cap_byte[win2_base - 10], 8'h01);
        chk8("w2.x0l ", cap_byte[win2_base - 9],  8'h2C);
        chk8("w2.x1l ", cap_byte[win2_base - 7],  8'h2C);
        chk8("w2.0x2B", cap_byte[win2_base - 6],  8'h2B);
        chk8("w2.y0h ", cap_byte[win2_base - 5],  8'h00);
        chk8("w2.y0l ", cap_byte[win2_base - 4],  8'hEF);
        chk8("w2.y1l ", cap_byte[win2_base - 2],  8'hEF);
        chk8("w2.0x2C", cap_byte[win2_base - 1],  8'h2C);
        chk8("w2.pix_hi", cap_byte[win2_base],     8'h2C);   // 300 & 0xFF
        chk8("w2.pix_lo", cap_byte[win2_base + 1], 8'hEF);   // 239

        $display("");
        $display("=== 全局一致性 ===");
        chkn("总字节数", cap_idx, 31 + 11 + 16 + 11 + 2);
        chkn("cs 下降次数", cs_falls, 3);
        chkn("cs 上升次数", cs_rises, 3);
        chkn("done 脉冲数", done_cnt, 2);
        chkn("像素请求次数", pix_req_cnt, 9);
        chkn("blk（背光）", blk, 1);

        $display("");
        $display("PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("%s", (fail_cnt == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end

    // 超时保护
    initial begin
        #50_000_000;
        $display("  FAIL  仿真超时（50ms）");
        $display("RESULT: SOME CHECKS FAILED");
        $finish;
    end

endmodule
