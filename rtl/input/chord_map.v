// ============================================================
// chord_map.v —— 七键 → C 大调自然三和弦，且"同一时刻只有一个和弦在响"
//
// 语义（2026-09-23 与用户确认的"最近按下优先"）：
//   按住 I            → 响 I 级和弦（C4-E4-G4）
//   再按 ii（I 不松） → 响 ii 级和弦（D4-F4-A4）
//   松开 ii（I 仍按） → 回到 I 级和弦
//   全部松开          → 停止
//
// 为什么限定"只有一个和弦"：4 个声部放不下两个三音和弦（6 音）。叠置会触发
// voice_alloc 轮转抢占 → 丢音；而且不同键的和弦之间会出现同名 note_id
// （例如 A 的 E4 与 B 的 E4 都是 64）→ 释放时会误杀别的键的音。
// 限定后声部需求 ≤ 3，两个问题从根上消失，听感也更像"和弦进行"。
//
// 七个键 = C 大调的七个音级（I ii iii IV V vi vii°），各自触发本音级上的
// 自然三和弦（vi/vii° 为小三和弦与减三和弦），不改变"一个键一个和弦"的语义。
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
    parameter KEYS   = 7,
    parameter BUSY_W = 4          // 声部数（与 KEYS 无关，v1.0 为 4）
) (
    input  wire            clk,
    input  wire            rst_n,
    input  wire            enable,       // 1 = 和弦模式
    input  wire [KEYS-1:0] pressed,      // 消抖后的按键电平
    input  wire [BUSY_W-1:0] voice_busy, // ADSR 是否还在发声

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

    // 第 s 个音：0=根音、1=三音、2=五音。
    // C 大调七个音级的自然三和弦音程：
    //   I(0,4,7) ii(0,3,7) iii(0,3,7) IV(0,4,7) V(0,4,7) vi(0,3,7) vii°(0,3,6)
    function [6:0] step_note;
        input [2:0] k;
        input [1:0] s;
        reg [6:0] root;
        reg [6:0] third;
        reg [6:0] fifth;
        begin
            case (k)
                3'd0: begin root = 7'd60; third = 7'd4; fifth = 7'd7; end // I    C E G
                3'd1: begin root = 7'd62; third = 7'd3; fifth = 7'd7; end // ii   D F A
                3'd2: begin root = 7'd64; third = 7'd3; fifth = 7'd7; end // iii  E G B
                3'd3: begin root = 7'd65; third = 7'd4; fifth = 7'd7; end // IV   F A C
                3'd4: begin root = 7'd67; third = 7'd4; fifth = 7'd7; end // V    G B D
                3'd5: begin root = 7'd69; third = 7'd3; fifth = 7'd7; end // vi   A C E
                default: begin root = 7'd71; third = 7'd3; fifth = 7'd6; end // vii° B D F
            endcase
            case (s)
                2'd1: step_note = root + third;
                2'd2: step_note = root + fifth;
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
                7'd62: inc_for_note = 32'd26276679;  // D4  293.665 Hz
                7'd64: inc_for_note = 32'd29494575;  // E4  329.628 Hz
                7'd65: inc_for_note = 32'd31248413;  // F4  349.228 Hz
                7'd67: inc_for_note = 32'd35075158;  // G4  391.995 Hz
                7'd69: inc_for_note = 32'd39370534;  // A4  440.000 Hz
                7'd71: inc_for_note = 32'd44191930;  // B4  493.883 Hz
                7'd72: inc_for_note = 32'd46819719;  // C5  523.251 Hz
                7'd74: inc_for_note = 32'd52553357;  // D5  587.330 Hz
                7'd76: inc_for_note = 32'd58989149;  // E5  659.255 Hz
                7'd77: inc_for_note = 32'd62496826;  // F5  698.456 Hz
                default: inc_for_note = 32'd23409859;
            endcase
        end
    endfunction

    reg [2:0] state;
    reg [1:0] step;
    reg       gap;                 // 脉冲之间空一拍
    reg [2:0] cur_key;             // 当前响着的键
    reg [2:0] want_key;            // 最近按下的键（扫描器输出，已寄存）
    reg       want_valid;

    reg [7:0] stamp [0:KEYS-1];    // 各键按下时间戳
    reg [7:0] stamp_ctr;
    reg [KEYS-1:0] pressed_d;

    // ---- 最近按下优先：逐拍扫描（每拍只比较一个键）----
    // 原来是一个 7 层组合链（mux + 8 位减法 + 比较串起来），7 键版本在 72 MHz 下
    // setup 违例达 −19.5 ns（P&R 报 u_chord/stamp → u_chord/step_*/CE）。
    // 改为每拍评估一个键、7 拍出一次结果：组合路径只剩一个 8 位减法器。
    // 代价是 want_* 每 7 拍（约 97 ns）才更新一次，对和弦切换完全无感。
    localparam SCAN_W = (KEYS <= 1) ? 1 : $clog2(KEYS);

    reg [SCAN_W-1:0] scan_idx;
    reg [2:0]        best_key;
    reg [7:0]        best_stamp;
    reg              best_valid;

    wire [7:0]       scan_diff  = stamp[scan_idx] - best_stamp;
    wire             scan_take  = pressed[scan_idx] &&
                                  (!best_valid ||
                                   ((scan_diff != 8'd0) && (scan_diff < 8'd128)));
    wire [2:0]       next_key   = scan_take ? scan_idx : best_key;
    wire             next_valid = best_valid | pressed[scan_idx];

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

    // ---- 扫描器：每拍评估一个键，一轮结束时把结果搬到 want_* ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_idx   <= {SCAN_W{1'b0}};
            best_key   <= 3'd0;
            best_stamp <= 8'd0;
            best_valid <= 1'b0;
            want_key   <= 3'd0;
            want_valid <= 1'b0;
        end else if (scan_idx == (KEYS - 1)) begin
            scan_idx   <= {SCAN_W{1'b0}};
            want_key   <= next_key;
            want_valid <= next_valid;
            best_valid <= 1'b0;              // 下一轮重新统计
        end else begin
            scan_idx   <= scan_idx + 1'b1;
            best_key   <= next_key;
            best_valid <= next_valid;
            best_stamp <= scan_take ? stamp[scan_idx] : best_stamp;
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
                        // 注意：voice_busy 的位宽是声部数（4），不等于 KEYS（7），
                        // 这里必须用"全零"判断，不能和 {KEYS{1'b0}} 比。
                        if (!(|voice_busy)) begin
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
