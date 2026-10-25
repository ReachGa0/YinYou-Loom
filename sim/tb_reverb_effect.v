`timescale 1ns/1ps

module tb_reverb_effect;
    localparam SAMPLE_W = 16;
    localparam ADDR_W   = 4;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_en = 1'b0;
    reg signed [SAMPLE_W-1:0] sample_in = 16'sd0;
    wire signed [SAMPLE_W-1:0] wet_out;
    wire valid_out;

    reg signed [SAMPLE_W-1:0] got [0:19];
    integer failures = 0;
    integer n = 0;
    integer i;
    integer j;
    integer guard;
    integer nonzero;

    always #5 clk = ~clk;

    reverb_effect #(
        .SAMPLE_W (SAMPLE_W),
        .ADDR_W   (ADDR_W),
        .LEN0     (4),
        .LEN1     (5),
        .LEN2     (7),
        .LEN3     (9)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .sample_en (sample_en),
        .sample_in (sample_in),
        .wet_out   (wet_out),
        .valid_out (valid_out)
    );

    task push_capture;
        input signed [SAMPLE_W-1:0] value;
        begin
            @(negedge clk);
            sample_in = value;
            sample_en = 1'b1;
            @(negedge clk);
            sample_en = 1'b0;

            guard = 0;
            while (!valid_out && guard < 24) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
            end
            if (!valid_out) begin
                $display("FAIL: reverb output timeout");
                failures = failures + 1;
            end
            if (n < 20) got[n] = wet_out;
            n = n + 1;
        end
    endtask

    initial begin
        for (j = 0; j < 64; j = j + 1)
            begin
                if (j < 4) dut.line0[j] = 16'sd0;
                if (j < 5) dut.line1[j] = 16'sd0;
                if (j < 7) dut.line2[j] = 16'sd0;
                if (j < 9) dut.line3[j] = 16'sd0;
            end
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        repeat (16) push_capture(16'sd0);
        n = 0;

        push_capture(16'sd1000);
        repeat (19) push_capture(16'sd0);

        nonzero = 0;
        for (i = 0; i < 20; i = i + 1)
            if (got[i] != 0) nonzero = nonzero + 1;

        if (nonzero < 8) begin
            $display("FAIL: reverb should create a decaying multi-tap tail, nonzero=%0d", nonzero);
            failures = failures + 1;
        end
        if (got[4] <= 0 || got[5] <= 0 || got[7] <= 0 || got[9] <= 0) begin
            $display("FAIL: four comb taps should produce early echoes");
            failures = failures + 1;
        end

        $display("");
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
