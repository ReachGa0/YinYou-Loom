// ============================================================
// ui_render.v —— 横屏 UI 渲染器（2.4 寸 ST7789，320×240）
//
// 设计要点（与 docs/22 第 4 节一致）：
//   1. **没有帧缓冲**：像素是"纯函数" pixel(x,y,state) → RGB565，现算现发；
//   2. **区域调度**：整屏只在开机画一次；之后每帧只重画波形"活动带"
//      （320×84，12 MHz 下约 36ms → 28fps）；选项变更时只重画该列的选项区；
//   3. **帧边界锁存**：每次 win_start 把演奏状态锁进 r_* 寄存器，
//      单个区域内的像素一定用同一份状态 → 不会出现"半屏旧半屏新"的撕裂；
//   4. 选中行**镜像**演奏侧的实际取值（UI 不持有自己的选中状态，只读不写）。
//
// 像素接口契约（与 tft_st7789 一致）：驱动器第 n 拍给 pix_x/pix_y + pix_we，
// 第 n+2 拍采样 px_data。本模块的字库是同步读（1 拍延迟），因此：
//   第 n+1 拍用坐标算字库地址 → 第 n+2 拍拿到字模字节，
//   而坐标在整个像素期间保持不变 → 第 n+2 拍可以组合出正确颜色。
//
// 布局（设备像素，原点左上；与 docs/22 / 预览图一致）：
//   y 0..127   波形带（中线 y=63，活动带 y=21..105，振幅 ±40px）
//   x 272..319, y 4..19   调式占位文本（黑底框，可覆盖波形一角）
//   y 128..129 分隔线；x=106 / x=213 竖向分隔线（y≥130）
//   y 130..145 表头行；y 146..209 四个选项行（16px/行）；y 212..227 按键提示行
//   列：0..105 / 107..212 / 214..319（各 106px，列内左留白 3px，最多 12 字符）
// ============================================================

