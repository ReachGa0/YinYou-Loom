module voice_adsr #(
    parameter LEVEL_W = 16
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  sample_en,       // 48kHz 单周期脉冲
    input  wire                  gate,            // 1=按下, 0=松开
    input  wire [LEVEL_W-1:0]    a_step,          // Attack 每采样增加量
    input  wire [LEVEL_W-1:0]    d_step,          // Decay 每采样减少量
    input  wire [LEVEL_W-1:0]    sustain_level,   // Sustain 保持电平
    input  wire [LEVEL_W-1:0]    r_step,          // Release 每采样减少量
    output reg  [LEVEL_W-1:0]    level,           // 当前包络值 0~65535
    output reg                   busy             // 是否还在发声
);
    localparam S_IDLE    = 3'd0;
    localparam S_ATTACK  = 3'd1;
    localparam S_DECAY   = 3'd2;
    localparam S_SUSTAIN = 3'd3;
    localparam S_RELEASE = 3'd4;

    localparam [LEVEL_W-1:0] LEVEL_MAX = {LEVEL_W{1'b1}};

    reg [2:0] state;

    wire [LEVEL_W:0] decay_stop = {1'b0, sustain_level} + {1'b0, d_step};

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            level <= {LEVEL_W{1'b0}};
            busy  <= 1'b0;
        end else if (sample_en) begin
            case (state)

                S_IDLE: begin
                    level <= {LEVEL_W{1'b0}};
                    busy  <= 1'b0;
                    if (gate) begin
                        state <= S_ATTACK;
                        busy  <= 1'b1;
                    end
                end

                S_ATTACK: begin
                    busy <= 1'b1;
                    if (!gate)
                        state <= S_RELEASE;
                    else if (level >= LEVEL_MAX - a_step) begin
                        level <= LEVEL_MAX;
                        state <= S_DECAY;
                    end else
                        level <= level + a_step;
                end

                S_DECAY: begin
                    busy <= 1'b1;
                    if (!gate)
                        state <= S_RELEASE;
                    else if ({1'b0, level} <= decay_stop) begin
                        level <= sustain_level;
                        state <= S_SUSTAIN;
                    end else
                        level <= level - d_step;
                end

                S_SUSTAIN: begin
                    busy  <= 1'b1;
                    level <= sustain_level;
                    if (!gate)
                        state <= S_RELEASE;
                end

                S_RELEASE: begin
                    busy <= 1'b1;
                    if (gate)
                        state <= S_ATTACK;          // 释放期间再按下，重新起音
                    else if (level <= r_step) begin
                        level <= {LEVEL_W{1'b0}};
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end else
                        level <= level - r_step;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule