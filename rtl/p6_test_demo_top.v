// ============================================================
// p6_test_demo_top.v —— P6 演示顶层
//   （独奏/和弦模式 + 音色 + 合唱 + 电平对比开关 + OLED + LED）
//
//   PIN28-PIN31 : 外接四键 C4/E4/G4/B4
//   PIN88 (S1)  : 切换音色 SINE / SQUARE
//   PIN87 (S2)  : 切换效果器 DRY / CHORUS
//   PIN27       : 模式开关：低 = 独奏 MONO（单音），高 = 和弦 CHORD（大三和弦）
//   PIN25       : 电平开关：低 = LO（约 −6dB），高 = HI（调试破音用）
//   PIN71/72    : 旧 OLED 的 I2C SCL/SDA
//   PIN51/54/55/56 : 功放使能与 I2S
//   PIN15-PIN20 : 板载 LED，低电平点亮
//
// LED：LED0 亮 = 和弦模式；LED1-4 = 对应按键按下；LED5 亮 = 合唱生效
// OLED：沿用 PATTERN_MODE=3 现有位布局（[1] 音色 [2] 效果 [5:3] 发声数），
//       本版不显示模式文字（模式看 LED0），文案调整留到下一版。
//
// 模式与音色都用"请求 + 延后生效"：按下即记录请求，等所有声部空闲（voice_busy == 0）
// 才真正切换。注意**不要**用 voice_busy 当阻断条件——ADSR 在 sustain 期间 busy 也为 1，
// 那样会导致"有音在响就永远切不动"（上一版踩过的坑）。
// ============================================================

