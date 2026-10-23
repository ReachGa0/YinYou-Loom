`timescale 1ns/1ps

// ui_render 的验证测试台
//
// 用一个"假驱动"按 tft_st7789 的像素契约（pix_we 之后第 2 拍采样）把像素
// 取回来，写进一整帧的数组，然后：
//   1. 按区域点数检查（分隔线位置、选中行反白、表头/提示/调式文字有像素、波形有像素）
//   2. 波形形状检查：活动带里**每一列恰好 3 个亮点**（3px 粗的曲线，无裁剪）
//   3. 区域调度检查：整屏 → 波形活动带 → （改动音色后）该列选项区
//   4. 把整帧导出成文本（sim/out/ui_frame.txt），供 tools 渲染成 PNG 肉眼核对
//
// 用法：
//   iverilog -g2012 -o t.vvp sim/tb_ui_render.v rtl/display/ui_render.v rtl/display/font8x16_rom.v
//   vvp t.vvp                     # 需在仓库根目录运行（$readmemh 相对路径）

module tb_ui_render;

    localparam [15:0] C_BG     = 16'h0000,
                      C_SEP    = 16'h39C7,
                      C_HDR    = 16'h07FF,
                      C_TXT    = 16'hFFFF,
                      C_HINT   = 16'h8C71,
                      C_SEL_BG = 16'hFFFF,
                      C_SEL_TX = 16'h0000,
                      C_WAVE   = 16'h07FF,
                      C_MID    = 16'h0220,
                      C_SCALE  = 16'hFFE0;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;                    // 100 MHz（只是为了跑得快）

    // ---- 状态总线 ----
    reg [1:0] st_timbre = 2'd0;
    reg [1:0] st_fx     = 2'd0;
    reg [1:0] st_mode   = 2'd0;
    reg [6:0] st_note   = 7'd60;
    reg [2:0] st_voices = 3'd2;              // 幅度 = voices×10 = 20px
    reg [6:0] st_key_root = 7'd0;

    // ---- 渲染器接口 ----
    wire        win_start;
    wire [9:0]  win_x0, win_x1, win_y0, win_y1;
    wire [15:0] px_data;
    wire [8:0]  px_x;
    wire [7:0]  px_y;
    reg         busy = 0;
    reg         done = 0;
    wire [2:0]  dbg_region;

    ui_render #(.FONT_INIT ("data/fonts/font8x16.hex")) u_ui (
        .clk (clk), .rst_n (rst_n),
        .st_timbre (st_timbre), .st_fx (st_fx), .st_mode (st_mode),
        .st_note (st_note), .st_voices (st_voices), .st_key_root (st_key_root),
        // 真实采样通路在仿真里不接：live_valid=0 → 走合成波形兜底
        .live_valid (1'b0), .live_bank (1'b0), .live_data (16'sd0),
        .capture_trig (), .rd_bank_sel (), .rd_addr (),
        .dbg_x_code (16'd0), .dbg_y_code (16'd0),
        .dbg_x_fault (1'b0), .dbg_y_fault (1'b0),
        .dbg_bend (16'd0),
        .win_start (win_start),
        .win_x0 (win_x0), .win_x1 (win_x1), .win_y0 (win_y0), .win_y1 (win_y1),
        .px_data (px_data), .px_x (px_x), .px_y (px_y),
        .busy (busy), .done (done), .dbg_region (dbg_region)
    );

    // ------------------------------------------------------------
    // 假驱动：按契约（pix_we 后第 2 拍）取像素，并记录每个事务的窗口
    // ------------------------------------------------------------
    reg [8:0]  pix_x_r = 9'd0;
    reg [7:0]  pix_y_r = 8'd0;
    reg        pix_we_r = 1'b0;
    assign px_x = pix_x_r;
    assign px_y = pix_y_r;

    reg [9:0]  wx0, wx1, wy0, wy1;
    reg [8:0]  cx;
    reg [7:0]  cy;
    reg [2:0]  dst = 3'd0;                   // 0 空闲 1 起像素 2 等 3 采样

    reg [15:0] frame [0:76799];              // 320×240 整帧
    integer    idx;

    integer    tx_cnt = 0;
    reg [2:0]  tx_region [0:15];
    reg [9:0]  tx_x0 [0:15], tx_y0 [0:15], tx_x1 [0:15], tx_y1 [0:15];
    integer    tx_pix [0:15];                // 每个事务的像素数

    reg        saw_tone_tx = 1'b0;           // 出现过 TONE 选项区事务
    integer    wave_done_cnt = 0;            // 波形活动带事务完成次数
    always @(posedge clk) begin
        if (rst_n && (dst == 3'd0) && win_start && (dbg_region == 3'd2))
            saw_tone_tx <= 1'b1;
        if (rst_n && done && (dbg_region == 3'd1))
            wave_done_cnt <= wave_done_cnt + 1;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            dst <= 3'd0; busy <= 1'b0; done <= 1'b0; pix_we_r <= 1'b0;
        end else begin
            done <= 1'b0;
            case (dst)
                3'd0: begin
                    busy <= 1'b0;
                    if (win_start) begin
                        wx0 <= win_x0; wx1 <= win_x1; wy0 <= win_y0; wy1 <= win_y1;
                        cx  <= win_x0[8:0];
                        cy  <= win_y0[7:0];
                        if (tx_cnt < 16) begin
                            tx_region[tx_cnt] <= dbg_region;
                            tx_x0[tx_cnt] <= win_x0; tx_x1[tx_cnt] <= win_x1;
                            tx_y0[tx_cnt] <= win_y0; tx_y1[tx_cnt] <= win_y1;
                            tx_pix[tx_cnt] <= 0;
                        end
                        tx_cnt <= tx_cnt + 1;
                        busy <= 1'b1;
                        dst  <= 3'd1;
                    end
                end
                3'd1: begin pix_x_r <= cx; pix_y_r <= cy; pix_we_r <= 1'b1; dst <= 3'd2; end
                3'd2: begin pix_we_r <= 1'b0; dst <= 3'd3; end
                default: begin
                    // dst==3：pix_we 之后第 2 拍，px_data 有效
                    idx = cy * 320 + cx;
                    if (idx >= 0 && idx < 76800) frame[idx] <= px_data;
                    if (tx_cnt >= 1 && tx_cnt <= 16) tx_pix[tx_cnt-1] <= tx_pix[tx_cnt-1] + 1;
                    if ((cx == wx1[8:0]) && (cy == wy1[7:0])) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        dst  <= 3'd0;
                    end else if (cx == wx1[8:0]) begin
                        cx  <= wx0[8:0];
                        cy  <= cy + 8'd1;
                        dst <= 3'd1;
                    end else begin
                        cx  <= cx + 9'd1;
                        dst <= 3'd1;
                    end
                end
            endcase
        end
    end

    // ------------------------------------------------------------
    // 检查工具
    // ------------------------------------------------------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk16(input [8*30-1:0] name, input [15:0] got, input [15:0] exp);
        begin
            if (got === exp) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s = 0x%04X (期望 0x%04X)", name, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task chkn(input [8*40-1:0] name, input integer got, input integer exp);
        begin
            if (got === exp) pass_cnt = pass_cnt + 1;
            else begin
                $display("  FAIL  %0s = %0d (期望 %0d)", name, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task chkge(input [8*40-1:0] name, input integer got, input integer lim);
        begin
            if (got >= lim) pass_cnt = pass_cnt + 1;
            else begin
                $display("  FAIL  %0s = %0d (要求 >= %0d)", name, got, lim);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------
    integer x, y, cnt, col_lit, k;
    integer hdr_cnt, hint_cnt, scale_cnt, wave_cnt, sel_cnt, txt_cnt;
    integer band_lit_max, band_lit_min;
    integer fout;

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;

        // ---- 等整屏事务（tx 0）完成 ----
        wait (tx_cnt >= 1);
        wait (dst == 3'd0);
        repeat (4) @(posedge clk);

        $display("");
        $display("=== 事务 0：整屏 ===");
        chkn("tx0.region", tx_region[0], 0);          // RG_FULL
        chkn("tx0.x0", tx_x0[0], 0);
        chkn("tx0.x1", tx_x1[0], 319);
        chkn("tx0.y0", tx_y0[0], 0);
        chkn("tx0.y1", tx_y1[0], 239);
        chkn("tx0.pixels", tx_pix[0], 320*240);

        // ---- 点检查：分隔线与选中行反白 ----
        $display("");
        $display("=== 布局点检查 ===");
        chk16("sep.row(0,128)",   frame[128*320 + 0],   C_SEP);
        chk16("sep.row(0,129)",   frame[129*320 + 0],   C_SEP);
        chk16("sep.row(0,210)",   frame[210*320 + 0],   C_SEP);
        chk16("sep.col(106,140)", frame[140*320 + 106], C_SEP);
        chk16("sep.col(213,200)", frame[200*320 + 213], C_SEP);
        chk16("TONE.sel.row1",    frame[150*320 + 100], C_SEL_BG);   // 选中行反白底
        chk16("TONE.unsel.row2",  frame[166*320 + 100], C_BG);
        chk16("FX.sel.row1",      frame[150*320 + 210], C_SEL_BG);
        chk16("MODE.sel.row1",    frame[150*320 + 315], C_SEL_BG);
        chk16("wave@x0",          frame[63*320 + 0],    C_WAVE);     // phase0=0 → 过零点
        chk16("wave.band.above",  frame[25*320 + 0],    C_BG);

        // ---- 点统计：文字区确实有字 ----
        $display("");
        $display("=== 文字像素统计 ===");
        hdr_cnt = 0; hint_cnt = 0; scale_cnt = 0; txt_cnt = 0;
        for (y = 130; y <= 145; y = y + 1)
            for (x = 0; x <= 319; x = x + 1)
                if (frame[y*320+x] == C_HDR) hdr_cnt = hdr_cnt + 1;
        for (y = 212; y <= 227; y = y + 1)
            for (x = 0; x <= 319; x = x + 1)
                if (frame[y*320+x] == C_HINT) hint_cnt = hint_cnt + 1;
        for (y = 4; y <= 19; y = y + 1)
            for (x = 272; x <= 319; x = x + 1) begin
                if (frame[y*320+x] == C_SCALE) scale_cnt = scale_cnt + 1;
                if (frame[y*320+x] == C_BG)    txt_cnt   = txt_cnt + 1;
            end
        chkge("表头像素数",   hdr_cnt,   30);
        chkge("提示行像素数", hint_cnt,  30);
        chkge("调式字符像素", scale_cnt, 10);
        chkge("调式框黑底",   txt_cnt,   200);

        // ---- 波形形状：活动带内每列恰好 3 个亮点 ----
        $display("");
        $display("=== 波形形状（活动带每列 3 个亮点）===");
        wave_cnt = 0; band_lit_max = 0; band_lit_min = 999;
        for (x = 0; x <= 319; x = x + 1) begin
            col_lit = 0;
            for (y = 21; y <= 105; y = y + 1)
                if (frame[y*320+x] == C_WAVE) begin
                    col_lit = col_lit + 1;
                    wave_cnt = wave_cnt + 1;
                end
            if (col_lit > band_lit_max) band_lit_max = col_lit;
            if (col_lit < band_lit_min) band_lit_min = col_lit;
        end
        chkn("每列亮点上限", band_lit_max, 3);
        chkn("每列亮点下限", band_lit_min, 3);
        chkge("波形总亮点数", wave_cnt, 900);          // ≈320×3

        // ---- 事务 1：波形活动带 ----
        $display("");
        $display("=== 事务 1：波形活动带 ===");
        wait (tx_cnt >= 2);
        wait (dst == 3'd0);
        repeat (4) @(posedge clk);
        chkn("tx1.region", tx_region[1], 1);           // RG_WAVE
        chkn("tx1.x0", tx_x0[1], 0);
        chkn("tx1.x1", tx_x1[1], 319);
        chkn("tx1.y0", tx_y0[1], 21);
        chkn("tx1.y1", tx_y1[1], 105);
        chkn("tx1.pixels", tx_pix[1], 320*85);      // 活动带 y 21..105（含）＝85 行

        // ---- 改音色 → 应触发 TONE 列选项区重画 ----
        $display("");
        $display("=== 改音色 → TONE 选项区 ===");
        st_timbre = 2'd1;
        wait (saw_tone_tx);                     // 等"事件"，不数事务个数
        wait (dst == 3'd0);
        repeat (4) @(posedge clk);
        cnt = 0;
        for (k = 0; k < 16; k = k + 1) if (tx_region[k] == 3'd2) cnt = cnt + 1;
        $display("  已记录事务区域码: %0d %0d %0d %0d %0d",
                 tx_region[0], tx_region[1], tx_region[2], tx_region[3], tx_region[4]);
        chkge("TONE 选项区事务数", cnt, 1);

        // 重画后：TONE 第 2 行应变成反白，第 1 行恢复黑底
        chk16("TONE.sel.row2",    frame[166*320 + 100], C_SEL_BG);
        chk16("TONE.unsel.row1",  frame[150*320 + 100], C_BG);

        // ---- 方波垂线：等一帧波形带重画完（此时音色已是方波）----
        $display("");
        $display("=== 方波垂线检查 ===");
        k = wave_done_cnt;
        wait (wave_done_cnt > k);
        wait (dst == 3'd0);
        repeat (4) @(posedge clk);
        band_lit_max = 0;
        for (x = 0; x <= 319; x = x + 1) begin
            col_lit = 0;
            for (y = 21; y <= 105; y = y + 1)
                if (frame[y*320+x] == C_WAVE) col_lit = col_lit + 1;
            if (col_lit > band_lit_max) band_lit_max = col_lit;
        end
        // 幅度 = voices×10 = 20px → 跳变列应有 2×20+1 ≈ 41 个亮点
        chkge("方波跳变列竖直段", band_lit_max, 35);

        // ---- 导出整帧做 PNG ----
        fout = $fopen("sim/out/ui_frame.txt", "w");
        for (y = 0; y < 240; y = y + 1) begin
            for (x = 0; x < 320; x = x + 1)
                $fwrite(fout, "%04X\n", frame[y*320+x]);
        end
        $fclose(fout);
        $display("");
        $display("  已导出整帧 → sim/out/ui_frame.txt（用 tools/render_ui_frame.py 转 PNG）");

        $display("");
        $display("PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("%s", (fail_cnt == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("  FAIL  仿真超时");
        $display("RESULT: SOME CHECKS FAILED");
        $finish;
    end

endmodule
