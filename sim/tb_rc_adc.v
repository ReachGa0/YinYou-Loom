`timescale 1ns/1ps

// rc_adc 验证：用行为模型模拟"放电后按固定延时升到门限"的 RC 网络。
//   1. 正常测量：code ≈ 模型设定的延时；
//   2. 引脚一直不升：超时后 fault=1；
//   3. valid 是单周期脉冲。

module tb_rc_adc;
    localparam CLK_HZ = 1_000_000;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    wire pin;

    wire [15:0] code;
    wire        valid;
    wire        fault;

    rc_adc #(
        .CLK_HZ       (CLK_HZ),
        .PRESCALE     (1),
        .DISCHARGE_US (10),
        .TIMEOUT_US   (200)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .pin   (pin),
        .code  (code),
        .valid (valid),
        .fault (fault)
    );

    // ---- RC 网络行为模型 ----
    reg        model_high = 1'b0;
    reg [15:0] model_cnt  = 16'd0;
    reg [15:0] rise_after = 16'd30;      // 模拟"电压高"（时间短）

    assign pin = model_high ? 1'b1 : 1'bz;

    always @(posedge clk) begin
        if (pin === 1'b1) begin
            model_high <= 1'b1;                 // 已经到门限
        end else if (pin === 1'bz) begin        // DUT 已释放，正在充电
            if (model_cnt < rise_after) begin
                model_high <= 1'b0;
                model_cnt  <= model_cnt + 1'b1;
            end else begin
                model_high <= 1'b1;
            end
        end else begin                          // 0 或 x：DUT 在放电
            model_high <= 1'b0;
            model_cnt  <= 16'd0;
        end
    end

    integer failures = 0;
    integer guard;
    reg [15:0] c1, c2;
    reg        f1, f2;

    always #5 clk = ~clk;

    task wait_valid;
        output [15:0] c;
        output        f;
        begin
            guard = 0;
            while (!valid && guard < 2000) begin @(posedge clk); guard = guard + 1; end
            c = code;
            f = fault;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // 场景 1：30 拍后升到高
        rise_after = 16'd30;
        wait_valid(c1, f1);
        $display("  normal: code=%0d fault=%0d", c1, f1);
        if (f1 !== 1'b0) begin $display("FAIL: normal should not fault"); failures = failures + 1; end
        if (c1 < 16'd28 || c1 > 16'd36) begin
            $display("FAIL: code %0d not near model delay", c1); failures = failures + 1;
        end

        // 场景 2：永远不升 → 超时
        repeat (5) @(posedge clk);          // 等 valid 落下，避免读到上一次的值
        rise_after = 16'hFFFF;
        wait_valid(c2, f2);
        $display("  timeout: code=%0d fault=%0d", c2, f2);
        if (f2 !== 1'b1) begin $display("FAIL: timeout should set fault"); failures = failures + 1; end

        $display("");
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
