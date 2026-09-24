// ============================================================
// chord_map.v —— 按键 → 大三和弦，且"同一时刻只有一个和弦在响"
//
// 语义（2026-09-23 与用户确认的"最近按下优先"）：
//   按住 A            → 响 A 的和弦（C4-E4-G4）
//   再按 B（A 不松）  → 响 B 的和弦
//   松开 B（A 仍按）  → 回到 A 的和弦
//   全部松开          → 停止
//
// 为什么限定"只有一个和弦"：4 个声部放不下两个三音和弦（6 音）。叠置会触发
// voice_alloc 轮转抢占 → 丢音；而且不同键的和弦之间会出现同名 note_id
// （例如 A 的 E4 与 B 的 E4 都是 64）→ 释放时会误杀别的键的音。
// 限定后声部需求 ≤ 3，两个问题从根上消失，听感也更像"和弦进行"。
//
// 实现要点：
//   1. 输入是按键电平 pressed[KEYS-1:0]（key_scan 消抖后），不依赖按下/松开
//      脉冲，因此不存在"三音发射途中松手"的窗口；
//   2. 每个键一份 8 位"按下时间戳"，判定最近按下用模 256 的"更近"判据
//      （差值 < 128 视为更近），避开计数回绕；
//   3. 换和弦顺序：释放旧和弦（3×note_off）→ 等 voice_busy == 0（约 34ms，
//      等尾音收干净）→ 起新和弦（3×note_on）→ 保持；这就是选定的"甲"方案；
//   4. note_on / note_off 均为单周期脉冲（voice_alloc 对 note_on 电平敏感）；
//   5. enable = 0（独奏模式）时强制回到空闲且不发脉冲，避免状态残留。
// ============================================================

