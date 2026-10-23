# STM32 OLED I2C test

Target: STM32F103C8T6 (Blue Pill)

## Wiring

| OLED | STM32 |
|---|---|
| VCC | 3.3V |
| GND | GND |
| SCL | PB6 |
| SDA | PB7 |

Use 3.3V only. Verify module power polarity before connecting.

## Build and upload

From the PlatformIO terminal:

```sh
pio run
pio run -t upload
pio device monitor
```

## LED result

- Startup: three quick blinks, then the result pattern repeats
- Slow blink: 0x3C acknowledged
- Double blink: 0x3D acknowledged
- Fast blink: no OLED ACK
