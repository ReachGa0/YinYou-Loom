`timescale 1ns/1ps

module tb_rotary_decode;
    parameter DEBOUNCE_CYCLES = 2;

    reg clk;
    reg rst_n;
    reg enc_a;
    reg enc_b;
    reg enc_sw_n;
    wire rotate_left;
    wire rotate_right;
    wire sw_pressed;
    wire sw_press;

    integer failures;
    integer right_count;
    integer left_count;
    integer press_count;

    rotary_decode #(
        .DEBOUNCE_CYCLES (DEBOUNCE_CYCLES)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .enc_a       (enc_a),
        .enc_b       (enc_b),
        .enc_sw_n    (enc_sw_n),
        .rotate_left (rotate_left),
        .rotate_right(rotate_right),
        .sw_pressed  (sw_pressed),
        .sw_press    (sw_press)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rotate_right) right_count <= right_count + 1;
        if (rotate_left)  left_count  <= left_count + 1;
        if (sw_press)     press_count <= press_count + 1;
    end

    task set_ab;
        input a;
        input b;
        begin
            enc_a = a;
            enc_b = b;
            repeat (5) @(posedge clk);
        end
    endtask

    task right_step;
        begin
            set_ab(1'b0, 1'b1);
            set_ab(1'b1, 1'b1);
            set_ab(1'b1, 1'b0);
            set_ab(1'b0, 1'b0);
        end
    endtask

    task left_step;
        begin
            set_ab(1'b1, 1'b0);
            set_ab(1'b1, 1'b1);
            set_ab(1'b0, 1'b1);
            set_ab(1'b0, 1'b0);
        end
    endtask

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
        clk         = 1'b0;
        rst_n       = 1'b0;
        enc_a       = 1'b0;
        enc_b       = 1'b0;
        enc_sw_n    = 1'b1;
        failures    = 0;
        right_count = 0;
        left_count  = 0;
        press_count = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        right_step;
        check(right_count == 1, "right step should produce one pulse");
        check(left_count == 0, "right step should not produce left pulse");

        left_step;
        check(left_count == 1, "left step should produce one pulse");
        check(right_count == 1, "left step should not produce extra right pulse");

        enc_sw_n = 1'b0;
        repeat (6) @(posedge clk);
        #1;
        check(sw_pressed === 1'b1, "encoder switch should be pressed");
        check(press_count == 1, "encoder switch should produce one press pulse");

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $finish;
    end
endmodule
