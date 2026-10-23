// ============================================================
// wavetable_bank.v —— 多张共享波表
//
// 所有声部共用这 4 张 ROM，不随 VOICES 增长。
// TABLE_SEL = 0/1/2/3 → INIT_FILE0..3（SINE / SQUARE / SAW / TRIANGLE）。
// ============================================================

module wavetable_bank #(
    parameter ADDR_BITS  = 12,
    parameter DATA_W     = 16,
    parameter INIT_FILE0 = "data/wavetables/sine_4096x16.hex",
    parameter INIT_FILE1 = "data/wavetables/square_4096x16.hex",
    parameter INIT_FILE2 = "data/wavetables/saw_4096x16.hex",
    parameter INIT_FILE3 = "data/wavetables/triangle_4096x16.hex"
) (
    input  wire                 clk,
    input  wire [ADDR_BITS-1:0] addr,
    input  wire [1:0]           table_sel,
    output wire signed [DATA_W-1:0] data
);
    wire signed [DATA_W-1:0] data0;
    wire signed [DATA_W-1:0] data1;
    wire signed [DATA_W-1:0] data2;
    wire signed [DATA_W-1:0] data3;

    wavetable_rom #(
        .ADDR_BITS (ADDR_BITS),
        .DATA_W    (DATA_W),
        .INIT_FILE (INIT_FILE0)
    ) u_table0 (
        .clk  (clk),
        .addr (addr),
        .data (data0)
    );

    wavetable_rom #(
        .ADDR_BITS (ADDR_BITS),
        .DATA_W    (DATA_W),
        .INIT_FILE (INIT_FILE1)
    ) u_table1 (
        .clk  (clk),
        .addr (addr),
        .data (data1)
    );

    wavetable_rom #(
        .ADDR_BITS (ADDR_BITS),
        .DATA_W    (DATA_W),
        .INIT_FILE (INIT_FILE2)
    ) u_table2 (
        .clk  (clk),
        .addr (addr),
        .data (data2)
    );

    wavetable_rom #(
        .ADDR_BITS (ADDR_BITS),
        .DATA_W    (DATA_W),
        .INIT_FILE (INIT_FILE3)
    ) u_table3 (
        .clk  (clk),
        .addr (addr),
        .data (data3)
    );

    assign data = (table_sel == 2'd0) ? data0 :
                  (table_sel == 2'd1) ? data1 :
                  (table_sel == 2'd2) ? data2 : data3;
endmodule
