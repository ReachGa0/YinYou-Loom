// ============================================================
// p5a_demo_top.v —— 四路保底按键上板演示顶层
//
// key_n[3:0] 低有效，分别映射到 C4/E4/G4/B4。
// 该顶层用于验证按键、声部分配和多声部输出，不替换正式顶层。
// ============================================================

module p5a_demo_top (
    input  wire       clk,
    input  wire [3:0] key_n,
    output wire       pa_en,
    output wire       i2s_bclk,
    output wire       i2s_lrck,
    output wire       i2s_din
);
    wire clk_sys;
    wire pll_lock;
    wire rst_n;
    wire bit_tick;
    wire sample_en;
    wire [3:0] pressed;
    wire [3:0] press_pulse;
    wire [3:0] release_pulse;
    wire note_on;
    wire note_off;
    wire [6:0] note_id;
    wire [31:0] note_inc;
    wire signed [15:0] mix_sample;
    wire scan_done;
    wire [3:0] voice_active;
    wire [3:0] voice_busy;

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

    key_scan #(
        .KEYS            (4),
        .DEBOUNCE_CYCLES (720000)  // 10 ms @ 72 MHz
    ) u_keys (
        .clk           (clk_sys),
        .rst_n         (rst_n),
        .key_n         (key_n),
        .pressed       (pressed),
        .press_pulse   (press_pulse),
        .release_pulse (release_pulse)
    );

    input_map #(
        .KEYS       (4),
        .PHASE_BITS (32),
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
        .VOICES        (4),
        .PHASE_BITS    (32),
        .ADDR_BITS     (12),
        .SAMPLE_W      (16),
        .LEVEL_W       (16),
        .NOTE_ID_W     (7),
        // 与 P3 单音同幅度的调试增益；四键齐按由 mixer 饱和限幅保护。
        .SUSTAIN_LEVEL (16'd32768),
        .INIT_FILE0    ("../../data/wavetables/sine_4096x16.hex"),
        .INIT_FILE1    ("../../data/wavetables/square_4096x16.hex")
    ) u_engine (
        .clk          (clk_sys),
        .rst_n        (rst_n),
        .sample_en    (sample_en),
        .table_sel    (2'd0),
        .bend_q15     (16'd32768),
        .velocity     (8'd255),
        .note_on      (note_on),
        .note_off     (note_off),
        .note_id      (note_id),
        .note_inc     (note_inc),
        .mix_sample   (mix_sample),
        .scan_done    (scan_done),
        .voice_active (voice_active),
        .voice_busy   (voice_busy)
    );

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
