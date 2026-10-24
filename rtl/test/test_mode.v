// ============================================================
// test_mode.v —— 测试模式：多路非谐波固定频率的"自动按键"
//
// 用途（docs/04 P6.1 / P6.3）：
//   让 N 个振荡器同时发声，频率已知且互不成谐波关系，使评委能在频谱上
//   直接数出独立谱峰，证明"同时活跃的独立振荡器数"。
//
// 设计口径（2026-09-23 确认）：
//   1. 本模块不产生音频，只产生 note_on / note_off / note_id / note_inc
//      刺激，音频仍由现有 synth_engine（voice_alloc + synth_top）产生，
//      保证频谱上的峰与演奏时完全同源。
//   2. note_on / note_off 必须是单周期脉冲：voice_alloc 的 note_on 是电平
//      敏感的，拉高多个周期会被当成多次分配。
//   3. 频率取 k << 20（32 位相位累加器 + 4096 点 FFT）：音高精确落在
//      48000/4096 = 11.71875 Hz 的栅格上，相干采样、零调谐误差；
//      各 k 之间互不成整数倍，分析带宽内不会出现谐波重叠。
//   4. note_id 从 7'd80 起：避开 synth_engine 中 gain_for_note 的
//      C4/E4/G4/A4/B4 表项，得到统一增益 32768，
//      不让 A 加权补偿影响各谱峰的相对幅度。
//   5. 起音/释放都在相邻时钟拍内连续发出（每个脉冲之间只空一拍），
//      于是 N 个 gate 落在同一个 48kHz 采样周期里，mixer 的归一化系数
//      只变化一次；配合每个声部自己的 ADSR 起音，起音与释放都没有台阶声。
//   6. 频率表提供 32 个质数 k；质数之间不存在非平凡整数倍关系，
//      可避免整数倍谐波重叠。
// ============================================================

