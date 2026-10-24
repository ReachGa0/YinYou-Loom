`timescale 1ns/1ps

module tb_test_mode_router;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg toggle_req = 1'b0;
    reg voice_busy = 1'b0;
    reg test_busy = 1'b0;
    wire test_enable;
    wire test_route;
    wire state_wait_quiet;
    wire state_test;

    integer failures = 0;

    test_mode_router dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .toggle_req       (toggle_req),
        .voice_busy       (voice_busy),
        .test_busy        (test_busy),
        .test_enable      (test_enable),
        .test_route       (test_route),
        .state_wait_quiet (state_wait_quiet),
        .state_test       (state_test)
    );

    always #5 clk = ~clk;

    task pulse_toggle;
        begin
            @(negedge clk);
            toggle_req = 1'b1;
            @(negedge clk);
            toggle_req = 1'b0;
        end
    endtask

    task check;
        input condition;
        input [8*64-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        check(!test_route, "reset starts in normal performance mode");

        voice_busy = 1'b1;
        pulse_toggle();
        repeat (2) @(posedge clk);
        check(state_wait_quiet, "enter request waits for active performance voices");
        check(!test_enable, "test is not enabled while performance voices are busy");

        voice_busy = 1'b0;
        repeat (2) @(posedge clk);
        check(state_test, "test starts after performance becomes quiet");
        check(test_enable && test_route, "test source is enabled and routed");

        test_busy = 1'b1;
        pulse_toggle();
        repeat (2) @(posedge clk);
        check(!test_enable, "exit request immediately stops allocating test notes");
        check(test_route, "test source stays routed during release");

        repeat (2) @(posedge clk);
        check(test_route, "router waits while test voices release");

        test_busy = 1'b0;
        voice_busy = 1'b0;
        repeat (2) @(posedge clk);
        check(!test_route, "router returns to performance only after all release");

        $display("");
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
