// TFT UI: 224x224 phase portrait on the left, three stacked menus on the right.
module ui_lissajous_render #(
    parameter FONT_INIT = "../../data/fonts/font8x16.hex",
    parameter [11:0] FLOW_INC = 12'd160,
    parameter [6:0] SLEW_INC = 7'd8,
    parameter DEBUG_JOY = 0
)(
    input wire clk, rst_n,
    input wire [1:0] st_timbre, st_fx, st_mode,
    input wire [6:0] st_note,
    input wire [2:0] st_voices,
    input wire st_test,
    input wire [6:0] st_key_root,
    input wire plot_hit, dirty_ready,
    input wire [13:0] dirty_bands,
    input wire live_valid, live_bank,
    input wire signed [15:0] live_data,
    output wire capture_trig, rd_bank_sel,
    output wire [8:0] rd_addr,
    input wire [15:0] dbg_x_code, dbg_y_code,
    input wire dbg_x_fault, dbg_y_fault,
    input wire [15:0] dbg_bend,
    output reg win_start,
    output reg [9:0] win_x0, win_x1, win_y0, win_y1,
    output reg [15:0] px_data,
    input wire [8:0] px_x,
    input wire [7:0] px_y,
    input wire busy, done,
    output wire [2:0] dbg_region
);
    localparam RG_FULL=3'd0, RG_PLOT=3'd1, RG_TONE=3'd2,
               RG_FX=3'd3, RG_MODE=3'd4;
    reg [2:0] region;
    reg [2:0] sched;
    reg full_pending, cap_trig;
    reg [13:0] bands_pending;
    reg [3:0] band;
    reg [20:0] frame_timer;
    localparam FRAME_INTERVAL = 21'd1440000; // 20 ms at 72 MHz
    reg [1:0] tone_drawn, fx_drawn, mode_drawn;
    reg test_drawn;
    reg [1:0] tone_frame, fx_frame, mode_frame;
    reg test_frame;
    assign dbg_region = region;
    assign capture_trig = cap_trig;
    assign rd_addr = 9'd0;
    assign rd_bank_sel = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            sched <= 0; region <= RG_FULL; full_pending <= 1;
            win_start <= 0; cap_trig <= 0;
            win_x0 <= 0; win_x1 <= 319; win_y0 <= 0; win_y1 <= 239;
            tone_drawn <= 0; fx_drawn <= 0; mode_drawn <= 0; test_drawn <= 0;
            tone_frame <= 0; fx_frame <= 0; mode_frame <= 0; test_frame <= 0;
            frame_timer <= 0; bands_pending <= 0; band <= 0;
        end else begin
            win_start <= 0; cap_trig <= 0;
            if (frame_timer < FRAME_INTERVAL) frame_timer <= frame_timer + 1'b1;
            case (sched)
              0: if (!busy) begin
                    if (full_pending) region <= RG_FULL;
                    else if (st_timbre != tone_drawn) region <= RG_TONE;
                    else if (st_fx != fx_drawn) region <= RG_FX;
                    else if (st_mode != mode_drawn || st_test != test_drawn) region <= RG_MODE;
                    else if (frame_timer >= FRAME_INTERVAL) region <= RG_PLOT;
                    if (full_pending || st_timbre != tone_drawn || st_fx != fx_drawn ||
                        st_mode != mode_drawn || st_test != test_drawn || frame_timer >= FRAME_INTERVAL)
                        sched <= 1;
                 end
              1: begin
                    tone_frame <= st_timbre; fx_frame <= st_fx;
                    mode_frame <= st_mode; test_frame <= st_test;
                    case (region)
                      RG_FULL: begin win_x0<=0; win_x1<=319; win_y0<=0; win_y1<=239; full_pending<=0; end
                      RG_PLOT: begin cap_trig<=1; frame_timer<=0; end
                      RG_TONE: begin win_x0<=224; win_x1<=319; win_y0<=0; win_y1<=79; end
                      RG_FX:   begin win_x0<=224; win_x1<=319; win_y0<=80; win_y1<=159; end
                      default: begin win_x0<=224; win_x1<=319; win_y0<=160; win_y1<=239; end
                    endcase
                    if (region == RG_PLOT) sched<=4;
                    else begin win_start<=1; sched<=2; end
                 end
              2: if (busy) sched<=3;
              3: if (done) begin
                    if (region==RG_FULL || region==RG_TONE) tone_drawn<=tone_frame;
                    if (region==RG_FULL || region==RG_FX) fx_drawn<=fx_frame;
                    if (region==RG_FULL || region==RG_MODE) begin mode_drawn<=mode_frame; test_drawn<=test_frame; end
                    sched<=0;
                 end
              4: if (dirty_ready) begin bands_pending<=dirty_bands; band<=0; sched<=5; end
              5: if (band == 14) sched<=0;
                 else if (bands_pending[band]) begin
                    win_x0<=0; win_x1<=223;
                    win_y0<=10'd8 + ({6'd0,band} << 4);
                    win_y1<=10'd23 + ({6'd0,band} << 4);
                    win_start<=1; sched<=6;
                 end else band<=band+1'b1;
              6: if (busy) sched<=7;
              7: if (done) begin band<=band+1'b1; sched<=5; end
            endcase
        end
    end

    function [95:0] line_text;
        input [1:0] group;
        input [2:0] line;
        input test_mode;
        begin
            case (group)
              0: case (line)
                0: line_text="TONE  S1    "; 1: line_text="SINE        ";
                2: line_text="SQUARE      "; 3: line_text="SAW         ";
                default: line_text="TRIANGLE    "; endcase
              1: case (line)
                0: line_text="FX    S2    "; 1: line_text="DRY         ";
                2: line_text="CHORUS      "; 3: line_text="DELAY       ";
                default: line_text="REVERB      "; endcase
              default: case (line)
                0: line_text=test_mode ? "TEST  SW    " : "MODE  SW    ";
                1: line_text="ONE         "; 2: line_text="TRI         ";
                3: line_text="PLUCK ONE   "; default: line_text="PLUCK TRI   "; endcase
            endcase
        end
    endfunction
    wire [1:0] group = px_y < 80 ? 2'd0 : (px_y < 160 ? 2'd1 : 2'd2);
    wire [7:0] local_y = group == 0 ? px_y : (group == 1 ? px_y - 8'd80 : px_y - 8'd160);
    wire [2:0] line = local_y[6:4];
    wire [6:0] local_x = px_x - 9'd224;
    wire [3:0] char_index = local_x[6:3];
    wire [2:0] char_bit = local_x[2:0];
    wire [95:0] text_line = line_text(group,line,test_frame);
    wire [7:0] ch = text_line[(11-char_index)*8 +: 8];
    wire [10:0] rom_addr = ({3'b0, (ch - 8'h20)} << 4) + {7'b0,local_y[3:0]};
    wire [7:0] glyph;
    font8x16_rom #(.INIT_FILE(FONT_INIT)) u_font (.clk(clk),.addr(rom_addr),.data(glyph));
    wire glyph_on = glyph[7-char_bit];
    wire [1:0] selected = group == 0 ? tone_frame : (group == 1 ? fx_frame : mode_frame);
    wire selected_line = line != 0 && line == ({1'b0,selected} + 3'd1);
    always @(*) begin
        if (px_x < 224)
            px_data = plot_hit ? 16'h07ff : 16'h0000;
        else if (selected_line)
            px_data = glyph_on ? 16'h0000 : 16'hffff;
        else
            px_data = glyph_on ? (line == 0 ? 16'h07ff : 16'hffff) : 16'h0000;
    end
endmodule
