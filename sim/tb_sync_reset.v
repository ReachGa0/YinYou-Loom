`timescale 1ns/1ps

// sync_reset 的验证测试台
//
// 重点验证两件事：
//   1. 异步置位：arst_n 拉低时 rst_n 必须"立刻"变低，不等时钟沿
//   2. 同步释放：arst_n 释放后，rst_n 必须等整整两个时钟沿才变高，
//      而且这个上升沿必须"踩在"时钟沿上
//
// 时钟：100MHz，上升沿出现在 t = 5, 15, 25, ...（5 的奇数倍）

module tb_sync_reset;

    reg  clk    = 0;
    reg  arst_n = 0;
    wire rst_n;

    always #5 clk = ~clk;

    sync_reset u_dut (
        .clk    (clk),
        .arst_n (arst_n),
        .rst_n  (rst_n)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk(input [8*36-1:0] name, input got, input exp);
        begin
            if (got === exp) begin
                $display("  PASS  %0s", name);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s  (得到 %b，期望 %b)", name, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("sim/out/sync_reset.vcd");
        $dumpvars(0, tb_sync_reset);

        clk    = 0;
        arst_n = 0;

        $display("=== 1. 异步置位：arst_n 拉低应立即生效 ===");
        #103;
        chk("t=103 复位期间 rst_n = 0", rst_n, 1'b0);

        $display("");
        $display("=== 2. 同步释放：等两个时钟沿（155 → 165 → 175）===");
        #55;
        arst_n = 1;
        #2;
        chk("t=160 释放后立即仍为 0", rst_n, 1'b0);

        #14;
        chk("t=174 第 1 拍后仍为 0", rst_n, 1'b0);

        #2;
        chk("t=176 第 2 拍后变为 1", rst_n, 1'b1);

        $display("");
        $display("=== 3. 再次异步置位：必须立刻生效，不等下一个沿（195）===");
        #11;
        arst_n = 0;
        #1;
        chk("t=188 异步拉低后立即为 0", rst_n, 1'b0);

        $display("");
        $display("PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("%s", (fail_cnt == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end

endmodule
