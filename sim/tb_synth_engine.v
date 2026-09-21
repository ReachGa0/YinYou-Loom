`timescale 1ns/1ps

module tb_synth_engine;
    parameter VOICES = 4;
    parameter PHASE_BITS = 32;

    reg clk;
    reg rst_n;
    reg sample_en;
    reg note_on;
    reg note_off;
    reg [6:0] note_id;
    reg [PHASE_BITS-1:0] note_inc;
    wire signed [15:0] mix_sample;
    wire scan_done;
    wire [VOICES-1:0] voice_active;
    wire [VOICES-1:0] voice_busy;

    integer failures;
    integer i;
    reg [11:0] div;

    synth_engine #(
        .VOICES     (VOICES),
        .PHASE_BITS (PHASE_BITS),
        .ADDR_BITS  (12),
        .SAMPLE_W   (16),
        .LEVEL_W    (16),
        .NOTE_ID_W  (7),
        .INIT_FILE0 ("data/wavetables/sine_4096x16.hex"),
        .INIT_FILE1 ("data/wavetables/square_4096x16.hex")
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_en    (sample_en),
        .table_sel    (1'b0),
        .note_on      (note_on),
        .note_off     (note_off),
        .note_id      (note_id),
        .note_inc     (note_inc),
        .mix_sample   (mix_sample),
        .scan_done    (scan_done),
        .voice_active (voice_active),
        .voice_busy   (voice_busy)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!rst_n) begin
            div       <= 12'd0;
            sample_en <= 1'b0;
        end else if (div == 12'd31) begin
            div       <= 12'd0;
            sample_en <= 1'b1;
        end else begin
            div       <= div + 1'b1;
            sample_en <= 1'b0;
        end
    end

    task press_note;
        input [6:0] id;
        input [PHASE_BITS-1:0] inc;
        begin
            @(negedge clk);
            note_on  = 1'b1;
            note_id  = id;
            note_inc = inc;
            @(negedge clk);
            note_on  = 1'b0;
            @(negedge clk);
        end
    endtask

    task release_note;
        input [6:0] id;
        begin
            @(negedge clk);
            note_off = 1'b1;
            note_id  = id;
            @(negedge clk);
            note_off = 1'b0;
            @(negedge clk);
        end
    endtask

    task wait_samples;
        input integer n;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge scan_done);
            #1;
        end
    endtask

    initial begin
        clk       = 1'b0;
        rst_n     = 1'b0;
        sample_en = 1'b0;
        note_on   = 1'b0;
        note_off  = 1'b0;
        note_id   = 7'd0;
        note_inc  = 32'd0;
        div       = 12'd0;
        failures  = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        press_note(7'd60, 32'd39370534);
        press_note(7'd64, 32'd44000000);
        press_note(7'd67, 32'd49000000);
        press_note(7'd72, 32'd55000000);

        wait_samples(80);
        if (voice_active !== 4'b1111) begin
            $display("FAIL: four voices should be active, got %b", voice_active);
            failures = failures + 1;
        end
        if ((mix_sample === 16'bx) || (mix_sample === 16'd0)) begin
            $display("FAIL: mix_sample should be a valid non-zero sample");
            failures = failures + 1;
        end

        release_note(7'd67);
        wait_samples(40);
        if (voice_active !== 4'b1011) begin
            $display("FAIL: released voice should not be active, got %b", voice_active);
            failures = failures + 1;
        end

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $finish;
    end
endmodule
