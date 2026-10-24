`timescale 1ns/1ps

module tb_voice_alloc32;
    localparam VOICES     = 32;
    localparam PHASE_BITS = 32;
    localparam NOTE_ID_W  = 7;
    localparam [VOICES-1:0] ALL_ONES = {VOICES{1'b1}};

    reg                         clk;
    reg                         rst_n;
    reg                         note_on;
    reg                         note_off;
    reg  [NOTE_ID_W-1:0]        note_id;
    reg  [PHASE_BITS-1:0]       note_inc;
    reg  [15:0]                 note_gain;
    reg  [VOICES-1:0]           voice_busy;
    wire [VOICES*PHASE_BITS-1:0] voice_inc_flat;
    wire [VOICES*16-1:0]        voice_gain_flat;
    wire [VOICES-1:0]           voice_gate_flat;
    wire [VOICES-1:0]           voice_active;

    integer failures;
    integer i;

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
        .note_gain       (note_gain),
        .voice_busy      (voice_busy),
        .voice_inc_flat  (voice_inc_flat),
        .voice_gain_flat (voice_gain_flat),
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
            note_gain = 16'd32768;
            @(negedge clk);
            note_on  = 1'b0;
            @(negedge clk);
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
        end
    endtask

    task check;
        input condition;
        input [8*56-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        clk        = 1'b0;
        rst_n      = 1'b0;
        note_on    = 1'b0;
        note_off   = 1'b0;
        note_id    = 7'd0;
        note_inc   = 32'd0;
        note_gain  = 16'd32768;
        voice_busy = {VOICES{1'b0}};
        failures   = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (i = 0; i < VOICES; i = i + 1)
            press_note(7'd80 + i[6:0], i + 1);

        check(voice_active === ALL_ONES, "32 notes occupy all voices");
        check(voice_gate_flat === ALL_ONES, "all 32 gates active");
        check(voice_inc_flat[31*PHASE_BITS +: PHASE_BITS] === 32'd32,
              "voice 31 increment mismatch");

        voice_busy = ALL_ONES;
        press_note(7'd70, 32'h00001234);
        check(voice_active === ALL_ONES, "steal keeps all voices active");
        check(voice_inc_flat[0*PHASE_BITS +: PHASE_BITS] === 32'h00001234,
              "round-robin steal wraps to voice 0");

        voice_busy = {VOICES{1'b0}};
        release_note(7'd81);
        check(voice_active[1] === 1'b0, "note ID releases corresponding voice");
        check(voice_gate_flat === (ALL_ONES & ~32'h0000_0002),
              "release clears only voice 1 gate");

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);
        $finish;
    end
endmodule
