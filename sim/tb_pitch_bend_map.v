`timescale 1ns/1ps

// pitch_bend_map 验证：中位、左右满量程、死区、故障回中
module tb_pitch_bend_map;
    localparam [15:0] CENTER = 16'd7845;
    localparam [15:0] SPAN_L = 16'd4170;
    localparam [15:0] SPAN_R = 16'd1795;
    localparam [15:0] BMAX   = 16'd4013;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg  [15:0] code = 16'd0;
    reg         valid = 1'b0;
    reg         fault = 1'b0;
    wire [15:0] bend;

    integer failures = 0;

    always #5 clk = ~clk;

    pitch_bend_map #(
        .SPAN_LEFT   (SPAN_L),
        .SPAN_RIGHT  (SPAN_R),
        .BEND_MAX    (BMAX)
    ) dut (
        .clk (clk), .rst_n (rst_n),
        .code (code), .center_code (CENTER), .valid (valid), .fault (fault),
        .bend_q15 (bend)
    );

    task apply;
        input [15:0] c;
        input        f;
        begin
            @(negedge clk);
            code = c; fault = f; valid = 1'b1;
            @(posedge clk); #1;          // 采样完成这一拍更新
            @(negedge clk);
            valid = 1'b0;                // 之后 valid 拉低，值必须保持
            repeat (5) @(posedge clk); #1;
        end
    endtask

    task chk;
        input [15:0] got;
        input [15:0] exp;
        input [15:0] tol;
        input [8*40-1:0] msg;
        begin
            if ((got > exp + tol) || (got + tol < exp)) begin
                $display("FAIL: %0s got=%0d exp=%0d", msg, got, exp);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        apply(CENTER, 1'b0);
        chk(bend, 16'd32768, 16'd1, "center = 1.0");

        apply(CENTER - 16'd20, 1'b0);             // 死区内
        chk(bend, 16'd32768, 16'd1, "deadzone stays 1.0");

        apply(CENTER - SPAN_R, 1'b0);             // 右端
        // 死区 150 会吃掉约 8% 行程，容差给 400
        chk(bend, 16'd32768 + BMAX, 16'd400, "right full scale = +2 semitones");

        apply(CENTER + SPAN_L, 1'b0);             // 左端
        chk(bend, 16'd32768 - BMAX, 16'd400, "left full scale = -2 semitones");

        apply(CENTER - 16'd900, 1'b0);            // 半程
        chk(bend, 16'd32768 + 16'd2013, 16'd400, "half right ~ +1 semitone");

        apply(CENTER, 1'b1);                      // 故障
        chk(bend, 16'd32768, 16'd1, "fault centres the bend");

        apply(16'h0001, 1'b0);                    // 越界
        chk(bend, 16'd32768, 16'd1, "out-of-range centres the bend");

        $display("");
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
