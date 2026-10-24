`timescale 1ns/1ps

// 32 声部 R3 测试：输出 4800 点，供 spectrum_peaks.py 检查 32 个峰。
module tb_test_mode32;
    localparam VOICES     = 32;
    localparam PHASE_BITS = 32;
    localparam CLK_MHZ    = 100;
    localparam DIV        = 63;
    localparam DUMP_LEN   = 4096;

    reg         clk;
    reg         rst_n;
    reg         sample_en;
    reg         enable;
    wire        note_on;
    wire        note_off;
    wire [6:0]  note_id;
    wire [31:0] note_inc;
    wire        busy;
    wire [5:0]  active_cnt;
    wire signed [15:0] mix_sample;
    wire        scan_done;
    wire [VOICES-1:0] voice_active;
    wire [VOICES-1:0] voice_busy;

    integer div;
    integer out_fd;
    integer i;
    integer failures;
    integer guard;
    integer on_run, on_run_max;
    integer off_run, off_run_max;
    integer max_abs;
    reg     capturing;

    test_mode #(
        .CLK_MHZ (CLK_MHZ),
        .N_TONES (VOICES),
        .HOLD_US (500)
    ) u_test (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (enable),
        .note_on    (note_on),
        .note_off   (note_off),
        .note_id    (note_id),
        .note_inc   (note_inc),
        .busy       (busy),
        .active_cnt (active_cnt)
    );

    synth_engine #(
        .VOICES        (VOICES),
        .PHASE_BITS    (PHASE_BITS),
        .ADDR_BITS     (12),
        .SAMPLE_W      (16),
        .LEVEL_W       (16),
        .NOTE_ID_W     (7),
        .SUSTAIN_LEVEL (16'd32768),
        .INIT_FILE0    ("data/wavetables/sine_4096x16.hex")
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_en    (sample_en),
        .table_sel    (2'd0),
        .bend_q15     (16'd32768),
        .velocity     (8'd255),
        .pluck        (1'b0),
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
            div       <= 0;
            sample_en <= 1'b0;
        end else if (div == DIV) begin
            div       <= 0;
            sample_en <= 1'b1;
        end else begin
            div       <= div + 1;
            sample_en <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (note_on) begin
            on_run <= on_run + 1;
        end else begin
            if (on_run > on_run_max) on_run_max <= on_run;
            on_run <= 0;
        end

        if (note_off) begin
            off_run <= off_run + 1;
        end else begin
            if (off_run > off_run_max) off_run_max <= off_run;
            off_run <= 0;
        end
    end

    always @(posedge clk) begin
        if (sample_en && capturing) begin
            if (mix_sample > max_abs)  max_abs <= mix_sample;
            if (mix_sample < -max_abs) max_abs <= -mix_sample;
        end
    end

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

    task wait_samples;
        input integer n;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge scan_done);
        end
    endtask

    initial begin
        clk       = 1'b0;
        rst_n     = 1'b0;
        sample_en = 1'b0;
        enable    = 1'b0;
        div       = 0;
        failures  = 0;
        on_run    = 0;
        on_run_max = 0;
        off_run   = 0;
        off_run_max = 0;
        max_abs   = 0;
        capturing = 1'b0;
        guard     = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        enable = 1'b1;
        guard = 0;
        while ((voice_active !== {VOICES{1'b1}}) && (guard < 400000)) begin
            @(posedge clk);
            guard = guard + 1;
        end

        check(voice_active === {VOICES{1'b1}},
              "32 voices active after entering test mode");
        check(active_cnt === 6'd32, "active_cnt reports 32 tones");
        $display("INFO: all 32 test voices active");

        wait_samples(100);
        $display("INFO: envelope settled");

        out_fd = $fopen("sim/out/test_mode_tones32.txt", "w");
        if (out_fd == 0) begin
            $display("ERROR: cannot open sim/out/test_mode_tones32.txt");
            $finish;
        end

        capturing = 1'b1;
        for (i = 0; i < DUMP_LEN; i = i + 1) begin
            @(posedge scan_done);
            $fwrite(out_fd, "%d\n", mix_sample);
        end
        capturing = 1'b0;
        $fclose(out_fd);
        $display("INFO: captured %0d mixed samples", DUMP_LEN);

        check(voice_active === {VOICES{1'b1}},
              "32 voices stay active while sounding");
        check(max_abs < 32000, "32-voice mix does not saturate");

        enable = 1'b0;
        guard = 0;
        while ((voice_active !== {VOICES{1'b0}}) && (guard < 400000)) begin
            @(posedge clk);
            guard = guard + 1;
        end
        check(voice_active === {VOICES{1'b0}},
              "all 32 voices released after leaving test mode");
        check(busy === 1'b0, "test_mode returns to idle");

        repeat (4) @(posedge clk);
        check(on_run_max == 1, "note_on is a single-cycle pulse");
        check(off_run_max == 1, "note_off is a single-cycle pulse");

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $display("INFO: dumped %0d samples to sim/out/test_mode_tones32.txt", DUMP_LEN);
        $finish;
    end
endmodule
