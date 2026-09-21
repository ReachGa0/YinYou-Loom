module voice_osc #(
    parameter PHASE_BITS = 32,
    parameter ADDR_BITS  = 12,
    parameter SAMPLE_W   = 16
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       sample_en,

    input  wire [PHASE_BITS-1:0]      inc,
    input  wire                       run,

    output wire [ADDR_BITS-1:0]       addr,
    input  wire signed [SAMPLE_W-1:0] wave_sample,
    input  wire                       wave_valid,

    output reg  signed [SAMPLE_W-1:0] sample,
    output reg                        sample_valid
);
    reg [PHASE_BITS-1:0] phase;

    assign addr = phase[PHASE_BITS-1 -: ADDR_BITS];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase        <= {PHASE_BITS{1'b0}};
            sample       <= {SAMPLE_W{1'b0}};
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= wave_valid;
            if (wave_valid)
                sample <= wave_sample;
            if (sample_en & run)
                phase <= phase + inc;
        end
    end
endmodule
