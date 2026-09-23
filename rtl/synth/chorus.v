// ============================================================
// chorus.v —— 单抽头调制延迟合唱效果器
//
// 第一版参数固定：延迟约 10.7~16.0 ms，LFO 约 0.37 Hz，50% dry/wet。
// 旁路时只保留与效果路径一致的两级流水延迟，方便顶层无毛刺切换。
// ============================================================

module chorus #(
    parameter SAMPLE_W = 16,
    parameter ADDR_W   = 11,
    parameter MIN_DELAY = 512,
    parameter [23:0] LFO_STEP = 24'd128
) (
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        sample_en,
    input  wire                        bypass,
    input  wire signed [SAMPLE_W-1:0]  sample_in,

    output reg  signed [SAMPLE_W-1:0]  sample_out,
    output reg                         sample_valid_out
);
    localparam DEPTH = (1 << ADDR_W);

    reg signed [SAMPLE_W-1:0] delay_mem [0:DEPTH-1];
    reg [ADDR_W-1:0]          write_ptr;
    reg [23:0]                lfo_phase;
    reg [1:0]                 read_pending;
    reg [ADDR_W-1:0]          read_addr;
    reg signed [SAMPLE_W-1:0] dry_hold;
    reg signed [SAMPLE_W-1:0] delayed_q;
    reg                       bypass_hold;

    // 三角 LFO：0..511，量化到 0..255 个采样点的额外延迟。
    wire [8:0] lfo_level = lfo_phase[23] ? ~lfo_phase[22:14]
                                         :  lfo_phase[22:14];
    wire [ADDR_W-1:0] lfo_offset = {1'b0, lfo_level[8:1]};
    wire [ADDR_W-1:0] min_delay  = MIN_DELAY;
    wire [ADDR_W-1:0] read_ptr   = write_ptr - min_delay - lfo_offset;

    wire signed [SAMPLE_W:0] mix_sum =
        {dry_hold[SAMPLE_W-1], dry_hold} +
        {delayed_q[SAMPLE_W-1], delayed_q};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_ptr        <= {ADDR_W{1'b0}};
            lfo_phase        <= 24'd0;
            read_pending     <= 2'd0;
            read_addr        <= {ADDR_W{1'b0}};
            dry_hold         <= {SAMPLE_W{1'b0}};
            delayed_q        <= {SAMPLE_W{1'b0}};
            bypass_hold      <= 1'b1;
            sample_out       <= {SAMPLE_W{1'b0}};
            sample_valid_out <= 1'b0;
        end else begin
            sample_valid_out <= 1'b0;

            if (sample_en) begin
                delay_mem[write_ptr] <= sample_in;
                write_ptr            <= write_ptr + 1'b1;
                lfo_phase            <= lfo_phase + LFO_STEP;
                read_addr            <= read_ptr;
                dry_hold             <= sample_in;
                bypass_hold          <= bypass;
                read_pending         <= 2'd1;
            end else if (read_pending == 2'd1) begin
                delayed_q    <= delay_mem[read_addr];
                read_pending <= 2'd2;
            end else if (read_pending == 2'd2) begin
                if (bypass_hold)
                    sample_out <= dry_hold;
                else
                    sample_out <= mix_sum >>> 1;
                sample_valid_out <= 1'b1;
                read_pending     <= 2'd0;
            end
        end
    end
endmodule
