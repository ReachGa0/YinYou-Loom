// ============================================================
// pitch_bend_map.v —— 摇杆 X 的 RC 计数值 → 音高弯音系数
//
// 输出 bend_q15：32768 = 1.0（不弯音），范围 32768 ± BEND_MAX。
// ±2 半音对应 2^(2/12) − 1 ≈ 0.1225 → BEND_MAX ≈ 4013。
//
// 为什么左右两段斜率不同：
//   RC 充电是 ln() 关系，摇杆在 0V 附近的计数值变化远大于 3.3V 附近，
//   实测同一段行程在"低电压侧"会产生约 2 倍于高电压侧的计数差。
//   这里用 SPAN_LEFT / SPAN_RIGHT 两个常量分别归一化，中位仍然精确回中。
//
// 安全：fault（开路/没接摇杆）或 code 超出合理范围时，一律回中（1.0），
//       避免悬空引脚被当成"满弯音"。
// ============================================================

module pitch_bend_map #(
    // 实测标定（读数条约 65px → 中位约 4200）：
    //   左端约 5400、右端约 3400 → 行程 1200 / 780
    parameter [15:0] SPAN_LEFT   = 16'd1200,   // 中 → 左端的计数差
    parameter [15:0] SPAN_RIGHT  = 16'd780,    // 中 → 右端的计数差
    parameter [15:0] DEADZONE    = 16'd150,    // 中位死区（计数，压住零点噪声与残余偏差）
    // ±1 半音：2^(1/12) − 1 ≈ 0.05946 → 0.05946 × 32768 ≈ 1948
    parameter [15:0] BEND_MAX    = 16'd1948,   // Q15
    parameter [15:0] CODE_MIN    = 16'd2500,   // 低于此值视为异常
    parameter [15:0] CODE_MAX    = 16'd22000   // 高于此值视为异常
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] code,
    input  wire [15:0] center_code,   // 开机自动对中测出来的零点
    input  wire        valid,
    input  wire        fault,

    output reg  [15:0] bend_q15
);
    // 注意：常数乘法必须在 32 位下算（16 位乘 256 会溢出），除完再截到 16 位
    localparam [15:0] K_R    = (BEND_MAX * 256) / SPAN_RIGHT;   // Q8
    localparam [15:0] K_L    = (BEND_MAX * 256) / SPAN_LEFT;
    localparam [15:0] BEND_LO = 16'd32768 - BEND_MAX;
    localparam [15:0] BEND_HI = 16'd32768 + BEND_MAX;

    wire code_ok = (code >= CODE_MIN) && (code <= CODE_MAX);

    // d > 0：code 比中位小 → 电压更高 → 摇杆往正方向
    wire signed [17:0] d   = $signed({2'b00, center_code}) - $signed({2'b00, code});
    wire        [17:0] mag = d[17] ? (~d + 18'd1) : d;
    wire        [17:0] eff = (mag > {2'b00, DEADZONE}) ? (mag - {2'b00, DEADZONE}) : 18'd0;

    // Verilog 的乘法结果宽度 = 两个操作数的最大宽度；这里必须把中间结果
    // 声明成足够宽（18+16=34 位），否则 1755×572 会被截断成 18 位。
    wire [15:0] k_sel = d[17] ? K_L : K_R;
    wire [33:0] prod  = eff * k_sel;
    wire [17:0] delta = (eff == 18'd0) ? 18'd0 : (prod >> 8);

    wire [16:0] sum_pos = {1'b0, 16'd32768} + {1'b0, delta[15:0]};
    wire [16:0] sum_neg = {1'b0, 16'd32768} - {1'b0, delta[15:0]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bend_q15 <= 16'd32768;
        // 只有"故障 / 越界"才强制回中
        else if (fault || !code_ok)
            bend_q15 <= 16'd32768;
        // valid 是单周期脉冲：只在采样完成那一拍更新，其余时间保持
        else if (valid) begin
            if (eff == 18'd0)
                bend_q15 <= 16'd32768;
            else if (d[17])
                bend_q15 <= (sum_neg < {1'b0, BEND_LO}) ? BEND_LO : sum_neg[15:0];
            else
                bend_q15 <= (sum_pos > {1'b0, BEND_HI}) ? BEND_HI : sum_pos[15:0];
        end
        // valid=0：保持上一次的弯音值（关键：不能在这里回中）
    end

endmodule
