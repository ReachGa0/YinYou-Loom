// ============================================================
// p6_test_demo_top.v —— P6 演示顶层（和弦模式 + 音色 + 合唱 + OLED）
//
//   PIN28-PIN31 : 外接四键，按下即发一个大三和弦（根音 + 大三度 + 纯五度）
//   PIN88 (S1)  : 切换音色 SINE / SQUARE（请求式：完全空闲后自动生效）
//   PIN87 (S2)  : 切换效果器 DRY / CHORUS
//   PIN71/72    : 旧 OLED 的 I2C SCL/SDA
//   PIN51/54/55/56 : 功放使能与 I2S
//   PIN15-PIN20 : 板载 LED，低电平点亮
//
// LED：LED0 亮 = 方波音色；LED1-4 = 对应按键按下；LED5 亮 = 合唱生效
// OLED（PATTERN_MODE=3）：第 1 行 PERF MODE、第 2 行实时发声数、
//   第 3 行音色 + 效果器。
//
// 测试模式已从本演示中移除（按用户要求改成和弦模式）。test_mode.v 仍保留在
// 仓库里，作为后续 P6 现场数峰的独立位流使用。
// ============================================================

module p6_test_demo_top (
    input  wire       clk,              // 27 MHz 板载晶振（PIN4）
    input  wire [3:0] key_n,            // 演奏键，低有效
    input  wire       key_timbre_n,     // 板载 S1，低有效
    input  wire       key_fx_n,         // 板载 S2，低有效

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

    wire        note_on;
    wire        note_off;
    wire [6:0]  note_id;
    wire [31:0] note_inc;
    wire [3:0]  chord_on;

    wire signed [15:0] mix_sample;
    wire signed [15:0] fx_sample;
    wire               scan_done;
    wire [3:0]         voice_active;
    wire [3:0]         voice_busy;

    reg timbre_sel;      // 0=SINE, 1=SQUARE
    reg timbre_req;      // 请求值：空闲时才搬进 timbre_sel
    reg fx_bypass;       // 1=DRY, 0=CHORUS

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

    // 音色切换用"请求 + 延后生效"：什么时候按都行，等所有声部空闲后自动搬过去。
    // 既不会因为按住音切音色产生爆音，也不会像旧版本那样"按了没反应"。
    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            timbre_sel <= 1'b0;
            timbre_req <= 1'b0;
            fx_bypass  <= 1'b1;
        end else begin
            if (ctrl_press_pulse[0])
                timbre_req <= ~timbre_req;

            if (ctrl_press_pulse[1])
                fx_bypass <= ~fx_bypass;

            if ((voice_busy == 4'b0000) && (timbre_sel != timbre_req))
                timbre_sel <= timbre_req;
        end
    end

    chord_map #(
        .KEYS (4)
    ) u_chord (
        .clk         (clk_sys),
        .rst_n       (rst_n),
        .key_press   (press_pulse),
        .key_release (release_pulse),
        .note_on     (note_on),
        .note_off    (note_off),
        .note_id     (note_id),
        .note_inc    (note_inc),
        .chord_on    (chord_on)
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

    // 实时发声数：gate 或释放尾音未结束都算在响
    always @* begin
        voice_cnt = 3'd0;
        for (i = 0; i < 4; i = i + 1)
            voice_cnt = voice_cnt + sounding[i];
    end

    // OLED 状态页（PATTERN_MODE=3）：[0]=0（无测试模式）[1] 音色 [2] 效果器 [5:3] 发声数
    wire [5:0] oled_status = {voice_cnt, fx_bypass, timbre_sel, 1'b0};

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

    // LED0 = 方波音色；LED1-4 = 对应按键；LED5 = 合唱生效
    assign led_n[0]   = ~timbre_sel;
    assign led_n[4:1] = ~pressed;
    assign led_n[5]   = fx_bypass;
endmodule
