// tft_bringup 时序约束：与其它工程一致，只约束板载 27 MHz 输入晶振
create_clock -name clk_27M -period 37.037 -waveform {0 18.518} [get_ports {clk}]
