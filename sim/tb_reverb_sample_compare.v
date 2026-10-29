`timescale 1ns/1ps
module tb_reverb_sample_compare;
    reg clk=0,rst_n=0,en=0,enabled=1,inject_error=0;
    reg signed [15:0] sample_in=0;
    wire signed [15:0] fx_out;
    wire valid,accept,ready,mismatch;
    wire signed [15:0] observed = inject_error ? (fx_out ^ 16'sd1) : fx_out;
    integer i,guard;
    always #5 clk=~clk;
    reverb_compare_fx_engine #(.CHORUS_ADDR_W(5),.MEM_ADDR_W(6),.CHORUS_MIN_DLY(4),
        .DELAY_SAMPLES(4),.CLEAR_SAMPLES(64),.REV_LEN0(4),.REV_LEN1(5),
        .REV_LEN2(7),.REV_LEN3(9),.FADE_SAMPLES(0)) fx (
        .clk(clk),.rst_n(rst_n),.sample_en(en),.mode(2'd3),.probe_sel(2'd0),
        .sample_in(sample_in),.sample_out(fx_out),.sample_valid_out(valid),.probe_accept(accept));
    reverb_sample_compare #(.REF_LEN(4),.ADDR_W(3)) dut (
        .clk(clk),.rst_n(rst_n),.enabled(enabled),.accept(accept),.sample_in(sample_in),
        .sample_valid(valid),.sample_out(observed),.ready(ready),.mismatch(mismatch));
    task push;
        input signed [15:0] value;
        begin
            @(negedge clk);sample_in=value;en=1;
            @(negedge clk);en=0;guard=0;
            while (!valid && guard<64) begin @(posedge clk);#1;guard=guard+1;end
            if(guard==64) $fatal(1,"timeout");
            repeat(16) @(posedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        push(0); repeat(40) push(0);
        for(i=0;i<100;i=i+1) push(i%2 ? -16'sd23456 : 16'sd12345);
        if(!ready || mismatch) $fatal(1,"reference disagrees with normal output");
        inject_error=1;push(1000);inject_error=0;
        repeat(4) @(negedge clk);
        if(!mismatch) $fatal(1,"single corrupted sample not latched");
        enabled=0;repeat(3) @(negedge clk);
        if(ready || mismatch) $fatal(1,"disable must reset indicators");
        $display("RESULT: ALL PASS");$finish;
    end
endmodule
