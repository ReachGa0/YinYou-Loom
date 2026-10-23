`timescale 1ns/1ps

module tb_wavetable_arbiter;
    parameter VOICES    = 4;
    parameter ADDR_BITS = 12;
    parameter SAMPLE_W  = 16;

    reg                           clk;
    reg                           rst_n;
    reg                           sample_en;
    reg  [1:0]                    table_sel;
    reg  [VOICES*ADDR_BITS-1:0]   addr_flat;
    wire [VOICES*SAMPLE_W-1:0]    sample_flat;
    wire [VOICES-1:0]             valid;
    wire                          scan_done;

    reg signed [15:0] sine_ref [0:4095];
    reg signed [15:0] square_ref [0:4095];
    integer failures;
    integer i;

    wavetable_arbiter #(
        .VOICES    (VOICES),
        .ADDR_BITS (ADDR_BITS),
        .SAMPLE_W  (SAMPLE_W),
        .INIT_FILE0 ("data/wavetables/sine_4096x16.hex"),
        .INIT_FILE1 ("data/wavetables/square_4096x16.hex")
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .sample_en        (sample_en),
        .table_sel        (table_sel),
        .wave_addr_flat   (addr_flat),
        .wave_sample_flat (sample_flat),
        .wave_valid       (valid),
        .scan_done        (scan_done)
    );

    always #5 clk = ~clk;

    task do_scan;
        begin
            @(negedge clk);
            sample_en = 1'b1;
            @(negedge clk);
            sample_en = 1'b0;
            wait (scan_done);
            #1;
        end
    endtask

    initial begin
        clk        = 1'b0;
        rst_n      = 1'b0;
        sample_en  = 1'b0;
        table_sel  = 2'd0;
        addr_flat  = {VOICES*ADDR_BITS{1'b0}};
        failures   = 0;

        $readmemh("data/wavetables/sine_4096x16.hex", sine_ref);
        $readmemh("data/wavetables/square_4096x16.hex", square_ref);

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (i = 0; i < VOICES; i = i + 1)
            addr_flat[i*ADDR_BITS +: ADDR_BITS] = i;

        do_scan;
        for (i = 0; i < VOICES; i = i + 1) begin
            if (sample_flat[i*SAMPLE_W +: SAMPLE_W] !== sine_ref[i]) begin
                $display("FAIL: sine voice %0d mismatch, got %h expected %h",
                    i, sample_flat[i*SAMPLE_W +: SAMPLE_W], sine_ref[i]);
                failures = failures + 1;
            end
        end

        table_sel = 2'd1;
        for (i = 0; i < VOICES; i = i + 1)
            addr_flat[i*ADDR_BITS +: ADDR_BITS] = i + 16;

        do_scan;
        for (i = 0; i < VOICES; i = i + 1) begin
            if (sample_flat[i*SAMPLE_W +: SAMPLE_W] !== square_ref[i + 16]) begin
                $display("FAIL: square voice %0d mismatch, got %h expected %h",
                    i, sample_flat[i*SAMPLE_W +: SAMPLE_W], square_ref[i + 16]);
                failures = failures + 1;
            end
        end

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $finish;
    end
endmodule
