`timescale 1ns/1ps

module tb_mixer32;
    localparam VOICES   = 32;
    localparam SAMPLE_W = 16;

    reg                           clk;
    reg                           rst_n;
    reg                           sample_en;
    reg  [VOICES*SAMPLE_W-1:0]    voice_sample_flat;
    reg  [VOICES-1:0]             voice_valid_flat;
    reg  [VOICES*16-1:0]          gain_flat;
    reg  [VOICES-1:0]             sound_flat;
    reg                           scan_done;
    wire signed [SAMPLE_W-1:0]    mix_sample;
    wire                          mix_valid;

    integer failures;
    integer i;

    mixer #(
        .VOICES   (VOICES),
        .SAMPLE_W (SAMPLE_W)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .sample_en         (sample_en),
        .voice_sample_flat (voice_sample_flat),
        .voice_valid_flat  (voice_valid_flat),
        .gain_flat         (gain_flat),
        .sound_flat        (sound_flat),
        .scan_done         (scan_done),
        .mix_sample        (mix_sample),
        .mix_valid         (mix_valid)
    );

    always #5 clk = ~clk;

    task frame;
        begin
            @(negedge clk);
            sample_en = 1'b1;
            @(negedge clk);
            sample_en = 1'b0;
            for (i = 0; i < VOICES; i = i + 1) begin
                @(negedge clk);
                voice_valid_flat[i] = 1'b1;
                @(negedge clk);
                voice_valid_flat[i] = 1'b0;
            end
            @(negedge clk);
            scan_done = 1'b1;
            @(negedge clk);
            scan_done = 1'b0;
            @(posedge mix_valid);
            #1;
        end
    endtask

    task settle;
        begin
            repeat (400) frame;
        end
    endtask

    task set_sample;
        input integer index;
        input [15:0] value;
        begin
            voice_sample_flat[index*SAMPLE_W +: SAMPLE_W] = value;
        end
    endtask

    task check;
        input signed [SAMPLE_W-1:0] expected;
        input [8*48-1:0] message;
        begin
            if (mix_sample !== expected) begin
                $display("FAIL: %0s got %0d expected %0d",
                         message, mix_sample, expected);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        clk               = 1'b0;
        rst_n             = 1'b0;
        sample_en         = 1'b0;
        scan_done         = 1'b0;
        voice_sample_flat = {VOICES*SAMPLE_W{1'b0}};
        voice_valid_flat  = {VOICES{1'b0}};
        gain_flat         = {VOICES{16'd32768}};
        sound_flat        = {VOICES{1'b0}};
        failures          = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // 5 声部各 1000，归一化后仍约 1000。
        for (i = 0; i < 5; i = i + 1)
            set_sample(i, 16'd1000);
        sound_flat = 32'h0000_001F;
        settle;
        check(16'sd1000, "five-voice normalization");

        // 32 声部各 1000，总和为 32000，1/32 后仍约 1000。
        for (i = 0; i < VOICES; i = i + 1)
            set_sample(i, 16'd1000);
        sound_flat = {VOICES{1'b1}};
        settle;
        check(16'sd1000, "32-voice normalization");

        // 单声部满幅必须饱和，不能被 32 声部接口截断。
        for (i = 0; i < VOICES; i = i + 1)
            set_sample(i, 16'd0);
        set_sample(0, 16'd32767);
        sound_flat = 32'h0000_0001;
        settle;
        check(16'sd32767, "single-voice positive saturation");

        if (failures == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: %0d FAIL", failures);

        $finish;
    end
endmodule
