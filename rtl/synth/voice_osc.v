module voice_osc #(
    parameter PHASE_BITS = 32,
    parameter ADDR_BITS  = 12,
    parameter SAMPLE_W   = 16,
    parameter INIT_FILE  = "data/wavetables/sine_4096x16.hex"
) (
    input wire                        clk,
    input wire                        rst_n,
    input wire                        sample_en,

    input wire [PHASE_BITS-1:0]       inc,
    input wire                        run,

    output wire signed [SAMPLE_W-1:0] sample,
    output reg                        sample_valid
);
    reg [PHASE_BITS-1:0]       phase;
    reg                        rd_en;

    wire [ADDR_BITS-1:0]       addr;
    wire signed [SAMPLE_W-1:0] rom_data ;

    assign addr   = phase[PHASE_BITS-1 -: ADDR_BITS];
    assign sample = rom_data;

    wavetable_rom #(
        .ADDR_BITS (ADDR_BITS),
        .DATA_W    (SAMPLE_W),
        .INIT_FILE (INIT_FILE)
    ) u_rom (
        .clk  (clk),
        .addr (addr),
        .data (rom_data)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            phase        <= {PHASE_BITS{1'b0}};
            rd_en        <= 1'b0;
            sample_valid <= 1'b0;
        end else begin
            rd_en        <= sample_en & run;
            sample_valid <= rd_en;
            if (sample_en & run)
                phase <= phase + inc; 
        end
    end
endmodule