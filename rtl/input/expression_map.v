// ============================================================
// expression_map.v —— 摇杆 Y 的统一力度 / 持续表情语义
//
// velocity   : note-on 瞬间由 synth_engine 锁存，进入每个声部
// expression : 按住音符期间的总体音量，位于混音之后
//
// 中心为 128。一个方向降低、另一个方向提高；两端都保留一定
// 可听余量，避免摇杆极限位置变成静音。
// ============================================================

module expression_map (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_valid,
    input  wire signed [16:0] filtered_y,
    input  wire        [15:0] center_y,
    output reg         [7:0]  velocity,
    output reg         [7:0]  expression
);
    reg signed [17:0] dy_q;
    reg        [17:0] mag_q;
    reg               sign_q1;
    reg        [17:0] eff_q;
    reg               sign_q2;
    reg        [17:0] off_q;
    reg        [7:0]  vel_q;
    reg v1, v2, v3, v4, v5;

    wire [17:0] mag_next = dy_q[17] ? (~dy_q + 18'd1) : dy_q;
    wire [17:0] eff_next =
        (mag_q > 18'd150) ? (mag_q - 18'd150) : 18'd0;

    // 增大和减小方向使用相同斜率；150 计数死区覆盖中位噪声。
    wire [17:0] off_next = (eff_q * 18'd41) >> 8;
    wire signed [9:0] vel_tmp = sign_q2
        ? (10'sd128 - $signed({2'b0, off_q[7:0]}))
        : (10'sd128 + $signed({2'b0, off_q[7:0]}));
    wire [7:0] vel_next = (vel_tmp < 0)   ? 8'd0 :
                          (vel_tmp > 255) ? 8'd255 : vel_tmp[7:0];

    wire [7:0] up_d      = vel_q - 8'd128;
    wire [8:0] expr_down = 9'd26 + {1'b0, vel_q[7:1]};
    wire [8:0] expr_up   = 9'd90 + {1'b0, up_d[7:1]};
    wire [8:0] expr_sum  = (vel_q <= 8'd128) ? expr_down : expr_up;
    wire [7:0] expr_next = (expr_sum > 9'd255) ? 8'd255 : expr_sum[7:0];

    // RC 采样本来就较慢；有效脉冲在内部展开成 5 级流水，不增加可感知延迟。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            velocity   <= 8'd128;
            expression <= 8'd90;
            dy_q       <= 18'sd0;
            mag_q      <= 18'd0;
            sign_q1    <= 1'b0;
            eff_q      <= 18'd0;
            sign_q2    <= 1'b0;
            off_q      <= 18'd0;
            vel_q      <= 8'd128;
            v1         <= 1'b0;
            v2         <= 1'b0;
            v3         <= 1'b0;
            v4         <= 1'b0;
            v5         <= 1'b0;
        end else begin
            v1 <= sample_valid;
            v2 <= v1;
            v3 <= v2;
            v4 <= v3;
            v5 <= v4;

            if (sample_valid)
                dy_q <= $signed({2'b00, center_y}) -
                        $signed({{1{filtered_y[16]}}, filtered_y});

            if (v1) begin
                mag_q   <= mag_next;
                sign_q1 <= dy_q[17];
            end

            if (v2) begin
                eff_q   <= eff_next;
                sign_q2 <= sign_q1;
            end

            if (v3)
                off_q <= off_next;

            if (v4) begin
                velocity <= vel_next;
                vel_q    <= vel_next;
            end

            if (v5)
                expression <= expr_next;
        end
    end
endmodule
