`timescale 1ns/1ps

module tb_delay_effect;
    localparam SAMPLE_W = 16;
    localparam ADDR_W   = 5;
    localparam DELAY    = 4;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_en = 1'b0;
    reg signed [SAMPLE_W-1:0] sample_in = 16'sd0;
    wire signed [SAMPLE_W-1:0] wet_out;
    wire valid_out;

    reg signed [SAMPLE_W-1:0] got [0:15];
    integer failures = 0;
    integer n = 0;
    integer guard;
    integer m;

    always #5 clk = ~clk;

    delay_effect #(
        .SAMPLE_W      (SAMPLE_W),
        .ADDR_W        (ADDR_W),
        .DELAY_SAMPLES (DELAY),
        .FEEDBACK_SHIFT (1)
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
            while (!valid_out && guard < 16) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
            end
            if (!valid_out) begin
                $display("FAIL: delay output timeout");
                failures = failures + 1;
            end
            got[n] = wet_out;
            n = n + 1;
        end
    endtask

    initial begin
        for (m = 0; m < 32; m = m + 1)
            dut.delay_mem[m] = 16'sd0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Prime the small memory with silence.
        repeat (8) push_capture(16'sd0);
        n = 0;

        push_capture(16'sd1000);
        repeat (12) push_capture(16'sd0);

        if (got[0] !== 0)  begin $display("FAIL: delay t0"); failures=failures+1; end
        if (got[1] !== 0)  begin $display("FAIL: delay t1"); failures=failures+1; end
        if (got[2] !== 0)  begin $display("FAIL: delay t2"); failures=failures+1; end
        if (got[3] !== 0)  begin $display("FAIL: delay t3"); failures=failures+1; end
        if (got[4] !== 1000) begin $display("FAIL: first echo got %0d", got[4]); failures=failures+1; end
        if (got[8] !== 500)  begin $display("FAIL: second echo got %0d", got[8]); failures=failures+1; end
        if (got[12] !== 250) begin $display("FAIL: third echo got %0d", got[12]); failures=failures+1; end

        $display("");
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
