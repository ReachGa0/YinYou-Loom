# STM32 I2C slave test

The STM32 acts as an I2C slave at 7-bit address `0x3C`.

| STM32 | FPGA OLED experiment |
|---|---|
| PB6 | FPGA PIN71 / SCL |
| PB7 | FPGA PIN72 / SDA |
| GND | GND |

Disconnect the OLED from SCL/SDA for this test. Keep the FPGA OLED
bitstream running. If the FPGA master is correct, it should see the
STM32 ACK and turn on its LED2.

Debug values:

- `g_addr_seen`: address match count
- `g_addr_code`: matched address register value
- `g_error_count`: HAL I2C error count
