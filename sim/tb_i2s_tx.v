`timescale 1ns/1ps

// i2s_tx 的验证测试台
//
// 核心思路：在测试台里放一个"I2S 接收器"，像真实 DAC 一样工作 ——
//   按 BCLK 上升沿采样 SDATA、按帧内位序号判断是延迟位/数据位/补零位，
//   把串行位流还原成左右声道两个 16 位样本，再和输入比对。
//
// 这样帧结构（48 拍）、1 位延迟、移位方向、左右声道顺序，任何一处错
// 都会让还原出的数值对不上。

module tb_i2s_tx;

    localparam BIT_DIV = 4;          // 仿真加速：每 4 拍一个 bit_tick（真实是 15）

    reg  clk   = 0;
    reg  rst_n = 0;
    reg  signed [15:0] sample_in = 16'h0000;

    wire bclk, lrclk, sdata, sample_req;

    always #5 clk = ~clk;

    // ---------------- bit_tick 发生器 ----------------
    reg [7:0] div_cnt  = 0;
    reg       bit_tick = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            div_cnt  <= 0;
            bit_tick <= 0;
        end else if (div_cnt == BIT_DIV - 1) begin
            div_cnt  <= 0;
            bit_tick <= 1;
        end else begin
            div_cnt  <= div_cnt + 1;
            bit_tick <= 0;
        end
    end

    // ---------------- 被测模块 ----------------
    i2s_tx u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .bit_tick   (bit_tick),
        .sample_in  (sample_in),
        .bclk       (bclk),
        .lrclk      (lrclk),
        .sdata      (sdata),
        .sample_req (sample_req)
    );

    // ---------------- I2S 接收器模型 ----------------
    reg bclk_d  = 0;
    reg lrclk_d = 0;
    always @(posedge clk) begin
        bclk_d  <= bclk;
        lrclk_d <= lrclk;
    end

    wire bclk_rise  = bclk  && !bclk_d;
    wire lrclk_fall = !lrclk && lrclk_d;

    reg [5:0]  bitidx = 0;
    reg [15:0] acc_l = 0, acc_r = 0;
    reg [15:0] got_l = 0, got_r = 0;

    wire [15:0] acc_l_next = {acc_l[14:0], sdata};
    wire [15:0] acc_r_next = {acc_r[14:0], sdata};

    // 统计量
    integer frames     = 0;      // LRCLK 下降沿次数 = 帧数
    integer req_cnt    = 0;      // sample_req 脉冲数
    integer bits_frame = 0;      // 本帧已收到的 BCLK 上升沿数
    integer min_bits   = 9999;
    integer max_bits   = 0;

    integer clk_cnt    = 0;
    integer last_rise  = -1;
    integer min_bclk_p = 9999;
    integer max_bclk_p = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bitidx     <= 0;
            acc_l      <= 0;
            acc_r      <= 0;
            frames     <= 0;
            req_cnt    <= 0;
            bits_frame <= 0;
        end else begin
            clk_cnt <= clk_cnt + 1;

            if (sample_req)
                req_cnt <= req_cnt + 1;

            if (lrclk_fall) begin
                // 一帧结束：结算本帧的 BCLK 个数
                if (frames > 0) begin
                    if (bits_frame < min_bits) min_bits = bits_frame;
                    if (bits_frame > max_bits) max_bits = bits_frame;
                end
                bits_frame <= 0;
                bitidx     <= 0;
                frames     <= frames + 1;
            end

            if (bclk_rise) begin
                bits_frame <= bits_frame + 1;

                // BCLK 周期测量
                if (last_rise >= 0) begin
                    if (clk_cnt - last_rise < min_bclk_p) min_bclk_p = clk_cnt - last_rise;
                    if (clk_cnt - last_rise > max_bclk_p) max_bclk_p = clk_cnt - last_rise;
                end
                last_rise = clk_cnt;

                // 帧内位序号 → 位置含义（24 位槽位：0=延迟，1..16=数据，17..23=补零）
                if (bitidx >= 1 && bitidx <= 16)  acc_l <= acc_l_next;
                if (bitidx >= 25 && bitidx <= 40) acc_r <= acc_r_next;
                if (bitidx == 16) got_l <= acc_l_next;
                if (bitidx == 40) got_r <= acc_r_next;

                bitidx <= bitidx + 1;
            end
        end
    end

    // ---------------- 检查 ----------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk_int(input [8*30-1:0] name, input integer got, input integer exp);
        begin
            if (got === exp) begin
                $display("  PASS  %0s = %0d", name, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s = %0d (期望 %0d)", name, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    integer i;
    initial begin
        $dumpfile("sim/out/i2s_tx.vcd");
        $dumpvars(0, tb_i2s_tx);

        rst_n = 0;
        #200;
        rst_n = 1;

        $display("=== 1. 固定样本 0x1234，跑 6 帧 ===");
        sample_in = 16'h1234;
        repeat (6) begin
            @(negedge lrclk);          // 等一帧开始
            #1;
        end
        #2000;

        $display("  帧数 = %0d，sample_req 次数 = %0d", frames, req_cnt);
        chk_int("左声道还原", got_l, 16'h1234);
        chk_int("右声道还原", got_r, 16'h1234);
        chk_int("每帧 BCLK 个数(最小)", min_bits, 48);
        chk_int("每帧 BCLK 个数(最大)", max_bits, 48);
        chk_int("BCLK 周期(拍)",      max_bclk_p, BIT_DIV * 2);

        $display("");
        $display("=== 2. 换样本 0xABCD，跑 3 帧 ===");
        sample_in = 16'hABCD;
        repeat (3) begin
            @(negedge lrclk);
            #1;
        end
        #2000;

        chk_int("左声道跟随更新", got_l, 16'hABCD);
        chk_int("右声道跟随更新", got_r, 16'hABCD);

        $display("");
        $display("=== 3. sample_req 与帧数一致 ===");
        chk_int("req 次数 = 帧数", req_cnt, frames);

        $display("");
        $display("PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("%s", (fail_cnt == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end

endmodule
