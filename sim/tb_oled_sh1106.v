`timescale 1ns/1ps

// oled_sh1106 的验证测试台
//   用一个 I2C 从机模型把总线上收到的每个字节记录到数组里，
//   然后检查：初始化命令顺序、页/列设置命令、数据图案、以及 0xAF 出现的位置。

module tb_oled_sh1106;

    reg clk   = 0;
    reg rst_n = 0;

    wire scl;
    wire sda;

    always #5 clk = ~clk;             // 100MHz 仿真时钟

    pullup(sda);

    // ---------------- 被测控制器 ----------------
    oled_sh1106 #(
        .CLK_HZ     (100_000_000),
        .SCL_HZ     (10_000_000),     // 仿真加速：SCL 10MHz
        .POR_CYCLES (100)             // 上电等待缩短为 100 拍
    ) u_dut (
        .clk   (clk),
        .rst_n (rst_n),
        .scl   (scl),
        .sda   (sda)
    );

    // ---------------- I2C 从机模型（记录所有收到的字节）----------------
    reg sda_d, scl_d;
    always @(posedge clk) begin
        sda_d <= sda;
        scl_d <= scl;
    end

    wire start_cond = scl && scl_d && sda_d && !sda;
    wire stop_cond  = scl && scl_d && !sda_d && sda;
    wire scl_rise   = scl && !scl_d;
    wire scl_fall   = !scl && scl_d;

    reg        in_frame = 0;
    reg [3:0]  bitn     = 0;
    reg [7:0]  rx_shift = 0;
    reg        acking   = 0;
    reg        told_stop = 0;

    reg [7:0]  rx_log [0:8191];
    integer    rx_count = 0;
    integer    tx_count = 0;
    reg        saw_af   = 0;

    assign sda = acking ? 1'b0 : 1'bz;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_frame  <= 1'b0;
            bitn      <= 4'd0;
            rx_shift  <= 8'd0;
            acking    <= 1'b0;
            rx_count  <= 0;
            tx_count  <= 0;
            saw_af    <= 1'b0;
        end else begin
            if (start_cond) begin
                in_frame <= 1'b1;
                bitn     <= 4'd0;
            end else if (stop_cond) begin
                in_frame <= 1'b0;
                acking   <= 1'b0;
                tx_count <= tx_count + 1;
            end else if (scl_rise && in_frame) begin
                if (bitn < 4'd8) begin
                    rx_shift <= {rx_shift[6:0], sda};
                    bitn     <= bitn + 1'b1;
                end else begin
                    if (rx_count < 8192)
                        rx_log[rx_count] <= rx_shift;
                    rx_count <= rx_count + 1;
                    if (rx_shift == 8'hAF)
                        saw_af <= 1'b1;
                    bitn <= 4'd0;
                end
            end else if (scl_fall && in_frame) begin
                if (bitn == 4'd8)
                    acking <= 1'b1;
                else
                    acking <= 1'b0;
            end
        end
    end

    // ---------------- 检查 ----------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk;
        input [8*40-1:0] name;
        input [7:0]      got;
        input [7:0]      exp;
        begin
            if (got === exp) begin
                $display("  PASS  %0s = 0x%02X", name, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s = 0x%02X (期望 0x%02X)", name, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    integer i;
    initial begin
        rst_n = 0;
        #200;
        rst_n = 1;

        // 等到"开显示"命令出现，再多跑一点
        while (!saw_af && $time < 50_000_000) #1000;
        #200000;

        $display("");
        $display("=== 总共记录了 %0d 个字节，%0d 次事务 ===", rx_count, tx_count);
        $display("");
        $display("--- 初始化序列前 9 个字节（3 次事务）---");
        chk("tx0.addr ", rx_log[0], 8'h78);
        chk("tx0.ctrl ", rx_log[1], 8'h00);
        chk("tx0.cmd  ", rx_log[2], 8'hAE);
        chk("tx1.addr ", rx_log[3], 8'h78);
        chk("tx1.ctrl ", rx_log[4], 8'h00);
        chk("tx1.cmd  ", rx_log[5], 8'h02);
        chk("tx2.addr ", rx_log[6], 8'h78);
        chk("tx2.ctrl ", rx_log[7], 8'h00);
        chk("tx2.cmd  ", rx_log[8], 8'h10);

        $display("");
        $display("--- 初始化最后一条命令（第 25 条 = 0x40）---");
        chk("tx24.ctrl", rx_log[24*3 + 1], 8'h00);
        chk("tx24.cmd ", rx_log[24*3 + 2], 8'h40);

        $display("");
        $display("--- 第一帧页 0 的页设置（事务 25~27）---");
        chk("pg0.ctrl ", rx_log[25*3 + 1], 8'h00);
        chk("pg0.col-lo", rx_log[25*3 + 2], 8'hB0);   // 页地址 0
        chk("col.low ", rx_log[26*3 + 2], 8'h02);     // 列地址低 4 位 = 2
        chk("col.high", rx_log[27*3 + 2], 8'h10);     // 列地址高 4 位

        $display("");
        $display("--- 页 0 的前 3 个数据字节（事务 28~30，图案应为 0xFF）---");
        chk("d0.ctrl ", rx_log[28*3 + 1], 8'h40);
        chk("d0.data ", rx_log[28*3 + 2], 8'hFF);
        chk("d1.data ", rx_log[29*3 + 2], 8'hFF);
        chk("d2.data ", rx_log[30*3 + 2], 8'hFF);

        $display("");
        $display("--- 页 1 的页设置（事务 156~158，页地址应为 0xB1）---");
        chk("pg1.cmd ", rx_log[156*3 + 2], 8'hB1);

        $display("");
        $display("--- 页 1 第 0 列数据（应为 0x01：左边框）---");
        chk("pg1.d0  ", rx_log[159*3 + 2], 8'h01);

        $display("");
        $display("--- 页 1 第 127 列数据（应为 0x80：右边框）---");
        chk("pg1.d127", rx_log[(159+127)*3 + 2], 8'h80);

        $display("");
        $display("PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("%s", (fail_cnt == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end

endmodule
