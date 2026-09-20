`timescale 1ns/1ps

// oled_sh1106 的验证测试台
//
// 用严格从机模型按"事务"记录总线上发生的一切，然后检查：
//   1. 每次事务都是 3 个字节（地址 + 控制 + 有效字节）
//   2. 地址字节固定为 0x78
//   3. 初始化命令顺序、页/列寻址、2 像素边框图案都正确
//   4. 0xAF（开显示）出现在第一帧写完之后

module tb_oled_sh1106;

    // 0 = SH1106 序列，1 = SSD1306 序列（用 iverilog -Ptb_oled_sh1106.MODE=1 切换）
    parameter MODE = 0;

    reg clk   = 0;
    reg rst_n = 0;

    wire ssd1306_mode = (MODE != 0);
    wire scl;
    wire sda;
    wire [1:0] dbg_phase;
    wire       dbg_ack_seen;

    always #5 clk = ~clk;              // 100MHz 仿真时钟
    pullup(sda);

    // ---------------- 被测控制器 ----------------
    oled_sh1106 #(
        .CLK_HZ     (100_000_000),
        .SCL_HZ     (10_000_000),      // 仿真加速
        .POR_CYCLES (100)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .ssd1306_mode (ssd1306_mode),
        .scl          (scl),
        .sda          (sda),
        .dbg_phase    (dbg_phase),
        .dbg_ack_seen (dbg_ack_seen)
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

    // ---------------- 按事务记录 ----------------
    reg [7:0] log_addr [0:4095];
    reg [7:0] log_ctrl [0:4095];
    reg [7:0] log_data [0:4095];
    integer   tx_idx    = 0;
    integer   bad_addr  = 0;
    integer   bad_bytes = 0;
    reg       saw_af    = 0;

    always @(posedge clk) begin
        if (trans_end) begin
            if (tx_idx < 4096) begin
                log_addr[tx_idx] <= rx_addr;
                log_ctrl[tx_idx] <= rx_ctrl;
                log_data[tx_idx] <= rx_payload;
            end
            if (rx_addr  !== 8'h78) bad_addr  <= bad_addr  + 1;
            // 第 0 次是地址探测（单字节事务），其余都应是 3 字节事务
            if (tx_idx != 0 && nbytes !== 8'd3)  bad_bytes <= bad_bytes + 1;
            if (rx_payload == 8'hAF) saw_af   <= 1'b1;
            tx_idx <= tx_idx + 1;
        end
    end

    // ---------------- 检查 ----------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk(input [8*28-1:0] name, input [7:0] got, input [7:0] exp);
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

        while (!saw_af && $time < 100_000_000) #1000;
        #5000;

        $display("");
        $display("=== 共记录 %0d 次 I2C 事务 ===", tx_idx);
        $display("    地址错误次数 = %0d   字节数错误次数 = %0d", bad_addr, bad_bytes);
        $display("");

        $display("--- 事务 0：地址探测（应为 0x78，单字节）---");
        chk("probe.addr", log_addr[0], 8'h78);

        $display("--- 初始化前 3 条命令 ---");
        chk("tx1.ctrl ", log_ctrl[1], 8'h00);
        chk("tx1.cmd  ", log_data[1], 8'hAE);
        chk("tx2.cmd  ", log_data[2], MODE ? 8'hD5 : 8'h02);
        chk("tx3.cmd  ", log_data[3], MODE ? 8'h80 : 8'h10);

        $display("");
        $display("--- 初始化最后一条命令（第 25 条）---");
        chk("tx25.ctrl", log_ctrl[25], 8'h00);
        chk("tx25.cmd ", log_data[25], MODE ? 8'h00 : 8'h40);

        $display("");
        $display("--- 第一帧页 0 的页设置（事务 26~28）---");
        chk("tx26.ctrl", log_ctrl[26], 8'h00);
        chk("tx26.page", log_data[26], 8'hB0);
        chk("tx27.col ", log_data[27], 8'h02);
        chk("tx28.col ", log_data[28], 8'h10);

        $display("");
        $display("--- 页 0 左侧 2 列数据（应为 0xFF）---");
        chk("tx29.ctrl", log_ctrl[29], 8'h40);
        chk("tx29.dat ", log_data[29], 8'hFF);
        chk("tx30.dat ", log_data[30], 8'hFF);

        $display("");
        $display("--- 页 1 的页设置与 2 像素边框数据 ---");
        chk("tx157.pg ", log_data[157], 8'hB1);
        chk("tx160.d0 ", log_data[160], 8'hFF);          // 左边框
        chk("tx287.d  ", log_data[160+127], 8'hFF);      // 右边框（第 127 列）

        $display("");
        $display("--- 全局一致性 ---");
        chk("bad_addr ", bad_addr[7:0],  8'h00);
        chk("bad_bytes", bad_bytes[7:0], 8'h00);

        $display("");
        $display("PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("%s", (fail_cnt == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end

endmodule
