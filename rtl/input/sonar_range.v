// ============================================================
// sonar_range.v —— 超声波测距（HC-SR04 / HC-SR04P）
//
// 职责：产生 TRIG 脉冲 → 测量 ECHO 高电平宽度 → 换算成毫米距离。
// 接口冻结定义见 docs/17_P5C超声波设计.md 第 3 节，本文件不擅自改动端口。
//
// 实现口径（2026-09-23 与用户确认，见 docs/17 第 4.4 / 4.5 / 5 / 6 节）：
//   1. 时间基：CLK_MHZ 个时钟 = 1us。72MHz 下是整数分频，精确、无累积误差。
//   2. 时间戳只在状态转移那一拍单次刷新；S_WAIT_HI / S_MEASURE / S_WAIT_LO
//      内部每个时钟周期都不刷新，否则超时判定失效、回波时间可能恒为 0。
//   3. ECHO 是异步输入：两级同步后只用 echo_s1（电平）和边沿脉冲，
//      绝不用端口 echo 或第一级 echo_s0。同步器延迟在
//      t_echo_fall - t_echo_rise 中相互抵消。
//   4. 距离换算：distance_mm = ((echo_us * 11233) + 32'h8000) >> 16（四舍五入）。
//      该常数对应约 0.171402 mm/us，即约 342.8 m/s。
//   5. valid 是电平型标志：进入 S_TRIG 时清 0，S_CALC 校验通过时置 1，
//      并保持到下一次进入 S_TRIG。上层只能使用 valid=1 时的 distance_mm，
//      不能把 16'hFFFF 或上一次的旧距离当成当前结果。
//   6. 4500mm 对应约 26.3ms 回波，距 TIMEOUT_US（30ms）仍有约 3.7ms 余量。
//      若把 MAX_DIST_MM 调大到 5000 以上，上限判定会被 S_MEASURE 超时抢先。
//   7. 已知残余风险：不设 rise_seen。ECHO 在 TRIG 之前已为高时，回波时间
//      从"进入 S_MEASURE 的时刻"起算，可能出现看起来合法的假读数
//      （见 docs/17 第 4.5 节）。
// ============================================================

