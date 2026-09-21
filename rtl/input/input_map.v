// ============================================================
// input_map.v —— 按键事件到音符事件的映射
//
// 当前用于 P5A 保底按键：
//   四路按键映射为 C4/E4/G4/B4。
// 后续触摸圆环可以替换上游来源，但保持 note_on/note_off 接口。
// ============================================================

module input_map #(
    parameter KEYS        = 4,
    parameter PHASE_BITS  = 32,
    parameter NOTE_ID_W   = 7
) (
    input  wire [KEYS-1:0]             key_press,
    input  wire [KEYS-1:0]             key_release,

    output reg                         note_on,
    output reg                         note_off,
    output reg  [NOTE_ID_W-1:0]        note_id,
    output reg  [PHASE_BITS-1:0]       note_inc
);
    function [NOTE_ID_W-1:0] note_id_for_key;
        input integer index;
        begin
            case (index)
                0: note_id_for_key = 7'd60;  // C4
                1: note_id_for_key = 7'd64;  // E4
                2: note_id_for_key = 7'd67;  // G4
                3: note_id_for_key = 7'd71;  // B4
                default: note_id_for_key = 7'd60;
            endcase
        end
    endfunction

    function [PHASE_BITS-1:0] inc_for_key;
        input integer index;
        begin
            case (index)
                0: inc_for_key = 32'd23409859;  // C4
                1: inc_for_key = 32'd29494575;  // E4
                2: inc_for_key = 32'd35075158;  // G4
                3: inc_for_key = 32'd44191930;  // B4
                default: inc_for_key = 32'd23409859;
            endcase
        end
    endfunction

    reg             found_press;
    reg             found_release;
    reg [NOTE_ID_W-1:0] pressed_id;
    reg [NOTE_ID_W-1:0] released_id;
    integer i;

    always @* begin
        note_on       = 1'b0;
        note_off      = 1'b0;
        note_id       = {NOTE_ID_W{1'b0}};
        note_inc      = {PHASE_BITS{1'b0}};
        found_press   = 1'b0;
        found_release = 1'b0;
        pressed_id    = {NOTE_ID_W{1'b0}};
        released_id   = {NOTE_ID_W{1'b0}};

        for (i = 0; i < KEYS; i = i + 1) begin
            if (key_press[i] && !found_press) begin
                found_press = 1'b1;
                pressed_id  = note_id_for_key(i);
            end
            if (key_release[i] && !found_release) begin
                found_release = 1'b1;
                released_id   = note_id_for_key(i);
            end
        end

        if (found_press) begin
            note_on  = 1'b1;
            note_id  = pressed_id;
            note_inc = inc_for_key(0);
            for (i = 0; i < KEYS; i = i + 1)
                if (key_press[i] && note_id_for_key(i) == pressed_id)
                    note_inc = inc_for_key(i);
        end else if (found_release) begin
            note_off = 1'b1;
            note_id  = released_id;
        end
    end
endmodule
