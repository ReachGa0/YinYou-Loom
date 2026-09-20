`timescale 1ns/1ps

// i2c_master 的验证测试台
//
// 重点验证"事务结构"：一次事务必须是
//     START 从机地址 控制字节 有效字节 STOP
// 早期版本每发一个字节就 STOP，导致控制/数据字节被当成新地址，
// 从机模型现在会通过 nbytes / addr_match 把这种错误直接暴露出来。

module tb_i2c_master;

    reg clk   = 0;
    reg rst_n = 0;

    reg        req   = 0;
    reg        first = 0;
    reg        last  = 0;
    reg  [7:0] tx_data = 8'h00;

    wire busy, done, ack, scl;
    wire sda;

    always #5 clk = ~clk;              // 100MHz 仿真时钟
    pullup(sda);                       // 总线上拉

    // ---------------- 被测主机 ----------------
    i2c_master #(
        .CLK_HZ (100_000_000),
        .SCL_HZ (1_000_000)            // 仿真加速：SCL 1MHz
    ) u_dut (
        .clk   (clk),
        .rst_n (rst_n),
        .req   (req),
        .first (first),
        .last  (last),
        .data  (tx_data),
        .busy  (busy),
        .done  (done),
        .ack   (ack),
        .scl   (scl),
        .sda   (sda)
    );

    // ---------------- 严格从机模型 ----------------
    wire       trans_end, addr_match;
    wire [7:0] rx_addr, rx_ctrl, rx_payload, nbytes;

    i2c_slave_model #(
        .ADDR (8'h78)
    ) u_slave (
        .clk       (clk),
        .rst_n     (rst_n),
        .scl       (scl),
        .sda       (sda),
        .trans_end (trans_end),
        .addr_match(addr_match),
        .rx_addr   (rx_addr),
        .rx_ctrl   (rx_ctrl),
        .rx_payload(rx_payload),
        .nbytes    (nbytes)
    );

    // ---------------- 激励 ----------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task send_byte(input [7:0] b, input f, input l);
        begin
            @(posedge clk);
            tx_data = b;
            first   = f;
            last    = l;
            req     = 1'b1;
            @(posedge clk);
            req = 1'b0;
            while (!done) @(posedge clk);
            @(posedge clk);
        end
    endtask

    task chk(input [8*32-1:0] name, input [7:0] got, input [7:0] exp);
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

    initial begin
        rst_n = 0;
        #200;
        rst_n = 1;
        #200;

        $dumpfile("sim/out/i2c_master.vcd");
        $dumpvars(0, tb_i2c_master);

        $display("=== 事务 1：写给 SH1106 一条命令（0x78 0x00 0xAE）===");
        send_byte(8'h78, 1'b1, 1'b0);     // 地址，带 START，不发 STOP
        send_byte(8'h00, 1'b0, 1'b0);     // 控制字节
        send_byte(8'hAE, 1'b0, 1'b1);     // 命令，带 STOP
        while (busy) @(posedge clk);      // 等 STOP 发完
        repeat (3) @(posedge clk);

        chk("nbytes   ", nbytes,     8'd3);
        chk("addr_ok  ", {7'd0, addr_match}, 8'h01);
        chk("rx_addr  ", rx_addr,    8'h78);
        chk("rx_ctrl  ", rx_ctrl,    8'h00);
        chk("rx_payld ", rx_payload, 8'hAE);

        $display("");
        $display("=== 事务 2：写一个数据字节（0x78 0x40 0x55）===");
        send_byte(8'h78, 1'b1, 1'b0);
        send_byte(8'h40, 1'b0, 1'b0);
        send_byte(8'h55, 1'b0, 1'b1);
        while (busy) @(posedge clk);
        repeat (3) @(posedge clk);

        chk("nbytes   ", nbytes,     8'd3);
        chk("addr_ok  ", {7'd0, addr_match}, 8'h01);
        chk("rx_addr  ", rx_addr,    8'h78);
        chk("rx_ctrl  ", rx_ctrl,    8'h40);
        chk("rx_payld ", rx_payload, 8'h55);

        $display("");
        $display("PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("%s", (fail_cnt == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end

endmodule
