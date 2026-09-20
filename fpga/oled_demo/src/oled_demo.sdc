// 27MHz 输入时钟约束（周期 37.037ns）
create_clock -name clk_27M -period 37.037 -waveform {0 18.518} [get_ports {clk}]
