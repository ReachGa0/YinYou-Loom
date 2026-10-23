// ============================================================
// p6_test_demo_top.v —— P6 演示顶层
//   （独奏/和弦模式 + 音色 + 合唱 + 电平对比开关 + OLED + LED）
//
//   PIN28/29/30/31 + PIN77/85/86 : 外接七键 C4/D4/E4/F4/G4/A4/B4
//   PIN88 (S1)  : 切换音色 SINE / SQUARE
//   PIN87 (S2)  : 切换效果器 DRY / CHORUS
//   PIN27       : 模式开关：低 = 独奏 MONO（单音），高 = 和弦 CHORD（大三和弦）
//   PIN25       : 电平开关：低 = LO（约 −6dB），高 = HI（调试破音用）
//   PIN71-76    : 2.4 寸 ST7789 TFT（SCLK/MOSI/CS/DC/RES/BLK），横屏 UI
//   PIN51/54/55/56 : 功放使能与 I2S
//   PIN15-PIN20 : 板载 LED，低电平点亮
//
// LED（2026-10-17 起优先显示七键）：LED0-4 = K1-K5 按下；LED5 = K6 或 K7 按下。
//       模式 / 音色 / 效果器状态改由 TFT 的三列显示。
// 显示：改由 rtl/display/ui_render.v 渲染横屏 UI（表头/三列选项/选中反白/波形动画/调式占位），
//       屏参（MADCTL/反显/SCLK）与接线见 docs/22；旧 I2C OLED 在本工程退休。
//
// 模式与音色都用"请求 + 延后生效"：按下即记录请求，等所有声部空闲（voice_busy == 0）
// 才真正切换。注意**不要**用 voice_busy 当阻断条件——ADSR 在 sustain 期间 busy 也为 1，
// 那样会导致"有音在响就永远切不动"（上一版踩过的坑）。
// ============================================================

