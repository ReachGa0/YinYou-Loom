`timescale 1ns/1ps

module tb_p5_baseline;
    parameter KEYS = 4;
    parameter PHASE_BITS = 32;
    parameter DEBOUNCE_CYCLES = 3;

    reg clk;
    reg rst_n;
    reg sample_en;
    reg [7:0] sample_div;
    reg [KEYS-1:0] key_n;
    wire [KEYS-1:0] pressed;
    wire [KEYS-1:0] press_pulse;
    wire [KEYS-1:0] release_pulse;
    wire note_on;
    wire note_off;
    wire [6:0] note_id;
    wire [PHASE_BITS-1:0] note_inc;
    wire signed [15:0] mix_sample;
    wire scan_done;
    wire [KEYS-1:0] voice_active;
    wire [KEYS-1:0] voice_busy;

    integer failures;
    integer i;

    key_scan #(
        .KEYS            (KEYS),
        .DEBOUNCE_CYCLES (DEBOUNCE_CYCLES)
    ) u_scan (
        .clk           (clk),
        .rst_n         (rst_n),
        .key_n         (key_n),
        .pressed       (pressed),
        .press_pulse   (press_pulse),
        .release_pulse (release_pulse)
    );

    input_map #(
        .KEYS       (KEYS),
        .PHASE_BITS (PHASE_BITS),
        .NOTE_ID_W  (7)
    ) u_map (
        .key_press   (press_pulse),
        .key_release (release_pulse),
        .note_on     (note_on),
        .note_off    (note_off),
        .note_id     (note_id),
        .note_inc    (note_inc)
    );

    synth_engine #(
        .VOICES     (KEYS),
        .PHASE_BITS (PHASE_BITS),
        .ADDR_BITS  (12),
        .SAMPLE_W   (16),
        .LEVEL_W    (16),
        .NOTE_ID_W  (7),
        .INIT_FILE0 ("data/wavetables/sine_4096x16.hex"),
        .INIT_FILE1 ("data/wavetables/square_4096x16.hex")
    ) u_engine (
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_en  <= 1'b0;
            sample_div <= 8'd0;
        end else if (sample_div == 8'd7) begin
            sample_en  <= 1'b1;
            sample_div <= 8'd0;
        end else begin
            sample_en  <= 1'b0;
            sample_div <= sample_div + 1'b1;
        end
    end

    task press_key;
        input integer index;
        begin
            key_n[index] = 1'b0;
            repeat (8) @(posedge clk);
        end
    endtask

    initial begin
        clk       = 1'b0;
        rst_n     = 1'b0;
        sample_en = 1'b0;
        sample_div = 8'd0;
        key_n     = 4'b1111;
        failures  = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        press_key(0);
        press_key(1);
        press_key(2);
        press_key(3);

        repeat (20) @(posedge clk);
        if (voice_active !== 4'b1111) begin
            $display("FAIL: four keys should allocate four voices, got %b", voice_active);
            failures = failures + 1;
        end

        key_n[2] = 1'b1;
        repeat (12) @(posedge clk);
        if (voice_active !== 4'b1011) begin
            $display("FAIL: releasing key 2 should clear voice 2, got %b", voice_active);
            failures = failures + 1;
        end

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $finish;
    end
endmodule
