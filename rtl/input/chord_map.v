// ============================================================
// chord_map.v —— 按键 → 大三和弦（一个键按下去叠加三个音）
//
// 根音与和弦：键0 C4(C4-E4-G4)、键1 E4(E4-G#4-B4)、
//             键2 G4(G4-B4-D5)、键3 B4(B4-D#5-F#5)
// 即每个键 = 根音 + 大三度(+4) + 纯五度(+7)。
//
// 时序：key_press / key_release 是 key_scan 消抖后的单周期脉冲。收到按下脉冲后
// 连续发三个 note_on（脉冲之间空一拍，保证每个脉冲只占一个周期）；收到释放
// 脉冲后用同样方式发三个 note_off。
//
// 注意：三音 × 两键 = 6 音 > VOICES=4，此时由 voice_alloc 轮转抢占（预期行为）。
// 调音字与 tools/tune_word.py 公式一致（440*2^((n-69)/12) × 2^32 / 48000）。
//
// 本文件含两个模块：chord_voice（单键三音序列）与 chord_map（显式例化 4 份）。
// 刻意不用 generate：高云综合器对 generate 内的 localparam 与打包数组切片支持
// 不好，会导致顶层被丢弃（2026-09-23 实际踩过）。
// ============================================================

module chord_voice (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        key_press,
    input  wire        key_release,
    input  wire [6:0]  base_note,

    output reg         note_on,
    output reg         note_off,
    output reg  [6:0]  note_id,
    output reg  [31:0] note_inc,
    output reg         held
);
    localparam [1:0] S_IDLE  = 2'd0,
                     S_PRESS = 2'd1,
                     S_HOLD  = 2'd2,
                     S_REL   = 2'd3;

    function [6:0] step_note;
        input [6:0] base;
        input [1:0] s;
        begin
            case (s)
                2'd1: step_note = base + 7'd4;
                2'd2: step_note = base + 7'd7;
                default: step_note = base;
            endcase
        end
    endfunction

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

    reg [1:0] st;
    reg [1:0] step;
    reg       gap;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            step     <= 2'd0;
            gap      <= 1'b0;
            note_on  <= 1'b0;
            note_off <= 1'b0;
            note_id  <= base_note;
            note_inc <= inc_for_note(base_note);
            held     <= 1'b0;
        end else begin
            note_on  <= 1'b0;
            note_off <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (key_press) begin
                        st   <= S_PRESS;
                        step <= 2'd0;
                        gap  <= 1'b0;
                    end
                end

                S_PRESS: begin
                    if (gap) begin
                        gap <= 1'b0;
                    end else begin
                        note_on  <= 1'b1;
                        note_id  <= step_note(base_note, step);
                        note_inc <= inc_for_note(step_note(base_note, step));
                        if (step == 2'd2) begin
                            st   <= S_HOLD;
                            held <= 1'b1;
                        end else begin
                            step <= step + 2'd1;
                            gap  <= 1'b1;
                        end
                    end
                end

                S_HOLD: begin
                    if (key_release) begin
                        st   <= S_REL;
                        step <= 2'd0;
                        gap  <= 1'b0;
                    end
                end

                S_REL: begin
                    if (gap) begin
                        gap <= 1'b0;
                    end else begin
                        note_off <= 1'b1;
                        note_id  <= step_note(base_note, step);
                        if (step == 2'd2) begin
                            st   <= S_IDLE;
                            held <= 1'b0;
                        end else begin
                            step <= step + 2'd1;
                            gap  <= 1'b1;
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule

module chord_map #(
    parameter KEYS = 4
) (
    input  wire            clk,
    input  wire            rst_n,
    input  wire [KEYS-1:0] key_press,
    input  wire [KEYS-1:0] key_release,

    output wire            note_on,
    output wire            note_off,
    output wire [6:0]      note_id,
    output wire [31:0]     note_inc,
    output wire [KEYS-1:0] chord_on
);
    wire        on0, on1, on2, on3;
    wire        off0, off1, off2, off3;
    wire [6:0]  id0, id1, id2, id3;
    wire [31:0] inc0, inc1, inc2, inc3;
    wire        h0, h1, h2, h3;

    chord_voice u_k0 (
        .clk(clk), .rst_n(rst_n), .key_press(key_press[0]), .key_release(key_release[0]),
        .base_note(7'd60),
        .note_on(on0), .note_off(off0), .note_id(id0), .note_inc(inc0), .held(h0));

    chord_voice u_k1 (
        .clk(clk), .rst_n(rst_n), .key_press(key_press[1]), .key_release(key_release[1]),
        .base_note(7'd64),
        .note_on(on1), .note_off(off1), .note_id(id1), .note_inc(inc1), .held(h1));

    chord_voice u_k2 (
        .clk(clk), .rst_n(rst_n), .key_press(key_press[2]), .key_release(key_release[2]),
        .base_note(7'd67),
        .note_on(on2), .note_off(off2), .note_id(id2), .note_inc(inc2), .held(h2));

    chord_voice u_k3 (
        .clk(clk), .rst_n(rst_n), .key_press(key_press[3]), .key_release(key_release[3]),
        .base_note(7'd71),
        .note_on(on3), .note_off(off3), .note_id(id3), .note_inc(inc3), .held(h3));

    wire any_on  = on0  | on1  | on2  | on3;
    wire any_off = off0 | off1 | off2 | off3;
    wire [1:0] sel_on  = on0  ? 2'd0 : on1  ? 2'd1 : on2  ? 2'd2 : 2'd3;
    wire [1:0] sel_off = off0 ? 2'd0 : off1 ? 2'd1 : off2 ? 2'd2 : 2'd3;

    wire [6:0] id_on  = (sel_on  == 2'd0) ? id0 : (sel_on  == 2'd1) ? id1 :
                        (sel_on  == 2'd2) ? id2 : id3;
    wire [6:0] id_off = (sel_off == 2'd0) ? id0 : (sel_off == 2'd1) ? id1 :
                        (sel_off == 2'd2) ? id2 : id3;

    assign note_on  = any_on;
    assign note_off = any_off;
    assign note_id  = any_on ? id_on : id_off;
    assign note_inc = (sel_on == 2'd0) ? inc0 : (sel_on == 2'd1) ? inc1 :
                      (sel_on == 2'd2) ? inc2 : inc3;
    assign chord_on = {h3, h2, h1, h0};
endmodule
