module pin_toggle_top (
    input  wire clk,
    output reg  pin71,
    output reg  pin72
);
    reg [23:0] cnt = 24'd0;

    always @(posedge clk) begin
        cnt   <= cnt + 1'b1;
        pin71 <= cnt[22];
        pin72 <= cnt[21];
    end
endmodule
