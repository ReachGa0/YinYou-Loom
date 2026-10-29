// Compare successive 112x112 point maps in 14 horizontal bands.
module lissajous_capture (
    input wire clk, rst_n, sample_en,
    input wire signed [15:0] sample_in,
    input wire frame_start,
    input wire [8:0] pixel_x,
    input wire [7:0] pixel_y,
    output wire pixel_on,
    output reg dirty_ready,
    output reg [13:0] dirty_bands
);
    (* syn_ramstyle = "block_ram" *) reg bank0 [0:16383];
    (* syn_ramstyle = "block_ram" *) reg bank1 [0:16383];
    reg signed [15:0] history [0:15];
    reg [4:0] history_count;
    reg write_bank, display_bank, display_valid;
    reg clearing, init_clear, scanning, scan_valid;
    reg [13:0] clear_pos, scan_pos, scan_previous;
    reg scan_last_issued;
    reg read0, read1;
    reg [15:0] frame_peak;
    reg [2:0] display_shift, pending_shift;
    reg [1:0] stable_count;
    integer i;

    wire [15:0] magnitude = sample_in[15] ? (~sample_in + 16'd1) : sample_in;
    function signed [15:0] scale_sample;
        input signed [15:0] value; input [2:0] shift;
        reg signed [31:0] wide;
        begin
            wide = $signed(value) <<< shift;
            if (wide > 32767) scale_sample = 16'sh7fff;
            else if (wide < -32768) scale_sample = 16'sh8000;
            else scale_sample = wide[15:0];
        end
    endfunction
    function [2:0] target_shift;
        input [15:0] peak;
        begin
            if (peak >= 16384) target_shift=0;
            else if (peak >= 8192) target_shift=1;
            else if (peak >= 4096) target_shift=2;
            else if (peak >= 2048) target_shift=3;
            else if (peak >= 1024) target_shift=4;
            else if (peak >= 128) target_shift=5;
            else target_shift=0;
        end
    endfunction
    wire signed [15:0] x_scaled = scale_sample(sample_in, display_shift);
    wire signed [15:0] y_scaled = scale_sample(history[15], display_shift);
    wire [6:0] x_raw = x_scaled[15:9] ^ 7'h40;
    wire [6:0] y_raw = y_scaled[15:9] ^ 7'h40;
    wire [6:0] x_comp = x_raw - (x_raw >> 3);
    wire [6:0] y_comp = y_raw - (y_raw >> 3);
    wire [6:0] plot_x = x_comp > 111 ? 111 : x_comp;
    wire [6:0] plot_y = 111 - (y_comp > 111 ? 111 : y_comp);
    wire in_plot = pixel_x < 224 && pixel_y >= 8 && pixel_y < 232;
    wire [7:0] relative_y = pixel_y - 8;
    wire [13:0] pixel_addr = {relative_y[7:1], pixel_x[7:1]};
    wire [13:0] read_addr = scanning ? scan_pos : pixel_addr;
    wire [13:0] write_addr = clearing ? clear_pos : {plot_y,plot_x};
    wire write_enable = clearing || (!scanning && sample_en && history_count == 16);
    wire write_value = !clearing;
    assign pixel_on = display_valid && in_plot && (display_bank ? read1 : read0);

    // Each bank has a synchronous read and a synchronous write port.
    always @(posedge clk) begin
        read0 <= bank0[read_addr];
        read1 <= bank1[read_addr];
        if (write_enable && (init_clear || !write_bank)) bank0[write_addr] <= write_value;
        if (write_enable && (init_clear || write_bank)) bank1[write_addr] <= write_value;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            write_bank<=0; display_bank<=1; display_valid<=0;
            clearing<=1; init_clear<=1; clear_pos<=0;
            scanning<=0; scan_valid<=0; scan_pos<=0; scan_previous<=0; scan_last_issued<=0;
            dirty_ready<=0; dirty_bands<=0; history_count<=0;
            frame_peak<=0; display_shift<=0; pending_shift<=0; stable_count<=0;
            for (i=0;i<16;i=i+1) history[i]<=0;
        end else begin
            dirty_ready<=0;
            if (sample_en) begin
                history[0]<=sample_in;
                for (i=1;i<16;i=i+1) history[i]<=history[i-1];
                if (history_count<16) history_count<=history_count+1'b1;
                if (magnitude>frame_peak) frame_peak<=magnitude;
            end
            if (clearing) begin
                if (clear_pos==14'h3fff) begin clearing<=0; init_clear<=0; end
                else clear_pos<=clear_pos+1'b1;
            end else if (scanning) begin
                if (!scan_last_issued) begin
                    scan_previous<=scan_pos;
                    scan_valid<=1;
                    if (scan_pos==14'h3fff) scan_last_issued<=1;
                    else scan_pos<=scan_pos+1'b1;
                end else scan_valid<=0;
                if (scan_valid) begin
                    if (scan_previous[13:7]<112 && scan_previous[6:0]<112 && read0!=read1)
                        dirty_bands[scan_previous[13:10]]<=1'b1;
                    if (scan_previous==14'h3fff) begin
                        scanning<=0; display_bank<=write_bank; write_bank<=~write_bank;
                        display_valid<=1; clearing<=1; clear_pos<=0; dirty_ready<=1;
                    end
                end
            end else if (frame_start) begin
                dirty_bands<=display_valid ? 14'd0 : 14'h3fff;
                scan_pos<=0; scan_valid<=0; scan_last_issued<=0; scanning<=1;
                frame_peak<=0;
                if (target_shift(frame_peak)==display_shift) begin
                    pending_shift<=display_shift; stable_count<=0;
                end else if (target_shift(frame_peak)!=pending_shift) begin
                    pending_shift<=target_shift(frame_peak); stable_count<=1;
                end else if (stable_count==2) begin
                    if (pending_shift>display_shift) display_shift<=display_shift+1'b1;
                    else display_shift<=display_shift-1'b1;
                    stable_count<=0;
                end else stable_count<=stable_count+1'b1;
            end
        end
    end
endmodule
