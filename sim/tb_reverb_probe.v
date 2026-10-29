`timescale 1ns/1ps
module tb_reverb_probe;
    reg clk=0, rst_n=0, sample_en=0;
    reg signed [15:0] sample_in=0;
    wire signed [15:0] sample_out;
    wire valid_out;
    integer i, failures=0, guard;
    always #5 clk=~clk;
    reverb_probe_fx_engine #(
        .CHORUS_ADDR_W(5), .CHORUS_MIN_DLY(4), .MEM_ADDR_W(6),
        .DELAY_SAMPLES(4), .CLEAR_SAMPLES(64),
        .REV_LEN0(4), .REV_LEN1(5), .REV_LEN2(7), .REV_LEN3(9), .FADE_SAMPLES(0)
    ) dut(.clk(clk),.rst_n(rst_n),.sample_en(sample_en),.mode(2'd3),
          .sample_in(sample_in),.sample_out(sample_out),.sample_valid_out(valid_out));
    always @(posedge clk) begin
        #1;
        if (dut.ram_we && dut.state >= dut.S_R_W1 && dut.state <= dut.S_R_OUT &&
            dut.ram_wdata !== (dut.dry18 >>> 2)) begin
            $display("FAIL: REVERB write includes feedback"); failures=failures+1;
        end
    end
    task push;
        input signed [15:0] value;
        begin
            @(negedge clk); sample_in=value; sample_en=1;
            @(negedge clk); sample_en=0;
            guard=0;
            while (!valid_out && guard<64) begin @(posedge clk); #1; guard=guard+1; end
            if (!valid_out) begin $display("FAIL: output timeout"); failures=failures+1; end
            repeat(16) @(posedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        push(0); repeat(40) push(0);
        push(3000);
        for (i=1;i<=30;i=i+1) begin
            push(0);
            if (i==4 && sample_out !== 16'sd93) begin
                $display("FAIL: first wet tap not preserved: %0d",sample_out); failures=failures+1;
            end
            if (i>9 && sample_out !== 16'sd0) begin
                $display("FAIL: unexpected tail at %0d: %0d",i,sample_out); failures=failures+1;
            end
        end
        if(failures!=0) $fatal(1,"%0d failures",failures);
        $display("RESULT: ALL PASS"); $finish;
    end
endmodule
