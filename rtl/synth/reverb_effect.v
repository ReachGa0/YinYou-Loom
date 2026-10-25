// ============================================================
// reverb_effect.v —— 四路短反馈延迟组成的简易硬件混响
//
// 四条延迟线长度不同，干声同时注入四路，每路反馈约 0.625。
// 四路湿声取平均，形成多个不同间隔的衰减回声。
// 为节省 DSP，反馈与混合全部使用移位和加法。
// ============================================================

module reverb_effect #(
    parameter SAMPLE_W = 16,
    parameter ADDR_W   = 11,
    parameter LEN0     = 997,
    parameter LEN1     = 1123,
    parameter LEN2     = 1277,
    parameter LEN3     = 1427
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       sample_en,
    input  wire signed [SAMPLE_W-1:0] sample_in,
    output reg  signed [SAMPLE_W-1:0] wet_out,
    output reg                        valid_out
) /*synthesis syn_ramstyle="block_ram"*/;
    localparam [3:0] S_IDLE  = 4'd0,
                     S_READ0 = 4'd1,
                     S_READ1 = 4'd2,
                     S_READ2 = 4'd3,
                     S_READ3 = 4'd4,
                     S_WRITE0 = 4'd5,
                     S_WRITE1 = 4'd6,
                     S_WRITE2 = 4'd7,
                     S_WRITE3 = 4'd8,
                     S_OUT    = 4'd9;

    reg signed [SAMPLE_W-1:0] line0 [0:LEN0-1];
    reg signed [SAMPLE_W-1:0] line1 [0:LEN1-1];
    reg signed [SAMPLE_W-1:0] line2 [0:LEN2-1];
    reg signed [SAMPLE_W-1:0] line3 [0:LEN3-1];
    reg [ADDR_W-1:0] pos0, pos1, pos2, pos3;
    reg signed [SAMPLE_W-1:0] tap0, tap1, tap2, tap3;
    reg signed [SAMPLE_W-1:0] dry_hold;
    reg [3:0] state;

    wire signed [SAMPLE_W+1:0] dry_ext =
        $signed({{(SAMPLE_W+2-SAMPLE_W){dry_hold[SAMPLE_W-1]}}, dry_hold});
    wire signed [SAMPLE_W+1:0] tap0_ext =
        $signed({{(SAMPLE_W+2-SAMPLE_W){tap0[SAMPLE_W-1]}}, tap0});
    wire signed [SAMPLE_W+1:0] tap1_ext =
        $signed({{(SAMPLE_W+2-SAMPLE_W){tap1[SAMPLE_W-1]}}, tap1});
    wire signed [SAMPLE_W+1:0] tap2_ext =
        $signed({{(SAMPLE_W+2-SAMPLE_W){tap2[SAMPLE_W-1]}}, tap2});
    wire signed [SAMPLE_W+1:0] tap3_ext =
        $signed({{(SAMPLE_W+2-SAMPLE_W){tap3[SAMPLE_W-1]}}, tap3});
    wire signed [SAMPLE_W+1:0] fb0 = tap0_ext - (tap0_ext >>> 3);
    wire signed [SAMPLE_W+1:0] fb1 = tap1_ext - (tap1_ext >>> 3);
    wire signed [SAMPLE_W+1:0] fb2 = tap2_ext - (tap2_ext >>> 3);
    wire signed [SAMPLE_W+1:0] fb3 = tap3_ext - (tap3_ext >>> 3);
    wire signed [SAMPLE_W+2:0] wet_sum =
        $signed({{2{tap0[SAMPLE_W-1]}}, tap0}) +
        $signed({{2{tap1[SAMPLE_W-1]}}, tap1}) +
        $signed({{2{tap2[SAMPLE_W-1]}}, tap2}) +
        $signed({{2{tap3[SAMPLE_W-1]}}, tap3});
    wire signed [SAMPLE_W-1:0] wet_mix = wet_sum >>> 2;

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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pos0 <= {ADDR_W{1'b0}};
            pos1 <= {ADDR_W{1'b0}};
            pos2 <= {ADDR_W{1'b0}};
            pos3 <= {ADDR_W{1'b0}};
            tap0 <= {SAMPLE_W{1'b0}};
            tap1 <= {SAMPLE_W{1'b0}};
            tap2 <= {SAMPLE_W{1'b0}};
            tap3 <= {SAMPLE_W{1'b0}};
            dry_hold <= {SAMPLE_W{1'b0}};
            wet_out <= {SAMPLE_W{1'b0}};
            valid_out <= 1'b0;
            state <= S_IDLE;
        end else begin
            valid_out <= 1'b0;

            case (state)
                S_IDLE: if (sample_en) begin
                    dry_hold <= sample_in;
                    state <= S_READ0;
                end

                S_READ0: begin
                    tap0 <= line0[pos0];
                    state <= S_READ1;
                end

                S_READ1: begin
                    tap1 <= line1[pos1];
                    state <= S_READ2;
                end

                S_READ2: begin
                    tap2 <= line2[pos2];
                    state <= S_READ3;
                end

                S_READ3: begin
                    tap3 <= line3[pos3];
                    state <= S_WRITE0;
                end

                S_WRITE0: begin
                    line0[pos0] <= saturate(dry_hold + fb0);
                    pos0 <= (pos0 == LEN0-1) ? {ADDR_W{1'b0}} : pos0 + 1'b1;
                    state <= S_WRITE1;
                end

                S_WRITE1: begin
                    line1[pos1] <= saturate(dry_hold + fb1);
                    pos1 <= (pos1 == LEN1-1) ? {ADDR_W{1'b0}} : pos1 + 1'b1;
                    state <= S_WRITE2;
                end

                S_WRITE2: begin
                    line2[pos2] <= saturate(dry_hold + fb2);
                    pos2 <= (pos2 == LEN2-1) ? {ADDR_W{1'b0}} : pos2 + 1'b1;
                    state <= S_WRITE3;
                end

                S_WRITE3: begin
                    line3[pos3] <= saturate(dry_hold + fb3);
                    pos3 <= (pos3 == LEN3-1) ? {ADDR_W{1'b0}} : pos3 + 1'b1;
                    state <= S_OUT;
                end

                S_OUT: begin
                    wet_out <= wet_mix;
                    valid_out <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
