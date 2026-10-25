// ============================================================
// fx_engine.v —— P6 四档统一效果器
//
// mode = 0 DRY
// mode = 1 CHORUS
// mode = 2 DELAY（约 250 ms）
// mode = 3 REVERB（四路短反馈延迟）
//
// chorus / delay / reverb 都持续处理同一输入，输出阶段按模式选择。
// 切换时对最终样本做约 10 ms 的一阶渐变，避免直接跳变造成爆音。
// ============================================================

module fx_engine #(
    parameter SAMPLE_W       = 16,
    parameter CHORUS_ADDR_W  = 11,
    parameter CHORUS_MIN_DLY = 512,
    parameter [23:0] LFO_STEP = 24'd128,
    parameter DELAY_ADDR_W   = 14,
    parameter DELAY_SAMPLES  = 12000,
    parameter REVERB_ADDR_W  = 11,
    parameter REV_LEN0       = 997,
    parameter REV_LEN1       = 1123,
    parameter REV_LEN2       = 1277,
    parameter REV_LEN3       = 1427,
    parameter integer FADE_SAMPLES = 512
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       sample_en,
    input  wire [1:0]                 mode,
    input  wire signed [SAMPLE_W-1:0] sample_in,
    output reg  signed [SAMPLE_W-1:0] sample_out,
    output reg                        sample_valid_out
);
    wire signed [SAMPLE_W-1:0] chorus_out;
    wire                       chorus_valid;
    wire signed [SAMPLE_W-1:0] delay_wet;
    wire                       delay_valid;
    wire signed [SAMPLE_W-1:0] reverb_wet;
    wire                       reverb_valid;

    chorus #(
        .SAMPLE_W  (SAMPLE_W),
        .ADDR_W    (CHORUS_ADDR_W),
        .MIN_DELAY (CHORUS_MIN_DLY),
        .LFO_STEP  (LFO_STEP)
    ) u_chorus (
        .clk              (clk),
        .rst_n            (rst_n),
        .sample_en        (sample_en),
        .mode             (2'd1),
        .sample_in        (sample_in),
        .sample_out       (chorus_out),
        .sample_valid_out (chorus_valid)
    );

    delay_effect #(
        .SAMPLE_W      (SAMPLE_W),
        .ADDR_W        (DELAY_ADDR_W),
        .DELAY_SAMPLES (DELAY_SAMPLES)
    ) u_delay (
        .clk       (clk),
        .rst_n     (rst_n),
        .sample_en (sample_en),
        .sample_in (sample_in),
        .wet_out   (delay_wet),
        .valid_out (delay_valid)
    );

    reverb_effect #(
        .SAMPLE_W (SAMPLE_W),
        .ADDR_W   (REVERB_ADDR_W),
        .LEN0     (REV_LEN0),
        .LEN1     (REV_LEN1),
        .LEN2     (REV_LEN2),
        .LEN3     (REV_LEN3)
    ) u_reverb (
        .clk       (clk),
        .rst_n     (rst_n),
        .sample_en (sample_en),
        .sample_in (sample_in),
        .wet_out   (reverb_wet),
        .valid_out (reverb_valid)
    );

    reg [5:0] wait_cnt;
    reg signed [SAMPLE_W-1:0] dry_hold;
    reg [1:0] active_mode;
    reg signed [SAMPLE_W-1:0] blend_out;
    reg [9:0] fade_remain;

    wire signed [SAMPLE_W+1:0] dry_ext =
        $signed({{(SAMPLE_W+2-SAMPLE_W){dry_hold[SAMPLE_W-1]}}, dry_hold});
    wire signed [SAMPLE_W+1:0] chorus_ext =
        $signed({{(SAMPLE_W+2-SAMPLE_W){chorus_out[SAMPLE_W-1]}}, chorus_out});
    wire signed [SAMPLE_W+1:0] delay_ext =
        $signed({{(SAMPLE_W+2-SAMPLE_W){delay_wet[SAMPLE_W-1]}}, delay_wet});
    wire signed [SAMPLE_W+1:0] reverb_ext =
        $signed({{(SAMPLE_W+2-SAMPLE_W){reverb_wet[SAMPLE_W-1]}}, reverb_wet});

    wire signed [SAMPLE_W+1:0] delay_mix  = (dry_ext + delay_ext) >>> 1;
    wire signed [SAMPLE_W+1:0] reverb_mix =
        dry_ext - (dry_ext >>> 2) + (reverb_ext >>> 2);

    reg signed [SAMPLE_W+1:0] target_sample;

    always @(*) begin
        case (active_mode)
            2'd1: target_sample = chorus_ext;
            2'd2: target_sample = delay_mix;
            2'd3: target_sample = reverb_mix;
            default: target_sample = dry_ext;
        endcase
    end

    wire signed [SAMPLE_W+1:0] fade_delta = target_sample - blend_out;
    wire signed [SAMPLE_W+1:0] fade_step  = fade_delta >>> 6;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wait_cnt         <= 6'd0;
            dry_hold         <= {SAMPLE_W{1'b0}};
            active_mode      <= 2'd0;
            blend_out        <= {SAMPLE_W{1'b0}};
            fade_remain      <= 10'd0;
            sample_out       <= {SAMPLE_W{1'b0}};
            sample_valid_out <= 1'b0;
        end else begin
            sample_valid_out <= 1'b0;

            if (sample_en) begin
                dry_hold <= sample_in;
                wait_cnt <= 6'd31;
                if (mode != active_mode) begin
                    active_mode <= mode;
                    fade_remain <= FADE_SAMPLES;
                end
            end else if (wait_cnt != 0) begin
                wait_cnt <= wait_cnt - 1'b1;
            end

            // 32 个时钟足以等待 chorus / delay / reverb 全部更新完成。
            if (wait_cnt == 6'd1) begin
                if (fade_remain != 0) begin
                    blend_out <= (fade_step == 0) ? target_sample
                                                  : blend_out + fade_step;
                    fade_remain <= fade_remain - 1'b1;
                end else begin
                    blend_out <= target_sample;
                end
                sample_out <= (fade_remain != 0 && fade_step != 0)
                              ? blend_out + fade_step : target_sample;
                sample_valid_out <= 1'b1;
            end
        end
    end

    wire unused_valid = chorus_valid ^ delay_valid ^ reverb_valid;
endmodule
