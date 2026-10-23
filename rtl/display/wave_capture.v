// ============================================================
// wave_capture.v —— 真实音频采样的"示波器窗口"抓取器
//
// 用途：把 I2S 送出的真实采样（48 kHz）抓 320 点，供 TFT 波形带显示。
//   1. 双 bank（2×512×16），抓一窗用时另一窗可读 → 不会撕裂；
//   2. 以"上升过零"为触发点，画面不会左右乱跳（示波器的 trigger）；
//   3. 静音/无过零时超时强制开抓，画面退化成一条直线，不会卡住；
//   4. 320 点 @48 kHz = 6.67 ms 窗口；440 Hz 约 2.9 个周期。
//
// 读写约定：
//   写口：sample_en 为 48 kHz 单周期脉冲时写入 sample_in；
//   读口：rd_bank_sel + rd_addr（组合地址）→ 下一拍出 rd_data。
//         bank 选择由渲染器在帧边界锁存，保证一帧内不会换 bank。
// ============================================================

module wave_capture #(
    parameter SAMPLE_W = 16,
    parameter LEN      = 320,        // 一窗点数（≤ 512）
    parameter TIMEOUT  = 4096        // 等不到过零时，最多等这么多采样
) (
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        sample_en,      // 48 kHz 单周期
    input  wire signed [SAMPLE_W-1:0]  sample_in,      // I2S 实际送出的样本
    input  wire                        trigger,        // 单周期：请求抓下一窗

    output reg                         frame_valid,    // 至少有一窗可用
    output reg                         last_bank,      // 最近抓完的 bank
    output reg  [15:0]                 peak_out,       // 本窗峰值（绝对值）

    input  wire                        rd_bank_sel,    // 渲染器锁存的 bank
    input  wire [8:0]                  rd_addr,        // 0..319
    output reg  signed [SAMPLE_W-1:0]  rd_data
);
    localparam ADDR_W = 10;          // 2 bank × 512

    reg signed [SAMPLE_W-1:0] mem [0:(1<<ADDR_W)-1];

    reg                        capturing;
    reg                        armed;         // 正在等上升过零
    reg                        wr_bank;
    reg [8:0]                  wr_idx;
    reg [12:0]                 wait_cnt;
    reg signed [SAMPLE_W-1:0]  prev_s;
    reg [15:0]                 peak_acc;

    // |sample|：负样本取补码；-32768 会得到 0x8000，按无符号正好是 32768
    wire [15:0] abs_s = sample_in[SAMPLE_W-1] ? (~sample_in + 16'd1) : sample_in;

    // ---- 读口：组合地址，下一拍出数据（与字库 ROM 同一套节拍） ----
    always @(posedge clk) begin
        rd_data <= mem[{rd_bank_sel, rd_addr}];
    end

    // ---- 写口 + 触发状态机 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            capturing   <= 1'b0;
            armed       <= 1'b0;
            wr_bank     <= 1'b0;
            wr_idx      <= 9'd0;
            wait_cnt    <= 13'd0;
            prev_s      <= {SAMPLE_W{1'b0}};
            frame_valid <= 1'b0;
            last_bank   <= 1'b0;
            peak_acc    <= 16'd0;
            peak_out    <= 16'd0;
        end else if (trigger && !capturing) begin
            capturing <= 1'b1;
            armed     <= 1'b1;
            wr_idx    <= 9'd0;
            wait_cnt  <= 13'd0;
            peak_acc  <= 16'd0;
        end else if (capturing && sample_en) begin
            prev_s <= sample_in;

            if (abs_s > peak_acc) peak_acc <= abs_s;

            if (armed) begin
                // 上升过零：从这一拍开始存 320 点。
                // 注意：必须用"符号位"判断，不能写 sample_in > 0 ——
                // 与无符号常量比较时 Verilog 会整体按无符号比较，负样本会被判成"大于 0"。
                if (prev_s[SAMPLE_W-1] && !sample_in[SAMPLE_W-1]) begin
                    armed  <= 1'b0;
                    mem[{wr_bank, 9'd0}] <= sample_in;
                    wr_idx <= 9'd1;
                end else if (wait_cnt >= TIMEOUT) begin
                    // 静音或信号不过零：超时后照样开抓（显示成直线）
                    armed  <= 1'b0;
                    mem[{wr_bank, 9'd0}] <= sample_in;
                    wr_idx <= 9'd1;
                end else begin
                    wait_cnt <= wait_cnt + 1'b1;
                end
            end else begin
                mem[{wr_bank, wr_idx}] <= sample_in;
                if (wr_idx == (LEN - 1)) begin
                    capturing   <= 1'b0;
                    frame_valid <= 1'b1;
                    last_bank   <= wr_bank;     // 这一块可以读了
                    peak_out    <= (abs_s > peak_acc) ? abs_s : peak_acc;
                    wr_bank     <= ~wr_bank;    // 下一窗写另一块
                    wr_idx      <= 9'd0;
                end else begin
                    wr_idx <= wr_idx + 1'b1;
                end
            end
        end
    end

endmodule
