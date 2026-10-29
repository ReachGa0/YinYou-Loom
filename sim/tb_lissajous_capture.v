`timescale 1ns/1ps
module tb_lissajous_capture;
    reg clk = 0, rst_n = 0, sample_en = 0, frame_start = 0;
    reg signed [15:0] sample_in = 0;
    reg [8:0] pixel_x = 112;
    reg [7:0] pixel_y = 118;
    wire pixel_on;
    wire dirty_ready;
    wire [13:0] dirty_bands;
    integer n;
    always #5 clk = ~clk;
    lissajous_capture dut(clk, rst_n, sample_en, sample_in, frame_start,
                          pixel_x, pixel_y, pixel_on, dirty_ready, dirty_bands);
    task sample;
        input signed [15:0] value;
        begin
            @(negedge clk); sample_in = value; sample_en = 1;
            @(negedge clk); sample_en = 0;
        end
    endtask
    task flip;
        begin
            @(negedge clk); frame_start = 1;
            @(negedge clk); frame_start = 0;
            wait(dirty_ready);
            @(negedge clk);
        end
    endtask
    initial begin
        repeat (2) @(negedge clk); rst_n = 1;
        repeat (32769) @(negedge clk);
        repeat (17) sample(16'sd0);
        flip();
        if (dirty_bands !== 14'h3fff) $fatal(1, "first frame must repaint all bands");
        repeat (3) @(negedge clk);
        if (pixel_on !== 1) $fatal(1, "zero samples should plot the centre");
        pixel_x = 114;
        repeat (3) @(negedge clk);
        if (pixel_on !== 0) $fatal(1, "unplotted pixel should be clear");
        repeat (16385) @(negedge clk);
        repeat (17) sample(16'sd0);
        flip();
        if (dirty_bands !== 0) $fatal(1, "identical frames must not refresh any bands");
        repeat (16385) @(negedge clk);
        sample(16'sd16384);
        flip();
        if (dirty_bands !== 14'h0040) $fatal(1, "only the changed band should be dirty");
        pixel_x = 168; pixel_y = 118;
        repeat (3) @(negedge clk);
        if (pixel_on !== 1) $fatal(1, "current sample should control X");
        pixel_x = 112;
        repeat (3) @(negedge clk);
        if (pixel_on !== 0) $fatal(1, "old frame must not persist");
        repeat (16385) @(negedge clk);
        repeat (16) sample(16'sd16384);
        sample(16'sd0);
        flip();
        pixel_x = 112; pixel_y = 62;
        repeat (3) @(negedge clk);
        if (pixel_on !== 1) $fatal(1, "delayed sample should control Y");
        for (n=0; n<13; n=n+1) begin
            repeat (16385) @(negedge clk);
            repeat (17) sample(16'sd1024);
            flip();
            if (n<2 && dut.display_shift !== 0) $fatal(1, "gain changed before three stable frames");
            if (n==2 && dut.display_shift !== 1) $fatal(1, "gain must move one step after three frames");
        end
        pixel_x = 168; pixel_y = 62;
        repeat (3) @(negedge clk);
        if (pixel_on !== 1) $fatal(1, "quiet input should expand using display gain");
        $display("RESULT: ALL PASS");
        $finish;
    end
endmodule