module p6_test_demo_top (
    input  wire       clk,              // 27 MHz 板载晶振（PIN4）
    input  wire [3:0] key_n,            // 演奏键，低有效
    input  wire       key_timbre_n,     // 板载 S1，低有效
    input  wire       key_fx_n,         // 板载 S2，低有效
    input  wire       key_mode_n,       // PIN27：低 = 独奏，高 = 和弦
    input  wire       key_level_n,      // PIN25：低 = LO，高 = HI

    output wire       pa_en,
    output wire       i2s_bclk,
    output wire       i2s_lrck,
    output wire       i2s_din,
    output wire       oled_scl,
    inout  wire       oled_sda,
    output wire [5:0] led_n
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

    wire [0:0] mode_pressed;
    wire [0:0] mode_press_pulse;
    wire [0:0] mode_release_pulse;

    wire [0:0] lvl_pressed;
    wire [0:0] lvl_press_pulse;
    wire [0:0] lvl_release_pulse;

    // 独奏（单音）通路
    wire        mono_note_on;
    wire        mono_note_off;
    wire [6:0]  mono_note_id;
    wire [31:0] mono_note_inc;

    // 和弦通路
    wire        ch_note_on;
    wire        ch_note_off;
    wire [6:0]  ch_note_id;
    wire [31:0] ch_note_inc;
    wire [3:0]  chord_on;

    wire        note_on;
    wire        note_off;
    wire [6:0]  note_id;
    wire [31:0] note_inc;

    wire signed [15:0] mix_raw;
    wire signed [15:0] mix_sample;
    wire signed [15:0] fx_sample;
    wire               scan_done;
    wire [3:0]         voice_active;
    wire [3:0]         voice_busy;

    reg timbre_sel;      // 0=SINE, 1=SQUARE
    reg timbre_req;
    reg fx_bypass;       // 1=DRY, 0=CHORUS
    reg chord_sel;       // 0=MONO 独奏，1=CHORD 和弦
    reg chord_req;

    wire level_lo = ~lvl_pressed[0];   // 低电平 = LO（−6dB），立即生效便于对比

    wire [3:0] sounding = voice_active | voice_busy;
    reg  [2:0] voice_cnt;
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
        .DEBOUNCE_CYCLES (720000)      // 10 ms @ 72 MHz
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

    key_scan #(
        .KEYS            (1),
        .DEBOUNCE_CYCLES (720000)
    ) u_mode_key (
        .clk           (clk_sys),
        .rst_n         (rst_n),
        .key_n         (key_mode_n),
        .pressed       (mode_pressed),
        .press_pulse   (mode_press_pulse),
        .release_pulse (mode_release_pulse)
    );

    key_scan #(
        .KEYS            (1),
        .DEBOUNCE_CYCLES (720000)
    ) u_level_key (
        .clk           (clk_sys),
        .rst_n         (rst_n),
        .key_n         (key_level_n),
        .pressed       (lvl_pressed),
        .press_pulse   (lvl_press_pulse),
        .release_pulse (lvl_release_pulse)
    );

    // 模式 / 音色：请求 + 延后生效（空闲时才搬），避免按住音切换导致爆音或卡音
    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            timbre_sel <= 1'b0;
            timbre_req <= 1'b0;
            fx_bypass  <= 1'b1;
            chord_sel  <= 1'b1;      // 上电默认和弦模式
            chord_req  <= 1'b1;
        end else begin
            if (ctrl_press_pulse[0])
                timbre_req <= ~timbre_req;

            if (ctrl_press_pulse[1])
                fx_bypass <= ~fx_bypass;

            // PIN27：每按一次翻转"独奏/和弦"。
            // 用脉冲翻转而不是电平判定：轻触键点一下就能切换，不必一直按住；
            // 拨动开关也适用（拨一次产生一个按下脉冲 = 翻转一次）。
            if (mode_press_pulse[0])
                chord_req <= ~chord_req;

            if (voice_busy == 4'b0000) begin
                if (timbre_sel != timbre_req)
                    timbre_sel <= timbre_req;
                if (chord_sel != chord_req)
                    chord_sel <= chord_req;
            end
        end
    end

    input_map #(
        .KEYS       (4),
        .PHASE_BITS (32),
        .NOTE_ID_W  (7)
    ) u_mono (
        .key_press   (press_pulse),
        .key_release (release_pulse),
        .note_on     (mono_note_on),
        .note_off    (mono_note_off),
        .note_id     (mono_note_id),
        .note_inc    (mono_note_inc)
    );

    chord_map #(
        .KEYS (4)
    ) u_chord (
        .clk         (clk_sys),
        .rst_n       (rst_n),
        .key_press   (press_pulse),
        .key_release (release_pulse),
        .note_on     (ch_note_on),
        .note_off    (ch_note_off),
        .note_id     (ch_note_id),
        .note_inc    (ch_note_inc),
        .chord_on    (chord_on)
    );

    // 两条通路按模式选择（select 不依赖数据，避免综合器误判未使用）
    assign note_on  = chord_sel ? ch_note_on  : mono_note_on;
    assign note_off = chord_sel ? ch_note_off : mono_note_off;
    assign note_id  = chord_sel ? ch_note_id  : mono_note_id;
    assign note_inc = chord_sel ? ch_note_inc : mono_note_inc;

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
        .mix_sample   (mix_raw),
        .scan_done    (scan_done),
        .voice_active (voice_active),
        .voice_busy   (voice_busy)
    );

    // 电平开关：HI 原样，LO 右移一位（约 −6dB），用于判断破音是数字端还是模拟端
    assign mix_sample = level_lo ? (mix_raw >>> 1) : mix_raw;

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

    // 实时发声数（和弦模式下最多 3）
    always @* begin
        voice_cnt = 3'd0;
        for (i = 0; i < 4; i = i + 1)
            voice_cnt = voice_cnt + sounding[i];
    end

    // OLED：[0]=模式(0=ONE 独奏，1=TRI 和弦) [1]=音色 [2]=效果 [5:3]=发声数
    wire [5:0] oled_status = {voice_cnt, fx_bypass, timbre_sel, chord_sel};

    oled_sh1106 #(
        .CLK_HZ       (72_000_000),
        .SCL_HZ       (100_000),
        .POR_CYCLES   (72_000_000 / 5),
        .PATTERN_MODE (3)
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

    assign pa_en      = pll_lock;

    // LED0 亮 = 和弦模式；LED1-4 = 对应按键；LED5 亮 = 合唱生效
    assign led_n[0]   = ~chord_sel;
    assign led_n[4:1] = ~pressed;
    assign led_n[5]   = fx_bypass;
endmodule
