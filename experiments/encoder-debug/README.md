# STM32 EC11 编码器辅助测试

用 STM32 + OLED 直接采样编码器 A/B/C，排除 FPGA 引脚和位流的影响。

## 接线

OLED：

```text
VCC -> 3.3V
GND -> GND
SCL -> PB6
SDA -> PB7
```

编码器：

```text
A -> PA0
B -> PA1
C -> PA2
VCC -> 3.3V
GND -> GND
```

按压开关如果不在 A/B/C 上，先断开两个疑似 `VCC/GND` 引脚的电源，
把其中一个开关端接 PA3，另一个开关端接 STM32 GND。PA3 使用内部上拉，按下时
应读到低电平。

## OLED 显示

从左到右六个方块：

```text
1. A 曾经发生过变化
2. B 曾经发生过变化
3. C 曾经发生过变化
4. A 当前高电平
5. B 当前高电平
6. 按压开关电平（PA3）
```
