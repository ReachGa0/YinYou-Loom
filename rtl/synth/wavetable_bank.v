// ============================================================
// wavetable_bank.v —— 多张共享波表
//
// 所有声部共用这两个 ROM，不随 VOICES 增长。
// TABLE_SEL=0 选择 INIT_FILE0，TABLE_SEL=1 选择 INIT_FILE1。
// ============================================================

module wavetable_bank #(
    parameter ADDR_BITS  = 12,
    parameter DATA_W     = 16,
    parameter INIT_FILE0 = "data/wavetables/sine_4096x16.hex",
    parameter INIT_FILE1 = "data/wavetables/square_4096x16.hex"
) (
    input  wire                 clk,
    input  wire [ADDR_BITS-1:0] addr,
    input  wire                 table_sel,
    output wire signed [DATA_W-1:0] data
);
    wire signed [DATA_W-1:0] data0;
    wire signed [DATA_W-1:0] data1;

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

    assign data = table_sel ? data1 : data0;
endmodule
