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

    // valid 是慢速 RC 采样脉冲；在内部展开为 5 级流水，避免“减法 +
    // 18×16 乘法 + 限幅”压进一个 72 MHz 周期。
    reg signed [17:0] d_q;
    reg        [17:0] mag_q;
    reg        [17:0] eff_q;
    reg        [17:0] delta_q;
    reg               sign_q1, sign_q2;
    reg               invalid_q1;
    reg v1, v2, v3, v4;

    wire        [17:0] mag_next = d_q[17] ? (~d_q + 18'd1) : d_q;
    wire        [17:0] eff_next =
        (mag_q > {2'b00, DEADZONE}) ? (mag_q - {2'b00, DEADZONE}) : 18'd0;
    wire        [15:0] k_sel = sign_q2 ? K_L : K_R;
    wire        [33:0] prod  = eff_q * k_sel;
    wire        [17:0] delta_next = (eff_q == 18'd0) ? 18'd0 : (prod >> 8);
    wire        [16:0] sum_neg_q = 17'd32768 - {1'b0, delta_q[15:0]};
    wire        [16:0] sum_pos_q = 17'd32768 + {1'b0, delta_q[15:0]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bend_q15 <= 16'd32768;
            d_q       <= 18'sd0;
            mag_q     <= 18'd0;
            eff_q     <= 18'd0;
            delta_q   <= 18'd0;
            sign_q1   <= 1'b0;
            sign_q2   <= 1'b0;
            invalid_q1 <= 1'b0;
            v1 <= 1'b0;
            v2 <= 1'b0;
            v3 <= 1'b0;
            v4 <= 1'b0;
        end else begin
            v1 <= valid;
            v2 <= v1;
            v3 <= v2;
            v4 <= v3;

            // d > 0：code 比中位小 → 电压更高 → 摇杆往正方向
            if (valid) begin
                d_q        <= $signed({2'b00, center_code}) -
                              $signed({2'b00, code});
                invalid_q1 <= fault || !code_ok;
            end

            if (v1) begin
                mag_q   <= mag_next;
                sign_q1 <= d_q[17];
            end

            if (v2) begin
                eff_q   <= eff_next;
                sign_q2 <= sign_q1;
            end

            if (v3)
                delta_q <= delta_next;

            if (v4) begin
                if (invalid_q1 || (delta_q == 18'd0))
                    bend_q15 <= 16'd32768;
                else if (sign_q2)
                    bend_q15 <= (sum_neg_q < {1'b0, BEND_LO}) ? BEND_LO : sum_neg_q[15:0];
                else
                    bend_q15 <= (sum_pos_q > {1'b0, BEND_HI}) ? BEND_HI : sum_pos_q[15:0];
            end
        end
    end

endmodule
