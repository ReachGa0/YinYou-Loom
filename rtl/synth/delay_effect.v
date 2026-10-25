// ============================================================
// delay_effect.v —— 单抽头反馈延迟
//
// 默认 12000 个采样的循环延迟，48 kHz 下约 250 ms。
// 写入值 = 当前干声 + 延迟样本 × 0.5，形成逐次衰减的回声。
// 当前没有可自由分配的 DSP，因此反馈使用移位，不使用乘法器。
// ============================================================

module delay_effect #(
    parameter SAMPLE_W     = 16,
    parameter ADDR_W       = 14,
    parameter DELAY_SAMPLES = 12000,
    parameter FEEDBACK_SHIFT = 1
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       sample_en,
    input  wire signed [SAMPLE_W-1:0] sample_in,
    output reg  signed [SAMPLE_W-1:0] wet_out,
    output reg                        valid_out
) /*synthesis syn_ramstyle="block_ram"*/;
    localparam DEPTH = (1 << ADDR_W);
    localparam [1:0] S_IDLE = 2'd0,
                     S_READ = 2'd1,
                     S_WRITE = 2'd2;

    reg signed [SAMPLE_W-1:0] delay_mem [0:DEPTH-1];
    reg [ADDR_W-1:0] write_ptr;
    reg [ADDR_W-1:0] read_addr;
    reg signed [SAMPLE_W-1:0] dry_hold;
    reg signed [SAMPLE_W-1:0] delayed_q;
    reg [1:0] state;

    wire signed [SAMPLE_W+1:0] dry_ext =
        $signed({{(SAMPLE_W+2-SAMPLE_W){dry_hold[SAMPLE_W-1]}}, dry_hold});
    wire signed [SAMPLE_W+1:0] delayed_ext =
        $signed({{(SAMPLE_W+2-SAMPLE_W){delayed_q[SAMPLE_W-1]}}, delayed_q});
    wire signed [SAMPLE_W+1:0] feedback_sum =
        dry_ext + (delayed_ext >>> FEEDBACK_SHIFT);

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
            write_ptr <= {ADDR_W{1'b0}};
            read_addr <= {ADDR_W{1'b0}};
            dry_hold  <= {SAMPLE_W{1'b0}};
            delayed_q <= {SAMPLE_W{1'b0}};
            wet_out   <= {SAMPLE_W{1'b0}};
            valid_out <= 1'b0;
            state     <= S_IDLE;
        end else begin
            valid_out <= 1'b0;

            case (state)
                S_IDLE: if (sample_en) begin
                    dry_hold <= sample_in;
                    read_addr <= write_ptr - DELAY_SAMPLES;
                    state <= S_READ;
                end

                S_READ: begin
                    delayed_q <= delay_mem[read_addr];
                    state <= S_WRITE;
                end

                S_WRITE: begin
                    delay_mem[write_ptr] <= saturate(feedback_sum);
                    write_ptr <= write_ptr + 1'b1;
                    wet_out  <= delayed_q;
                    valid_out <= 1'b1;
                    state    <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
