`timescale 1ns/1ps

module tb_voice_alloc;
    parameter VOICES    = 4;
    parameter PHASE_BITS = 32;
    parameter NOTE_ID_W  = 7;

    reg                         clk;
    reg                         rst_n;
    reg                         note_on;
    reg                         note_off;
    reg  [NOTE_ID_W-1:0]        note_id;
    reg  [PHASE_BITS-1:0]       note_inc;
    reg  [VOICES-1:0]           voice_busy;
    wire [VOICES*PHASE_BITS-1:0] voice_inc_flat;
    wire [VOICES-1:0]           voice_gate_flat;
    wire [VOICES-1:0]           voice_active;

    integer failures;

    voice_alloc #(
        .VOICES     (VOICES),
        .PHASE_BITS (PHASE_BITS),
        .NOTE_ID_W  (NOTE_ID_W)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .note_on         (note_on),
        .note_off        (note_off),
        .note_id         (note_id),
        .note_inc        (note_inc),
        .voice_busy      (voice_busy),
        .voice_inc_flat  (voice_inc_flat),
        .voice_gate_flat (voice_gate_flat),
        .voice_active    (voice_active)
    );

    always #5 clk = ~clk;

    task press_note;
        input [NOTE_ID_W-1:0] id;
        input [PHASE_BITS-1:0] inc;
        begin
            @(negedge clk);
            note_on  = 1'b1;
            note_id  = id;
            note_inc = inc;
            @(negedge clk);
            note_on  = 1'b0;
            @(negedge clk);
            #1;
        end
    endtask

    task release_note;
        input [NOTE_ID_W-1:0] id;
        begin
            @(negedge clk);
            note_off = 1'b1;
            note_id  = id;
            @(negedge clk);
            note_off = 1'b0;
            @(negedge clk);
            #1;
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
        note_on     = 1'b0;
        note_off    = 1'b0;
        note_id     = 7'd0;
        note_inc    = 32'd0;
        voice_busy  = 4'd0;
        failures    = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        press_note(7'd60, 32'h00000001);
        press_note(7'd64, 32'h00000002);
        press_note(7'd67, 32'h00000003);
        press_note(7'd72, 32'h00000004);

        check(voice_active === 4'b1111, "four notes should occupy four voices");
        check(voice_gate_flat === 4'b1111, "four gates should be active");
        check(voice_inc_flat[0*PHASE_BITS +: PHASE_BITS] === 32'h00000001,
            "voice 0 inc mismatch");
        check(voice_inc_flat[3*PHASE_BITS +: PHASE_BITS] === 32'h00000004,
            "voice 3 inc mismatch");

        voice_busy = 4'b1111;
        press_note(7'd79, 32'h00000005);
        check(voice_active === 4'b1111, "all voices should remain active after steal");
        check(voice_inc_flat[0*PHASE_BITS +: PHASE_BITS] === 32'h00000005,
            "steal pointer should reuse voice 0");

        voice_busy = 4'b0000;
        release_note(7'd64);
        check(voice_active === 4'b1101, "middle voice should release");
        check(voice_gate_flat === 4'b1101, "middle gate should release");

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $finish;
    end
endmodule
