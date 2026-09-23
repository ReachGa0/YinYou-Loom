`timescale 1ns/1ps

// Verifies the PATTERN_MODE=2 status page byte-for-byte. The testbench keeps
// its own font and string decoder so it catches wiring, page and glyph errors.
module tb_oled_status;
    parameter integer COUNT   = 3;
    parameter integer TIMBRE  = 1;
    parameter integer BYPASS  = 0;

    localparam [2:0] COUNT_BITS = COUNT;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    wire scl;
    wire sda;
    wire [1:0] dbg_phase;
    wire       dbg_ack_seen;
    wire [5:0] indicator_bits = {COUNT_BITS, BYPASS[0], TIMBRE[0]};

    always #5 clk = ~clk;
    pullup(sda);

    oled_sh1106 #(
        .CLK_HZ       (100_000_000),
        .SCL_HZ       (10_000_000),
        .POR_CYCLES   (100),
        .PATTERN_MODE (2)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .ssd1306_mode   (1'b0),
        .indicator_bits (indicator_bits),
        .scl            (scl),
        .sda            (sda),
        .dbg_phase      (dbg_phase),
        .dbg_ack_seen   (dbg_ack_seen)
    );

    wire       trans_end, addr_match;
    wire [7:0] rx_addr, rx_ctrl, rx_payload, nbytes;

    i2c_slave_model #(.ADDR(8'h78)) slave (
        .clk        (clk),
        .rst_n      (rst_n),
        .scl        (scl),
        .sda        (sda),
        .trans_end  (trans_end),
        .addr_match (addr_match),
        .rx_addr    (rx_addr),
        .rx_ctrl    (rx_ctrl),
        .rx_payload (rx_payload),
        .nbytes     (nbytes)
    );

    reg [7:0] log_data [0:4095];
    integer tx_idx = 0;
    reg saw_af = 1'b0;

    always @(posedge clk) begin
        if (trans_end) begin
            if (tx_idx < 4096)
                log_data[tx_idx] <= rx_payload;
            if (rx_payload == 8'hAF)
                saw_af <= 1'b1;
            tx_idx <= tx_idx + 1;
        end
    end

    function [7:0] frame_byte;
        input integer page;
        input integer col;
        integer idx;
        begin
            idx = 29 + page * 131 + col;
            frame_byte = (idx < 4096) ? log_data[idx] : 8'hxx;
        end
    endfunction

    function [7:0] ref_char;
        input [2:0] line;
        input [4:0] pos;
        begin
            ref_char = 8'h20;
            case (line)
                3'd0: case (pos)
                    4'd0: ref_char = 8'h54; // T
                    4'd1: ref_char = 8'h49; // I
                    4'd2: ref_char = 8'h4D; // M
                    4'd3: ref_char = 8'h42; // B
                    4'd4: ref_char = 8'h52; // R
                    4'd5: ref_char = 8'h45; // E
                    4'd6: ref_char = 8'h20;
                    4'd7: ref_char = 8'h53; // S
                    4'd8: ref_char = TIMBRE ? 8'h51 : 8'h49; // Q / I
                    4'd9: ref_char = TIMBRE ? 8'h55 : 8'h4E; // U / N
                    4'd10: ref_char = TIMBRE ? 8'h41 : 8'h45; // A / E
                    4'd11: ref_char = TIMBRE ? 8'h52 : 8'h20; // R / space
                    4'd12: ref_char = TIMBRE ? 8'h45 : 8'h20; // E / space
                    default: ref_char = 8'h20;
                endcase
                3'd2: case (pos)
                    4'd0: ref_char = 8'h46; // F
                    4'd1: ref_char = 8'h58; // X
                    4'd2: ref_char = 8'h20;
                    4'd3: ref_char = BYPASS ? 8'h44 : 8'h43; // D / C
                    4'd4: ref_char = BYPASS ? 8'h52 : 8'h48; // R / H
                    4'd5: ref_char = BYPASS ? 8'h59 : 8'h4F; // Y / O
                    4'd6: ref_char = BYPASS ? 8'h20 : 8'h52; // space / R
                    4'd7: ref_char = BYPASS ? 8'h20 : 8'h55; // space / U
                    4'd8: ref_char = BYPASS ? 8'h20 : 8'h53; // space / S
                    default: ref_char = 8'h20;
                endcase
                3'd4: case (pos)
                    4'd0: ref_char = 8'h56; // V
                    4'd1: ref_char = 8'h4F; // O
                    4'd2: ref_char = 8'h49; // I
                    4'd3: ref_char = 8'h43; // C
                    4'd4: ref_char = 8'h45; // E
                    4'd5: ref_char = 8'h20;
                    4'd6: ref_char = 8'h30 + COUNT_BITS;
                    4'd7: ref_char = 8'h2F; // /
                    4'd8: ref_char = 8'h34; // 4
                    default: ref_char = 8'h20;
                endcase
                default: ref_char = 8'h20;
            endcase
        end
    endfunction

    function [6:0] ref_glyph;
        input [7:0] ch;
        input [2:0] col;
        begin
            case (ch)
                8'h41: case (col) 0:ref_glyph=7'h7E; 1:ref_glyph=7'h11; 2:ref_glyph=7'h11; 3:ref_glyph=7'h11; default:ref_glyph=7'h7E; endcase // A
                8'h42: case (col) 0:ref_glyph=7'h7F; 1:ref_glyph=7'h49; 2:ref_glyph=7'h49; 3:ref_glyph=7'h49; default:ref_glyph=7'h36; endcase // B
                8'h43: case (col) 0:ref_glyph=7'h3E; 1:ref_glyph=7'h41; 2:ref_glyph=7'h41; 3:ref_glyph=7'h41; default:ref_glyph=7'h22; endcase // C
                8'h44: case (col) 0:ref_glyph=7'h7F; 1:ref_glyph=7'h41; 2:ref_glyph=7'h41; 3:ref_glyph=7'h22; default:ref_glyph=7'h1C; endcase // D
                8'h45: case (col) 0:ref_glyph=7'h7F; 1:ref_glyph=7'h49; 2:ref_glyph=7'h49; 3:ref_glyph=7'h49; default:ref_glyph=7'h41; endcase // E
                8'h46: case (col) 0:ref_glyph=7'h7F; 1:ref_glyph=7'h09; 2:ref_glyph=7'h09; 3:ref_glyph=7'h09; default:ref_glyph=7'h01; endcase // F
                8'h48: case (col) 0:ref_glyph=7'h7F; 1:ref_glyph=7'h08; 2:ref_glyph=7'h08; 3:ref_glyph=7'h08; default:ref_glyph=7'h7F; endcase // H
                8'h49: case (col) 0:ref_glyph=7'h00; 1:ref_glyph=7'h41; 2:ref_glyph=7'h7F; 3:ref_glyph=7'h41; default:ref_glyph=7'h00; endcase // I
                8'h4D: case (col) 0:ref_glyph=7'h7F; 1:ref_glyph=7'h02; 2:ref_glyph=7'h0C; 3:ref_glyph=7'h02; default:ref_glyph=7'h7F; endcase // M
                8'h4E: case (col) 0:ref_glyph=7'h7F; 1:ref_glyph=7'h04; 2:ref_glyph=7'h08; 3:ref_glyph=7'h10; default:ref_glyph=7'h7F; endcase // N
                8'h4F: case (col) 0:ref_glyph=7'h3E; 1:ref_glyph=7'h41; 2:ref_glyph=7'h41; 3:ref_glyph=7'h41; default:ref_glyph=7'h3E; endcase // O
                8'h51: case (col) 0:ref_glyph=7'h3E; 1:ref_glyph=7'h41; 2:ref_glyph=7'h51; 3:ref_glyph=7'h21; default:ref_glyph=7'h5E; endcase // Q
                8'h52: case (col) 0:ref_glyph=7'h7F; 1:ref_glyph=7'h09; 2:ref_glyph=7'h19; 3:ref_glyph=7'h29; default:ref_glyph=7'h46; endcase // R
                8'h53: case (col) 0:ref_glyph=7'h46; 1:ref_glyph=7'h49; 2:ref_glyph=7'h49; 3:ref_glyph=7'h49; default:ref_glyph=7'h31; endcase // S
                8'h54: case (col) 0:ref_glyph=7'h01; 1:ref_glyph=7'h01; 2:ref_glyph=7'h7F; 3:ref_glyph=7'h01; default:ref_glyph=7'h01; endcase // T
                8'h55: case (col) 0:ref_glyph=7'h3F; 1:ref_glyph=7'h40; 2:ref_glyph=7'h40; 3:ref_glyph=7'h40; default:ref_glyph=7'h3F; endcase // U
                8'h56: case (col) 0:ref_glyph=7'h1F; 1:ref_glyph=7'h20; 2:ref_glyph=7'h40; 3:ref_glyph=7'h20; default:ref_glyph=7'h1F; endcase // V
                8'h58: case (col) 0:ref_glyph=7'h63; 1:ref_glyph=7'h14; 2:ref_glyph=7'h08; 3:ref_glyph=7'h14; default:ref_glyph=7'h63; endcase // X
                8'h59: case (col) 0:ref_glyph=7'h07; 1:ref_glyph=7'h08; 2:ref_glyph=7'h70; 3:ref_glyph=7'h08; default:ref_glyph=7'h07; endcase // Y
                8'h30: case (col) 0:ref_glyph=7'h3E; 1:ref_glyph=7'h51; 2:ref_glyph=7'h49; 3:ref_glyph=7'h45; default:ref_glyph=7'h3E; endcase // 0
                8'h31: case (col) 0:ref_glyph=7'h00; 1:ref_glyph=7'h42; 2:ref_glyph=7'h7F; 3:ref_glyph=7'h40; default:ref_glyph=7'h00; endcase // 1
                8'h32: case (col) 0:ref_glyph=7'h42; 1:ref_glyph=7'h61; 2:ref_glyph=7'h51; 3:ref_glyph=7'h49; default:ref_glyph=7'h46; endcase // 2
                8'h33: case (col) 0:ref_glyph=7'h21; 1:ref_glyph=7'h41; 2:ref_glyph=7'h45; 3:ref_glyph=7'h4B; default:ref_glyph=7'h31; endcase // 3
                8'h34: case (col) 0:ref_glyph=7'h18; 1:ref_glyph=7'h14; 2:ref_glyph=7'h12; 3:ref_glyph=7'h7F; default:ref_glyph=7'h10; endcase // 4
                8'h2F: case (col) 0:ref_glyph=7'h20; 1:ref_glyph=7'h10; 2:ref_glyph=7'h08; 3:ref_glyph=7'h04; default:ref_glyph=7'h02; endcase // /
                default: ref_glyph = 7'h00;
            endcase
        end
    endfunction

    integer page, col, char_col, char_pos;
    integer failures = 0;
    integer first_fail = 1;
    reg [7:0] expected;
    reg [7:0] actual;
    reg [6:0] glyph;

    initial begin
        rst_n = 1'b0;
        #200;
        rst_n = 1'b1;

        while (!saw_af && $time < 100_000_000) #1000;
        #5000;

        for (page = 0; page < 8; page = page + 1) begin
            for (col = 0; col < 128; col = col + 1) begin
                expected = 8'h00;
                if ((page == 0 || page == 2 || page == 4) && col >= 4) begin
                    char_col = (col - 4) % 6;
                    char_pos = (col - 4) / 6;
                    if (char_col < 5) begin
                        glyph = ref_glyph(ref_char(page[2:0], char_pos[4:0]), char_col[2:0]);
                        expected = {1'b0, glyph};
                    end
                end

                actual = frame_byte(page, col);
                if (actual !== expected) begin
                    failures = failures + 1;
                    if (first_fail) begin
                        $display("FAIL: page=%0d col=%0d expected=0x%02X actual=0x%02X",
                                 page, col, expected, actual);
                        first_fail = 0;
                    end
                end
            end
        end

        $display("");
        $display("STATUS COUNT=%0d TIMBRE=%0d BYPASS=%0d", COUNT, TIMBRE, BYPASS);
        $display("PASS=%0d FAIL=%0d", 1024 - failures, failures);
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
