`timescale 1ns/1ps
module tb_reverb_tap_probe;
    reg clk=0,rst_n=0,en=0;
    reg [1:0] mode=0,sel=0;
    reg signed [15:0] sample_in=0;
    wire signed [15:0] sample_out;
    wire valid_out;
    integer k,i,sign_case,guard,delay_samples,failures=0;
    always #5 clk=~clk;
    reverb_tap_fx_engine #(.CHORUS_ADDR_W(5),.MEM_ADDR_W(6),.CHORUS_MIN_DLY(4),
        .DELAY_SAMPLES(4),.CLEAR_SAMPLES(64),.REV_LEN0(4),.REV_LEN1(5),
        .REV_LEN2(7),.REV_LEN3(9),.FADE_SAMPLES(0)) dut (
        .clk(clk),.rst_n(rst_n),.sample_en(en),.mode(mode),.probe_sel(sel),
        .sample_in(sample_in),.sample_out(sample_out),.sample_valid_out(valid_out));
    task push;
        input signed [15:0] value;
        begin
            @(negedge clk); sample_in=value; en=1;
            @(negedge clk); en=0; guard=0;
            while (!valid_out && guard<64) begin @(posedge clk); #1; guard=guard+1; end
            if (guard==64) $fatal(1,"timeout");
            repeat(16) @(posedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        for(sign_case=0;sign_case<2;sign_case=sign_case+1)
        for(k=0;k<4;k=k+1) begin
            mode=0;push(0);mode=3;sel=k;push(0);repeat(40) push(0);
            delay_samples=(k==0)?4:(k==1)?5:(k==2)?7:9;
            push(sign_case ? -16'sd3000 : 16'sd3000);
            for(i=1;i<=12;i=i+1) begin
                push(0);
                if (sample_out !== ((i==delay_samples)?(sign_case ? -16'sd375 : 16'sd375):16'sd0)) begin
                    $display("FAIL: tap=%0d sample=%0d out=%0d",k,i,sample_out);
                    failures=failures+1;
                end
            end
        end
        if(failures) $fatal(1,"%0d failures",failures);
        $display("RESULT: ALL PASS");$finish;
    end
endmodule
