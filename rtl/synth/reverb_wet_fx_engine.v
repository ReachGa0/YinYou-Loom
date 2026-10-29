// ============================================================
// 独立诊断版：REVERB 输出仅保留 wet 分量，反馈为零。
// 其他模式、共享 RAM、延迟长度与干湿输出沿用原 fx_engine。
//
// mode = 0 DRY
// mode = 1 CHORUS
// mode = 2 DELAY（约 250 ms）
// mode = 3 REVERB（四路短反馈延迟）
//
// CHORUS / DELAY / REVERB 使用同一块 16384×16 BSRAM：
//   CHORUS : 低地址区 2048 点调制延迟
//   DELAY  : 0..11999 环形缓冲
//   REVERB : 低地址区划分四条短反馈线
// 三档互斥，模式切换时先输出干声并清空使用区，避免旧尾音串入新效果。
// ============================================================

module reverb_wet_fx_engine #(
    parameter SAMPLE_W        = 16,
    parameter MEM_ADDR_W      = 14,
    parameter CHORUS_ADDR_W   = 11,
    parameter CHORUS_MIN_DLY  = 512,
    parameter [23:0] LFO_STEP = 24'd128,
    parameter DELAY_SAMPLES   = 12000,
    parameter CLEAR_SAMPLES   = 12000,
    parameter REV_LEN0        = 997,
    parameter REV_LEN1        = 1123,
    parameter REV_LEN2        = 1277,
    parameter REV_LEN3        = 1427,
    parameter FADE_SHIFT      = 5,
    parameter integer FADE_SAMPLES = 512
) /*synthesis syn_ramstyle="block_ram"*/ (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       sample_en,
    input  wire [1:0]                 mode,
    input  wire signed [SAMPLE_W-1:0] sample_in,
    output reg  signed [SAMPLE_W-1:0] sample_out,
    output reg                        sample_valid_out
);
    localparam DEPTH = (1 << MEM_ADDR_W);
    localparam CH_DEPTH = (1 << CHORUS_ADDR_W);
    localparam integer REV_BASE0 = 0;
    localparam integer REV_BASE1 = REV_LEN0;
    localparam integer REV_BASE2 = REV_LEN0 + REV_LEN1;
    localparam integer REV_BASE3 = REV_LEN0 + REV_LEN1 + REV_LEN2;

    localparam [4:0] S_IDLE    = 5'd0,
                     S_CLEAR   = 5'd1,
                     S_CH_RA   = 5'd2,
                     S_CH_RB   = 5'd3,
                     S_CH_WR   = 5'd4,
                     S_CH_OUT  = 5'd5,
                     S_D_READ  = 5'd6,
                     S_D_WRITE = 5'd7,
                     S_D_OUT   = 5'd8,
                     S_R_R0    = 5'd9,
                     S_R_R1    = 5'd10,
                     S_R_R2    = 5'd11,
                     S_R_R3    = 5'd12,
                     S_R_W0    = 5'd13,
                     S_R_W1    = 5'd14,
                     S_R_W2    = 5'd15,
                     S_R_W3    = 5'd16,
                     S_R_OUT   = 5'd17,
                     S_CH_MIX  = 5'd18,
                     S_CH_WAIT_A = 5'd19,
                     S_CH_WAIT_B = 5'd20,
                     S_D_WAIT    = 5'd21,
                     S_R_WAIT0   = 5'd22,
                     S_R_WAIT1   = 5'd23,
                     S_R_WAIT2   = 5'd24,
                     S_R_WAIT3   = 5'd25;

    reg [4:0] state;
    reg [MEM_ADDR_W-1:0] read_addr;
    reg [MEM_ADDR_W-1:0] clear_addr;
    reg [MEM_ADDR_W-1:0] delay_ptr;
    reg [CHORUS_ADDR_W-1:0] chorus_ptr;
    reg [CHORUS_ADDR_W-1:0] rev_pos0, rev_pos1, rev_pos2, rev_pos3;
    reg [23:0] lfo_phase;
    reg [1:0] active_mode;
    reg       clear_done;
    reg [9:0] fade_samples;
    reg signed [SAMPLE_W-1:0] dry_hold;
    reg signed [SAMPLE_W-1:0] tap_a;
    reg signed [SAMPLE_W-1:0] tap_b;
    reg signed [SAMPLE_W-1:0] tap_delay;
    reg signed [SAMPLE_W-1:0] tap0, tap1, tap2, tap3;
    reg [7:0] frac_hold;
    reg signed [SAMPLE_W+8:0] ch_prod_q;
    reg signed [SAMPLE_W-1:0] ch_wet_q;
    reg signed [SAMPLE_W:0] blend_out;

    wire signed [SAMPLE_W-1:0] ram_rdata;
    reg  signed [SAMPLE_W-1:0] ram_wdata;
    reg [MEM_ADDR_W-1:0] ram_waddr;
    reg                   ram_we;

    reverb_wet_shared_ram #(
        .SAMPLE_W (SAMPLE_W),
        .ADDR_W   (MEM_ADDR_W)
    ) u_shared_ram (
        .clk   (clk),
        .we    (ram_we),
        .raddr (read_addr),
        .rdata (ram_rdata),
        .waddr (ram_waddr),
        .wdata (ram_wdata)
    );

    wire [7:0] lfo_int  = lfo_phase[23] ? ~lfo_phase[22:15] : lfo_phase[22:15];
    wire [7:0] lfo_frac = lfo_phase[23] ? ~lfo_phase[14:7]  : lfo_phase[14:7];
    wire [CHORUS_ADDR_W-1:0] ch_addr_a =
        chorus_ptr - CHORUS_MIN_DLY - lfo_int;
    wire [CHORUS_ADDR_W-1:0] ch_addr_b = ch_addr_a - 1'b1;
    wire [MEM_ADDR_W-1:0] delay_addr = delay_ptr - DELAY_SAMPLES;

    wire signed [SAMPLE_W:0] dry_ext = {dry_hold[SAMPLE_W-1], dry_hold};
    wire signed [SAMPLE_W:0] diff_ch = tap_b - tap_a;
    wire signed [SAMPLE_W+8:0] ch_prod = diff_ch * $signed({1'b0, frac_hold});
    wire signed [SAMPLE_W-1:0] chorus_wet = tap_a + (ch_prod_q >>> 8);
    wire signed [SAMPLE_W:0] chorus_ext = {ch_wet_q[SAMPLE_W-1], ch_wet_q};
    wire signed [SAMPLE_W:0] chorus_mix = (dry_ext + chorus_ext) >>> 1;

    wire signed [SAMPLE_W:0] delay_ext = {tap_delay[SAMPLE_W-1], tap_delay};
    wire signed [SAMPLE_W:0] delay_mix = (dry_ext + delay_ext) >>> 1;

    wire signed [SAMPLE_W+1:0] tap0_ext = {{2{tap0[SAMPLE_W-1]}}, tap0};
    wire signed [SAMPLE_W+1:0] tap1_ext = {{2{tap1[SAMPLE_W-1]}}, tap1};
    wire signed [SAMPLE_W+1:0] tap2_ext = {{2{tap2[SAMPLE_W-1]}}, tap2};
    wire signed [SAMPLE_W+1:0] tap3_ext = {{2{tap3[SAMPLE_W-1]}}, tap3};
    wire signed [SAMPLE_W+1:0] tap0_fb = (tap0_ext >>> 1) + (tap0_ext >>> 3);
    wire signed [SAMPLE_W+1:0] tap1_fb = (tap1_ext >>> 1) + (tap1_ext >>> 3);
    wire signed [SAMPLE_W+1:0] tap2_fb = (tap2_ext >>> 1) + (tap2_ext >>> 3);
    wire signed [SAMPLE_W+1:0] tap3_fb = (tap3_ext >>> 1) + (tap3_ext >>> 3);
    wire signed [SAMPLE_W+2:0] reverb_sum =
        {{2{tap0[SAMPLE_W-1]}}, tap0} +
        {{2{tap1[SAMPLE_W-1]}}, tap1} +
        {{2{tap2[SAMPLE_W-1]}}, tap2} +
        {{2{tap3[SAMPLE_W-1]}}, tap3};
    wire signed [SAMPLE_W-1:0] reverb_wet = reverb_sum >>> 2;
    wire signed [SAMPLE_W+1:0] reverb_ext = {{2{reverb_wet[SAMPLE_W-1]}}, reverb_wet};
    wire signed [SAMPLE_W+1:0] dry18 = {{2{dry_hold[SAMPLE_W-1]}}, dry_hold};
    // 半干声 + 半湿声；单路线路注入已降为 1/4，整体输出仍不超出 16 位范围。
    wire signed [SAMPLE_W+1:0] reverb_mix =
        (reverb_ext >>> 1);

    function signed [SAMPLE_W-1:0] saturate;
        input signed [SAMPLE_W+1:0] value;
        begin
            if (value > 32767)
                saturate = 16'sh7fff;
            else if (value < -32768)
                saturate = 16'sh8000;
            else
                saturate = value[SAMPLE_W-1:0];
        end
    endfunction

    function signed [SAMPLE_W:0] smooth_target;
        input signed [SAMPLE_W:0] target;
        begin
            if ((target - blend_out) > (1 << FADE_SHIFT))
                smooth_target = blend_out + ((target - blend_out) >>> FADE_SHIFT);
            else if ((blend_out - target) > (1 << FADE_SHIFT))
                smooth_target = blend_out - ((blend_out - target) >>> FADE_SHIFT);
            else
                smooth_target = target;
        end
    endfunction

    function signed [SAMPLE_W:0] next_output;
        input signed [SAMPLE_W:0] target;
        begin
            if (fade_samples == 0)
                next_output = target;
            else
                next_output = smooth_target(target);
        end
    endfunction

    reg signed [SAMPLE_W:0] next_mix;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            read_addr        <= {MEM_ADDR_W{1'b0}};
            clear_addr       <= {MEM_ADDR_W{1'b0}};
            delay_ptr        <= {MEM_ADDR_W{1'b0}};
            chorus_ptr       <= {CHORUS_ADDR_W{1'b0}};
            rev_pos0         <= {CHORUS_ADDR_W{1'b0}};
            rev_pos1         <= {CHORUS_ADDR_W{1'b0}};
            rev_pos2         <= {CHORUS_ADDR_W{1'b0}};
            rev_pos3         <= {CHORUS_ADDR_W{1'b0}};
            lfo_phase        <= 24'd0;
            active_mode      <= 2'd0;
            clear_done       <= 1'b0;
            fade_samples     <= 10'd0;
            dry_hold         <= {SAMPLE_W{1'b0}};
            tap_a            <= {SAMPLE_W{1'b0}};
            tap_b            <= {SAMPLE_W{1'b0}};
            tap_delay        <= {SAMPLE_W{1'b0}};
            tap0             <= {SAMPLE_W{1'b0}};
            tap1             <= {SAMPLE_W{1'b0}};
            tap2             <= {SAMPLE_W{1'b0}};
            tap3             <= {SAMPLE_W{1'b0}};
            frac_hold        <= 8'd0;
            ch_prod_q        <= {(SAMPLE_W+9){1'b0}};
            ch_wet_q         <= {SAMPLE_W{1'b0}};
            blend_out        <= {SAMPLE_W+1{1'b0}};
            ram_we           <= 1'b0;
            ram_waddr        <= {MEM_ADDR_W{1'b0}};
            ram_wdata        <= {SAMPLE_W{1'b0}};
            sample_out       <= {SAMPLE_W{1'b0}};
            sample_valid_out <= 1'b0;
        end else begin
            sample_valid_out <= 1'b0;
            ram_we           <= 1'b0;

            case (state)
                S_IDLE: if (sample_en) begin
                    dry_hold <= sample_in;
                    if (mode != active_mode) begin
                        active_mode <= mode;
                        if (mode == 2'd0) begin
                            next_mix = next_output({sample_in[SAMPLE_W-1], sample_in});
                            sample_out       <= next_mix[SAMPLE_W-1:0];
                            blend_out        <= next_mix;
                            sample_valid_out <= 1'b1;
                        end else begin
                            clear_addr       <= {MEM_ADDR_W{1'b0}};
                            clear_done       <= 1'b0;
                            fade_samples     <= FADE_SAMPLES;
                            next_mix = next_output({sample_in[SAMPLE_W-1], sample_in});
                            sample_out       <= next_mix[SAMPLE_W-1:0];
                            blend_out        <= next_mix;
                            sample_valid_out <= 1'b1;
                            state            <= S_CLEAR;
                        end
                    end else begin
                        case (mode)
                            2'd0: begin
                                next_mix = next_output({sample_in[SAMPLE_W-1], sample_in});
                                blend_out        <= next_mix;
                                sample_out       <= next_mix[SAMPLE_W-1:0];
                                sample_valid_out <= 1'b1;
                            end
                            2'd1: begin
                                read_addr <= ch_addr_a;
                                frac_hold <= lfo_frac;
                                state     <= S_CH_WAIT_A;
                            end
                            2'd2: begin
                                read_addr <= delay_addr;
                                state     <= S_D_WAIT;
                            end
                            default: begin
                                read_addr <= REV_BASE0 + rev_pos0;
                                state     <= S_R_WAIT0;
                            end
                        endcase
                    end
                end

                S_CLEAR: begin
                    if (sample_en) begin
                        next_mix = next_output({sample_in[SAMPLE_W-1], sample_in});
                        sample_out       <= next_mix[SAMPLE_W-1:0];
                        blend_out        <= next_mix;
                        sample_valid_out <= 1'b1;
                        if (fade_samples != 0)
                            fade_samples <= fade_samples - 1'b1;
                        if (clear_done && (fade_samples <= 1))
                            state <= S_IDLE;
                    end else if (!clear_done) begin
                        ram_we    <= 1'b1;
                        ram_waddr <= clear_addr;
                        ram_wdata <= {SAMPLE_W{1'b0}};
                        if (clear_addr == CLEAR_SAMPLES-1) begin
                            clear_done <= 1'b1;
                            if (fade_samples == 0)
                                state <= S_IDLE;
                        end else begin
                            clear_addr <= clear_addr + 1'b1;
                        end
                    end
                end

                S_CH_WAIT_A: state <= S_CH_RA;

                S_CH_RA: begin
                    tap_a     <= ram_rdata;
                    read_addr <= ch_addr_b;
                    state     <= S_CH_WAIT_B;
                end

                S_CH_WAIT_B: state <= S_CH_RB;

                S_CH_RB: begin
                    tap_b <= ram_rdata;
                    state <= S_CH_WR;
                end

                S_CH_WR: begin
                    ram_we    <= 1'b1;
                    ram_waddr <= chorus_ptr;
                    ram_wdata <= dry_hold;
                    ch_prod_q <= ch_prod;
                    state <= S_CH_MIX;
                end

                S_CH_MIX: begin
                    ch_wet_q <= chorus_wet;
                    state <= S_CH_OUT;
                end

                S_CH_OUT: begin
                    next_mix = next_output(chorus_mix);
                    blend_out        <= next_mix;
                    sample_out       <= next_mix[SAMPLE_W-1:0];
                    sample_valid_out <= 1'b1;
                    chorus_ptr <= chorus_ptr + 1'b1;
                    lfo_phase  <= lfo_phase + LFO_STEP;
                    state      <= S_IDLE;
                end

                S_D_WAIT: state <= S_D_READ;

                S_D_READ: begin
                    tap_delay <= ram_rdata;
                    state     <= S_D_WRITE;
                end

                S_D_WRITE: begin
                    ram_we    <= 1'b1;
                    ram_waddr <= delay_ptr;
                    ram_wdata <= saturate(dry_ext + (delay_ext >>> 1));
                    delay_ptr <= delay_ptr + 1'b1;
                    state     <= S_D_OUT;
                end

                S_D_OUT: begin
                    next_mix = next_output(delay_mix);
                    blend_out        <= next_mix;
                    sample_out       <= next_mix[SAMPLE_W-1:0];
                    sample_valid_out <= 1'b1;
                    state            <= S_IDLE;
                end

                S_R_WAIT0: state <= S_R_R0;

                S_R_R0: begin
                    tap0 <= ram_rdata;
                    read_addr <= REV_BASE1 + rev_pos1;
                    state <= S_R_WAIT1;
                end

                S_R_WAIT1: state <= S_R_R1;

                S_R_R1: begin
                    tap1 <= ram_rdata;
                    read_addr <= REV_BASE2 + rev_pos2;
                    state <= S_R_WAIT2;
                end

                S_R_WAIT2: state <= S_R_R2;

                S_R_R2: begin
                    tap2 <= ram_rdata;
                    read_addr <= REV_BASE3 + rev_pos3;
                    state <= S_R_WAIT3;
                end

                S_R_WAIT3: state <= S_R_R3;

                S_R_R3: begin
                    tap3 <= ram_rdata;
                    state <= S_R_W0;
                end

                S_R_W0: begin
                    ram_we    <= 1'b1;
                    ram_waddr <= REV_BASE0 + rev_pos0;
                    ram_wdata <= saturate((dry18 >>> 2));
                    rev_pos0 <= (rev_pos0 == REV_LEN0-1) ? {CHORUS_ADDR_W{1'b0}} : rev_pos0 + 1'b1;
                    state <= S_R_W1;
                end

                S_R_W1: begin
                    ram_we    <= 1'b1;
                    ram_waddr <= REV_BASE1 + rev_pos1;
                    ram_wdata <= saturate((dry18 >>> 2));
                    rev_pos1 <= (rev_pos1 == REV_LEN1-1) ? {CHORUS_ADDR_W{1'b0}} : rev_pos1 + 1'b1;
                    state <= S_R_W2;
                end

                S_R_W2: begin
                    ram_we    <= 1'b1;
                    ram_waddr <= REV_BASE2 + rev_pos2;
                    ram_wdata <= saturate((dry18 >>> 2));
                    rev_pos2 <= (rev_pos2 == REV_LEN2-1) ? {CHORUS_ADDR_W{1'b0}} : rev_pos2 + 1'b1;
                    state <= S_R_W3;
                end

                S_R_W3: begin
                    ram_we    <= 1'b1;
                    ram_waddr <= REV_BASE3 + rev_pos3;
                    ram_wdata <= saturate((dry18 >>> 2));
                    rev_pos3 <= (rev_pos3 == REV_LEN3-1) ? {CHORUS_ADDR_W{1'b0}} : rev_pos3 + 1'b1;
                    state <= S_R_OUT;
                end

                S_R_OUT: begin
                    next_mix = next_output(reverb_mix);
                    blend_out        <= next_mix;
                    sample_out       <= next_mix[SAMPLE_W-1:0];
                    sample_valid_out <= 1'b1;
                    state            <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

// 单读口、单写口、同步读 RAM。保持端口结构固定，便于 Gowin 稳定映射 BSRAM。
module reverb_wet_shared_ram #(
    parameter SAMPLE_W = 16,
    parameter ADDR_W   = 14
) (
    input  wire                  clk,
    input  wire                  we,
    input  wire [ADDR_W-1:0]     raddr,
    output reg signed [SAMPLE_W-1:0] rdata,
    input  wire [ADDR_W-1:0]     waddr,
    input  wire signed [SAMPLE_W-1:0] wdata
) /*synthesis syn_ramstyle="block_ram"*/;
    localparam DEPTH = (1 << ADDR_W);

    reg signed [SAMPLE_W-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
    end

    always @(posedge clk) begin
        rdata <= mem[raddr];
    end
endmodule