module chord_map #(
    parameter KEYS = 4
) (
    input  wire            clk,
    input  wire            rst_n,
    input  wire            enable,       // 1 = 和弦模式
    input  wire [KEYS-1:0] pressed,      // 消抖后的按键电平
    input  wire [KEYS-1:0] voice_busy,   // ADSR 是否还在发声

    output reg             note_on,      // 单周期脉冲
    output reg             note_off,     // 单周期脉冲
    output reg  [6:0]      note_id,
    output reg  [31:0]     note_inc,
    output wire [KEYS-1:0] chord_on      // 当前响着的和弦（one-hot）
);
    localparam [2:0] S_IDLE  = 3'd0,     // 没有和弦在响
                     S_PRESS = 3'd1,     // 正在发 3 个 note_on
                     S_SOUND = 3'd2,     // 和弦保持
                     S_REL   = 3'd3,     // 正在发 3 个 note_off
                     S_WAIT  = 3'd4;     // 等尾音收完再决定下一个和弦

    integer i;

    // 第 s 个音：0=根音、1=大三度(+4)、2=纯五度(+7)
    function [6:0] step_note;
        input [1:0] k;
        input [1:0] s;
        reg [6:0] root;
        begin
            case (k)
                2'd0: root = 7'd60;      // C4
                2'd1: root = 7'd64;      // E4
                2'd2: root = 7'd67;      // G4
                default: root = 7'd71;   // B4
            endcase
            case (s)
                2'd1: step_note = root + 7'd4;
                2'd2: step_note = root + 7'd7;
                default: step_note = root;
            endcase
        end
    endfunction

    // MIDI 音号 → 32 位相位增量（48000 Hz、32 位相位累加器）
    function [31:0] inc_for_note;
        input [6:0] n;
        begin
            case (n)
                7'd60: inc_for_note = 32'd23409859;  // C4  261.626 Hz
                7'd64: inc_for_note = 32'd29494575;  // E4  329.628 Hz
                7'd67: inc_for_note = 32'd35075158;  // G4  391.995 Hz
                7'd68: inc_for_note = 32'd37160835;  // G#4 415.305 Hz
                7'd71: inc_for_note = 32'd44191930;  // B4  493.883 Hz
                7'd74: inc_for_note = 32'd52553357;  // D5  587.330 Hz
                7'd75: inc_for_note = 32'd55678342;  // D#5 622.254 Hz
                7'd78: inc_for_note = 32'd66213081;  // F#5 739.989 Hz
                default: inc_for_note = 32'd23409859;
            endcase
        end
    endfunction

    reg [2:0] state;
    reg [1:0] step;
    reg       gap;                 // 脉冲之间空一拍
    reg [1:0] cur_key;             // 当前响着的键
    reg [1:0] want_key;            // 最近按下的键
    reg       want_valid;

    reg [7:0] stamp [0:KEYS-1];    // 各键按下时间戳
    reg [7:0] stamp_ctr;
    reg [3:0] pressed_d;

    // ---- 按下时间戳：每个键在按下沿取一次序号 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pressed_d <= {KEYS{1'b0}};
            stamp_ctr <= 8'd0;
            for (i = 0; i < KEYS; i = i + 1)
                stamp[i] <= 8'd0;
        end else begin
            pressed_d <= pressed;
            for (i = 0; i < KEYS; i = i + 1) begin
                if (pressed[i] && !pressed_d[i]) begin
                    stamp[i]  <= stamp_ctr;
                    stamp_ctr <= stamp_ctr + 8'd1;
                end
            end
        end
    end

    // ---- 最近按下优先：仍按着且时间戳最新的那个键 ----
    always @* begin
        want_key   = 2'd0;
        want_valid = 1'b0;
        for (i = 0; i < KEYS; i = i + 1) begin
            if (pressed[i]) begin
                if (!want_valid) begin
                    want_valid = 1'b1;
                    want_key   = i[1:0];
                end else if (((stamp[i] - stamp[want_key]) != 8'd0) &&
                             ((stamp[i] - stamp[want_key]) < 8'd128)) begin
                    want_key = i[1:0];      // 模 256 判"更近"
                end
            end
        end
    end

    // ---- 和弦状态机 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            step     <= 2'd0;
            gap      <= 1'b0;
            cur_key  <= 2'd0;
            note_on  <= 1'b0;
            note_off <= 1'b0;
            note_id  <= 7'd60;
            note_inc <= 32'd23409859;
        end else begin
            note_on  <= 1'b0;
            note_off <= 1'b0;

            if (!enable) begin
                // 独奏模式：强制空闲，不发脉冲（换模式时顶层已确保声部空闲）
                state <= S_IDLE;
                step  <= 2'd0;
                gap   <= 1'b0;
            end else begin
                case (state)
                    S_IDLE: begin
                        if (want_valid) begin
                            cur_key <= want_key;
                            step    <= 2'd0;
                            gap     <= 1'b0;
                            state   <= S_PRESS;
                        end
                    end

                    S_PRESS: begin
                        if (gap) begin
                            gap <= 1'b0;
                        end else begin
                            note_on  <= 1'b1;      // 单周期脉冲
                            note_id  <= step_note(cur_key, step);
                            note_inc <= inc_for_note(step_note(cur_key, step));
                            if (step == 2'd2) begin
                                state <= S_SOUND;
                            end else begin
                                step <= step + 2'd1;
                                gap  <= 1'b1;
                            end
                        end
                    end

                    S_SOUND: begin
                        // 目标变了（或全部松开）→ 先释放当前和弦
                        if (!want_valid || (want_key != cur_key)) begin
                            step  <= 2'd0;
                            gap   <= 1'b0;
                            state <= S_REL;
                        end
                    end

                    S_REL: begin
                        if (gap) begin
                            gap <= 1'b0;
                        end else begin
                            note_off <= 1'b1;      // 单周期脉冲
                            note_id  <= step_note(cur_key, step);
                            if (step == 2'd2) begin
                                state <= S_WAIT;
                            end else begin
                                step <= step + 2'd1;
                                gap  <= 1'b1;
                            end
                        end
                    end

                    S_WAIT: begin
                        // 等三个音都走完 ADSR 释放，再起下一个和弦
                        if (voice_busy == {KEYS{1'b0}}) begin
                            if (want_valid) begin
                                cur_key <= want_key;
                                step    <= 2'd0;
                                gap     <= 1'b0;
                                state   <= S_PRESS;
                            end else begin
                                state <= S_IDLE;
                            end
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

    reg [KEYS-1:0] chord_on_r;
    always @* begin
        chord_on_r = {KEYS{1'b0}};
        chord_on_r[cur_key] = 1'b1;
    end

    assign chord_on = ((state == S_PRESS) || (state == S_SOUND)) ? chord_on_r
                                                                 : {KEYS{1'b0}};
endmodule
