// ============================================================
// chorus.v —— 单抽头调制延迟合唱效果器
//
// 延迟约 10.7~16.0 ms，LFO 约 0.37 Hz，50% dry/wet。
// 旁路时只保留与效果路径一致的三级流水延迟，方便顶层无毛刺切换。
//
// 分数延迟 + 线性插值（2026-09-23 修正）：
//   早期版本按"整数样本"步进读延迟线，每 256 个样本延迟量突然跳 1 个样本
//   （约 5.3ms 一次），等于在波形上周期性插一阶不连续点，听感是持续破音
//   （实测：单音 + 合唱也破，冻结 LFO 后破音消失，确证机理）。
//   现在改为：整数部分 lfo_int（8 位）+ 小数部分 lfo_frac（Q8），
//   每次取相邻两个抽头 a=mem[addr_a]、b=mem[addr_b]，
//   输出 a + (b - a) * frac >> 8，延迟连续变化，跳变消失。
//   两个抽头用**同一端口在不同时钟**分时读取，不会复制 BSRAM。
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
    reg [ADDR_W-1:0]          read_addr_a;
    reg [ADDR_W-1:0]          read_addr_b;
    reg signed [SAMPLE_W-1:0] dry_hold;
    reg signed [SAMPLE_W-1:0] a_q;
    reg signed [SAMPLE_W-1:0] b_q;
    reg [7:0]                 frac_hold;
    reg                       bypass_hold;

    // 三角 LFO：整数部分 0..255 个样本，小数部分 Q8
    wire [7:0] lfo_int  = lfo_phase[23] ? ~lfo_phase[22:15] : lfo_phase[22:15];
    wire [7:0] lfo_frac = lfo_phase[23] ? ~lfo_phase[14:7]  : lfo_phase[14:7];

    wire [ADDR_W-1:0] min_delay = MIN_DELAY;
    wire [ADDR_W-1:0] addr_a    = write_ptr - min_delay - {3'b000, lfo_int};
    wire [ADDR_W-1:0] addr_b    = addr_a - 1'b1;

    // 线性插值：a 是较近的抽头，b 是再早一个样本
    wire signed [SAMPLE_W:0]   diff  = b_q - a_q;
    wire signed [SAMPLE_W+8:0] prod  = diff * $signed({1'b0, frac_hold});
    wire signed [SAMPLE_W-1:0] wet_q = a_q + (prod >>> 8);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_ptr        <= {ADDR_W{1'b0}};
            lfo_phase        <= 24'd0;
            read_pending     <= 2'd0;
            read_addr_a      <= {ADDR_W{1'b0}};
            read_addr_b      <= {ADDR_W{1'b0}};
            dry_hold         <= {SAMPLE_W{1'b0}};
            a_q              <= {SAMPLE_W{1'b0}};
            b_q              <= {SAMPLE_W{1'b0}};
            frac_hold        <= 8'd0;
            bypass_hold      <= 1'b1;
            sample_out       <= {SAMPLE_W{1'b0}};
            sample_valid_out <= 1'b0;
        end else begin
            sample_valid_out <= 1'b0;

            if (sample_en) begin
                delay_mem[write_ptr] <= sample_in;
                write_ptr            <= write_ptr + 1'b1;
                lfo_phase            <= lfo_phase + LFO_STEP;
                read_addr_a          <= addr_a;
                read_addr_b          <= addr_b;
                frac_hold            <= lfo_frac;
                dry_hold             <= sample_in;
                bypass_hold          <= bypass;
                read_pending         <= 2'd1;
            end else if (read_pending == 2'd1) begin
                a_q          <= delay_mem[read_addr_a];
                read_pending <= 2'd2;
            end else if (read_pending == 2'd2) begin
                b_q          <= delay_mem[read_addr_b];
                read_pending <= 2'd3;
            end else if (read_pending == 2'd3) begin
                if (bypass_hold)
                    sample_out <= dry_hold;
                else
                    // 50% dry + 50% wet（wet 为分数延迟线性插值结果）
                    sample_out <= (dry_hold + wet_q) >>> 1;
                sample_valid_out <= 1'b1;
                read_pending     <= 2'd0;
            end
        end
    end
endmodule
