// ============================================================
// p4_demo_top.v —— 四声部和弦硬件验证顶层
//
// 上电后自动依次触发 C4/E4/G4/B4，四个声部持续发声。
// 该顶层只用于多声部上板验证，不替换正式 loom_top。
// ============================================================

module p4_demo_top (
    input  wire clk,
    output wire pa_en,
    output wire i2s_bclk,
    output wire i2s_lrck,
    output wire i2s_din
);
    // C4 / E4 / G4 / B4 @ 48kHz，32bit phase accumulator
    localparam [31:0] INC_C4 = 32'd23409859;
    localparam [31:0] INC_E4 = 32'd29494575;
    localparam [31:0] INC_G4 = 32'd35075158;
    localparam [31:0] INC_B4 = 32'd44191930;

    wire clk_sys;
    wire pll_lock;
    wire rst_n;
    wire bit_tick;
    wire sample_en;
    wire signed [15:0] mix_sample;
    wire scan_done;
    wire [3:0] voice_active;
    wire [3:0] voice_busy;

    reg        note_on;
    reg [6:0]  note_id;
    reg [31:0] note_inc;
    reg [17:0] delay_cnt;
    reg [3:0]  seq;

    Gowin_rPLL u_pll (
        .clkin  (clk),
        .reset  (1'b0),
        .clkout (clk_sys),
        .lock   (pll_lock)
    );

    sync_reset u_rst (
        .clk    (clk_sys),
        .arst_n (pll_lock),
        .rst_n  (rst_n)
    );

    frac_div #(
        .STEP (8),
        .DEN  (125)
    ) u_div (
        .clk   (clk_sys),
        .rst_n (rst_n),
        .tick  (bit_tick)
    );

    synth_engine #(
        .VOICES        (4),
        .PHASE_BITS    (32),
        .ADDR_BITS     (12),
        .SAMPLE_W      (16),
        .LEVEL_W       (16),
        .NOTE_ID_W     (7),
        .SUSTAIN_LEVEL (16'd8192),
        .INIT_FILE0    ("../../data/wavetables/sine_4096x16.hex"),
        .INIT_FILE1    ("../../data/wavetables/square_4096x16.hex")
    ) u_engine (
        .clk          (clk_sys),
        .rst_n        (rst_n),
        .sample_en    (sample_en),
        .table_sel    (2'd0),
        .bend_q15     (16'd32768),
        .velocity     (8'd255),
        .pluck        (1'b0),
        .note_on      (note_on),
        .note_off     (1'b0),
        .note_id      (note_id),
        .note_inc     (note_inc),
        .mix_sample   (mix_sample),
        .scan_done    (scan_done),
        .voice_active (voice_active),
        .voice_busy   (voice_busy)
    );

    // 上电后依次触发四个音符
    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            note_on  <= 1'b0;
            note_id  <= 7'd0;
            note_inc <= 32'd0;
            delay_cnt <= 18'd0;
            seq       <= 4'd0;
        end else begin
            note_on <= 1'b0;
            case (seq)
                4'd0: if (delay_cnt == 18'd2000) begin
                    delay_cnt <= 18'd0;
                    seq       <= 4'd1;
                end else
                    delay_cnt <= delay_cnt + 1'b1;
                4'd1: begin
                    note_on  <= 1'b1;
                    note_id  <= 7'd60;
                    note_inc <= INC_C4;
                    seq      <= 4'd2;
                end
                4'd2: if (delay_cnt == 18'd200) begin
                    delay_cnt <= 18'd0;
                    seq       <= 4'd3;
                end else
                    delay_cnt <= delay_cnt + 1'b1;
                4'd3: begin
                    note_on  <= 1'b1;
                    note_id  <= 7'd64;
                    note_inc <= INC_E4;
                    seq      <= 4'd4;
                end
                4'd4: if (delay_cnt == 18'd200) begin
                    delay_cnt <= 18'd0;
                    seq       <= 4'd5;
                end else
                    delay_cnt <= delay_cnt + 1'b1;
                4'd5: begin
                    note_on  <= 1'b1;
                    note_id  <= 7'd67;
                    note_inc <= INC_G4;
                    seq      <= 4'd6;
                end
                4'd6: if (delay_cnt == 18'd200) begin
                    delay_cnt <= 18'd0;
                    seq       <= 4'd7;
                end else
                    delay_cnt <= delay_cnt + 1'b1;
                4'd7: begin
                    note_on  <= 1'b1;
                    note_id  <= 7'd71;
                    note_inc <= INC_B4;
                    seq      <= 4'd8;
                end
                default: begin
                    note_on <= 1'b0;
                end
            endcase
        end
    end

    i2s_tx u_i2s (
        .clk        (clk_sys),
        .rst_n      (rst_n),
        .bit_tick   (bit_tick),
        .sample_in  (mix_sample),
        .bclk       (i2s_bclk),
        .lrclk      (i2s_lrck),
        .sdata      (i2s_din),
        .sample_req (sample_en)
    );

    assign pa_en = 1'b1;
endmodule
