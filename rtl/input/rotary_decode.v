// ============================================================
// rotary_decode.v —— EC11 兼容旋转编码器解码与按键消抖
//
// A/B 两相经过同步和稳定过滤，累计一个完整正交周期后
// 输出一次 rotate_left 或 rotate_right。
// 5 引脚编码器的按压开关复用 key_scan 做消抖。
// ============================================================

module rotary_decode #(
    parameter DEBOUNCE_CYCLES = 72000
) (
    input  wire clk,
    input  wire rst_n,
    input  wire enc_a,
    input  wire enc_b,
    input  wire enc_sw_n,

    output reg  rotate_left,
    output reg  rotate_right,
    output wire sw_pressed,
    output wire sw_press
);
    localparam CW = (DEBOUNCE_CYCLES <= 1) ? 1 : $clog2(DEBOUNCE_CYCLES);

    reg a_sync0, a_sync1;
    reg b_sync0, b_sync1;
    reg [1:0] stable_state;
    reg [CW-1:0] stable_cnt;
    reg signed [4:0] quad_acc;

    wire [1:0] raw_state = {a_sync1, b_sync1};

    function signed [2:0] quad_delta;
        input [1:0] old_state;
        input [1:0] new_state;
        begin
            case ({old_state, new_state})
                4'b00_01,
                4'b01_11,
                4'b11_10,
                4'b10_00: quad_delta = 3'sd1;
                4'b00_10,
                4'b10_11,
                4'b11_01,
                4'b01_00: quad_delta = -3'sd1;
                default:    quad_delta = 3'sd0;
            endcase
        end
    endfunction

    reg signed [2:0] delta;
    wire signed [4:0] delta_ext = delta;
    wire signed [4:0] next_acc  = quad_acc + delta_ext;

    key_scan #(
        .KEYS            (1),
        .DEBOUNCE_CYCLES (DEBOUNCE_CYCLES)
    ) u_sw (
        .clk           (clk),
        .rst_n         (rst_n),
        .key_n         (enc_sw_n),
        .pressed       (sw_pressed),
        .press_pulse   (sw_press),
        .release_pulse ()
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_sync0      <= 1'b0;
            a_sync1      <= 1'b0;
            b_sync0      <= 1'b0;
            b_sync1      <= 1'b0;
            stable_state <= 2'b00;
            stable_cnt   <= {CW{1'b0}};
            quad_acc     <= 5'sd0;
            rotate_left  <= 1'b0;
            rotate_right <= 1'b0;
        end else begin
            a_sync0 <= enc_a;
            a_sync1 <= a_sync0;
            b_sync0 <= enc_b;
            b_sync1 <= b_sync0;

            rotate_left  <= 1'b0;
            rotate_right <= 1'b0;

            if (raw_state == stable_state) begin
                stable_cnt <= {CW{1'b0}};
            end else if (stable_cnt == DEBOUNCE_CYCLES - 1) begin
                stable_cnt <= {CW{1'b0}};
                delta = quad_delta(stable_state, raw_state);
                stable_state <= raw_state;

                if (delta != 0) begin
                    if (next_acc >= 5'sd4) begin
                        quad_acc     <= next_acc - 5'sd4;
                        rotate_right <= 1'b1;
                    end else if (next_acc <= -5'sd4) begin
                        quad_acc    <= next_acc + 5'sd4;
                        rotate_left <= 1'b1;
                    end else begin
                        quad_acc <= next_acc;
                    end
                end
            end else begin
                stable_cnt <= stable_cnt + 1'b1;
            end
        end
    end
endmodule
