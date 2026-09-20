// ============================================================
// i2c_master.v —— I2C 主机（每次发送一个字节，可组成多次字节的事务）
//
// 正确的 I2C 事务格式：  START 地址 数据1 数据2 ... STOP
//
// 因此本模块用两个标志来控制一次"字节发送"在事务中的位置：
//   first = 1 ：本字节之前发 START（事务的第一个字节）
//   last  = 1 ：本字节之后发 STOP （事务的最后一个字节）
//   两者都为 0：字节之间保持总线（SCL 拉低），不发 START/STOP
//
// 典型用法（写 OLED）：连续调用三次
//   first=1,last=0 发从机地址
//   first=0,last=0 发控制字节
//   first=0,last=1 发数据/命令
//
// 时序：每个状态停留半个 SCL 周期，SCL 高/低电平时间各半个周期。
// ============================================================

module i2c_master #(
    parameter CLK_HZ = 27_000_000,      // 输入时钟频率
    parameter SCL_HZ = 100_000          // 目标 SCL 频率
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       req,              // 单周期脉冲：请求发送一个字节
    input  wire       first,            // 本字节前是否发 START
    input  wire       last,             // 本字节后是否发 STOP
    input  wire [7:0] data,             // 要发送的字节
    output reg        busy,             // 1 = 一次事务进行中
    output reg        done,             // 单周期脉冲：一个字节发送完毕
    output reg        ack,              // 该字节的应答（0 = 从机 ACK）
    output reg        scl,
    inout  wire       sda
);
    localparam HALF   = CLK_HZ / (SCL_HZ * 2);      // 半周期时钟数
    localparam HALF_W = $clog2(HALF);
    localparam [HALF_W-1:0] HALF_M1 = HALF - 1;

    localparam S_IDLE      = 4'd0,   // 总线空闲（SCL=1）
               S_WAIT      = 4'd1,   // 事务中途，保持总线（SCL=0），等下一个 req
               S_START1    = 4'd2,
               S_START2    = 4'd3,
               S_BIT_LOW   = 4'd4,
               S_BIT_HIGH  = 4'd5,
               S_ACK_LOW   = 4'd6,
               S_ACK_HIGH  = 4'd7,
               S_STOP_LOW  = 4'd8,
               S_STOP_HIGH = 4'd9;

    reg [HALF_W-1:0] cnt;
    reg [3:0]        state;
    reg [2:0]        bit_cnt;
    reg [7:0]        shreg;
    reg              sda_low;

    wire half_end = (cnt == HALF_M1);

    // 开漏输出：只拉低，不推高；高电平由总线上的上拉电阻提供
    assign sda = sda_low ? 1'b0 : 1'bz;

    // ---- 半周期计数器 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cnt <= {HALF_W{1'b0}};
        else if (state == S_IDLE || state == S_WAIT)
            cnt <= {HALF_W{1'b0}};
        else if (half_end)
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
            done    <= 1'b0;
            ack     <= 1'b0;
            bit_cnt <= 3'd0;
            shreg   <= 8'd0;
        end else begin
            done <= 1'b0;               // 默认：done 只保持一个时钟周期
            case (state)

                // 总线空闲：SCL=1，SDA 释放
                S_IDLE: begin
                    scl     <= 1'b1;
                    sda_low <= 1'b0;
                    busy    <= 1'b0;
                    done    <= 1'b0;
                    if (req) begin
                        shreg   <= data;
                        bit_cnt <= 3'd0;
                        busy    <= 1'b1;
                        state   <= first ? S_START1 : S_BIT_LOW;
                    end
                end

                // 事务中途：保持总线，SCL=0，SDA 释放，等下一个字节
                S_WAIT: begin
                    scl     <= 1'b0;
                    sda_low <= 1'b0;
                    done    <= 1'b0;        // 清除上一字节的完成脉冲
                    if (req) begin
                        shreg   <= data;
                        bit_cnt <= 3'd0;
                        state   <= S_BIT_LOW;
                    end
                end

                // ---- START 条件 ----
                S_START1: begin
                    if (half_end) begin
                        sda_low <= 1'b1;        // SCL 高时拉低 SDA = START
                        state   <= S_START2;
                    end
                end

                S_START2: begin
                    if (half_end) begin
                        scl   <= 1'b0;          // 拉低 SCL，准备发数据位
                        state <= S_BIT_LOW;
                    end
                end

                // ---- 8 个数据位 ----
                S_BIT_LOW: begin
                    sda_low <= ~shreg[7];       // SCL 低时改变数据
                    if (half_end) begin
                        scl   <= 1'b1;          // 拉高 SCL，从机采样
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

                // ---- 应答位 ----
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
                        if (last) begin
                            state <= S_STOP_LOW;
                        end else begin
                            done  <= 1'b1;      // 非最后字节：应答完即完成
                            state <= S_WAIT;    // 保持总线，等下一个字节
                        end
                    end
                end

                // ---- STOP 条件 ----
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
                        busy    <= 1'b0;
                        done    <= 1'b1;        // 最后字节：整个事务发完才算完成
                        state   <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
