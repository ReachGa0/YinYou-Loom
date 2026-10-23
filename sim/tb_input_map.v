`timescale 1ns/1ps

module tb_input_map;
    parameter KEYS = 7;
    parameter PHASE_BITS = 32;
    parameter NOTE_ID_W = 7;

    reg [KEYS-1:0] key_press;
    reg [KEYS-1:0] key_release;
    wire note_on;
    wire note_off;
    wire [NOTE_ID_W-1:0] note_id;
    wire [PHASE_BITS-1:0] note_inc;

    integer failures;

    input_map #(
        .KEYS       (KEYS),
        .PHASE_BITS (PHASE_BITS),
        .NOTE_ID_W  (NOTE_ID_W)
    ) dut (
        .key_press   (key_press),
        .key_release (key_release),
        .note_on     (note_on),
        .note_off    (note_off),
        .note_id     (note_id),
        .note_inc    (note_inc)
    );

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
        key_press   = {KEYS{1'b0}};
        key_release = {KEYS{1'b0}};
        failures    = 0;
        #1;

        // K1 -> C4
        key_press = 7'b0000001;
        #1;
        check(note_on === 1'b1, "key 0 should emit note_on");
        check(note_off === 1'b0, "note_off should be low while pressing");
        check(note_id === 7'd60, "key 0 should map to C4");
        check(note_inc === 32'd23409859, "key 0 inc should match C4");

        // K5 -> G4
        key_press = 7'b0010000;
        #1;
        check(note_id === 7'd67, "key 4 should map to G4");
        check(note_inc === 32'd35075158, "key 4 inc should match G4");

        // K7 -> B4
        key_press = 7'b1000000;
        #1;
        check(note_id === 7'd71, "key 6 should map to B4");
        check(note_inc === 32'd44191930, "key 6 inc should match B4");

        // 松开 K2 -> D4
        key_press   = {KEYS{1'b0}};
        key_release = 7'b0000010;
        #1;
        check(note_on === 1'b0, "note_on should be low while releasing");
        check(note_off === 1'b1, "key 1 release should emit note_off");
        check(note_id === 7'd62, "key 1 should map to D4");

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $finish;
    end
endmodule
