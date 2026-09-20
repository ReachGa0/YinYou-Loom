module i2s_tx (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               bit_tick,      // 每 15 个系统时钟一个脉冲
    input  wire signed [15:0] sample_in,     // 合成引擎当前样本
    output reg                bclk,
    output reg                lrclk,
    output reg                sdata,
    output reg                sample_req     // 每帧一个脉冲，触发合成引擎
);
    reg        half;         // 0 = BCLK 低，1 = BCLK 高
    reg [5:0]  cyc;          // 帧内 BCLK 周期序号 0..47
    reg [47:0] sh;           // 整帧 48 位移位寄存器

    // 声道字：1 位延迟 + 16 位样本 + 7 位补零
    wire [23:0] word_ch    = {1'b0, sample_in[15:0], 7'b0};
    wire [47:0] frame_word = {word_ch, word_ch};   // 左声道在前

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            half       <= 1'b0;
            bclk       <= 1'b0;
            cyc        <= 6'd0;
            sh         <= 48'd0;
            sdata      <= 1'b0;
            lrclk      <= 1'b0;
            sample_req <= 1'b0;
        end else begin
            sample_req <= 1'b0;

            if (bit_tick) begin
                if (!half) begin
                    bclk <= 1'b1;             // 上升沿：从机在此采样
                    half <= 1'b1;
                end else begin
                    bclk <= 1'b0;             // 下降沿：改变数据
                    half <= 1'b0;

                    if (cyc == 6'd47) begin
                        cyc        <= 6'd0;
                        lrclk      <= 1'b0;                  // 切到左声道
                        sdata      <= frame_word[47];        // 第一位（延迟位）
                        sh         <= {frame_word[46:0], 1'b0};
                        sample_req <= 1'b1;                  // 请引擎算下一帧
                    end else begin
                        cyc <= cyc + 1'b1;
                        if (cyc == 6'd23)
                            lrclk <= 1'b1;                   // 切到右声道
                        sdata <= sh[47];
                        sh    <= {sh[46:0], 1'b0};
                    end
                end
            end
        end
    end
endmodule