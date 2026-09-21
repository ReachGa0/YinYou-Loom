`timescale 1ns/1ps

module tb_key_scan;
    parameter KEYS = 2;
    parameter DEBOUNCE_CYCLES = 3;

    reg clk;
    reg rst_n;
    reg [KEYS-1:0] key_n;
    wire [KEYS-1:0] pressed;
    wire [KEYS-1:0] press_pulse;
    wire [KEYS-1:0] release_pulse;

    integer failures;
    integer press_count;
    integer release_count;

    key_scan #(
        .KEYS            (KEYS),
        .DEBOUNCE_CYCLES (DEBOUNCE_CYCLES)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .key_n         (key_n),
        .pressed       (pressed),
        .press_pulse   (press_pulse),
        .release_pulse (release_pulse)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (press_pulse[0])
            press_count <= press_count + 1;
        if (release_pulse[0])
            release_count <= release_count + 1;
    end

    task check;
        input condition;
        input [8*32-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        clk           = 1'b0;
        rst_n         = 1'b0;
        key_n         = 2'b11;
        failures      = 0;
        press_count   = 0;
        release_count = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        key_n = 2'b10;
        repeat (6) @(posedge clk);
        #1;
        check(pressed[0] === 1'b1, "key 0 should be pressed");
        check(press_count == 1, "key 0 should produce one press pulse");

        key_n = 2'b11;
        repeat (6) @(posedge clk);
        #1;
        check(pressed[0] === 1'b0, "key 0 should be released");
        check(release_count == 1, "key 0 should produce one release pulse");

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $finish;
    end
endmodule
