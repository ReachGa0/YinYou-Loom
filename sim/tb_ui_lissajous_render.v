`timescale 1ns/1ps
module tb_ui_lissajous_render;
    reg clk=0, rst_n=0, plot_hit=0;
    reg [8:0] x=0;
    reg [7:0] y=0;
    wire [15:0] color;
    always #5 clk=~clk;
    ui_lissajous_render #(.FONT_INIT("data/fonts/font8x16.hex")) dut (
        .clk(clk), .rst_n(rst_n), .st_timbre(2'd0), .st_fx(2'd0), .st_mode(2'd0),
        .st_note(7'd0), .st_voices(3'd0), .st_test(1'b0), .st_key_root(7'd0),
        .plot_hit(plot_hit), .dirty_ready(1'b0), .dirty_bands(14'd0), .live_valid(1'b0), .live_bank(1'b0), .live_data(16'd0),
        .dbg_x_code(16'd0), .dbg_y_code(16'd0), .dbg_x_fault(1'b0), .dbg_y_fault(1'b0), .dbg_bend(16'd0),
        .px_data(color), .px_x(x), .px_y(y), .busy(1'b1), .done(1'b0)
    );
    task check_color;
        input [8:0] px; input [7:0] py; input [15:0] expected;
        begin
            @(negedge clk); x=px; y=py;
            repeat(4) @(negedge clk);
            if (color !== expected) $fatal(1,"pixel %0d,%0d got %h expected %h",x,y,color,expected);
        end
    endtask
    initial begin
        repeat(2) @(negedge clk); rst_n=1;
        plot_hit=1;
        check_color(100,100,16'h07ff);
        plot_hit=0;
        check_color(100,100,16'h0000);
        check_color(319,16,16'hffff);
        check_color(319,32,16'h0000);
        check_color(319,96,16'hffff);
        check_color(319,176,16'hffff);
        $display("RESULT: ALL PASS");
        $finish;
    end
endmodule
