// ============================================================
// key_scan.v —— 多路按键同步、消抖和事件检测
//
// 输入 key_n 为低有效。输出：
//   pressed       ：消抖后的按下电平
//   press_pulse   ：按下瞬间的单周期脉冲
//   release_pulse ：释放瞬间的单周期脉冲
// ============================================================

module key_scan #(
    parameter KEYS            = 4,
    parameter DEBOUNCE_CYCLES = 72000
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [KEYS-1:0]  key_n,

    output wire [KEYS-1:0]  pressed,
    output reg  [KEYS-1:0]  press_pulse,
    output reg  [KEYS-1:0]  release_pulse
);
    localparam CW = (DEBOUNCE_CYCLES <= 1) ? 1 : $clog2(DEBOUNCE_CYCLES);

    reg [KEYS-1:0] sync0;
    reg [KEYS-1:0] sync1;
    reg [KEYS-1:0] stable;
    reg [CW-1:0]   cnt [0:KEYS-1];

    integer i;

    wire [KEYS-1:0] raw_pressed = ~sync1;

    assign pressed = stable;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync0         <= {KEYS{1'b0}};
            sync1         <= {KEYS{1'b0}};
            stable        <= {KEYS{1'b0}};
            press_pulse   <= {KEYS{1'b0}};
            release_pulse <= {KEYS{1'b0}};
            for (i = 0; i < KEYS; i = i + 1)
                cnt[i] <= {CW{1'b0}};
        end else begin
            sync0 <= key_n;
            sync1 <= sync0;
            press_pulse   <= {KEYS{1'b0}};
            release_pulse <= {KEYS{1'b0}};

            for (i = 0; i < KEYS; i = i + 1) begin
                if (raw_pressed[i] != stable[i]) begin
                    if (cnt[i] == DEBOUNCE_CYCLES - 1) begin
                        cnt[i]   <= {CW{1'b0}};
                        stable[i] <= raw_pressed[i];
                        if (raw_pressed[i])
                            press_pulse[i] <= 1'b1;
                        else
                            release_pulse[i] <= 1'b1;
                    end else begin
                        cnt[i] <= cnt[i] + 1'b1;
                    end
                end else begin
                    cnt[i] <= {CW{1'b0}};
                end
            end
        end
    end
endmodule
