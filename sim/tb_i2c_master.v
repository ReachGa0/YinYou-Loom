`timescale 1ns/1ps

// i2c_master 的验证测试台
//   1. 测试台里带一个"简易 I2C 从机模型"，模拟真实从机
//   2. 从机模型监听总线，把主机发来的 8 位数据移进寄存器，并在第 9 个时钟拉低 SDA 应答
//   3. 每一项都做自检并打印 PASS / FAIL

module tb_i2c_master;

    reg clk   = 0;
    reg rst_n = 0;

    reg        start   = 0;
    reg  [7:0] tx_data = 8'h00;
    reg        do_stop = 1'b1;

    wire       busy;
    wire       ack;
    wire       scl;
    wire       sda;

    always #5 clk = ~clk;          // 100MHz 仿真时钟

    pullup(sda);                   // 总线上拉（弱 1，强 0 可以把它拉低）

    // ---------------- 被测主机 ----------------
    i2c_master #(
        .CLK_HZ (100_000_000),
        .SCL_HZ (1_000_000)        // 仿真里用 1MHz，跑得快
    ) u_dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (start),
        .data    (tx_data),
        .do_stop (do_stop),
        .busy    (busy),
        .ack     (ack),
        .scl     (scl),
        .sda     (sda)
    );

    // ---------------- 简易 I2C 从机模型 ----------------
    reg sda_d, scl_d;
    always @(posedge clk) begin
        sda_d <= sda;
        scl_d <= scl;
    end

    wire start_cond = scl && scl_d && sda_d && !sda;   // SCL 高时 SDA 下降
    wire stop_cond  = scl && scl_d && !sda_d && sda;   // SCL 高时 SDA 上升
    wire scl_rise   = scl && !scl_d;
    wire scl_fall   = !scl && scl_d;

    reg        in_frame = 0;
    reg [3:0]  bitn     = 0;
    reg [7:0]  rx_shift = 0;
    reg        acking   = 0;
    reg [7:0]  rx_byte  = 0;
    reg        rx_valid = 0;
    reg        got_stop = 0;

    assign sda = acking ? 1'b0 : 1'bz;      // 从机只在应答时拉低 SDA

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_frame <= 1'b0;
            bitn     <= 4'd0;
            rx_shift <= 8'd0;
            acking   <= 1'b0;
            rx_byte  <= 8'd0;
            rx_valid <= 1'b0;
            got_stop <= 1'b0;
        end else begin
            if (start_cond) begin
                in_frame <= 1'b1;
                bitn     <= 4'd0;
                rx_valid <= 1'b0;
            end else if (stop_cond) begin
                in_frame <= 1'b0;
                acking   <= 1'b0;
                got_stop <= 1'b1;
            end else if (scl_rise && in_frame) begin
                if (bitn < 4'd8) begin
                    rx_shift <= {rx_shift[6:0], sda};   // 高位在前
                    bitn     <= bitn + 1'b1;
                end else begin
                    rx_byte  <= rx_shift;
                    rx_valid <= 1'b1;                   // 一字节收完
                    bitn     <= 4'd0;
                end
            end else if (scl_fall && in_frame) begin
                if (bitn == 4'd8)
                    acking <= 1'b1;                     // 第 9 个时钟：拉低应答
                else
                    acking <= 1'b0;
            end
        end
    end

    // ---------------- 测试流程 ----------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task send_and_check(input [7:0] b);
        begin
            rx_valid = 1'b0;
            @(posedge clk);
            tx_data  = b;
            do_stop  = 1'b1;
            start    = 1'b1;
            @(posedge clk);
            start    = 1'b0;
            while (busy) @(posedge clk);
            @(posedge clk);

            if (rx_valid && (rx_byte === b) && (ack === 1'b0)) begin
                $display("PASS  sent=0x%02X  received=0x%02X  ack=%b", b, rx_byte, ack);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL  sent=0x%02X  received=0x%02X  rx_valid=%b  ack=%b",
                         b, rx_byte, rx_valid, ack);
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

        $display("=== I2C 主机验证：发送 SH1106 初始化会用到的字节 ===");
        send_and_check(8'h78);      // 从机地址 0x3C << 1 | 写
        send_and_check(8'h00);      // 控制字节：后面跟命令
        send_and_check(8'hAE);      // display off
        send_and_check(8'h40);      // 控制字节：后面跟数据
        send_and_check(8'h55);      // 任意数据
        send_and_check(8'hAA);
        send_and_check(8'h00);
        send_and_check(8'hFF);

        $display("");
        $display("PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("%s", (fail_cnt == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end

endmodule
