`timescale 1ps/1ps

// ============================================================
// tb_sonar_range.v —— sonar_range 功能验证
//
// 用例取自 docs/17_P5C超声波设计.md 第 6 节，并覆盖第 6 节的三条全局断言：
//   TRIG 高电平 >= 10us、相邻 TRIG 启动间隔 >= PERIOD_US、以及 valid=0 时
//   距离必须保持上一次有效值。
//
// 两个 DUT 实例：
//   1) u_fast —— CLK_MHZ=10、PERIOD_US=6000，其余超时参数保持真实值
//      （TIMEOUT_US=30000、STUCK_US=100000）。只缩短时钟频率和触发周期，
//      所以"38ms 无回波"和"卡高 130ms"两类故障用例仍按真实微秒数执行。
//   2) u_real —— CLK_MHZ=72 且全部使用真实参数，用来检查 72MHz 下的
//      整数分频和边沿处理。其时钟在快速用例结束后才启动，避免拖长仿真。
//
// 时间模型：TB 自己算出"一个 DUT 微秒"等于多少 ps（CLK_MHZ x 时钟周期），
// 因此回波宽度在 DUT 眼里恰好是设定的微秒数，与 timescale 取整无关。
// ============================================================

module tb_sonar_range;
    // ---- 快速配置：只缩短时钟与周期，超时参数保持真实值 ----
    localparam CLK_MHZ_F     = 10;
    localparam TRIG_US_F     = 12;
    localparam PERIOD_US_F   = 6_000;
    localparam TIMEOUT_US_F  = 30_000;
    localparam STUCK_US_F    = 100_000;
    localparam MIN_ECHO_US_F = 50;
    localparam MAX_DIST_MM_F = 4500;

    // ---- 真实配置 ----
    localparam CLK_MHZ_R     = 72;
    localparam TRIG_US_R     = 12;
    localparam PERIOD_US_R   = 70_000;
    localparam TIMEOUT_US_R  = 30_000;
    localparam STUCK_US_R    = 100_000;
    localparam MIN_ECHO_US_R = 50;
    localparam MAX_DIST_MM_R = 4500;

    // ---- 时间换算：全部用 64 位，避免大延迟溢出 32 位整数 ----
    localparam [63:0] CLK_PT_F_PS = 1_000_000 / CLK_MHZ_F;   // 时钟周期(ps)
    localparam [63:0] CLK_PT_R_PS = 1_000_000 / CLK_MHZ_R;
    localparam [63:0] US_F_PS     = CLK_MHZ_F * CLK_PT_F_PS; // 一个 DUT 微秒(ps)
    localparam [63:0] US_R_PS     = CLK_MHZ_R * CLK_PT_R_PS;

    reg clk_f, clk_r;
    reg rst_n_f, rst_n_r;
    reg echo_f, echo_r;
    reg run_real;

    wire        trig_f;
    wire [15:0] distance_f;
    wire        valid_f;
    wire        fault_f;
    wire [7:0]  stuck_cnt_f;

    wire        trig_r;
    wire [15:0] distance_r;
    wire        valid_r;
    wire        fault_r;
    wire [7:0]  stuck_cnt_r;

    integer failures;
    integer valid_f_rises;
    integer trig_f_rises;

    time t_f_last, t_f_rise, width_f, period_f;
    time t_r_last, t_r_rise, width_r, period_r;

    reg [15:0] d_prev;
    integer    v0, v1;

    sonar_range #(
        .CLK_MHZ     (CLK_MHZ_F),
        .TRIG_US     (TRIG_US_F),
        .PERIOD_US   (PERIOD_US_F),
        .TIMEOUT_US  (TIMEOUT_US_F),
        .STUCK_US    (STUCK_US_F),
        .MIN_ECHO_US (MIN_ECHO_US_F),
        .MAX_DIST_MM (MAX_DIST_MM_F)
    ) u_fast (
        .clk         (clk_f),
        .rst_n       (rst_n_f),
        .trig        (trig_f),
        .echo        (echo_f),
        .distance_mm (distance_f),
        .valid       (valid_f),
        .fault       (fault_f),
        .stuck_cnt   (stuck_cnt_f)
    );

    sonar_range #(
        .CLK_MHZ     (CLK_MHZ_R),
        .TRIG_US     (TRIG_US_R),
        .PERIOD_US   (PERIOD_US_R),
        .TIMEOUT_US  (TIMEOUT_US_R),
        .STUCK_US    (STUCK_US_R),
        .MIN_ECHO_US (MIN_ECHO_US_R),
        .MAX_DIST_MM (MAX_DIST_MM_R)
    ) u_real (
        .clk         (clk_r),
        .rst_n       (rst_n_r),
        .trig        (trig_r),
        .echo        (echo_r),
        .distance_mm (distance_r),
        .valid       (valid_r),
        .fault       (fault_r),
        .stuck_cnt   (stuck_cnt_r)
    );

    // 10MHz 时钟常开；72MHz 时钟由 run_real 门控，快速用例期间不产生事件
    always #(CLK_PT_F_PS / 2) clk_f = ~clk_f;

    always begin
        wait (run_real == 1'b1);
        #(CLK_PT_R_PS / 2) clk_r = ~clk_r;
    end

    // 真实实例的回波应答器：每轮 TRIG 后给出 10cm 回波（500us 起，583us 宽）
    initial begin
        echo_r = 1'b0;
        forever begin
            @(posedge trig_r);
            #(500 * US_R_PS);
            echo_r = 1'b1;
            #(583 * US_R_PS);
            echo_r = 1'b0;
        end
    end

    // ---- 全局断言：TRIG 宽度 >= 10us，周期 >= PERIOD_US ----
    always @(posedge trig_f) begin
        time p;
        if (t_f_last != 0) begin
            p = ($time - t_f_last) / US_F_PS;
            period_f = p;
            // 允许 1us 量化余量：trig 是寄存器输出，比 us 比较点晚一拍，
            // 且 TB 用整数 microsecond 截断，边界上会量到 PERIOD_US-1us
            if (p < (PERIOD_US_F - 1)) begin
                $display("FAIL: fast TRIG period %0d us < %0d us", p, PERIOD_US_F - 1);
                failures = failures + 1;
            end
        end
        t_f_last   = $time;
        t_f_rise   = $time;
        trig_f_rises = trig_f_rises + 1;
    end

    always @(negedge trig_f) begin
        time w;
        w = ($time - t_f_rise) / US_F_PS;
        width_f = w;
        if (w < 10) begin
            $display("FAIL: fast TRIG width %0d us < 10 us", w);
            failures = failures + 1;
        end
    end

    always @(posedge trig_r) begin
        time p;
        if (t_r_last != 0) begin
            p = ($time - t_r_last) / US_R_PS;
            period_r = p;
            if (p < (PERIOD_US_R - 1)) begin
                $display("FAIL: real TRIG period %0d us < %0d us", p, PERIOD_US_R - 1);
                failures = failures + 1;
            end
        end
        t_r_last = $time;
        t_r_rise = $time;
    end

    always @(negedge trig_r) begin
        time w;
        w = ($time - t_r_rise) / US_R_PS;
        width_r = w;
        if (w < 10) begin
            $display("FAIL: real TRIG width %0d us < 10 us", w);
            failures = failures + 1;
        end
    end

    // 计数 valid 上升沿，用于确认一次测量只产生一个有效标志
    always @(posedge valid_f) valid_f_rises = valid_f_rises + 1;

    task check;
        input condition;
        input [8*48-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                failures = failures + 1;
            end
        end
    endtask

    // 等到本轮 TRIG 结束（状态机刚进入 S_WAIT_HI），再驱动回波
    task automatic fast_trig_wait;
        begin
            @(negedge trig_f);
        end
    endtask

    // 产生一次回波：rise_us 后拉高，持续 echo_us，然后回落
    task automatic fast_measure;
        input integer rise_us;
        input integer echo_us;
        begin
            fast_trig_wait();
            if (rise_us > 0) #(rise_us * US_F_PS);
            echo_f = 1'b1;
            #(echo_us * US_F_PS);
            echo_f = 1'b0;
            #(10 * US_F_PS);
        end
    endtask

    initial begin
        clk_f      = 1'b0;
        clk_r      = 1'b0;
        rst_n_f    = 1'b0;
        rst_n_r    = 1'b0;
        echo_f     = 1'b0;
        echo_r     = 1'b0;
        run_real   = 1'b0;
        failures   = 0;
        valid_f_rises = 0;
        trig_f_rises  = 0;
        t_f_last   = 0;
        t_r_last   = 0;
        d_prev     = 16'h0000;

        repeat (8) @(posedge clk_f);
        rst_n_f = 1'b1;
        repeat (4) @(posedge clk_f);

        // ---- 用例 9：复位值 + 复位后首次无回波 ----
        check(trig_f === 1'b0,         "case9 trig=0 after reset");
        check(valid_f === 1'b0,        "case9 valid=0 after reset");
        check(distance_f === 16'hFFFF, "case9 distance_mm=16'hFFFF after reset");
        check(fault_f === 1'b0,        "case9 fault=0 after reset");
        check(stuck_cnt_f === 8'd0,    "case9 stuck_cnt=0 after reset");

        v0 = valid_f_rises;            // 长回波用例里下一轮 TRIG 会立刻清 valid，
                                       // 因此"是否出现过有效结果"按上升沿计数判断
        fast_trig_wait();
        #(40_000 * US_F_PS);           // 全程无回波，等过 TIMEOUT_US
        check(valid_f_rises == v0,     "case9 first no-echo: no valid pulse");
        check(distance_f === 16'hFFFF, "case9 first no-echo: distance must not be used");

        // ---- 用例 1：583us 回波，约 10cm ----
        v0 = valid_f_rises;
        fast_measure(300, 583);
        check(valid_f === 1'b1, "case1 valid=1");
        check((valid_f_rises - v0) == 1, "case1 exactly one valid pulse");
        check((distance_f >= 99) && (distance_f <= 101), "case1 distance ~100mm");
        d_prev = distance_f;

        // ---- 用例 2：116us / 2915us，约 2cm / 50cm ----
        v0 = valid_f_rises;
        fast_measure(300, 116);
        check((valid_f_rises - v0) == 1, "case2a exactly one valid pulse");
        check((distance_f >= 19) && (distance_f <= 21), "case2a distance ~20mm");
        d_prev = distance_f;

        v0 = valid_f_rises;
        fast_measure(300, 2915);
        check((valid_f_rises - v0) == 1, "case2b exactly one valid pulse");
        check((distance_f >= 498) && (distance_f <= 502), "case2b distance ~500mm");
        d_prev = distance_f;

        // ---- 用例 3：有效测量后再无回波，距离必须保持 ----
        v0 = valid_f_rises;
        fast_trig_wait();
        #(40_000 * US_F_PS);
        check(valid_f_rises == v0,     "case3 no valid pulse when echo absent");
        check(distance_f === d_prev,   "case3 distance holds previous valid value");

        // ---- 用例 7：一个时钟周期的毛刺 ----
        v0 = valid_f_rises;
        fast_trig_wait();
        #(300 * US_F_PS);
        @(posedge clk_f); echo_f = 1'b1;
        @(posedge clk_f); echo_f = 1'b0;
        #(50 * US_F_PS);
        check(valid_f_rises == v0,   "case7 glitch: no valid pulse");
        check(distance_f === d_prev, "case7 glitch: distance unchanged");

        // ---- 用例 8：边沿落在时钟边沿附近 ----
        v0 = valid_f_rises;
        fast_trig_wait();
        #(300 * US_F_PS + CLK_PT_F_PS / 2 + 1);
        echo_f = 1'b1;
        #(583 * US_F_PS + 1);
        echo_f = 1'b0;
        #(10 * US_F_PS);
        check(valid_f === 1'b1, "case8 valid=1 with edges near clock boundary");
        check((distance_f >= 99) && (distance_f <= 101), "case8 distance ~100mm");
        check((valid_f_rises - v0) == 1, "case8 exactly one valid edge per measurement");
        d_prev = distance_f;

        // ---- 用例 10：换算结果超过 MAX_DIST_MM ----
        v0 = valid_f_rises;
        fast_trig_wait();
        #(300 * US_F_PS); echo_f = 1'b1;
        #(26_500 * US_F_PS); echo_f = 1'b0;
        #(10 * US_F_PS);
        check(valid_f_rises == v0,   "case10 over-range rejected");
        check(distance_f === d_prev, "case10 distance unchanged");

        // ---- 用例 4：38ms 长高脉冲（部分模块的无回波表现）----
        v0 = valid_f_rises;
        fast_trig_wait();
        #(300 * US_F_PS); echo_f = 1'b1;
        #(38_000 * US_F_PS); echo_f = 1'b0;
        #(50 * US_F_PS);
        check(valid_f_rises == v0,   "case4 38ms pulse rejected");
        check(fault_f === 1'b0,      "case4 single 38ms pulse does not set fault");
        check(distance_f === d_prev, "case4 distance unchanged");

        // ---- 用例 5：ECHO 持续卡高 ----
        v1 = trig_f_rises;
        fast_trig_wait();
        echo_f = 1'b1;                       // 立刻卡高，本次测量必然超时
        #(185_000 * US_F_PS);                // 过 TIMEOUT_US+STUCK_US(130ms)，落在下一轮 S_WAIT_LO 窗口内
        check(fault_f === 1'b1,      "case5 fault latched when echo stuck high");
        check(stuck_cnt_f >= 8'd1,   "case5 stuck_cnt counted the stuck event");
        check(trig_f_rises > v1,     "case5 TRIG keeps firing after fault");

        // ---- 用例 6：卡高后回落并恢复 ----
        echo_f = 1'b0;                       // 在 S_WAIT_LO 内释放，不产生读数
        fast_measure(300, 583);
        fast_measure(300, 583);
        check(valid_f === 1'b1,      "case6 recovery valid=1");
        check(fault_f === 1'b0,      "case6 recovery clears fault by successful measurement");
        check((distance_f >= 99) && (distance_f <= 101), "case6 recovery distance ~100mm");

        // ---- 真实 72MHz 配置：检查整数分频、边沿处理和一次完整测量 ----
        run_real = 1'b1;
        repeat (8) @(posedge clk_r);
        rst_n_r = 1'b1;

        @(negedge trig_r);                   // 第一次 TRIG 结束（复位后约 70ms）
        wait (valid_r === 1'b1);             // 583us 回波完成换算
        check((distance_r >= 99) && (distance_r <= 101), "real 72MHz: 583us -> ~100mm");
        check(fault_r === 1'b0,              "real 72MHz: fault stays 0");
        check(stuck_cnt_r === 8'd0,          "real 72MHz: stuck_cnt stays 0");

        @(posedge trig_r);                   // 第二次 TRIG：周期断言在此校验
        #(100 * US_R_PS);                    // 等监视器完成本次周期记录
        check(period_r >= 60_000, "real 72MHz: TRIG interval meets >=60ms spec");

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $display("INFO: fast CLK_MHZ=%0d TRIG width=%0d us period=%0d us",
                 CLK_MHZ_F, width_f, period_f);
        $display("INFO: real CLK_MHZ=%0d TRIG width=%0d us period=%0d us",
                 CLK_MHZ_R, width_r, period_r);

        $finish;
    end
endmodule
