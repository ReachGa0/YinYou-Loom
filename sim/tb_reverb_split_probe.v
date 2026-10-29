`timescale 1ns/1ps
module tb_reverb_split_probe;
    reg clk=0,rst_n=0,en=0;
    reg signed [15:0] sample_in=0;
    wire signed [15:0] mixed,dry,wet;
    wire vm,vd,vw;
    integer i,guard,failures=0;
    always #5 clk=~clk;
    `define PARAMS #(.CHORUS_ADDR_W(5),.MEM_ADDR_W(6),.CHORUS_MIN_DLY(4), \
        .DELAY_SAMPLES(4),.CLEAR_SAMPLES(64),.REV_LEN0(4),.REV_LEN1(5), \
        .REV_LEN2(7),.REV_LEN3(9),.FADE_SAMPLES(0))
    reverb_probe_fx_engine `PARAMS m(.clk(clk),.rst_n(rst_n),.sample_en(en),.mode(2'd3),.sample_in(sample_in),.sample_out(mixed),.sample_valid_out(vm));
    reverb_dry_fx_engine `PARAMS d(.clk(clk),.rst_n(rst_n),.sample_en(en),.mode(2'd3),.sample_in(sample_in),.sample_out(dry),.sample_valid_out(vd));
    reverb_wet_fx_engine `PARAMS w(.clk(clk),.rst_n(rst_n),.sample_en(en),.mode(2'd3),.sample_in(sample_in),.sample_out(wet),.sample_valid_out(vw));
    task push;
        input signed [15:0] value;
        begin
            @(negedge clk); sample_in=value; en=1;
            @(negedge clk); en=0;
            guard=0;
            while (!(vm && vd && vw) && guard<64) begin @(posedge clk); #1; guard=guard+1; end
            if (guard==64) $fatal(1,"timeout");
            repeat(16) @(posedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        push(0);repeat(40) push(0);
        for(i=0;i<300;i=i+1) begin
            push((i%32<16)?16'sd12000:-16'sd12000);
            if ($signed(dry)!==($signed(sample_in) >>> 1)) begin
                $display("FAIL: dry at %0d",i);failures=failures+1;
            end
            if (($signed(dry)+$signed(wet)) !== $signed(mixed)) begin
                $display("FAIL: components do not sum at %0d",i);failures=failures+1;
            end
        end
        if(failures) $fatal(1,"%0d failures",failures);
        $display("RESULT: ALL PASS");$finish;
    end
endmodule
