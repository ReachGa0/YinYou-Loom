`timescale 1ns/1ps

module tb_frac_div;
    reg  clk;
    reg  rst_n;
    wire tick;

    integer ticks;
    integer cycles;
    integer failures;

    frac_div #(
        .STEP (8),
        .DEN  (125)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .tick  (tick)
    );

    always #5 clk = ~clk;

    task count_ticks;
        input integer n;
        begin
            ticks = 0;
            for (cycles = 0; cycles < n; cycles = cycles + 1) begin
                @(posedge clk);
                #1;
                if (tick)
                    ticks = ticks + 1;
            end
        end
    endtask

    initial begin
        clk      = 1'b0;
        rst_n    = 1'b0;
        failures = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        count_ticks(125);
        if (ticks == 8) begin
            $display("PASS: 125 cycles produced 8 ticks");
        end else begin
            $display("FAIL: 125 cycles produced %0d ticks, expected 8", ticks);
            failures = failures + 1;
        end

        count_ticks(1250);
        if (ticks == 80) begin
            $display("PASS: 1250 cycles produced 80 ticks");
        end else begin
            $display("FAIL: 1250 cycles produced %0d ticks, expected 80", ticks);
            failures = failures + 1;
        end

        count_ticks(1);
        if (ticks == 0) begin
            $display("PASS: fractional remainder carried across short window");
        end else begin
            $display("FAIL: short window unexpectedly produced %0d tick", ticks);
            failures = failures + 1;
        end

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $finish;
    end
endmodule
