// ============================================================
// test_mode_router.v —— R3 测试模式的启停握手
//
// 正式演奏与测试模式不能同时接入 synth_engine：
//   1. 收到切换请求后，先等正式演奏声部全部空闲；
//   2. 测试进行中再次切换，只撤销 enable 并等待测试音符释放；
//   3. 测试音和正式音全部结束后，才把音频源切回演奏输入。
//
// toggle_req 是消抖后的单周期脉冲。voice_busy 和 test_busy 分别是
// 合成引擎与 test_mode 的忙信号。
// ============================================================

module test_mode_router (
    input  wire clk,
    input  wire rst_n,
    input  wire toggle_req,
    input  wire voice_busy,
    input  wire test_busy,
    output reg  test_enable,
    output wire test_route,
    output wire state_wait_quiet,
    output wire state_test
);
    localparam [1:0] S_OFF     = 2'd0,
                     S_WAIT    = 2'd1,
                     S_TEST    = 2'd2,
                     S_RELEASE = 2'd3;

    reg [1:0] state;

    assign test_route       = (state == S_TEST) || (state == S_RELEASE);
    assign state_wait_quiet = (state == S_WAIT);
    assign state_test       = (state == S_TEST);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_OFF;
            test_enable <= 1'b0;
        end else begin
            case (state)
                S_OFF: begin
                    test_enable <= 1'b0;
                    if (toggle_req)
                        state <= S_WAIT;
                end

                S_WAIT: begin
                    test_enable <= 1'b0;
                    if (toggle_req)
                        state <= S_OFF;
                    else if (!voice_busy)
                        state <= S_TEST;
                end

                S_TEST: begin
                    test_enable <= 1'b1;
                    if (toggle_req) begin
                        test_enable <= 1'b0;
                        state       <= S_RELEASE;
                    end
                end

                S_RELEASE: begin
                    test_enable <= 1'b0;
                    if (!voice_busy && !test_busy)
                        state <= S_OFF;
                end

                default: begin
                    state       <= S_OFF;
                    test_enable <= 1'b0;
                end
            endcase
        end
    end
endmodule
