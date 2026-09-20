module wavetable_rom #(
    parameter ADDR_BITS  = 12,
    parameter DATA_W     = 16,
    parameter INIT_FILE  = "data/wavetables/sine_4096x16.hex"
) (
    input wire                     clk,
    input wire [ADDR_BITS-1:0]     addr,
    output reg signed [DATA_W-1:0] data
);

    reg signed [DATA_W-1:0] mem [0:(1<<ADDR_BITS)-1];

    initial begin
      $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) begin
        data <= mem[addr];
    end

endmodule