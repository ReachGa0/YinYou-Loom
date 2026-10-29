// Read-only diagnostic: compare tap 0 with an independently stored delayed input.
module reverb_sample_compare #(
    parameter integer REF_LEN=997,
    parameter integer ADDR_W=10
)(
    input wire clk, rst_n, enabled, accept,
    input wire signed [15:0] sample_in,
    input wire sample_valid,
    input wire signed [15:0] sample_out,
    output reg ready, mismatch
);
    (* syn_ramstyle="block_ram" *) reg signed [15:0] history [0:REF_LEN-1];
    reg [ADDR_W-1:0] pos;
    reg [ADDR_W:0] seen;
    reg signed [15:0] expected;
    reg pending, expected_valid;
    always @(posedge clk) begin
        if (enabled && accept) begin
            expected <= history[pos];
            history[pos] <= sample_in >>> 3;
        end
    end
    always @(posedge clk) begin
        if (!rst_n || !enabled) begin
            pos<=0; seen<=0; pending<=0; expected_valid<=0;
            ready<=0; mismatch<=0;
        end else begin
            if (accept) begin
                pos <= (pos==REF_LEN-1) ? 0 : pos+1'b1;
                if (seen<REF_LEN) seen<=seen+1'b1;
                expected_valid <= (seen>=REF_LEN);
                pending<=1;
            end
            if (sample_valid && pending) begin
                pending<=0;
                if (expected_valid) begin
                    ready<=1;
                    if (sample_out != expected) mismatch<=1;
                end
            end
        end
    end
endmodule
