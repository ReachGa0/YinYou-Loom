`timescale 1ns/1ps

// wave_capture 验证：
//   1. 触发后能抓到一窗 320 点，frame_valid 置位、last_bank 翻转；
//   2. 窗口第一点落在"上升过零"之后（采样值 > 0）；
//   3. 读口按 bank/addr 能取回刚写入的数据；
//   4. 输入恒为 0（静音）时，超时也能完成一窗，不会把显示卡死。

module tb_wave_capture;
    localparam LEN = 320;

    reg                clk = 1'b0;
    reg                rst_n = 1'b0;
    reg                sample_en = 1'b0;
    reg  signed [15:0] sample_in = 16'sd0;
    reg                trigger = 1'b0;

    wire               frame_valid;
    wire               last_bank;
    reg                rd_bank_sel = 1'b0;
    reg  [8:0]         rd_addr = 9'd0;
    wire signed [15:0] rd_data;

    integer failures = 0;
    integer guard;
    reg signed [15:0] v0;
    reg signed [15:0] v160;

    always #5 clk = ~clk;

    // ---- 48 kHz 节拍（每 4 拍一个 sample_en）----
    reg [1:0] div = 2'd0;
    always @(posedge clk) begin
        if (div == 2'd3) begin
            div       <= 2'd0;
            sample_en <= 1'b1;
        end else begin
            div       <= div + 1'b1;
            sample_en <= 1'b0;
        end
    end

    // ---- 测试信号：±16384 三角波（必然周期性过零）----
    reg [11:0] ph = 12'd0;
    always @(posedge clk) if (sample_en) ph <= ph + 12'd17;

    wire signed [15:0] sig = ph[11] ? (16'sd1024 - $signed({1'b0, ph[10:0]})) * 16
                                    : ($signed({1'b0, ph[10:0]}) - 16'sd1024) * 16;

    always @* sample_in = sig;

    wave_capture #(
        .TIMEOUT (64)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_en   (sample_en),
        .sample_in   (sample_in),
        .trigger     (trigger),
        .frame_valid (frame_valid),
        .last_bank   (last_bank),
        .rd_bank_sel (rd_bank_sel),
        .rd_addr     (rd_addr),
        .rd_data     (rd_data)
    );

    task check;
        input condition;
        input [8*48-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                failures = failures + 1;
            end
        end
    endtask

    task do_trigger;
        begin
            @(posedge clk);
            trigger = 1'b1;
            @(posedge clk);
            trigger = 1'b0;
        end
    endtask

    task read_point;
        input        bank;
        input [8:0]  addr;
        output signed [15:0] val;
        begin
            @(posedge clk);
            rd_bank_sel = bank;
            rd_addr     = addr;
            @(posedge clk);
            #1 val = rd_data;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // ---- 场景 1：正常三角波触发 ----
        do_trigger();
        guard = 0;
        while (!frame_valid && guard < 4000) begin
            @(posedge clk); guard = guard + 1;
        end
        check(frame_valid == 1'b1, "frame_valid should set after one window");
        check(last_bank == 1'b0,  "first window should land in bank 0");

        read_point(1'b0, 9'd0, v0);
        check(v0 > 0, "window sample 0 should be just after rising zero crossing");

        read_point(1'b0, 9'd160, v160);
        check(v160 != 0, "mid-window sample should be non-zero");

        // ---- 场景 2：静音输入，超时也要完成一窗 ----
        force sample_in = 16'sd0;
        do_trigger();
        guard = 0;
        while ((last_bank != 1'b1) && guard < 4000) begin
            @(posedge clk); guard = guard + 1;
        end
        check(last_bank == 1'b1, "silent input: timeout should still finish a window");
        release sample_in;

        $display("");
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
