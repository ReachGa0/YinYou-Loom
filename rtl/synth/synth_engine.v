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
    parameter INIT_FILE0 = "data/wavetables/sine_4096x16.hex",
    parameter INIT_FILE1 = "data/wavetables/square_4096x16.hex"
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          sample_en,
    input  wire                          table_sel,
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
    wire [VOICES-1:0]            gate_flat;

    localparam [VOICES*LEVEL_W-1:0] A_STEP_FLAT =
        {VOICES{16'd273}};
    localparam [VOICES*LEVEL_W-1:0] D_STEP_FLAT =
        {VOICES{16'd20}};
    localparam [VOICES*LEVEL_W-1:0] SUSTAIN_FLAT =
        {VOICES{16'd32768}};
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
        .voice_busy      (voice_busy),
        .voice_inc_flat  (inc_flat),
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
        .INIT_FILE1 (INIT_FILE1)
    ) u_synth (
        .clk                (clk),
        .rst_n              (rst_n),
        .sample_en          (sample_en),
        .table_sel          (table_sel),
        .inc_flat           (inc_flat),
        .gate_flat          (gate_flat),
        .a_step_flat        (A_STEP_FLAT),
        .d_step_flat        (D_STEP_FLAT),
        .sustain_level_flat (SUSTAIN_FLAT),
        .r_step_flat        (R_STEP_FLAT),
        .mix_sample         (mix_sample),
        .scan_done          (scan_done),
        .voice_valid        (),
        .busy_flat          (voice_busy)
    );
endmodule
