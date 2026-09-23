// ============================================================
// timbre_fx_demo_top.v —— 音色 / 合唱 / 旧 OLED 状态页联合演示
//
//   PIN28-PIN31 : 外接四键，C4/E4/G4/B4
//   PIN88 (S1)  : 静音时切换 SINE / SQUARE
//   PIN87 (S2)  : 切换 DRY / CHORUS
//   PIN71/72    : 旧 OLED 的 I2C SCL/SDA
// ============================================================

module timbre_fx_demo_top (
    input  wire       clk,              // 板载 27MHz
    input  wire [3:0] key_n,            // C4/E4/G4/B4，低有效
    input  wire       key_timbre_n,     // 板载 S1，低有效
    input  wire       key_fx_n,         // 板载 S2，低有效

    output wire       pa_en,
    output wire       i2s_bclk,
    output wire       i2s_lrck,
    output wire       i2s_din,

    output wire       oled_scl,
    inout  wire       oled_sda,
    output wire [5:0] led_n             // 低电平点亮
);
    wire clk_sys;
    wire pll_lock;
    wire rst_n;
    wire bit_tick;
    wire sample_en;

    wire [3:0] pressed;
    wire [3:0] press_pulse;
    wire [3:0] release_pulse;
    wire [1:0] ctrl_pressed;
    wire [1:0] ctrl_press_pulse;
    wire [1:0] ctrl_release_pulse;

    wire note_on;
    wire note_off;
    wire [6:0] note_id;
    wire [31:0] note_inc;

    wire signed [15:0] mix_sample;
    wire signed [15:0] fx_sample;
    wire scan_done;
    wire [3:0] voice_active;
    wire [3:0] voice_busy;

    reg timbre_sel;       // 0=SINE, 1=SQUARE
    reg fx_bypass;        // 1=DRY, 0=CHORUS
    reg [2:0] pressed_count;
    integer i;

    wire [1:0] ctrl_key_n = {key_fx_n, key_timbre_n};

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
        .DEBOUNCE_CYCLES (720000)
    ) u_keys (
        .clk           (clk_sys),
        .rst_n         (rst_n),
        .key_n         (key_n),
        .pressed       (pressed),
        .press_pulse   (press_pulse),
        .release_pulse (release_pulse)
    );

    key_scan #(
        .KEYS            (2),
        .DEBOUNCE_CYCLES (720000)
    ) u_ctrl_keys (
        .clk           (clk_sys),
        .rst_n         (rst_n),
        .key_n         (ctrl_key_n),
        .pressed       (ctrl_pressed),
        .press_pulse   (ctrl_press_pulse),
        .release_pulse (ctrl_release_pulse)
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
        .SUSTAIN_LEVEL (16'd32768),
        .INIT_FILE0    ("../../data/wavetables/sine_4096x16.hex"),
        .INIT_FILE1    ("../../data/wavetables/square_4096x16.hex")
    ) u_engine (
        .clk          (clk_sys),
        .rst_n        (rst_n),
        .sample_en    (sample_en),
        .table_sel    (timbre_sel),
        .note_on      (note_on),
        .note_off     (note_off),
        .note_id      (note_id),
        .note_inc     (note_inc),
        .mix_sample   (mix_sample),
        .scan_done    (scan_done),
        .voice_active (voice_active),
        .voice_busy   (voice_busy)
    );

    chorus #(
        .SAMPLE_W  (16),
        .ADDR_W    (11),
        .MIN_DELAY (512),
        .LFO_STEP  (24'd128)
    ) u_chorus (
        .clk              (clk_sys),
        .rst_n            (rst_n),
        .sample_en        (sample_en),
        .bypass           (fx_bypass),
        .sample_in        (mix_sample),
        .sample_out       (fx_sample),
        .sample_valid_out ()
    );

    i2s_tx u_i2s (
        .clk        (clk_sys),
        .rst_n      (rst_n),
        .bit_tick   (bit_tick),
        .sample_in  (fx_sample),
        .bclk       (i2s_bclk),
        .lrclk      (i2s_lrck),
        .sdata      (i2s_din),
        .sample_req (sample_en)
    );

    // S1 只在完全没有按键、也没有尾音时切换波表，避免切换瞬间产生爆音。
    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            timbre_sel <= 1'b0;
            fx_bypass  <= 1'b1;
        end else begin
            if (ctrl_press_pulse[0] && (pressed == 4'b0000) &&
                (voice_busy == 4'b0000))
                timbre_sel <= ~timbre_sel;

            if (ctrl_press_pulse[1])
                fx_bypass <= ~fx_bypass;
        end
    end

    always @* begin
        pressed_count = 3'd0;
        for (i = 0; i < 4; i = i + 1)
            pressed_count = pressed_count + pressed[i];
    end

    wire [5:0] oled_status = {pressed_count, fx_bypass, timbre_sel};

    oled_sh1106 #(
        .CLK_HZ       (72_000_000),
        .SCL_HZ       (100_000),
        .POR_CYCLES   (72_000_000 / 5),
        .PATTERN_MODE (2)
    ) u_oled (
        .clk            (clk_sys),
        .rst_n          (rst_n),
        .ssd1306_mode   (1'b0),
        .indicator_bits (oled_status),
        .scl            (oled_scl),
        .sda            (oled_sda),
        .dbg_phase      (),
        .dbg_ack_seen   ()
    );

    assign led_n[3:0] = ~pressed;
    assign led_n[4]   = ~fx_bypass;  // 亮 = 合唱生效
    assign led_n[5]   = ~timbre_sel; // 亮 = 方波音色
    assign pa_en      = pll_lock;
endmodule
