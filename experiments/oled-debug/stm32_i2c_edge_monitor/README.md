# STM32 I2C edge monitor

Counts edges on PB6 and PB7 to prove whether the FPGA I2C signals reach
the STM32.

| STM32 | FPGA OLED experiment |
|---|---|
| PB6 | FPGA PIN71 / SCL |
| PB7 | FPGA PIN72 / SDA |
| GND | GND |

Debug values:

- `g_scl_edges`: PB6 edge count
- `g_sda_edges`: PB7 edge count
