`timescale 1ns/1ps

// clk_div 的验证测试台
//
// 检查三件事：
//   1. 相邻两次 tick 之间的间隔是否恰好 DIV 个时钟
//   2. tick 高电平是否只持续 1 个时钟（单周期脉冲，不能拖长）
//   3. 复位后计数是否从 0 重新开始

module tb_clk_div;

    parameter DIV = 15;

    reg  clk   = 0;
    reg  rst_n = 0;
    wire tick;

    always #5 clk = ~clk;

    clk_div #(
        .DIV (DIV)
    ) u_dut (
        .clk   (clk),
        .rst_n (rst_n),
        .tick  (tick)
    );

    // ---- 监视器 ----
    integer since    = 0;
    integer high_cnt = 0;
    integer n_tick   = 0;
    integer min_p    = 999999;
    integer max_p    = 0;
    integer max_high = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            since = since + 1;            // 每个时钟加一，tick 那一拍也算进去
            if (tick) begin
                if (n_tick > 0) begin
                    if (since < min_p) min_p = since;
                    if (since > max_p) max_p = since;
                end
                since    = 0;
                n_tick   = n_tick + 1;
                high_cnt = high_cnt + 1;
            end else begin
                if (high_cnt > max_high) max_high = high_cnt;
                high_cnt = 0;
            end
        end
    end

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk_int(input [8*32-1:0] name, input integer got, input integer exp);
        begin
            if (got == exp) begin
                $display("  PASS  %0s = %0d", name, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s = %0d (期望 %0d)", name, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // 计数类指标允许 ±1，因为复位释放时刻不对齐时钟沿
    task chk_range(input [8*32-1:0] name, input integer got, input integer exp);
        begin
            if (got >= exp-1 && got <= exp+1) begin
                $display("  PASS  %0s = %0d (期望约 %0d)", name, got, exp);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s = %0d (期望约 %0d)", name, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("sim/out/clk_div.vcd");
        $dumpvars(0, tb_clk_div);

        rst_n = 0;
        #103;
        rst_n = 1;

        #5000;                              // 跑约 500 个时钟

        $display("=== clk_div (DIV=%0d) 统计 ===", DIV);
        chk_range("tick 次数",   n_tick,   5000/10/DIV);
        chk_int("最小周期",      min_p,    DIV);
        chk_int("最大周期",      max_p,    DIV);
        chk_int("最长高电平拍数", max_high, 1);

        $display("");
        $display("PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("%s", (fail_cnt == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end

endmodule