module ui_render #(
    // 字库路径：**相对工程目录**（Gowin 综合时以 fpga/<工程>/ 为基准）。
    // 所有 fpga 工程都在同一深度，所以 ../../data/... 通用。
    // 跑仿真时由测试台覆盖成 "data/fonts/font8x16.hex"（Icarus 以仓库根为基准）。
    parameter FONT_INIT = "../../data/fonts/font8x16.hex",
    // 视觉流动速度：每帧相位推进（4096 = 一个周期）
    //   160 × 27fps / 4096 ≈ 1.05 周期/秒（原 48 ≈ 0.32 周期/秒，太慢）
    parameter [11:0] FLOW_INC = 12'd160,
    // 波长/参数的跟踪速度：每帧移动多少 Q4（16 = 一整步）
    //   8 → 满量程（4 步=64）约 8 帧 ≈ 0.3s，摇杆微调时波形能跟得上手；
    //   原值 1 → 满量程 64 帧 ≈ 2.4s，明显滞后
    parameter [6:0] SLEW_INC = 7'd8,
    // 调试页：1 = 波形带改成"摇杆 X/Y 读数条"，用于标定 RC 前级
    parameter DEBUG_JOY = 0
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 状态总线（只读；由演奏逻辑提供）----
    input  wire [1:0]  st_timbre,      // 0=SINE 1=SQUARE
    input  wire [1:0]  st_fx,          // 0=DRY  1=CHORUS
    input  wire [1:0]  st_mode,        // 0=ONE  1=TRI
    input  wire [6:0]  st_note,        // 当前发声音符 → 波长
    input  wire [2:0]  st_voices,      // 同时发声数 0..4 → 幅度
    input  wire [6:0]  st_key_root,    // 调式占位（本轮不用）

    // ---- 真实采样显示（波形带）----
    //   live_valid=1 时用真实采样画；=0（上电最初几帧 / 仿真）退回合成波形
    input  wire        live_valid,     // 至少有一窗采满
    input  wire        live_bank,      // 最近抓完的 bank
    input  wire signed [15:0] live_data, // 当前像素列的采样值（1 拍延迟）
    output wire        capture_trig,   // 请求抓下一窗
    output wire        rd_bank_sel,    // 读哪个 bank（帧边界锁存）
    output wire [8:0]  rd_addr,        // 读地址 = px_x

    // ---- 摇杆调试读数（DEBUG_JOY=1 时显示）----
    input  wire [15:0] dbg_x_code,
    input  wire [15:0] dbg_y_code,
    input  wire        dbg_x_fault,
    input  wire        dbg_y_fault,
    input  wire [15:0] dbg_bend,

    // ---- 窗口/像素接口（接 tft_st7789）----
    output reg         win_start,
    output reg  [9:0]  win_x0, win_x1, win_y0, win_y1,
    output reg  [15:0] px_data,
    input  wire [8:0]  px_x,
    input  wire [7:0]  px_y,
    input  wire        busy,
    input  wire        done,

    output wire [2:0]  dbg_region
);

    // ------------------------------------------------------------
    // 几何与调色板
    // ------------------------------------------------------------
    localparam [7:0]  MID_Y     = 8'd63;
    localparam [7:0]  BAND_Y0   = 8'd21;
    localparam [7:0]  BAND_Y1   = 8'd105;
    localparam [9:0]  SCALE_BOX_X0 = 10'd272;
    localparam [9:0]  SCALE_TX     = 10'd276;
    localparam [7:0]  SCALE_Y0  = 8'd4;
    localparam [7:0]  SCALE_Y1  = 8'd19;
    localparam [7:0]  SEP1_Y0   = 8'd128, SEP1_Y1 = 8'd129;
    localparam [7:0]  SEP2_Y0   = 8'd210, SEP2_Y1 = 8'd211;
    localparam [7:0]  HDR_Y0    = 8'd130, HDR_Y1  = 8'd145;
    localparam [7:0]  OPT_Y0    = 8'd146, OPT_Y1  = 8'd209;
    localparam [7:0]  HINT_Y0   = 8'd212, HINT_Y1 = 8'd227;
    localparam [9:0]  COL0_X0   = 10'd0,   COL0_X1 = 10'd105;
    localparam [9:0]  COL1_X0   = 10'd107, COL1_X1 = 10'd212;
    localparam [9:0]  COL2_X0   = 10'd214, COL2_X1 = 10'd319;
    localparam [9:0]  TXT_PAD   = 10'd3;

    localparam [15:0] C_BG     = 16'h0000,   // 背景
                      C_SEP    = 16'h39C7,   // 分隔线（深灰）
                      C_HDR    = 16'h07FF,   // 表头（青）
                      C_TXT    = 16'hFFFF,   // 选项（白）
                      C_HINT   = 16'h8C71,   // 按键提示（灰）
                      C_SEL_BG = 16'hFFFF,   // 选中行底（白）
                      C_SEL_TX = 16'h0000,   // 选中行字（黑）
                      C_WAVE   = 16'h07FF,   // 波形（青）
                      C_MID    = 16'h0220,   // 中线（暗绿）
                      C_SCALE  = 16'hFFE0,   // 调式（黄）
                      C_BAR_X  = 16'h07FF,   // 调试：X 读数条（青）
                      C_BAR_Y  = 16'h07E0,   // 调试：Y 读数条（绿）
                      C_TICK   = 16'h4A69,   // 调试：中位刻度（灰）
                      C_FAULT  = 16'hF800;   // 调试：故障（红）

    // 字符串：每条固定 12 字符（不足补空格），首字符在最高字节
    localparam [95:0] S_HDR0  = "TONE        ";
    localparam [95:0] S_HDR1  = "FX          ";
    localparam [95:0] S_HDR2  = "MODE        ";
    localparam [95:0] S_OPT00 = "SINE        ";
    localparam [95:0] S_OPT01 = "SQUARE      ";
    localparam [95:0] S_OPT02 = "SAW         ";
    localparam [95:0] S_OPT03 = "TRIANGLE    ";
    localparam [95:0] S_OPT10 = "DRY         ";
    localparam [95:0] S_OPT11 = "CHORUS      ";
    localparam [95:0] S_OPT12 = "VIBRATO     ";
    localparam [95:0] S_OPT13 = "TREMOLO     ";
    localparam [95:0] S_OPT20 = "ONE         ";
    localparam [95:0] S_OPT21 = "TRI         ";
    localparam [95:0] S_OPT22 = "PLUCK ONE   ";
    localparam [95:0] S_OPT23 = "PLUCK TRI   ";
    localparam [95:0] S_HINT0 = "S1 TIMBRE   ";
    localparam [95:0] S_HINT1 = "S2 FX       ";
    localparam [95:0] S_HINT2 = "SW MODE     ";
    localparam [95:0] S_SCALE = "C MAJ       ";

    // ------------------------------------------------------------
    // 64 点正弦表（sin(2πi/64)×127）
    // ------------------------------------------------------------
    function signed [7:0] sine64;
        input [5:0] i;
        begin
            case (i)
                6'd0 : sine64 = 8'sd0   ;   6'd1 : sine64 = 8'sd12  ;
                6'd2 : sine64 = 8'sd25  ;   6'd3 : sine64 = 8'sd37  ;
                6'd4 : sine64 = 8'sd49  ;   6'd5 : sine64 = 8'sd60  ;
                6'd6 : sine64 = 8'sd71  ;   6'd7 : sine64 = 8'sd81  ;
                6'd8 : sine64 = 8'sd90  ;   6'd9 : sine64 = 8'sd98  ;
                6'd10: sine64 = 8'sd106 ;   6'd11: sine64 = 8'sd112 ;
                6'd12: sine64 = 8'sd117 ;   6'd13: sine64 = 8'sd122 ;
                6'd14: sine64 = 8'sd125 ;   6'd15: sine64 = 8'sd126 ;
                6'd16: sine64 = 8'sd127 ;   6'd17: sine64 = 8'sd126 ;
                6'd18: sine64 = 8'sd125 ;   6'd19: sine64 = 8'sd122 ;
                6'd20: sine64 = 8'sd117 ;   6'd21: sine64 = 8'sd112 ;
                6'd22: sine64 = 8'sd106 ;   6'd23: sine64 = 8'sd98  ;
                6'd24: sine64 = 8'sd90  ;   6'd25: sine64 = 8'sd81  ;
                6'd26: sine64 = 8'sd71  ;   6'd27: sine64 = 8'sd60  ;
                6'd28: sine64 = 8'sd49  ;   6'd29: sine64 = 8'sd37  ;
                6'd30: sine64 = 8'sd25  ;   6'd31: sine64 = 8'sd12  ;
                6'd32: sine64 = 8'sd0   ;   6'd33: sine64 = -8'sd12 ;
                6'd34: sine64 = -8'sd25 ;   6'd35: sine64 = -8'sd37 ;
                6'd36: sine64 = -8'sd49 ;   6'd37: sine64 = -8'sd60 ;
                6'd38: sine64 = -8'sd71 ;   6'd39: sine64 = -8'sd81 ;
                6'd40: sine64 = -8'sd90 ;   6'd41: sine64 = -8'sd98 ;
                6'd42: sine64 = -8'sd106;   6'd43: sine64 = -8'sd112;
                6'd44: sine64 = -8'sd117;   6'd45: sine64 = -8'sd122;
                6'd46: sine64 = -8'sd125;   6'd47: sine64 = -8'sd126;
                6'd48: sine64 = -8'sd127;   6'd49: sine64 = -8'sd126;
                6'd50: sine64 = -8'sd125;   6'd51: sine64 = -8'sd122;
                6'd52: sine64 = -8'sd117;   6'd53: sine64 = -8'sd112;
                6'd54: sine64 = -8'sd106;   6'd55: sine64 = -8'sd98 ;
                6'd56: sine64 = -8'sd90 ;   6'd57: sine64 = -8'sd81 ;
                6'd58: sine64 = -8'sd71 ;   6'd59: sine64 = -8'sd60 ;
                6'd60: sine64 = -8'sd49 ;   6'd61: sine64 = -8'sd37 ;
                6'd62: sine64 = -8'sd25 ;   default: sine64 = -8'sd12;
            endcase
        end
    endfunction

    // ------------------------------------------------------------
    // 字符查表：col 0/1/2 = 三列，line 0=表头 / 1..4=选项 / 5=提示；col=3 → 调式占位
    // ------------------------------------------------------------
    function [7:0] hex_char;
        input [3:0] v;
        begin
            hex_char = (v < 4'd10) ? (8'h30 + {4'b0, v})
                                   : (8'h41 + {4'b0, v} - 8'h0A);
        end
    endfunction

    function [7:0] ui_char;
        input [1:0] col;
        input [2:0] line;
        input [3:0] idx;
        reg   [4:0] bi;
        begin
            bi = 5'd11 - {1'b0, idx};
            case (col)
                2'd0: case (line)
                    3'd0: ui_char = S_HDR0 [8*bi +: 8];
                    3'd1: ui_char = S_OPT00[8*bi +: 8];
                    3'd2: ui_char = S_OPT01[8*bi +: 8];
                    3'd3: ui_char = S_OPT02[8*bi +: 8];
                    3'd4: ui_char = S_OPT03[8*bi +: 8];
                    3'd5: ui_char = S_HINT0[8*bi +: 8];
                    default: ui_char = 8'h20;
                endcase
                2'd1: case (line)
                    3'd0: ui_char = S_HDR1 [8*bi +: 8];
                    3'd1: ui_char = S_OPT10[8*bi +: 8];
                    3'd2: ui_char = S_OPT11[8*bi +: 8];
                    3'd3: ui_char = S_OPT12[8*bi +: 8];
                    3'd4: ui_char = S_OPT13[8*bi +: 8];
                    3'd5: ui_char = S_HINT1[8*bi +: 8];
                    default: ui_char = 8'h20;
                endcase
                2'd2: case (line)
                    3'd0: ui_char = S_HDR2 [8*bi +: 8];
                    3'd1: ui_char = S_OPT20[8*bi +: 8];
                    3'd2: ui_char = S_OPT21[8*bi +: 8];
                    3'd3: ui_char = S_OPT22[8*bi +: 8];
                    3'd4: ui_char = S_OPT23[8*bi +: 8];
                    3'd5: ui_char = S_HINT2[8*bi +: 8];
                    default: ui_char = 8'h20;
                endcase
                default: ui_char = S_SCALE[8*bi +: 8];      // 调式占位
            endcase
        end
    endfunction

    // ------------------------------------------------------------
    // 帧边界锁存的状态 + 选项脏标记（粘住，直到对应区域画完）
    // ------------------------------------------------------------
    reg [1:0] r_timbre, r_fx, r_mode;
    reg [6:0] r_note;
    reg [2:0] r_voices;
    reg       r_bank;          // 本帧读的采样 bank
    reg       r_live;          // 本帧是否用真实采样

    reg tone_dirty, fx_dirty, mode_dirty;
    reg mode_dirty_clr, fx_dirty_clr, tone_dirty_clr;
    reg frame_wave_done;           // 波形带事务完成脉冲（调度器产生，相位推进用）

    always @(posedge clk) begin
        if (!rst_n) begin
            r_timbre <= 2'd0; r_fx <= 2'd0; r_mode <= 2'd0;
            r_note <= 7'd60;  r_voices <= 3'd0;
            tone_dirty <= 1'b0; fx_dirty <= 1'b0; mode_dirty <= 1'b0;
        end else begin
            // 变更检测（与已锁存值比较；选中行镜像演奏侧，UI 不持状态）
            if (st_timbre != r_timbre) tone_dirty <= 1'b1;
            else if (tone_dirty_clr)   tone_dirty <= 1'b0;
            if (st_fx     != r_fx)     fx_dirty   <= 1'b1;
            else if (fx_dirty_clr)     fx_dirty   <= 1'b0;
            if (st_mode   != r_mode)   mode_dirty <= 1'b1;
            else if (mode_dirty_clr)   mode_dirty <= 1'b0;
            // 每次区域开始都锁存一次完整状态（区域内部像素用同一份）
            if (win_start) begin
                r_timbre <= st_timbre;
                r_fx     <= st_fx;
                r_mode   <= st_mode;
                r_note   <= st_note;
                r_voices <= st_voices;
                r_bank   <= live_bank;
                r_live   <= live_valid;
            end
        end
    end

    // 选中行：TONE / FX 各 4 项（2 位），MODE 仍为 2 项
    wire [1:0] sel0 = r_timbre;
    wire [1:0] sel1 = r_fx;
    wire [1:0] sel2 = r_mode;

    // ------------------------------------------------------------
    // 波形参数：波长（音符→步长，带平滑）、幅度（发声数）、每帧相位推进
    //   相位单位：4096/周期；步长 Q4（16 倍）→ 步长 32..96 对应一屏 2.5..7.5 周期
    // ------------------------------------------------------------
    wire [6:0] n_clamp = (r_note < 7'd48) ? 7'd48 : ((r_note > 7'd72) ? 7'd72 : r_note);
    wire [4:0] step_lin = {1'b0, (n_clamp - 7'd48)} >> 2;                  // 0..6
    wire [2:0] step_tgt = 3'd2 + ((step_lin > 5'd4) ? 3'd4 : step_lin[2:0]); // 2..6
    wire [6:0] step_tgt_q4 = {step_tgt, 4'b0000};                          // Q4

    wire [5:0] amp = {r_voices, 3'b000} + {r_voices, 1'b0};        // voices×10 → 0..40

    // ---- 真实采样：±32767 映射到 ±32 像素（活动带 ±42，留余量）----
    assign rd_bank_sel = r_bank;
    assign rd_addr     = px_x;

    wire signed [15:0] live_scale = live_data >>> 10;
    wire signed [15:0] live_yw_s  = 16'sd63 - live_scale;
    wire        [8:0]  live_yw    = live_yw_s[8:0];

    reg [6:0]  step_q4;
    reg [11:0] phase0;
    reg [11:0] ph_acc;
    reg [8:0]  px_x_d;
    reg [7:0]  px_y_d;
    reg [8:0]  prev_yw;        // 上一列的采样 y（画竖线连接用）
    reg        prev_sq_sign;   // 上一像素的方波极性（画竖线用）
    reg        edge_d;         // 上一列是"跳变列"

    always @(posedge clk) begin
        if (!rst_n) begin
            step_q4 <= 7'd32;          // 初始 2.5 周期
            phase0  <= 12'd0;
            ph_acc  <= 12'd0;
            px_x_d  <= 9'h1FF;
            px_y_d  <= 8'hFF;
            prev_yw <= 9'd63;
            prev_sq_sign <= 1'b0;
            edge_d       <= 1'b0;
        end else begin
            px_x_d <= px_x;
            px_y_d <= px_y;
            // 坐标变化 = 进入新像素：行首回到 phase0，否则推进一个像素的相位
            if ((px_x != px_x_d) || (px_y != px_y_d)) begin
                ph_acc <= (px_x == 9'd0) ? phase0 : (ph_acc + {5'b0, step_q4});
                prev_sq_sign <= ph_acc[11];       // ph_acc 此刻仍是上一像素的相位
                edge_d       <= edge_now;
                // live_data 此刻仍是"上一列"的值（读口 1 拍延迟）
                if (px_x != 9'd0) prev_yw <= live_yw;
            end
            // 每画完一帧波形带：相位推进 + 步长向上限平滑（避免换音跳变）
            if (frame_wave_done) begin
                phase0 <= phase0 + FLOW_INC;
                if (step_q4 < step_tgt_q4)
                    step_q4 <= (step_q4 + SLEW_INC > step_tgt_q4) ? step_tgt_q4
                                                                  : (step_q4 + SLEW_INC);
                else if (step_q4 > step_tgt_q4)
                    step_q4 <= (step_q4 < step_tgt_q4 + SLEW_INC) ? step_tgt_q4
                                                                  : (step_q4 - SLEW_INC);
            end
        end
    end

    wire signed [15:0] amp_s      = $signed({10'b0, amp});
    wire signed [15:0] prod_sin   = sine64(ph_acc[11:6]) * amp_s;          // ±5080
    wire signed [15:0] scaled_sin = prod_sin >>> 7;                        // ±39
    wire signed [15:0] scaled_sq  = ph_acc[11] ? amp_s : -amp_s;
    wire signed [15:0] scaled     = r_timbre[0] ? scaled_sq : scaled_sin;
    wire signed [15:0] yw_s       = 16'sd63 - scaled;
    wire        [8:0]  yw         = yw_s[8:0];
    wire        [8:0]  py9        = {1'b0, px_y};
    wire               wave_hit   = (py9 + 9'd1 >= yw) && (py9 <= yw + 9'd1);   // 3px 粗

    // 真实采样：把相邻两列的 y 连起来（示波器式竖线），陡坡处不会断线
    wire [8:0]  ly_lo    = (live_yw < prev_yw) ? live_yw : prev_yw;
    wire [8:0]  ly_hi    = (live_yw < prev_yw) ? prev_yw : live_yw;
    wire        live_hit = r_live &&
                           ((px_x == 9'd0)
                             ? ((py9 + 9'd1 >= live_yw) && (py9 <= live_yw + 9'd1))
                             : ((py9 + 9'd1 >= ly_lo)   && (py9 <= ly_hi)));

    // 方波的"垂线"：极性跳变的那一列，把上下两条平行线之间的整段点亮
    wire        edge_now = (px_x != 9'd0) && (ph_acc[11] != prev_sq_sign);
    wire [8:0]  amp9     = {3'b0, amp};
    wire [8:0]  y_top    = 9'd63 - amp9;
    wire [8:0]  y_bot    = 9'd63 + amp9;
    wire        vert_hit = r_timbre[0] && (edge_now || edge_d) &&
                           (py9 >= y_top) && (py9 <= y_bot);

    // ------------------------------------------------------------
    // 区域调度：整屏一次 → 之后"有选项变更就刷那一列，否则刷波形活动带"
    // ------------------------------------------------------------
    localparam [2:0] RG_FULL = 3'd0,
                     RG_WAVE = 3'd1,
                     RG_TONE = 3'd2,
                     RG_FX   = 3'd3,
                     RG_MODE = 3'd4;

    reg [2:0]  region;
    reg [1:0]  sched;              // 0=选区域 1=发窗口 2=等 busy 3=等 done
    reg        full_pending;
    reg        cap_trig;           // 波形带开始 → 请求抓下一窗真实采样

    assign dbg_region = region;
    assign capture_trig = cap_trig;

    always @(posedge clk) begin
        if (!rst_n) begin
            win_start <= 1'b0;
            win_x0 <= 10'd0; win_x1 <= 10'd319; win_y0 <= 10'd0; win_y1 <= 10'd239;
            region <= RG_FULL;
            sched  <= 2'd0;
            full_pending <= 1'b1;
            cap_trig <= 1'b0;
            frame_wave_done <= 1'b0;
            tone_dirty_clr <= 1'b0; fx_dirty_clr <= 1'b0; mode_dirty_clr <= 1'b0;
        end else begin
            win_start <= 1'b0;
            frame_wave_done <= 1'b0;
            cap_trig <= 1'b0;
            tone_dirty_clr <= 1'b0; fx_dirty_clr <= 1'b0; mode_dirty_clr <= 1'b0;

            case (sched)
                2'd0: if (!busy) begin
                    // 选下一个区域：选项变更优先（很小、事件式），否则刷波形活动带
                    if (full_pending)      region <= RG_FULL;
                    else if (tone_dirty)   region <= RG_TONE;
                    else if (fx_dirty)     region <= RG_FX;
                    else if (mode_dirty)   region <= RG_MODE;
                    else                   region <= RG_WAVE;
                    sched <= 2'd1;
                end
                2'd1: begin
                    case (region)
                        RG_FULL: begin
                            win_x0 <= 10'd0;   win_x1 <= 10'd319;
                            win_y0 <= 10'd0;   win_y1 <= 10'd239;
                            full_pending <= 1'b0;
                        end
                        RG_WAVE: begin
                            win_x0 <= 10'd0;   win_x1 <= 10'd319;
                            win_y0 <= {2'b0, BAND_Y0}; win_y1 <= {2'b0, BAND_Y1};
                        end
                        RG_TONE: begin
                            win_x0 <= COL0_X0; win_x1 <= COL0_X1;
                            win_y0 <= {2'b0, OPT_Y0}; win_y1 <= {2'b0, OPT_Y1};
                        end
                        RG_FX: begin
                            win_x0 <= COL1_X0; win_x1 <= COL1_X1;
                            win_y0 <= {2'b0, OPT_Y0}; win_y1 <= {2'b0, OPT_Y1};
                        end
                        default: begin
                            win_x0 <= COL2_X0; win_x1 <= COL2_X1;
                            win_y0 <= {2'b0, OPT_Y0}; win_y1 <= {2'b0, OPT_Y1};
                        end
                    endcase
                    win_start <= 1'b1;
                    if (region == RG_WAVE) cap_trig <= 1'b1;
                    sched <= 2'd2;
                end
                2'd2: if (busy) sched <= 2'd3;          // 驱动器接手
                2'd3: if (done) begin                    // 事务完成
                    case (region)
                        RG_WAVE: frame_wave_done <= 1'b1;
                        RG_TONE: tone_dirty_clr  <= 1'b1;
                        RG_FX:   fx_dirty_clr    <= 1'b1;
                        RG_MODE: mode_dirty_clr  <= 1'b1;
                        default: ;
                    endcase
                    sched <= 2'd0;
                end
                default: sched <= 2'd0;
            endcase
        end
    end

    // ------------------------------------------------------------
    // 像素归属判断
    // ------------------------------------------------------------
    wire in_wave_area = (px_y <= 8'd127);

    // ---- 摇杆调试读数条：code >> 6 → 0..319 像素 ----
    // 100nF 版本：code >> 6，0..20416 映射到 0..319
    wire [9:0] bar_x_w = {1'b0, dbg_x_code[15:6]};
    wire [9:0] bar_y_w = {1'b0, dbg_y_code[15:6]};
    wire [9:0] bar_x   = (bar_x_w > 10'd319) ? 10'd319 : bar_x_w;
    wire [9:0] bar_y   = (bar_y_w > 10'd319) ? 10'd319 : bar_y_w;
    localparam [9:0] BAR_TICK_X = 10'd65;        // 实测中位约 4200 >> 6
    wire bar_x_zone = (px_y >= 8'd20) && (px_y <= 8'd40);
    wire bar_y_zone = (px_y >= 8'd70) && (px_y <= 8'd90);

    // 调试：16 个二进制方块（MSB 在左），不依赖字库，绝不会乱码。
    // 方块 12px + 间隙 4px = 16px 一格；x 0..255 放 16 个。
    wire [3:0] bx_idx = px_x[8:4];
    wire [3:0] bb_idx = px_x[8:4];
    wire       bx_zone = (px_y >= 8'd4)  && (px_y <= 8'd15) &&
                         ({1'b0, px_x} < 10'd256) && (px_x[3:0] < 4'd12);
    wire       bb_zone = (px_y >= 8'd48) && (px_y <= 8'd59) &&
                         ({1'b0, px_x} < 10'd256) && (px_x[3:0] < 4'd12);
    // 亮的方块 = 1（左边是 bit15）
    wire       bx_on = bx_zone && dbg_x_code[15 - bx_idx];
    wire       bb_on = bb_zone && dbg_bend[15 - bb_idx];

    // 故障指示：两行最右侧的小红块
    wire in_fault_x = dbg_x_fault && (px_y >= 8'd4)  && (px_y <= 8'd15) &&
                      ({1'b0, px_x} >= 10'd264) && ({1'b0, px_x} <= 10'd271);
    wire in_fault_y = dbg_y_fault && (px_y >= 8'd48) && (px_y <= 8'd59) &&
                      ({1'b0, px_x} >= 10'd264) && ({1'b0, px_x} <= 10'd271);

    wire in_scale_box = (px_y >= SCALE_Y0) && (px_y <= SCALE_Y1) && ({1'b0, px_x} >= SCALE_BOX_X0);
    wire in_scale_txt = (px_y >= SCALE_Y0) && (px_y <= SCALE_Y1) &&
                        ({1'b0, px_x} >= SCALE_TX) && ({1'b0, px_x} <= 10'd319);
    wire in_sep_row   = ((px_y >= SEP1_Y0) && (px_y <= SEP1_Y1)) ||
                        ((px_y >= SEP2_Y0) && (px_y <= SEP2_Y1));
    wire in_col_sep   = ({1'b0, px_x} == 10'd106) || ({1'b0, px_x} == 10'd213);
    wire in_hdr_row   = (px_y >= HDR_Y0) && (px_y <= HDR_Y1);
    wire in_opt_row   = (px_y >= OPT_Y0) && (px_y <= OPT_Y1);
    wire in_hint_row  = (px_y >= HINT_Y0) && (px_y <= HINT_Y1);
    wire in_text_row  = in_hdr_row || in_opt_row || in_hint_row;

    wire        in_col0 = ({1'b0, px_x} <= COL0_X1);
    wire        in_col1 = ({1'b0, px_x} >= COL1_X0) && ({1'b0, px_x} <= COL1_X1);
    wire [1:0]  cur_col = in_col0 ? 2'd0 : (in_col1 ? 2'd1 : 2'd2);
    wire [9:0]  cur_col_x0 = in_col0 ? COL0_X0 : (in_col1 ? COL1_X0 : COL2_X0);

    wire [9:0]  cx10    = {1'b0, px_x} - cur_col_x0 - TXT_PAD;
    wire        cx_ok   = (cx10 < 10'd96);                 // 最多 12 字符
    wire [3:0]  ch_idx  = cx10[6:3];
    wire [2:0]  ch_bit  = cx10[2:0];

    wire [9:0]  sxl     = {1'b0, px_x} - SCALE_TX;
    wire [3:0]  s_idx   = sxl[6:3];
    wire [2:0]  s_bit   = sxl[2:0];

    wire [7:0]  opt_y      = px_y - OPT_Y0;
    wire [1:0]  opt_row    = opt_y[5:4];                   // 0..3
    wire [2:0]  cur_line   = in_hdr_row  ? 3'd0 :
                             in_opt_row  ? (3'd1 + {1'b0, opt_row}) :
                             in_hint_row ? 3'd5 : 3'd0;
    // 注意：位选只能作用于"命名信号"，不能作用于括号表达式
    //（Gowin 综合器会报 EX3863，Icarus 却不报——仿真过不等于可综合）
    wire [7:0]  hdr_row_in  = px_y - HDR_Y0;
    wire [7:0]  hint_row_in = px_y - HINT_Y0;
    wire [7:0]  scl_row_in  = px_y - SCALE_Y0;
    wire [3:0]  cur_row_in  = in_hdr_row  ? hdr_row_in[3:0] :
                              in_opt_row  ? opt_y[3:0]      :
                                            hint_row_in[3:0];
    wire [1:0]  cur_sel    = (cur_col == 2'd0) ? sel0 :
                             (cur_col == 2'd1) ? sel1 : sel2;

    // ------------------------------------------------------------
    // 字库地址（同步读 1 拍；调式框与文本行互斥，共用这一个读口）
    // ------------------------------------------------------------
    wire [7:0] ch_code_raw = in_scale_txt ? ui_char(2'd3, 3'd0, s_idx)
                                           : (in_text_row && cx_ok ? ui_char(cur_col, cur_line, ch_idx)
                                                                   : 8'h20);
    wire [3:0] ch_row_raw  = in_scale_txt ? scl_row_in[3:0] : cur_row_in;
    wire [7:0] ch_code = ch_code_raw;
    wire [3:0] ch_row  = ch_row_raw;
    wire [10:0] rom_addr = ({3'b0, (ch_code - 8'h20)} << 4) + {7'b0, ch_row};

    wire [7:0] glyph;

    font8x16_rom #(.INIT_FILE (FONT_INIT)) u_font (
        .clk  (clk),
        .addr (rom_addr),
        .data (glyph)
    );

    wire       gbit_txt = glyph[3'd7 - ch_bit];
    wire       gbit_scl = glyph[3'd7 - s_bit];
    wire       gbit     = in_scale_txt ? gbit_scl : gbit_txt;

    // ------------------------------------------------------------
    // 像素纯函数（组合；第 n+2 拍稳定）
    // ------------------------------------------------------------
    always @(*) begin
        px_data = C_BG;

        if (in_scale_box) begin
            // 调式占位：黑底 + 黄字（覆盖波形一角）
            px_data = (in_scale_txt && gbit) ? C_SCALE : C_BG;
        end else if (in_wave_area) begin
            if (DEBUG_JOY) begin
                // 摇杆读数页：上面一条 X、下面一条 Y；红块 = 该轴 fault
                if (in_fault_x || in_fault_y)
                    px_data = C_FAULT;
                else if (bx_on)
                    px_data = C_BAR_X;
                else if (bb_on)
                    px_data = C_BAR_Y;
                else if (bar_x_zone) begin
                    if ({1'b0, px_x} == BAR_TICK_X) px_data = C_TICK;
                    else if ({1'b0, px_x} < bar_x)  px_data = C_BAR_X;
                    else                            px_data = C_BG;
                end else if (bar_y_zone) begin
                    if ({1'b0, px_x} == BAR_TICK_X) px_data = C_TICK;
                    else if ({1'b0, px_x} < bar_y)  px_data = C_BAR_Y;
                    else                            px_data = C_BG;
                end else begin
                    px_data = C_BG;
                end
            end else if (r_live) begin
                // 真实采样：示波器式折线
                if (live_hit)             px_data = C_WAVE;
                else if (px_y == MID_Y)   px_data = C_MID;
                else                      px_data = C_BG;
            end else begin
                // 还没有采到窗口（上电最初几帧 / 仿真）：合成波形兜底
                if (wave_hit || vert_hit) px_data = C_WAVE;
                else if (px_y == MID_Y)   px_data = C_MID;
                else                      px_data = C_BG;
            end
        end else if (in_sep_row) begin
            px_data = C_SEP;
        end else if (in_col_sep) begin
            px_data = (px_y >= HDR_Y0) ? C_SEP : C_BG;
        end else if (in_text_row) begin
            if (in_opt_row && (opt_row == cur_sel)) begin
                // 选中行反白：整列宽都铺白底（包括超出 12 字符的空白尾部）
                px_data = (cx_ok && gbit) ? C_SEL_TX : C_SEL_BG;
            end else if (!cx_ok) begin
                px_data = C_BG;
            end else begin
                px_data = gbit ? (in_hdr_row  ? C_HDR  :
                                  in_hint_row ? C_HINT : C_TXT) : C_BG;
            end
        end
    end

endmodule
