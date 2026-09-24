`timescale 1ns/1ps

// ============================================================
// tb_chord_map.v —— 和弦"最近按下优先"验证
//
// 场景：
//   1. enable=0（独奏模式）时按任何键都不应发脉冲；
//   2. 按 A → 三个 note_on（60/64/67），且 G4 的调音字必须是 35075158
//      （防止表里的数字再被写错一位）；
//   3. 按住 A 再按 B → 先释放 A 的三个音，等 voice_busy 归零后起 B 的三个音
//      （64/68/71）；
//   4. 松开 B（A 仍按住）→ 释放 B，等空前再起回 A（60/64/67）；
//   5. 松开 A → 释放后进入空闲，不再有任何脉冲；
//   6. note_on / note_off 必须是单周期脉冲。
//
// voice_busy 由测试台模拟：收到 note_off 后保持 300 个周期（相当于 ADSR 释放尾音）。
// ============================================================

module tb_chord_map;
    localparam KEYS = 4;

    reg               clk = 1'b0;
    reg               rst_n = 1'b0;
    reg               enable = 1'b0;
    reg  [KEYS-1:0]   pressed = {KEYS{1'b0}};
    reg  [KEYS-1:0]   voice_busy = {KEYS{1'b0}};

    wire              note_on;
    wire              note_off;
    wire [6:0]        note_id;
    wire [31:0]       note_inc;
    wire [KEYS-1:0]   chord_on;

    integer failures = 0;
    integer checks   = 0;
    integer i;

    // 采集脉冲
    reg [6:0]  on_ids  [0:15];
    reg [31:0] on_incs [0:15];
    reg [6:0]  off_ids [0:15];
    integer    on_count  = 0;
    integer    off_count = 0;

    integer busy_cnt = 0;
    integer on_run = 0;
    integer on_run_max = 0;
    integer off_run = 0;
    integer off_run_max = 0;

    always #5 clk = ~clk;

    chord_map #(
        .KEYS (KEYS)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (enable),
        .pressed    (pressed),
        .voice_busy (voice_busy),
        .note_on    (note_on),
        .note_off   (note_off),
        .note_id    (note_id),
        .note_inc   (note_inc),
        .chord_on   (chord_on)
    );

    always @(posedge clk) begin
        if (note_on) begin
            if (on_count < 16) begin
                on_ids[on_count]  <= note_id;
                on_incs[on_count] <= note_inc;
            end
            on_count <= on_count + 1;
        end

        if (note_off) begin
            if (off_count < 16)
                off_ids[off_count] <= note_id;
            off_count <= off_count + 1;
        end

        // 单周期脉冲监视
        if (note_on) begin
            on_run <= on_run + 1;
        end else begin
            if (on_run > on_run_max) on_run_max <= on_run;
            on_run <= 0;
        end

        if (note_off) begin
            off_run <= off_run + 1;
        end else begin
            if (off_run > off_run_max) off_run_max <= off_run;
            off_run <= 0;
        end

        // 模拟 ADSR 释放尾音
        if (note_off)
            busy_cnt <= 300;
        else if (busy_cnt != 0)
            busy_cnt <= busy_cnt - 1;

        voice_busy <= (busy_cnt != 0) ? {KEYS{1'b1}} : {KEYS{1'b0}};
    end

    task check;
        input condition;
        input [8*48-1:0] message;
        begin
            checks = checks + 1;
            if (!condition) begin
                $display("FAIL: %0s", message);
                failures = failures + 1;
            end
        end
    endtask

    task wait_ons;
        input integer n;
        integer guard;
        begin
            guard = 0;
            while ((on_count < n) && (guard < 20000)) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    task wait_offs;
        input integer n;
        integer guard;
        begin
            guard = 0;
            while ((off_count < n) && (guard < 20000)) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // 场景 1：独奏模式（enable=0）按键不发声
        pressed[0] = 1'b1;
        repeat (200) @(posedge clk);
        check(on_count == 0, "enable=0: no note_on pulses");
        check(off_count == 0, "enable=0: no note_off pulses");

        // 场景 2：切到和弦模式，按 A → 三个音 60/64/67
        enable = 1'b1;
        wait_ons(3);
        repeat (2) @(posedge clk);
        check(on_count == 3, "A: exactly three note_on");
        check(on_ids[0] == 7'd60, "A chord step0 = C4");
        check(on_ids[1] == 7'd64, "A chord step1 = E4");
        check(on_ids[2] == 7'd67, "A chord step2 = G4");
        check(on_incs[2] == 32'd35075158, "G4 tuning word is 35075158");
        check(on_incs[0] == 32'd23409859, "C4 tuning word is 23409859");
        check(off_count == 0, "A: no note_off while held");

        // 场景 3：按住 A 再按 B → 释放 A(60/64/67) → 起 B(64/68/71)
        pressed[1] = 1'b1;
        wait_offs(3);
        check(off_ids[0] == 7'd60 && off_ids[1] == 7'd64 && off_ids[2] == 7'd67,
              "B press releases A chord 60/64/67");
        wait_ons(6);
        repeat (2) @(posedge clk);
        check(on_ids[3] == 7'd64, "B chord step0 = E4");
        check(on_ids[4] == 7'd68, "B chord step1 = G#4");
        check(on_ids[5] == 7'd71, "B chord step2 = B4");
        check(on_count == 6, "B: exactly three more note_on");

        // 场景 4：松开 B（A 仍按住）→ 释放 B → 回到 A
        pressed[1] = 1'b0;
        wait_offs(6);
        repeat (2) @(posedge clk);
        check(off_ids[3] == 7'd64 && off_ids[4] == 7'd68 && off_ids[5] == 7'd71,
              "B release sends 64/68/71");
        wait_ons(9);
        repeat (2) @(posedge clk);
        check(on_ids[6] == 7'd60 && on_ids[7] == 7'd64 && on_ids[8] == 7'd67,
              "release B: back to A chord 60/64/67");
        check(on_count == 9, "back to A: exactly three more note_on");

        // 场景 5：松开 A → 释放后空闲，不再有脉冲
        pressed[0] = 1'b0;
        wait_offs(9);
        repeat (400) @(posedge clk);
        check(on_count == 9, "all released: no extra note_on");
        check(off_count == 9, "all released: exactly nine note_off total");
        check(chord_on == 4'b0000, "chord_on cleared when idle");

        // 场景 6：脉冲宽度
        check(on_run_max == 1,  "note_on is a single-cycle pulse");
        check(off_run_max == 1, "note_off is a single-cycle pulse");

        $display("");
        $display("PASS=%0d  FAIL=%0d", checks - failures, failures);
        $display("%s", (failures == 0) ? "RESULT: ALL PASS" : "RESULT: SOME CHECKS FAILED");
        $finish;
    end
endmodule
