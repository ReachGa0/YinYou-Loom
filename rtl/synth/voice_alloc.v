// ============================================================
// voice_alloc.v —— 简单多声部分配器
//
// note_on：优先分配空闲声部；没有空闲声部时按轮转指针抢占。
// note_off：按 note_id 释放对应声部。
// voice_busy 来自 ADSR，Release 未结束时不会复用该声部。
// ============================================================

module voice_alloc #(
    parameter VOICES    = 4,
    parameter PHASE_BITS = 32,
    parameter NOTE_ID_W  = 7
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         note_on,
    input  wire                         note_off,
    input  wire [NOTE_ID_W-1:0]         note_id,
    input  wire [PHASE_BITS-1:0]        note_inc,
    input  wire [VOICES-1:0]            voice_busy,

    output reg  [VOICES*PHASE_BITS-1:0] voice_inc_flat,
    output reg  [VOICES-1:0]            voice_gate_flat,
    output reg  [VOICES-1:0]            voice_active
);
    localparam IDX_W = (VOICES <= 1) ? 1 : $clog2(VOICES);

    reg [NOTE_ID_W-1:0] note_id_reg [0:VOICES-1];
    reg [IDX_W-1:0]     steal_ptr;
    reg [VOICES-1:0]    free_mask;
    reg [IDX_W-1:0]     alloc_idx;
    reg                 alloc_found;

    integer i;

    always @* begin
        free_mask  = {VOICES{1'b0}};
        alloc_idx  = {IDX_W{1'b0}};
        alloc_found = 1'b0;

        for (i = 0; i < VOICES; i = i + 1)
            if (!voice_active[i] && !voice_busy[i])
                free_mask[i] = 1'b1;

        for (i = 0; i < VOICES; i = i + 1)
            if (free_mask[i] && !alloc_found) begin
                alloc_found = 1'b1;
                alloc_idx   = i;
            end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            voice_inc_flat  <= {VOICES*PHASE_BITS{1'b0}};
            voice_gate_flat <= {VOICES{1'b0}};
            voice_active    <= {VOICES{1'b0}};
            steal_ptr       <= {IDX_W{1'b0}};
            for (i = 0; i < VOICES; i = i + 1)
                note_id_reg[i] <= {NOTE_ID_W{1'b0}};
        end else if (note_off) begin
            for (i = 0; i < VOICES; i = i + 1)
                if (voice_active[i] && note_id_reg[i] == note_id) begin
                    voice_gate_flat[i] <= 1'b0;
                    voice_active[i]    <= 1'b0;
                end
        end else if (note_on) begin
            if (alloc_found) begin
                voice_gate_flat[alloc_idx] <= 1'b1;
                voice_active[alloc_idx]    <= 1'b1;
                voice_inc_flat[alloc_idx*PHASE_BITS +: PHASE_BITS] <= note_inc;
                note_id_reg[alloc_idx]     <= note_id;
                steal_ptr <= alloc_idx + 1'b1;
            end else begin
                voice_gate_flat[steal_ptr] <= 1'b1;
                voice_active[steal_ptr]    <= 1'b1;
                voice_inc_flat[steal_ptr*PHASE_BITS +: PHASE_BITS] <= note_inc;
                note_id_reg[steal_ptr]     <= note_id;
                steal_ptr <= steal_ptr + 1'b1;
            end
        end
    end
endmodule
