`include "loom_defs.vh"

module loom_top (
    input  wire clk,          // 板载 27MHz 晶振（PIN4）
    output wire pa_en,        // 功放使能（PIN51），高有效
    output wire i2s_bclk,     // PIN56
    output wire i2s_lrck,     // PIN55
    output wire i2s_din       // PIN54
);
    // ---------- 1. PLL：27MHz -> 72MHz ----------
`ifdef SIM
    // 仿真时不例化 Gowin 原语，测试台直接给 72MHz
    wire clk_sys  = clk;
    wire pll_lock = 1'b1;
`else
    wire clk_sys, pll_lock;
    Gowin_rPLL u_pll (
        .clkin  (clk),
        .reset  (1'b0),
        .clkout (clk_sys),
        .lock   (pll_lock)
    );
`endif

    // ---------- 2. 复位同步：等 PLL 锁定后同步释放 ----------
    wire rst_n;
    sync_reset u_rst (
        .clk    (clk_sys),
        .arst_n (pll_lock),
        .rst_n  (rst_n)
    );

    // ---------- 3. I2S 位节拍：72MHz * 8 / 125 = 4.608MHz ----------
    wire bit_tick;
    frac_div #(
        .STEP (8),
        .DEN  (125)
    ) u_div (
        .clk   (clk_sys),
        .rst_n (rst_n),
        .tick  (bit_tick)
    );

    // ---------- 4. 合成引擎：单声部验证共享波表路径 ----------
    wire signed [15:0] sample;
    wire               sample_en;      // 来自 i2s_tx 的每帧请求
    wire               voice_valid;
    wire               busy;

    // 波表路径要分两种运行环境：
    //   仿真（Icarus）从仓库根目录运行 → "data/wavetables/..."
    //   Gowin 综合时工作目录是 fpga/loom/ → "../../data/wavetables/..."
    // 注意：$readmemh 找不到文件时只会警告，ROM 会变成全 0（静默失败），
    //       所以综合后务必检查日志里有没有 readmemh 的告警。
`ifdef SIM
    localparam INIT_SINE   = "data/wavetables/sine_4096x16.hex";
    localparam INIT_SQUARE = "data/wavetables/square_4096x16.hex";
`else
    localparam INIT_SINE   = "../../data/wavetables/sine_4096x16.hex";
    localparam INIT_SQUARE = "../../data/wavetables/square_4096x16.hex";
`endif

    synth_top #(
        .VOICES     (1),
        .PHASE_BITS (32),
        .ADDR_BITS  (12),
        .SAMPLE_W   (16),
        .LEVEL_W    (16),
        .INIT_FILE0 (INIT_SINE),
        .INIT_FILE1 (INIT_SQUARE)
    ) u_synth (
        .clk                (clk_sys),
        .rst_n              (rst_n),
        .sample_en          (sample_en),
        .table_sel          (2'd0),
        .bend_q15           (16'd32768),
        .inc_flat           (`INC_440),
        .gate_flat          (1'b1),
        .a_step_flat        (16'd273),
        .d_step_flat        (16'd20),
        .sustain_level_flat (16'd32768),
        .r_step_flat        (16'd20),
        .gain_flat          (16'd32768),
        .mix_sample         (sample),
        .scan_done          (),
        .voice_valid        (voice_valid),
        .busy_flat          (busy)
    );

    // ---------- 5. I2S 发送 ----------
    i2s_tx u_i2s (
        .clk        (clk_sys),
        .rst_n      (rst_n),
        .bit_tick   (bit_tick),
        .sample_in  (sample),
        .bclk       (i2s_bclk),
        .lrclk      (i2s_lrck),
        .sdata      (i2s_din),
        .sample_req (sample_en)
    );

    // ---------- 6. 功放使能：常开 ----------
    assign pa_en = 1'b1;

endmodule
