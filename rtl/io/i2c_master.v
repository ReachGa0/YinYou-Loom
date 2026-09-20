module i2c_master #(
    parameter CLK_HZ = 27_000_000,      // 输入时钟频率
    parameter SCL_HZ = 100_000          // 目标 SCL 频率
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,            // 单周期脉冲：发起一次传输
    input  wire [7:0] data,             // 本次要发送的字节
    input  wire       do_stop,          // 传输结束后是否发 STOP
    output reg        busy,             // 1 = 正在传输
    output reg        ack,              // 0 = 从机应答了(ACK)
    output reg        scl,
    inout  wire       sda
);
    localparam HALF   = CLK_HZ / (SCL_HZ * 2);      // 135
    localparam HALF_W = $clog2(HALF);               // 8
    localparam [HALF_W-1:0] HALF_M1 = HALF - 1;

    localparam S_IDLE      = 4'd0,
               S_START1    = 4'd1,
               S_START2    = 4'd2,
               S_BIT_LOW   = 4'd3,
               S_BIT_HIGH  = 4'd4,
               S_ACK_LOW   = 4'd5,
               S_ACK_HIGH  = 4'd6,
               S_STOP_LOW  = 4'd7,
               S_STOP_HIGH = 4'd8;

    reg [HALF_W-1:0] cnt;
    reg [3:0]        state;
    reg [2:0]        bit_cnt;
    reg [7:0]        shreg;
    reg              sda_low;

    wire half_end = (cnt == HALF_M1);

    // 开漏输出：只在需要时把 SDA 拉低，其余时间释放（靠外部上拉为高）
    assign sda = sda_low ? 1'b0 : 1'bz;

    // ---- 半周期计数器 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cnt <= {HALF_W{1'b0}};
        else if (state == S_IDLE || half_end)
            cnt <= {HALF_W{1'b0}};
        else
            cnt <= cnt + 1'b1;
    end

    // ---- 主状态机 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            scl     <= 1'b1;
            sda_low <= 1'b0;
            busy    <= 1'b0;
            ack     <= 1'b0;
            bit_cnt <= 3'd0;
            shreg   <= 8'd0;
        end else begin
            case (state)

                S_IDLE: begin
                    scl     <= 1'b1;
                    sda_low <= 1'b0;
                    busy    <= 1'b0;
                    if (start) begin
                        shreg   <= data;
                        bit_cnt <= 3'd0;
                        busy    <= 1'b1;
                        state   <= S_START1;
                    end
                end

                S_START1: begin
                    if (half_end) begin
                        sda_low <= 1'b1;        // SCL 高时拉低 SDA = START
                        state <= S_START2;
                    end
                end

                S_START2: begin
                    if (half_end) begin
                        scl   <= 1'b0;          // START 之后拉低 SCL，准备发数据位
                        state   <= S_BIT_LOW;
                    end
                end

                S_BIT_LOW: begin
                    sda_low <= ~shreg[7];       // SCL 低时改变数据
                    if (half_end) begin
                        scl   <= 1'b1;          // SCL 拉高，从机采样
                        state <= S_BIT_HIGH;
                    end
                end

                S_BIT_HIGH: begin
                    if (half_end) begin
                        scl <= 1'b0;
                        if (bit_cnt == 3'd7) begin
                            state <= S_ACK_LOW;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                            shreg   <= {shreg[6:0], 1'b0};
                            state   <= S_BIT_LOW;
                        end
                    end
                end

                S_ACK_LOW: begin
                    sda_low <= 1'b0;            // 释放 SDA，交给从机应答
                    if (half_end) begin
                        scl   <= 1'b1;
                        state <= S_ACK_HIGH;
                    end
                end

                S_ACK_HIGH: begin
                    if (half_end) begin
                        ack   <= sda;           // SCL 高时采样应答
                        scl   <= 1'b0;
                        state <= do_stop ? S_STOP_LOW : S_IDLE;
                    end
                end

                S_STOP_LOW: begin
                    sda_low <= 1'b1;
                    if (half_end) begin
                        scl   <= 1'b1;
                        state <= S_STOP_HIGH;
                    end
                end

                S_STOP_HIGH: begin
                    if (half_end) begin
                        sda_low <= 1'b0;        // SCL 高时释放 SDA = STOP
                        state   <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
