// ============================================================
// synth_engine.v —— 带声部分配的完整合成引擎
//
// note_on / note_off
//        ↓
//    voice_alloc
//        ↓ gate / inc
//      synth_top（共享波表 + ADSR + mixer）
// ============================================================

module synth_engine #(
    parameter VOICES     = 4,
    parameter PHASE_BITS = 32,
    parameter ADDR_BITS  = 12,
    parameter SAMPLE_W   = 16,
    parameter LEVEL_W    = 16,
    parameter NOTE_ID_W  = 7,
    parameter [LEVEL_W-1:0] SUSTAIN_LEVEL = 16'd8192,
    parameter INIT_FILE0 = "data/wavetables/sine_4096x16.hex",
    parameter INIT_FILE1 = "data/wavetables/square_4096x16.hex",
    parameter INIT_FILE2 = "data/wavetables/saw_4096x16.hex",
    parameter INIT_FILE3 = "data/wavetables/triangle_4096x16.hex"
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          sample_en,
    input  wire [1:0]                    table_sel,
    input  wire [15:0]                   bend_q15,     // 32768 = 1.0
    input  wire [7:0]                    velocity,     // 0..255（note-on 时锁存）
    input  wire                          note_on,
    input  wire                          note_off,
    input  wire [NOTE_ID_W-1:0]          note_id,
    input  wire [PHASE_BITS-1:0]         note_inc,

    output wire signed [SAMPLE_W-1:0]    mix_sample,
    output wire                          scan_done,
    output wire [VOICES-1:0]             voice_active,
    output wire [VOICES-1:0]             voice_busy
);
    wire [VOICES*PHASE_BITS-1:0] inc_flat;
    wire [VOICES*16-1:0]         gain_flat;
    wire [VOICES-1:0]            gate_flat;

    // A 加权近似补偿表，按 C4 归一化并用 1/32 分辨率量化。
    // 这些系数在 voice 中用加减和移位实现，避免新增乘法器拖长时序。
    function [15:0] gain_for_note;
        input [NOTE_ID_W-1:0] id;
        begin
            case (id)
                7'd60: gain_for_note = 16'd32768;  // C4, 1.0000
                7'd64: gain_for_note = 16'd25600;  // E4, 25/32 = 0.78125
                7'd67: gain_for_note = 16'd22528;  // G4, 11/16 = 0.68750
                7'd69: gain_for_note = 16'd20480;  // A4, 5/8  = 0.62500
                7'd71: gain_for_note = 16'd18432;  // B4, 9/16 = 0.56250
                default: gain_for_note = 16'd32768;
            endcase
        end
    endfunction

    // 力度：音色 A 加权系数 × velocity/255（24 位中间量，避免乘法被截断）
    wire [15:0] a_gain   = gain_for_note(note_id);
    wire [23:0] gain_vel = a_gain * velocity;
    wire [15:0] note_gain = gain_vel[23:8];

    localparam [VOICES*LEVEL_W-1:0] A_STEP_FLAT =
        {VOICES{16'd273}};
    localparam [VOICES*LEVEL_W-1:0] D_STEP_FLAT =
        {VOICES{16'd20}};
    localparam [VOICES*LEVEL_W-1:0] SUSTAIN_FLAT =
        {VOICES{SUSTAIN_LEVEL}};
    localparam [VOICES*LEVEL_W-1:0] R_STEP_FLAT =
        {VOICES{16'd20}};

    voice_alloc #(
        .VOICES     (VOICES),
        .PHASE_BITS (PHASE_BITS),
        .NOTE_ID_W  (NOTE_ID_W)
    ) u_alloc (
        .clk             (clk),
        .rst_n           (rst_n),
        .note_on         (note_on),
        .note_off        (note_off),
        .note_id         (note_id),
        .note_inc        (note_inc),
        .note_gain       (note_gain),
        .voice_busy      (voice_busy),
        .voice_inc_flat  (inc_flat),
        .voice_gain_flat (gain_flat),
        .voice_gate_flat (gate_flat),
        .voice_active    (voice_active)
    );

    synth_top #(
        .VOICES     (VOICES),
        .PHASE_BITS (PHASE_BITS),
        .ADDR_BITS  (ADDR_BITS),
        .SAMPLE_W   (SAMPLE_W),
        .LEVEL_W    (LEVEL_W),
        .INIT_FILE0 (INIT_FILE0),
        .INIT_FILE1 (INIT_FILE1),
        .INIT_FILE2 (INIT_FILE2),
        .INIT_FILE3 (INIT_FILE3)
    ) u_synth (
        .clk                (clk),
        .rst_n              (rst_n),
        .sample_en          (sample_en),
        .table_sel          (table_sel),
        .bend_q15           (bend_q15),
        .inc_flat           (inc_flat),
        .gate_flat          (gate_flat),
        .a_step_flat        (A_STEP_FLAT),
        .d_step_flat        (D_STEP_FLAT),
        .sustain_level_flat (SUSTAIN_FLAT),
        .r_step_flat        (R_STEP_FLAT),
        .gain_flat          (gain_flat),
        .mix_sample         (mix_sample),
        .scan_done          (scan_done),
        .voice_valid        (),
        .busy_flat          (voice_busy)
    );
endmodule
