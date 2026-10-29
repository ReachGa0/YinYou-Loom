`timescale 1ns/1ps
module tb_ui_lissajous_dirty;
    reg clk=0, rst_n=0, busy=0, done=0, ready=0;
    reg [13:0] bands=0;
    wire request, start;
    wire [9:0] x0,x1,y0,y1;
    always #5 clk=~clk;
    ui_lissajous_render #(.FONT_INIT("data/fonts/font8x16.hex")) dut (
        .clk(clk),.rst_n(rst_n),.st_timbre(2'd0),.st_fx(2'd0),.st_mode(2'd0),
        .st_note(7'd0),.st_voices(3'd0),.st_test(1'b0),.st_key_root(7'd0),
        .plot_hit(1'b0),.dirty_ready(ready),.dirty_bands(bands),
        .live_valid(1'b0),.live_bank(1'b0),.live_data(16'd0),
        .capture_trig(request),.dbg_x_code(16'd0),.dbg_y_code(16'd0),
        .dbg_x_fault(1'b0),.dbg_y_fault(1'b0),.dbg_bend(16'd0),
        .win_start(start),.win_x0(x0),.win_x1(x1),.win_y0(y0),.win_y1(y1),
        .px_x(9'd0),.px_y(8'd0),.busy(busy),.done(done)
    );
    task finish_window;
        begin
            @(negedge clk); busy=1;
            repeat(2) @(negedge clk);
            done=1; busy=0;
            @(negedge clk); done=0;
        end
    endtask
    initial begin
        repeat(2) @(negedge clk); rst_n=1;
        wait(start); if (x1!=319 || y1!=239) $fatal(1,"initial screen");
        finish_window();
        // Advance the frame timer to keep the simulation short.
        @(negedge clk); dut.frame_timer=21'd1440000;
        wait(request); @(negedge clk); bands=(14'b1<<2)|(14'b1<<10); ready=1;
        @(negedge clk); ready=0;
        wait(start); if (x0!=0 || x1!=223 || y0!=40 || y1!=55) $fatal(1,"band 2 window");
        finish_window();
        wait(start); if (y0!=168 || y1!=183) $fatal(1,"band 10 window");
        finish_window();
        repeat(30) begin @(negedge clk); if (start) $fatal(1,"unexpected extra refresh"); end
        $display("RESULT: ALL PASS"); $finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule
