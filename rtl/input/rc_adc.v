// ============================================================
// rc_adc.v —— 用数字 IO + RC 网络测电位器位置（无 ADC 芯片）
//
// 电路（每路 3 个无源件）：
//
//   摇杆 VRX ──[ R_in 100k ]──┬── FPGA 引脚
//                             │
//                       [ R_pu 47k ]
//                             │
//                            3V3
//                             └──[ C 10nF ]── GND
//
// 原理：
//   1. 引脚推低（drive_low=1），把 C 放到 0V；
//   2. 引脚切成高阻，C 经 R_in 朝摇杆电压充电；
//   3. 数到"引脚读到高"为止，得到 charge_us。电压越高，时间越短、code 越小。
//   R_pu 的作用是把 0V 时的终值抬到输入门限（约 2.0V）以上，
//   否则摇杆下半程永远等不到上升沿。
//
// 注意：
//   - 引脚必须配 PULL_MODE=NONE（外部已有 47k 上拉）；
//   - 超时 fault=1（没接摇杆/线断），上层应把它当作"回中"，不要当满量程。
// ============================================================

module rc_adc #(
    parameter CLK_HZ       = 72_000_000,
    parameter PRESCALE     = 16,        // 计数预分频：72MHz/16 = 4.5MHz
    parameter DISCHARGE_US = 200,       // 放电时间（≥5τ）
    parameter TIMEOUT_US   = 12000,     // 等不到上升沿就判故障（C=100nF 时需要更长）
    parameter WIDTH        = 16
) (
    input  wire             clk,
    input  wire             rst_n,
    inout  wire             pin,

    output reg  [WIDTH-1:0] code,       // 充电计数值（越小 = 电压越高）
    output reg              valid,      // 单周期：一次测量完成
    output reg              fault       // 1 = 超时（开路 / 无摇杆）
);
    // 预分频后的有效计数时钟
    localparam integer TICK_HZ = CLK_HZ / PRESCALE;
    localparam integer DIS_CYC = (TICK_HZ * DISCHARGE_US) / 1_000_000;
    localparam integer TO_CYC  = (TICK_HZ * TIMEOUT_US)   / 1_000_000;

    localparam [1:0] S_IDLE = 2'd0,
                     S_DIS  = 2'd1,
                     S_MEAS = 2'd2;

    reg [1:0]  state;
    reg        drive_low;
    reg [18:0] cnt;
    reg [15:0] presc_cnt;

    // 每 PRESCALE 个 clk 产生一个 tick（计数与状态机都按 tick 走）
    wire tick = (presc_cnt == (PRESCALE - 1));

    assign pin = drive_low ? 1'b0 : 1'bz;
    wire pin_in = pin;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            drive_low <= 1'b0;
            cnt       <= 19'd0;
            presc_cnt <= 16'd0;
            code      <= {WIDTH{1'b0}};
            valid     <= 1'b0;
            fault     <= 1'b0;
        end else begin
            valid <= 1'b0;
            presc_cnt <= tick ? 16'd0 : (presc_cnt + 1'b1);

            if (tick) case (state)
                S_IDLE: begin
                    drive_low <= 1'b1;          // 开始放电
                    cnt       <= 19'd0;
                    state     <= S_DIS;
                end

                S_DIS: begin
                    if (cnt == (DIS_CYC - 1)) begin
                        drive_low <= 1'b0;      // 释放 → 开始充电
                        cnt       <= 19'd0;
                        state     <= S_MEAS;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                S_MEAS: begin
                    if (pin_in) begin
                        code  <= cnt[WIDTH-1:0];
                        fault <= 1'b0;
                        valid <= 1'b1;
                        state <= S_IDLE;
                    end else if (cnt == (TO_CYC - 1)) begin
                        code  <= cnt[WIDTH-1:0];
                        fault <= 1'b1;
                        valid <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