module test_mode #(
    parameter CLK_MHZ = 72,
    parameter N_TONES = 4,        // 同时发声的固定频率数，最大 32
    parameter HOLD_US = 500       // enable 后等稳定再起音
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,     // 1 = 测试模式（来自已消抖的按键）
    output reg         note_on,    // 单周期脉冲
    output reg         note_off,   // 单周期脉冲
    output reg  [6:0]  note_id,
    output reg  [31:0] note_inc,
    output wire        busy,       // 非空闲：顶层据此决定是否把本模块接到引擎
    output wire [5:0]  active_cnt  // 已起音的音数（给 LED / 调试）
);
    localparam [1:0] S_IDLE    = 2'd0,
                     S_ALLOC   = 2'd1,
                     S_SOUND   = 2'd2,
                     S_RELEASE = 2'd3;

    localparam integer TICK_DIV = (CLK_MHZ < 1) ? 1 : CLK_MHZ;
    localparam integer TICK_W   = (TICK_DIV <= 1) ? 1 : $clog2(TICK_DIV);

    localparam [31:0] HOLD_C = HOLD_US;
    localparam [5:0]  N_C    = N_TONES;

    reg [1:0]        state;
    reg [TICK_W-1:0] tick_cnt;
    reg [31:0]       us_cnt;      // 当前状态内已过去的微秒数
    reg [5:0]        idx;         // 正在处理的音序号
    reg [5:0]        assigned;    // 已起音、待释放的音数
    reg              gap_wait;    // 发完一个脉冲后空一拍，保证单周期脉冲

    wire tick_now = (tick_cnt == TICK_DIV - 1);

    // 频率表：k 是 48000/4096 = 11.71875 Hz 的整数倍，音高零调谐误差
    function [31:0] inc_for_index;
        input [5:0] i;
        begin
            case (i)
                6'd0: inc_for_index = 32'd37  << 20;  //  433.59375 Hz
                6'd1: inc_for_index = 32'd41  << 20;  //  480.46875 Hz
                6'd2: inc_for_index = 32'd43  << 20;  //  503.90625 Hz
                6'd3: inc_for_index = 32'd47  << 20;  //  550.78125 Hz
                6'd4: inc_for_index = 32'd53  << 20;  //  621.09375 Hz
                6'd5: inc_for_index = 32'd59  << 20;  //  691.40625 Hz
                6'd6: inc_for_index = 32'd61  << 20;  //  714.84375 Hz
                6'd7: inc_for_index = 32'd67  << 20;  //  785.15625 Hz
                6'd8: inc_for_index = 32'd71  << 20;  //  832.03125 Hz
                6'd9: inc_for_index = 32'd73  << 20;  //  855.46875 Hz
                6'd10: inc_for_index = 32'd79 << 20;  //  925.78125 Hz
                6'd11: inc_for_index = 32'd83 << 20;  //  972.65625 Hz
                6'd12: inc_for_index = 32'd89 << 20;  // 1042.96875 Hz
                6'd13: inc_for_index = 32'd97 << 20;  // 1136.71875 Hz
                6'd14: inc_for_index = 32'd101 << 20; // 1183.59375 Hz
                6'd15: inc_for_index = 32'd103 << 20; // 1207.03125 Hz
                6'd16: inc_for_index = 32'd107 << 20; // 1253.90625 Hz
                6'd17: inc_for_index = 32'd109 << 20; // 1277.34375 Hz
                6'd18: inc_for_index = 32'd113 << 20; // 1324.21875 Hz
                6'd19: inc_for_index = 32'd127 << 20; // 1488.28125 Hz
                6'd20: inc_for_index = 32'd131 << 20; // 1535.15625 Hz
                6'd21: inc_for_index = 32'd137 << 20; // 1605.46875 Hz
                6'd22: inc_for_index = 32'd139 << 20; // 1628.90625 Hz
                6'd23: inc_for_index = 32'd149 << 20; // 1746.09375 Hz
                6'd24: inc_for_index = 32'd151 << 20; // 1769.53125 Hz
                6'd25: inc_for_index = 32'd157 << 20; // 1839.84375 Hz
                6'd26: inc_for_index = 32'd163 << 20; // 1910.15625 Hz
                6'd27: inc_for_index = 32'd167 << 20; // 1957.03125 Hz
                6'd28: inc_for_index = 32'd173 << 20; // 2027.34375 Hz
                6'd29: inc_for_index = 32'd179 << 20; // 2097.65625 Hz
                6'd30: inc_for_index = 32'd181 << 20; // 2121.09375 Hz
                6'd31: inc_for_index = 32'd191 << 20; // 2238.28125 Hz
                default: inc_for_index = 32'd37 << 20;
            endcase
        end
    endfunction

    assign busy       = (state != S_IDLE);
    assign active_cnt = assigned;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            tick_cnt <= {TICK_W{1'b0}};
            us_cnt   <= 32'd0;
            idx      <= 6'd0;
            assigned <= 6'd0;
            gap_wait <= 1'b0;
            note_on  <= 1'b0;
            note_off <= 1'b0;
            note_id  <= 7'd80;
            note_inc <= 32'd37 << 20;
        end else begin
            note_on  <= 1'b0;      // 默认拉低，保证是单周期脉冲
            note_off <= 1'b0;

            if (tick_now) begin
                tick_cnt <= {TICK_W{1'b0}};
                us_cnt   <= us_cnt + 32'd1;
            end else begin
                tick_cnt <= tick_cnt + 1'b1;
            end

            case (state)
                S_IDLE: begin
                    us_cnt   <= 32'd0;
                    idx      <= 6'd0;
                    assigned <= 6'd0;
                    gap_wait <= 1'b0;
                    if (enable)
                        state <= S_ALLOC;
                end

                S_ALLOC: begin
                    if (!enable) begin                   // 起音途中被取消
                        idx      <= 6'd0;
                        gap_wait <= 1'b0;
                        state    <= S_RELEASE;
                    end else if (idx >= N_C) begin
                        state <= S_SOUND;
                    end else if (gap_wait) begin
                        gap_wait <= 1'b0;                // 空一拍
                    end else if ((idx != 6'd0) || (us_cnt >= HOLD_C)) begin
                        // 相邻音只隔一拍 → N 个 gate 落在同一个采样周期内，
                        // mixer 归一化只变化一次，起音无台阶声。
                        note_on  <= 1'b1;                // 单周期脉冲
                        note_id  <= 7'd80 + idx;
                        note_inc <= inc_for_index(idx);
                        assigned <= idx + 6'd1;
                        idx      <= idx + 6'd1;
                        gap_wait <= 1'b1;
                    end
                end

                S_SOUND: begin
                    if (!enable) begin
                        idx      <= 6'd0;
                        gap_wait <= 1'b0;
                        state    <= S_RELEASE;
                    end
                end

                S_RELEASE: begin
                    if (idx >= assigned) begin
                        state <= S_IDLE;
                    end else if (gap_wait) begin
                        gap_wait <= 1'b0;
                    end else begin
                        note_off <= 1'b1;                // 单周期脉冲
                        note_id  <= 7'd80 + idx;
                        idx      <= idx + 6'd1;
                        gap_wait <= 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