module p6_test_demo_top (
    input  wire       clk,              // 27 MHz 板载晶振（PIN4）
    input  wire [6:0] key_n,            // 七个演奏键，低有效
    input  wire       key_timbre_n,     // 板载 S1，低有效
    input  wire       key_fx_n,         // 板载 S2，低有效
    input  wire       key_mode_n,       // PIN27：低 = 独奏，高 = 和弦
    input  wire       key_level_n,      // PIN25：低 = LO，高 = HI

    // 摇杆（HW-504）：RC 测时，不用 ADC 芯片
    inout  wire       joy_x,            // PIN48
    inout  wire       joy_y,            // PIN49

    output wire       pa_en,
    output wire       i2s_bclk,
    output wire       i2s_lrck,
    output wire       i2s_din,
    // 2.4 寸 ST7789 TFT（横屏 UI，见 docs/22）：PIN71-76
    // 旧 1.3 寸 I2C OLED 在本工程退休（模块文件保留，其它工程仍可用）
    output wire       tft_sclk,
    output wire       tft_mosi,
    output wire       tft_cs_n,
    output wire       tft_dc,
    output wire       tft_res_n,
    output wire       tft_blk,
    output wire [5:0] led_n
);
    wire clk_sys;
    wire pll_lock;
    wire rst_n;
    wire bit_tick;
    wire sample_en;

    wire [6:0] pressed;
    wire [6:0] press_pulse;
    wire [6:0] release_pulse;

    // ---------------- 摇杆 RC 采集（Pitch Bend）----------------
    wire [15:0] joyx_code, joyy_code;
    wire        joyx_valid, joyy_valid, joyx_fault, joyy_fault;
    wire [15:0] bend_q15;
    reg  signed [16:0] joyx_filt, joyy_filt;   // 一阶低通后的平滑值

    // 开机自动对中：上电后采 64 次 X 轴取平均当零点（此时摇杆应回中）
    reg [21:0] cal_sum;
    reg [6:0]  cal_cnt;
    reg [15:0] center_code;
    reg        cal_done;
    reg [11:0] settle_cnt;      // 开机后 2000 次采样内做慢速零点收敛（约 2 秒）

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            cal_sum     <= 22'd0;
            cal_cnt     <= 7'd0;
            center_code <= 16'd7845;
            cal_done    <= 1'b0;
            settle_cnt  <= 12'd0;
        end else if (!cal_done && joyx_valid && !joyx_fault) begin
            if (cal_cnt == 7'd63) begin
                center_code <= (cal_sum + {6'b0, joyx_code}) >> 6;
                cal_done    <= 1'b1;
            end else begin
                cal_sum <= cal_sum + {6'b0, joyx_code};
                cal_cnt <= cal_cnt + 1'b1;
            end
        // 开机后 2 秒内、没人按键时，让零点慢慢追上摇杆的真实静止位置
        end else if (cal_done && (settle_cnt < 12'd2000) &&
                     joyx_valid && !joyx_fault && (pressed == 7'd0)) begin
            settle_cnt <= settle_cnt + 1'b1;
            if (joyx_code > center_code + 16'd2)
                center_code <= center_code + 1'b1;
            else if (joyx_code + 16'd2 < center_code)
                center_code <= center_code - 1'b1;
        end
    end

    // Y 轴同样自动对中（用于力度）
    reg [21:0] cal_sum_y;
    reg [6:0]  cal_cnt_y;
    reg [15:0] center_y;
    reg        cal_done_y;
    reg [11:0] settle_cnt_y;

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            cal_sum_y    <= 22'd0;
            cal_cnt_y    <= 7'd0;
            center_y     <= 16'd7845;
            cal_done_y   <= 1'b0;
            settle_cnt_y <= 12'd0;
        end else if (!cal_done_y && joyy_valid && !joyy_fault) begin
            if (cal_cnt_y == 7'd63) begin
                center_y   <= (cal_sum_y + {6'b0, joyy_code}) >> 6;
                cal_done_y <= 1'b1;
            end else begin
                cal_sum_y <= cal_sum_y + {6'b0, joyy_code};
                cal_cnt_y <= cal_cnt_y + 1'b1;
            end
        end else if (cal_done_y && (settle_cnt_y < 12'd2000) &&
                     joyy_valid && !joyy_fault && (pressed == 7'd0)) begin
            settle_cnt_y <= settle_cnt_y + 1'b1;
            if (joyy_code > center_y + 16'd2)
                center_y <= center_y + 1'b1;
            else if (joyy_code + 16'd2 < center_y)
                center_y <= center_y - 1'b1;
        end
    end

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
    wire [6:0]  chord_on;

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

    reg [1:0] timbre_sel;   // 0=SINE 1=SQUARE 2=SAW 3=TRIANGLE
    reg [1:0] timbre_req;
    reg [1:0] fx_mode;      // 0=DRY 1=CHORUS 2=VIBRATO 3=TREMOLO
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
        .KEYS            (7),
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

    // 摇杆两轴：引脚推低放电 → 释放 → 数到输入变高
    rc_adc u_joy_x (
        .clk   (clk_sys),
        .rst_n (rst_n),
        .pin   (joy_x),
        .code  (joyx_code),
        .valid (joyx_valid),
        .fault (joyx_fault)
    );

    rc_adc u_joy_y (
        .clk   (clk_sys),
        .rst_n (rst_n),
        .pin   (joy_y),
        .code  (joyy_code),
        .valid (joyy_valid),
        .fault (joyy_fault)
    );

    // 一阶低通：y += (x - y)/8（约 8ms 时间常数，弯音仍然跟手）
    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            joyx_filt <= 17'sd0;
            joyy_filt <= 17'sd0;
        end else begin
            if (joyx_valid && !joyx_fault)
                joyx_filt <= joyx_filt +
                             (($signed({1'b0, joyx_code}) - joyx_filt) >>> 3);
            if (joyy_valid && !joyy_fault)
                joyy_filt <= joyy_filt +
                             (($signed({1'b0, joyy_code}) - joyy_filt) >>> 3);
        end
    end

    // Y 轴 → 力度 0..255（中位 128，推到两端接近 0/255）
    // dy > 0：电压更高（code 更小）方向
    wire signed [17:0] dy      = $signed({2'b00, center_y}) - $signed({2'b00, joyy_filt[15:0]});
    wire        [17:0] dy_mag  = dy[17] ? (~dy + 18'd1) : dy;
    wire        [17:0] dy_eff  = (dy_mag > 18'd150) ? (dy_mag - 18'd150) : 18'd0;
    // 减小方向保持 41；增大方向放大到 70（原来 27 太小，听不出"变响"）
    wire        [17:0] vel_off = dy[17] ? ((dy_eff * 18'd41) >> 8)
                                        : ((dy_eff * 18'd70) >> 8);
    // 一个方向加、另一个方向减（原来两边都在加，所以听不出力度差）
    wire signed [9:0]  vel_tmp = dy[17]
                                 ? (10'sd128 - $signed({2'b0, vel_off[7:0]}))
                                 : (10'sd128 + $signed({2'b0, vel_off[7:0]}));
    wire        [7:0]  vel_calc = (vel_tmp < 0)   ? 8'd0 :
                                  (vel_tmp > 255) ? 8'd255 : vel_tmp[7:0];

    // X 轴 → 音高弯音（±2 半音）
    pitch_bend_map u_bend (
        .clk      (clk_sys),
        .rst_n    (rst_n),
        .code     (joyx_filt[15:0]),
        .center_code (center_code),
        .valid    (joyx_valid),
        .fault    (joyx_fault),
        .bend_q15 (bend_q15)
    );

    // 模式 / 音色：请求 + 延后生效（空闲时才搬），避免按住音切换导致爆音或卡音
    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            timbre_sel <= 2'd0;
            timbre_req <= 2'd0;
            fx_mode    <= 2'd0;
            chord_sel  <= 1'b1;      // 上电默认和弦模式
            chord_req  <= 1'b1;
        end else begin
            if (ctrl_press_pulse[0])
                timbre_req <= timbre_req + 2'd1;      // SINE→SQUARE→SAW→TRI 循环

            if (ctrl_press_pulse[1])
                fx_mode <= fx_mode + 2'd1;            // DRY→CHORUS→VIBRATO→TREMOLO 循环

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
        .KEYS       (7),
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
        .KEYS (7)
    ) u_chord (
        .clk         (clk_sys),
        .rst_n       (rst_n),
        .enable      (chord_sel),        // 独奏模式下强制空闲
        .pressed     (pressed),          // 按键电平（最近按下优先）
        .voice_busy  (voice_busy),       // 等尾音收完再起新和弦
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
        // 2026-10-17 用户要求"正弦再响一些"：Sustain 0.5 → 1.0（+6 dB）。
        // 起音本来就已经到满幅，所以不会削顶；混音器按发声数归一化，多声部也安全。
        .SUSTAIN_LEVEL (16'd65535),
        .INIT_FILE0    ("../../data/wavetables/sine_4096x16.hex"),
        .INIT_FILE1    ("../../data/wavetables/square_4096x16.hex"),
        .INIT_FILE2    ("../../data/wavetables/saw_4096x16.hex"),
        .INIT_FILE3    ("../../data/wavetables/triangle_4096x16.hex")
    ) u_engine (
        .clk          (clk_sys),
        .rst_n        (rst_n),
        .sample_en    (sample_en),
        .table_sel    (timbre_sel),
        .bend_q15     (bend_q15),
        // 力度改为"持续表情"（混音后增益），单声部锁存力度固定为满
        .velocity     (8'd255),
        .note_on      (note_on),
        .note_off     (note_off),
        .note_id      (note_id),
        .note_inc     (note_inc),
        .mix_sample   (mix_raw),
        .scan_done    (scan_done),
        .voice_active (voice_active),
        .voice_busy   (voice_busy)
    );

    // 四音色的听感平衡（按 RMS + 亮度实测的粗略补偿）：
    //   SINE/TRI 1.0，SQUARE 0.5（谐波集中在 1~4kHz，听感偏冲），SAW 0.75。
    wire signed [15:0] timbre_trim =
        (timbre_sel == 2'd1) ? (mix_raw >>> 1) :
        (timbre_sel == 2'd2) ? (mix_raw - (mix_raw >>> 2)) :
        mix_raw;

    // 持续表情：Y 轴实时控制整体音量（0.25 ~ 1.0，约 12dB）
    // 按住音时推摇杆也能听到变化；按下瞬间的音量也由当时位置决定。
    // 中心约 0.35，最低约 0.10，最高 1.0：
    //   下半段 expr = 26 + vel/2（26..90）
    //   上半段 expr = 90 + 1.3*(vel-128)（90..255）→ 增大方向约 +9dB
    wire [7:0] up_d      = vel_calc - 8'd128;
    wire [8:0] expr_down = 9'd26 + {1'b0, vel_calc[7:1]};
    wire [8:0] expr_up   = 9'd90 + {1'b0, up_d} + {2'b0, up_d[7:2]} + {4'b0, up_d[7:4]};
    wire [8:0] expr_sum  = (vel_calc <= 8'd128) ? expr_down : expr_up;
    wire [7:0] expr_gain = (expr_sum > 9'd255) ? 8'd255 : expr_sum[7:0];
    wire signed [23:0] expr_prod = timbre_trim * $signed({1'b0, expr_gain});
    wire signed [15:0] expr_trim = expr_prod[23:8];          // >>8

    // 电平开关：HI 原样，LO 右移一位（约 −6dB），用于判断破音是数字端还是模拟端
    assign mix_sample = level_lo ? (expr_trim >>> 1) : expr_trim;

    chorus #(
        .SAMPLE_W  (16),
        .ADDR_W    (11),
        .MIN_DELAY (512),
        .LFO_STEP  (24'd128)
    ) u_chorus (
        .clk              (clk_sys),
        .rst_n            (rst_n),
        .sample_en        (sample_en),
        .mode             (fx_mode),
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

    // ------------------------------------------------------------
    // 2.4 寸 TFT 横屏 UI（docs/22）：ui_render 只读演奏状态，不反向改音频
    //   st_timbre : timbre_sel（0=SINE 1=SQUARE 2=SAW 3=TRI）
    //   st_fx     : fx_mode（0=DRY 1=CHORUS 2=VIBRATO 3=TREMOLO）
    //   st_mode   : chord_sel（0=ONE 独奏 1=TRI 和弦）
    //   st_note   : 当前发声音符（驱动波长）  st_voices: 同时发声数（驱动幅度 0..±40px）
    //   调式仍是占位（旋钮未接线），固定 0
    // ------------------------------------------------------------
    wire        ui_win_start;
    wire [9:0]  ui_win_x0, ui_win_x1, ui_win_y0, ui_win_y1;
    wire [15:0] ui_px_data;
    wire [8:0]  ui_pix_x;
    wire [7:0]  ui_pix_y;
    wire        ui_busy, ui_done;
    wire [2:0]  ui_region;

    // 真实采样窗口（波形带用）
    wire               wave_valid;
    wire               wave_bank;
    wire               wave_trig;
    wire               wave_rd_bank;
    wire [8:0]         wave_rd_addr;
    wire signed [15:0] wave_sample;
    wire [15:0]        wave_peak;

    // DEBUG_JOY=1：波形带临时改成摇杆 X/Y 读数条（标定完改回 0）
    ui_render #(.DEBUG_JOY(1)) u_ui (
        .clk         (clk_sys),
        .rst_n       (rst_n),
        .st_timbre   (timbre_sel),
        .st_fx       (fx_mode),
        .st_mode     ({1'b0, chord_sel}),
        .st_note     (note_id),
        .st_voices   (voice_cnt),
        .st_key_root (7'd0),
        .live_valid  (wave_valid),
        .live_bank   (wave_bank),
        .live_data   (wave_sample),
        .capture_trig(wave_trig),
        .rd_bank_sel (wave_rd_bank),
        .rd_addr     (wave_rd_addr),
        // X 显示原始计数（屏蔽低 4 位）；Y 显示力度值 vel_calc
        .dbg_x_code  (joyx_filt[15:0] & 16'hFFF0),
        .dbg_y_code  ({8'b0, vel_calc}),
        .dbg_x_fault (joyx_fault),
        .dbg_y_fault (joyy_fault),
        .dbg_bend    (bend_q15),
        .win_start   (ui_win_start),
        .win_x0      (ui_win_x0),
        .win_x1      (ui_win_x1),
        .win_y0      (ui_win_y0),
        .win_y1      (ui_win_y1),
        .px_data     (ui_px_data),
        .px_x        (ui_pix_x),
        .px_y        (ui_pix_y),
        .busy        (ui_busy),
        .done        (ui_done),
        .dbg_region  (ui_region)
    );

    // 抓取 I2S 实际送出的样本（合唱之后、DAC 之前），48 kHz、320 点一窗
    wave_capture u_wave_cap (
        .clk         (clk_sys),
        .rst_n       (rst_n),
        .sample_en   (sample_en),
        .sample_in   (fx_sample),
        .trigger     (wave_trig),
        .frame_valid (wave_valid),
        .last_bank   (wave_bank),
        .peak_out    (wave_peak),
        .rd_bank_sel (wave_rd_bank),
        .rd_addr     (wave_rd_addr),
        .rd_data     (wave_sample)
    );

    tft_st7789 #(
        .CLK_HZ     (72_000_000),
        .SCLK_HZ    (12_000_000),          // 阶梯实测：12 干净、18 贴门限、36 不通
        .MADCTL_VAL (8'hA0),               // 实测锁定（见 docs/22）
        .INVERT_ON  (1'b0)                 // 实测锁定（见 docs/22）
    ) u_tft (
        .clk       (clk_sys),
        .rst_n     (rst_n),
        .win_start (ui_win_start),
        .win_x0    (ui_win_x0),
        .win_x1    (ui_win_x1),
        .win_y0    (ui_win_y0),
        .win_y1    (ui_win_y1),
        .pix_data  (ui_px_data),
        .pix_we    (),
        .pix_x     (ui_pix_x),
        .pix_y     (ui_pix_y),
        .busy      (ui_busy),
        .done      (ui_done),
        .sclk      (tft_sclk),
        .mosi      (tft_mosi),
        .cs_n      (tft_cs_n),
        .dc        (tft_dc),
        .res_n     (tft_res_n),
        .blk       (tft_blk),
        .dbg_state ()
    );

    assign pa_en      = pll_lock;

    // 七键调试：LED0-4 = K1-K5；LED5 = K6 或 K7（板载只有 6 颗灯）
    assign led_n[4:0] = ~pressed[4:0];
    assign led_n[5]   = ~(pressed[5] | pressed[6]);
endmodule