module sonar_range #(
    parameter CLK_MHZ     = 72,        // 当前设计只保证整数 MHz 输入
    parameter TRIG_US     = 12,        // TRIG 高电平宽度，规格要求 >=10us
    parameter PERIOD_US   = 70_000,    // 两次 TRIG 启动间隔下限，>=60ms
    parameter TIMEOUT_US  = 30_000,    // 等待 ECHO 或测量 ECHO 的单次超时
    parameter STUCK_US    = 100_000,   // S_WAIT_LO 有界等待时间
    parameter MIN_ECHO_US = 50,        // 低于此值视为毛刺
    parameter MAX_DIST_MM = 4500       // 距离上限，超出则判无效
) (
    input  wire        clk,
    input  wire        rst_n,
    output reg         trig,           // 到 PIN26
    input  wire        echo,           // 来自 PIN80，异步输入
    output reg  [15:0] distance_mm,    // 0-4500；复位时为 16'hFFFF
    output reg         valid,          // 有效标志；置 1 后保持到下次进入 S_TRIG
    output reg         fault,          // ECHO 卡高锁存标志，成功测量后清除
    output reg  [7:0]  stuck_cnt       // 卡高次数，饱和到 255，调试用
);
    // 参数显式转 32 位，避免有符号 / 无符号比较告警
    localparam [31:0] TRIG_C     = TRIG_US;
    localparam [31:0] PERIOD_C   = PERIOD_US;
    localparam [31:0] TIMEOUT_C  = TIMEOUT_US;
    localparam [31:0] STUCK_C    = STUCK_US;
    localparam [31:0] MIN_ECHO_C = MIN_ECHO_US;
    localparam [31:0] MAX_DIST_C = MAX_DIST_MM;

    localparam integer TICK_DIV = (CLK_MHZ < 1) ? 1 : CLK_MHZ;
    localparam integer TICK_W   = (TICK_DIV <= 1) ? 1 : $clog2(TICK_DIV);

    localparam [2:0] S_IDLE    = 3'd0,
                     S_TRIG    = 3'd1,
                     S_WAIT_HI = 3'd2,
                     S_MEASURE = 3'd3,
                     S_CALC    = 3'd4,
                     S_WAIT_LO = 3'd5;

    reg [2:0]        state;
    reg [TICK_W-1:0] tick_cnt;
    reg [31:0]       us_cnt;          // 自由运行微秒计数器

    reg [31:0] t_trig_start;          // 进入 S_TRIG 时刷新：TRIG 宽度 + 周期下限
    reg [31:0] t_state;               // S_TRIG->S_WAIT_HI / S_MEASURE->S_WAIT_LO 刷新
    reg [31:0] t_echo_rise;           // S_WAIT_HI->S_MEASURE 刷新：回波起点
    reg [31:0] t_echo_fall;           // S_MEASURE 检测到下降沿时刷新：回波终点

    // ---- ECHO 两级同步 + 边沿检测 ----
    reg echo_s0;                      // 第一级：可能亚稳，禁止在别处引用
    reg echo_s1;                      // 第二级：稳定值，状态机只用它
    reg echo_s1d;                     // 延迟一拍，用于边沿检测

    wire echo_fall = ~echo_s1 & echo_s1d;

    // ---- 微秒节拍 ----
    wire tick_now = (tick_cnt == TICK_DIV - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= {TICK_W{1'b0}};
            us_cnt   <= 32'd0;
        end else if (tick_now) begin
            tick_cnt <= {TICK_W{1'b0}};
            us_cnt   <= us_cnt + 32'd1;
        end else begin
            tick_cnt <= tick_cnt + 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            echo_s0  <= 1'b0;
            echo_s1  <= 1'b0;
            echo_s1d <= 1'b0;
        end else begin
            echo_s0  <= echo;
            echo_s1  <= echo_s0;
            echo_s1d <= echo_s1;
        end
    end

    // ---- 距离换算（组合逻辑，在 S_CALC 内使用）----
    // echo_us 上限被 S_MEASURE 的 TIMEOUT_US 钳住，32 位中间积足够
    wire [31:0] echo_us_w = t_echo_fall - t_echo_rise;
    wire [31:0] dist_w    = ((echo_us_w * 32'd11233) + 32'd32768) >> 16;

    // ---- 状态机 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            trig         <= 1'b0;
            distance_mm  <= 16'hFFFF;
            valid        <= 1'b0;
            fault        <= 1'b0;
            stuck_cnt    <= 8'd0;
            t_trig_start <= 32'd0;
            t_state      <= 32'd0;
            t_echo_rise  <= 32'd0;
            t_echo_fall  <= 32'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if ((us_cnt - t_trig_start) >= PERIOD_C) begin
                        trig         <= 1'b1;
                        valid        <= 1'b0;      // 每次进入 S_TRIG 立即清 0
                        t_trig_start <= us_cnt;    // 刷新点：周期从 TRIG 启动算起
                        state        <= S_TRIG;
                    end
                end

                S_TRIG: begin
                    if ((us_cnt - t_trig_start) >= TRIG_C) begin
                        trig    <= 1'b0;
                        t_state <= us_cnt;         // 刷新点：S_WAIT_HI 超时起点
                        state   <= S_WAIT_HI;
                    end
                end

                S_WAIT_HI: begin
                    // 电平判定，优先于超时：ECHO 一开始就为高时也能进入测量
                    if (echo_s1) begin
                        t_echo_rise <= us_cnt;     // 刷新点：回波起点
                        state       <= S_MEASURE;
                    end else if ((us_cnt - t_state) >= TIMEOUT_C) begin
                        state <= S_IDLE;           // 本次无效，距离保持
                    end
                end

                S_MEASURE: begin
                    if (echo_fall) begin
                        t_echo_fall <= us_cnt;     // 刷新点：回波终点
                        state       <= S_CALC;
                    end else if ((us_cnt - t_echo_rise) >= TIMEOUT_C) begin
                        t_state <= us_cnt;         // 刷新点：S_WAIT_LO 超时起点
                        state   <= S_WAIT_LO;      // 本次无效，距离保持
                    end
                end

                S_WAIT_LO: begin
                    if (!echo_s1) begin
                        state <= S_IDLE;
                    end else if ((us_cnt - t_state) >= STUCK_C) begin
                        fault     <= 1'b1;         // 锁存；只有成功测量才清除
                        stuck_cnt <= (stuck_cnt == 8'hFF) ? 8'hFF
                                                          : (stuck_cnt + 8'd1);
                        state     <= S_IDLE;
                    end
                end

                S_CALC: begin                      // 单周期：校验并更新输出
                    if ((echo_us_w >= MIN_ECHO_C) && (dist_w <= MAX_DIST_C)) begin
                        distance_mm <= dist_w[15:0];
                        valid       <= 1'b1;
                        fault       <= 1'b0;       // 成功测量清除卡高标志
                    end
                    state <= S_IDLE;               // 校验失败：距离保持、valid 保持 0
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
